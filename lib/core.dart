import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const serverUrl = 'ws://10.236.145.112:8080';

String _e(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _d(String s) => base64Url.decode(base64Url.normalize(s));
int _now() => DateTime.now().millisecondsSinceEpoch;
String _rid() => _e(List.generate(9, (_) => Random.secure().nextInt(256)));

class Msg {
  String id, text; bool mine, acked; int ts;
  Msg(this.id, this.text, this.mine, this.ts, {this.acked = false});
  Map toJson() => {'id': id, 'text': text, 'mine': mine, 'ts': ts, 'acked': acked};
  factory Msg.fromJson(Map j) => Msg(j['id'], j['text'], j['mine'], j['ts'], acked: j['acked']);
}

class Contact {
  String id, name; String? avatar; bool sentAny, gotAny; int lastPres; List<Msg> msgs;
  Contact(this.id, this.name, {this.avatar, this.sentAny = false, this.gotAny = false, this.lastPres = 0, List<Msg>? msgs})
      : msgs = msgs ?? [];
  // Metrics (online, delivered, photo, calls) unlock only after BOTH sides have sent a message.
  bool get established => sentAny && gotAny;
  bool get online => _now() - lastPres < 45000;
  Map toJson() => {'id': id, 'name': name, 'avatar': avatar, 'sentAny': sentAny, 'gotAny': gotAny, 'msgs': msgs};
  factory Contact.fromJson(Map j) => Contact(j['id'], j['name'], avatar: j['avatar'], sentAny: j['sentAny'], gotAny: j['gotAny'],
      msgs: (j['msgs'] as List).map((e) => Msg.fromJson(e)).toList());
}

class Svc extends ChangeNotifier {
  static final i = Svc._();
  Svc._();
  late SimpleKeyPair kp; late String myId; String myName = 'Me'; String? myAvatar;
  final contacts = <String, Contact>{};
  final sigs = StreamController<Map>.broadcast();
  final iceBuf = <String, List<Map>>{};
  final incoming = ValueNotifier<Map?>(null);
  late SharedPreferences prefs; WebSocketChannel? ws; bool _retrying = false;
  final x = X25519(); final aes = AesGcm.with256bits();

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    const ss = FlutterSecureStorage();
    var seed = await ss.read(key: 'seed');
    if (seed == null) {
      seed = _e(List.generate(32, (_) => Random.secure().nextInt(256)));
      await ss.write(key: 'seed', value: seed);
    }
    kp = await x.newKeyPairFromSeed(_d(seed));
    myId = _e((await kp.extractPublicKey()).bytes); // your ID = your public key
    myName = prefs.getString('name') ?? 'Me';
    myAvatar = prefs.getString('avatar');
    final raw = prefs.getString('contacts');
    if (raw != null) for (final c in jsonDecode(raw)) { final k = Contact.fromJson(c); contacts[k.id] = k; }
    _connect();
    Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  void _connect() {
    _retrying = false;
    try {
      ws = WebSocketChannel.connect(Uri.parse(serverUrl));
      ws!.sink.add(jsonEncode({'reg': myId}));
      ws!.stream.listen((d) => _recv(jsonDecode(d)), onDone: _reconnect, onError: (_) => _reconnect());
      _tick();
    } catch (_) { _reconnect(); }
  }
  void _reconnect() {
    if (_retrying) return;
    _retrying = true; ws = null;
    Future.delayed(const Duration(seconds: 3), _connect);
  }

  // Resend unacked messages (recipient dedupes by id) for 24h; send presence to established contacts.
  void _tick() {
    for (final c in contacts.values) {
      for (final m in c.msgs) {
        if (m.mine && !m.acked && _now() - m.ts < 86400000) _send(c.id, {'k': 'msg', 'id': m.id, 't': m.text, 'ts': m.ts});
      }
      if (c.established) _send(c.id, {'k': 'pres'});
    }
    notifyListeners();
  }

  Future<SecretKey> _key(String peer) async {
    final s = await x.sharedSecretKey(keyPair: kp, remotePublicKey: SimplePublicKey(_d(peer), type: KeyPairType.x25519));
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: s, nonce: utf8.encode('p2pchat-v1'));
  }

  Future<void> _send(String to, Map inner) async {
    try {
      final box = await aes.encrypt(utf8.encode(jsonEncode(inner)), secretKey: await _key(to));
      ws?.sink.add(jsonEncode({'to': to, 'p': _e(box.concatenation())}));
    } catch (_) {}
  }
  void signal(String to, Map d) => _send(to, {'k': 'sig', ...d});

  Future<void> _recv(Map m) async {
    final from = m['from'] as String; Map d;
    try {
      final box = SecretBox.fromConcatenation(_d(m['p']), nonceLength: 12, macLength: 16);
      d = jsonDecode(utf8.decode(await aes.decrypt(box, secretKey: await _key(from))));
    } catch (_) { return; }
    final c = contacts.putIfAbsent(from, () => Contact(from, from.substring(0, 6)));
    final k = d['k'];
    if (k == 'msg') {
      if (!c.msgs.any((x) => x.id == d['id'])) { c.msgs.add(Msg(d['id'], d['t'], false, d['ts'])); c.gotAny = true; }
      _sync(c);
    } else if (c.established) {
      if (k == 'ack') { for (final x in c.msgs) { if (x.id == d['id']) x.acked = true; } }
      else if (k == 'pres') { c.lastPres = _now(); }
      else if (k == 'prof') { c.avatar = d['a']; }
      else if (k == 'sig') { _sig(from, d); }
    }
    _save(); notifyListeners();
  }

  // Once both sides have spoken: ack everything received, share photo + presence.
  void _sync(Contact c) {
    if (!c.established) return;
    for (final m in c.msgs) { if (!m.mine && !m.acked) { m.acked = true; _send(c.id, {'k': 'ack', 'id': m.id}); } }
    _send(c.id, {'k': 'prof', 'a': myAvatar});
    _send(c.id, {'k': 'pres'});
  }

  void _sig(String from, Map d) {
    final t = d['t'];
    if (t == 'offer') { iceBuf[from] = []; incoming.value = {'from': from, 'offer': d}; }
    else if (t == 'ice') { iceBuf[from]?.add(d); }
    else if (t == 'bye' && incoming.value?['from'] == from) { incoming.value = null; iceBuf.remove(from); }
    sigs.add({'from': from, ...d});
  }

  void sendText(Contact c, String t) {
    final m = Msg(_rid(), t, true, _now());
    c.msgs.add(m); c.sentAny = true;
    _send(c.id, {'k': 'msg', 'id': m.id, 't': t, 'ts': m.ts});
    _sync(c); _save(); notifyListeners();
  }

  bool addContact(String id, String name) {
    id = id.trim();
    if (id.length != 43 || id == myId) return false;
    contacts.putIfAbsent(id, () => Contact(id, name.isEmpty ? id.substring(0, 6) : name));
    _save(); notifyListeners(); return true;
  }

  void setProfile(String n, String? a) {
    myName = n; myAvatar = a;
    prefs.setString('name', n);
    a == null ? prefs.remove('avatar') : prefs.setString('avatar', a);
    for (final c in contacts.values) { if (c.established) _send(c.id, {'k': 'prof', 'a': a}); }
    notifyListeners();
  }

  void _save() => prefs.setString('contacts', jsonEncode(contacts.values.toList()));
  void rename(Contact c, String n) { c.name = n; _save(); notifyListeners(); }
}
