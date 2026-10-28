import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'notify.dart';

const serverUrl = 'wss://secure-chat-1-w3ax.onrender.com'; // host taken from your log; change if needed

// Logging helper. Filter in terminal:  flutter logs -d <device> | grep '^I/flutter'
// Never logs message text, keys or photos. Only event names, short IDs (6 chars) and sizes.
void L(String tag, String msg) => debugPrint('[$tag] $msg');
String _s(String id) => id.length > 6 ? id.substring(0, 6) : id;

String _e(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _d(String s) => base64Url.decode(base64Url.normalize(s));
int _now() => DateTime.now().millisecondsSinceEpoch;
String _rid() => _e(List.generate(9, (_) => Random.secure().nextInt(256)));

class Msg {
  String id, text; bool mine, acked, read; int ts; // read: mine = they opened the chat, theirs = I sent a read receipt
  Msg(this.id, this.text, this.mine, this.ts, {this.acked = false, this.read = false});
  Map toJson() => {'id': id, 'text': text, 'mine': mine, 'ts': ts, 'acked': acked, 'read': read};
  factory Msg.fromJson(Map j) => Msg(j['id'], j['text'], j['mine'], j['ts'], acked: j['acked'], read: j['read'] ?? false);
}

class Contact {
  String id, name; String? avatar; bool sentAny, gotAny; int lastPres; List<Msg> msgs;
  Contact(this.id, this.name, {this.avatar, this.sentAny = false, this.gotAny = false, this.lastPres = 0, List<Msg>? msgs})
      : msgs = msgs ?? [];
  bool get established => sentAny && gotAny;
  bool get online => _now() - lastPres < 45000;
  Map toJson() => {'id': id, 'name': name, 'avatar': avatar, 'sentAny': sentAny, 'gotAny': gotAny, 'lastPres': lastPres, 'msgs': msgs};
  factory Contact.fromJson(Map j) => Contact(j['id'], j['name'], avatar: j['avatar'], sentAny: j['sentAny'], gotAny: j['gotAny'], lastPres: j['lastPres'] ?? 0,
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
  String? openPeer; // chat currently on screen (and app in foreground)
  late SharedPreferences prefs; WebSocketChannel? ws; bool _retrying = false; int _attempt = 0;
  final x = X25519(); final aes = AesGcm.with256bits();

  Future<void> init() async {
    L('INIT', 'start');
    prefs = await SharedPreferences.getInstance();
    L('INIT', 'prefs loaded');
    const ss = FlutterSecureStorage();
    String? seed;
    try { seed = await ss.read(key: 'seed'); }
    catch (e) { L('INIT', 'secure storage READ FAILED: $e'); }
    if (seed == null) {
      L('INIT', 'no key found, generating new identity');
      seed = _e(List.generate(32, (_) => Random.secure().nextInt(256)));
      try { await ss.write(key: 'seed', value: seed); L('INIT', 'key saved'); }
      catch (e) { L('INIT', 'secure storage WRITE FAILED (identity will change on restart!): $e'); }
    } else { L('INIT', 'existing key loaded'); }
    kp = await x.newKeyPairFromSeed(_d(seed));
    myId = _e((await kp.extractPublicKey()).bytes);
    L('INIT', 'my id starts with ${_s(myId)}, length ${myId.length}');
    myName = prefs.getString('name') ?? 'Me';
    myAvatar = prefs.getString('avatar');
    final raw = prefs.getString('contacts');
    if (raw != null) {
      try {
        for (final c in jsonDecode(raw)) {
          try { final k = Contact.fromJson(c); contacts[k.id] = k; }
          catch (e) { L('INIT', 'bad contact record skipped: $e'); }
        }
      } catch (e) { L('INIT', 'contacts JSON corrupt: $e'); }
    }
    L('INIT', 'loaded ${contacts.length} contacts');
    incoming.addListener(() { if (incoming.value == null) Notif.cancel(1); });
    _connect();
    Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    L('INIT', 'done');
  }

  Future<void> _connect() async {
    _retrying = false; _attempt++;
    L('NET', 'connecting (attempt $_attempt) to $serverUrl');
    try {
      final ch = WebSocketChannel.connect(Uri.parse(serverUrl));
      await ch.ready; // throws if host unreachable / DNS fails / server asleep
      ws = ch;
      ch.sink.add(jsonEncode({'reg': myId}));
      L('NET', 'connected and registered');
      _attempt = 0;
      ch.stream.listen(_recv,
          onDone: () { L('NET', 'socket closed by server/network (code ${ch.closeCode})'); _reconnect(); },
          onError: (e) { L('NET', 'socket error: $e'); _reconnect(); });
      _tick();
    } catch (e) {
      L('NET', 'connect FAILED: $e');
      _reconnect();
    }
  }

  void _reconnect() {
    if (_retrying) return;
    _retrying = true; ws = null;
    final wait = min(3 + _attempt * 2, 30);
    L('NET', 'retry in ${wait}s');
    notifyListeners();
    Future.delayed(Duration(seconds: wait), _connect);
  }

  void _tick() {
    if (ws == null) L('TICK', 'offline, keeping unsent messages for later');
    int resent = 0;
    for (final c in contacts.values) {
      for (final m in c.msgs) {
        if (m.mine && !m.acked && _now() - m.ts < 86400000) {
          resent++; _send(c.id, {'k': 'msg', 'id': m.id, 't': m.text, 'ts': m.ts});
        }
      }
      if (c.established) _send(c.id, {'k': 'pres'});
    }
    if (resent > 0) L('TICK', 'resending $resent unconfirmed messages');
    notifyListeners();
  }

  Future<SecretKey> _key(String peer) async {
    final s = await x.sharedSecretKey(keyPair: kp, remotePublicKey: SimplePublicKey(_d(peer), type: KeyPairType.x25519));
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: s, nonce: utf8.encode('p2pchat-v1'));
  }

  Future<void> _send(String to, Map inner) async {
    final k = inner['k'];
    try {
      final box = await aes.encrypt(utf8.encode(jsonEncode(inner)), secretKey: await _key(to));
      if (ws == null) { if (k != 'pres') L('SEND', 'DROPPED $k to ${_s(to)}: no connection'); return; }
      final out = jsonEncode({'to': to, 'p': _e(box.concatenation())});
      ws!.sink.add(out);
      if (k != 'pres') L('SEND', '$k -> ${_s(to)} (${out.length} bytes)');
    } catch (e) { L('SEND', 'FAILED $k to ${_s(to)}: $e'); }
  }
  void signal(String to, Map d) { L('SIG', 'out ${d['t']} -> ${_s(to)}'); _send(to, {'k': 'sig', ...d}); }

  Future<void> _recv(dynamic raw) async {
    Map m;
    try { m = jsonDecode(raw as String); } catch (e) { L('RECV', 'bad packet from server: $e'); return; }
    final from = m['from']; final p = m['p'];
    if (from is! String || p is! String) { L('RECV', 'packet missing from/p, ignored'); return; }
    Map d;
    try {
      final box = SecretBox.fromConcatenation(_d(p), nonceLength: 12, macLength: 16);
      d = jsonDecode(utf8.decode(await aes.decrypt(box, secretKey: await _key(from))));
    } catch (e) { L('RECV', 'DECRYPT FAILED from ${_s(from)} (wrong key / tampered / invalid id): $e'); return; }
    final isNew = !contacts.containsKey(from);
    final c = contacts.putIfAbsent(from, () => Contact(from, _s(from)));
    final k = d['k'];
    c.lastPres = _now(); // any packet from them = last seen
    if (k != 'pres') L('RECV', '$k <- ${_s(from)}${isNew ? ' (new unknown contact)' : ''}');
    if (k == 'msg') {
      if (c.msgs.any((x) => x.id == d['id'])) { L('RECV', 'duplicate message ignored'); }
      else { c.msgs.add(Msg(d['id'], d['t'], false, d['ts'])); c.gotAny = true; L('RECV', 'message stored, established=${c.established}');
        if (!(Notif.foreground && openPeer == from)) Notif.show(from.hashCode & 0x7fffffff, c.name, showPreview ? '${d['t']}' : 'New message'); }
      _sync(c);
    } else if (c.established) {
      if (k == 'ack') { for (final x in c.msgs) { if (x.id == d['id']) { x.acked = true; L('RECV', 'message delivered'); } } }
      else if (k == 'pres') { }
      else if (k == 'read') { for (final x in c.msgs) { if (x.mine && (d['ids'] as List).contains(x.id)) { x.acked = true; x.read = true; } } L('RECV', 'messages seen by ${_s(from)}'); }
      else if (k == 'prof') { c.avatar = d['a']; L('RECV', 'profile photo updated (${(d['a'] as String?)?.length ?? 0} chars)'); }
      else if (k == 'sig') { _sig(from, d); }
      else { L('RECV', 'unknown kind "$k" ignored'); }
    } else { L('RECV', 'IGNORED $k from ${_s(from)}: not established yet (you both must send a message first)'); }
    _save(); notifyListeners();
  }

  void _sync(Contact c) {
    if (!c.established) return;
    L('SYNC', 'established with ${_s(c.id)}: sending acks, photo, presence');
    for (final m in c.msgs) { if (!m.mine && !m.acked) { m.acked = true; _send(c.id, {'k': 'ack', 'id': m.id}); } }
    _send(c.id, {'k': 'prof', 'a': myAvatar});
    _send(c.id, {'k': 'pres'});
    if (openPeer == c.id) markRead(c);
  }

  // Tell them I have seen their messages (blue ticks). Only after both sides have spoken.
  void markRead(Contact c) {
    if (!c.established) return;
    final ids = [for (final m in c.msgs) if (!m.mine && !m.read) m.id];
    if (ids.isEmpty) return;
    for (final m in c.msgs) { if (!m.mine) m.read = true; }
    L('READ', 'sending read receipt for ${ids.length} messages to ${_s(c.id)}');
    _send(c.id, {'k': 'read', 'ids': ids}); _save();
  }

  void _sig(String from, Map d) {
    final t = d['t'];
    L('SIG', 'in $t <- ${_s(from)}');
    if (t == 'offer') { iceBuf[from] = []; incoming.value = {'from': from, 'offer': d}; L('SIG', 'incoming call, video=${d['v']}');
      if (!Notif.foreground) Notif.show(1, contacts[from]?.name ?? 'Call', 'Incoming ${d['v'] == true ? 'video' : 'voice'} call', call: true); }
    else if (t == 'ice') { if (iceBuf[from] != null) { iceBuf[from]!.add(d); L('SIG', 'ice buffered (${iceBuf[from]!.length}) until call accepted'); } }
    else if (t == 'bye' && incoming.value?['from'] == from) { incoming.value = null; iceBuf.remove(from); L('SIG', 'caller hung up before answer'); }
    sigs.add({'from': from, ...d});
  }

  void sendText(Contact c, String t) {
    final m = Msg(_rid(), t, true, _now());
    c.msgs.add(m); c.sentAny = true;
    L('CHAT', 'sending message to ${_s(c.id)} (${t.length} chars), established=${c.established}, online socket=${ws != null}');
    _send(c.id, {'k': 'msg', 'id': m.id, 't': t, 'ts': m.ts});
    _sync(c); _save(); notifyListeners();
  }

  bool addContact(String id, String name) {
    id = id.trim();
    if (id.length != 43) { L('CONTACT', 'rejected: ID length ${id.length}, expected 43'); return false; }
    if (id == myId) { L('CONTACT', 'rejected: that is your own ID'); return false; }
    try { _d(id); } catch (e) { L('CONTACT', 'rejected: ID is not valid base64url: $e'); return false; }
    contacts.putIfAbsent(id, () => Contact(id, name.isEmpty ? _s(id) : name));
    L('CONTACT', 'added ${_s(id)}');
    _save(); notifyListeners(); return true;
  }

  void setProfile(String n, String? a) {
    myName = n; myAvatar = a;
    L('PROFILE', 'saved name, photo=${a == null ? 'none' : '${a.length} chars'}');
    prefs.setString('name', n);
    a == null ? prefs.remove('avatar') : prefs.setString('avatar', a);
    for (final c in contacts.values) { if (c.established) _send(c.id, {'k': 'prof', 'a': a}); }
    notifyListeners();
  }

  void _save() {
    try { prefs.setString('contacts', jsonEncode(contacts.values.toList())); }
    catch (e) { L('SAVE', 'FAILED to save contacts: $e'); }
  }
  void rename(Contact c, String n) { c.name = n; L('CONTACT', 'renamed ${_s(c.id)}'); _save(); notifyListeners(); }
}