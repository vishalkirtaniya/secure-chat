import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'call.dart';
import 'core.dart';
import 'notify.dart';

const wa = Color(0xFF00A884);
bool dk(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color grey(BuildContext c) => dk(c) ? const Color(0xFF8696A0) : const Color(0xFF667781);

ThemeData th(Brightness b) {
  final d = b == Brightness.dark;
  return ThemeData(
    useMaterial3: true, brightness: b, colorSchemeSeed: wa,
    scaffoldBackgroundColor: d ? const Color(0xFF0B141A) : Colors.white,
    appBarTheme: AppBarTheme(
      backgroundColor: d ? const Color(0xFF1F2C34) : const Color(0xFF008069),
      foregroundColor: Colors.white, iconTheme: const IconThemeData(color: Colors.white),
      titleTextStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: wa, foregroundColor: Colors.white),
  );
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) => L('FLUTTER', 'UI error: ${d.exceptionAsString()}');
    L('APP', 'starting');
    try { await Notif.init(); await Svc.i.init(); L('APP', 'service ready'); }
    catch (e, st) { L('APP', 'INIT FAILED: $e\n$st'); }
    runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: th(Brightness.light), darkTheme: th(Brightness.dark), themeMode: ThemeMode.system, home: const Home()));
  }, (e, st) => L('ZONE', 'UNHANDLED: $e\n$st'));
}

Widget avatar(String name, String? a, [double r = 20]) {
  ImageProvider? img;
  if (a != null) { try { img = MemoryImage(base64Decode(a)); } catch (e) { L('UI', 'bad avatar data: $e'); } }
  return CircleAvatar(radius: r, backgroundColor: const Color(0xFF6B7C85), foregroundColor: Colors.white,
      backgroundImage: img, child: img == null ? Icon(Icons.person, size: r * 1.2) : null);
}

String hm(BuildContext c, int ts) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ts)).format(c);
String dayLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts), n = DateTime.now();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  return days == 0 ? 'Today' : days == 1 ? 'Yesterday' : '${d.day}/${d.month}/${d.year}';
}
// clock = waiting (no reply yet), one tick = sent, two ticks = delivered
// blue double tick = they opened the chat and saw it
Widget tick(Msg m, bool est, Color c) => Icon(!est ? Icons.schedule : (m.acked || m.read) ? Icons.done_all : Icons.done, size: 15, color: m.read && est ? const Color(0xFF53BDEB) : c);

String lastSeen(BuildContext c, Contact k) {
  if (k.online) return 'online';
  if (k.lastPres == 0) return 'offline';
  final d = dayLabel(k.lastPres);
  return 'last seen ${d == 'Today' ? 'today' : d == 'Yesterday' ? 'yesterday' : d} at ${hm(c, k.lastPres)}';
}

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }
class _HomeState extends State<Home> {
  bool ringing = false;
  @override void initState() { super.initState(); Svc.i.incoming.addListener(_ring); }

  void _ring() {
    final v = Svc.i.incoming.value;
    if (v == null) { if (ringing) { ringing = false; L('UI', 'closing ring dialog'); Navigator.of(context).pop(); } return; }
    if (ringing) return;
    ringing = true;
    final c = Svc.i.contacts[v['from']]; final offer = v['offer'] as Map;
    if (c == null) { ringing = false; return; }
    L('UI', 'showing incoming call from ${c.name}');
    showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(
      icon: avatar(c.name, c.avatar, 32),
      title: Text(c.name), content: Text('Incoming ${offer['v'] == true ? 'video' : 'voice'} call', textAlign: TextAlign.center),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), iconSize: 30,
          onPressed: () { L('UI', 'call DECLINED'); Svc.i.signal(c.id, {'t': 'bye'}); Svc.i.iceBuf.remove(c.id); Svc.i.incoming.value = null; },
          icon: const Icon(Icons.call_end)),
        IconButton.filled(style: IconButton.styleFrom(backgroundColor: wa), iconSize: 30,
          onPressed: () {
            L('UI', 'call ACCEPTED');
            Svc.i.incoming.value = null;
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallScreen(c.id, offer['v'] == true, offer: offer)));
          }, icon: Icon(offer['v'] == true ? Icons.videocam : Icons.call)),
      ]));
  }

  void _add() {
    final id = TextEditingController(), nm = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(title: const Text('New contact'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: nm, decoration: const InputDecoration(labelText: 'Name')),
      TextField(controller: id, decoration: const InputDecoration(labelText: 'Their ID')),
    ]), actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(style: FilledButton.styleFrom(backgroundColor: wa), onPressed: () {
        if (Svc.i.addContact(id.text, nm.text)) { Navigator.pop(context); }
        else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid ID (43 characters, not your own)'))); }
      }, child: const Text('Save'))]));
  }

  void _profile() {
    final nm = TextEditingController(text: Svc.i.myName);
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(onTap: () async {
          try {
            final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 200, imageQuality: 60);
            if (f == null) return;
            final bytes = await f.readAsBytes(); L('UI', 'photo picked: ${bytes.length} bytes');
            Svc.i.setProfile(nm.text, base64Encode(bytes)); if (mounted) Navigator.pop(context);
          } catch (e) { L('UI', 'photo pick FAILED: $e'); }
        }, child: avatar(Svc.i.myName, Svc.i.myAvatar, 48)),
        const SizedBox(height: 4), Text('Tap photo to change', style: TextStyle(color: grey(context), fontSize: 12)),
        TextField(controller: nm, decoration: const InputDecoration(labelText: 'Your name')),
        const SizedBox(height: 12),
        SelectableText('Your ID\n${Svc.i.myId}', style: TextStyle(color: grey(context))),
        Row(children: [
          TextButton.icon(icon: const Icon(Icons.copy, size: 18), onPressed: () { Clipboard.setData(ClipboardData(text: Svc.i.myId)); L('UI', 'ID copied'); }, label: const Text('Copy ID')),
          const Spacer(),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: wa), onPressed: () { Svc.i.setProfile(nm.text, Svc.i.myAvatar); Navigator.pop(context); }, child: const Text('Save')),
        ]),
      ])));
  }

  @override Widget build(BuildContext context) => AnimatedBuilder(animation: Svc.i, builder: (_, __) {
    final list = Svc.i.contacts.values.toList()..sort((a, b) => (b.msgs.isEmpty ? 0 : b.msgs.last.ts).compareTo(a.msgs.isEmpty ? 0 : a.msgs.last.ts));
    return Scaffold(
      appBar: AppBar(title: const Text('Private Chat'), actions: [
        Icon(Svc.i.ws == null ? Icons.cloud_off : Icons.lock, size: 18),
        IconButton(icon: const Icon(Icons.account_circle_outlined), onPressed: _profile)]),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.person_add_alt_1)),
      body: list.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 48, color: grey(context)), const SizedBox(height: 12),
              Text('Nothing here yet.\nTap the button and add a contact using their ID.\nEverything stays on your phone, end-to-end encrypted.', textAlign: TextAlign.center, style: TextStyle(color: grey(context)))])))
          : ListView(children: [
              for (final c in list) Builder(builder: (_) {
                final last = c.msgs.isEmpty ? null : c.msgs.last;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: avatar(c.name, c.established ? c.avatar : null, 26),
                  title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                  subtitle: last == null ? null : Row(children: [
                    if (last.mine) Padding(padding: const EdgeInsets.only(right: 4), child: tick(last, c.established, grey(context))),
                    Expanded(child: Text(last.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: grey(context))))]),
                  trailing: last == null ? null : Text(dayLabel(last.ts) == 'Today' ? hm(context, last.ts) : dayLabel(last.ts), style: TextStyle(fontSize: 12, color: grey(context))),
                  onTap: () { L('UI', 'open chat ${c.id.substring(0, 6)}'); Navigator.push(context, MaterialPageRoute(builder: (_) => Chat(c))); },
                  onLongPress: () { final t = TextEditingController(text: c.name);
                    showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Rename'), content: TextField(controller: t),
                      actions: [TextButton(onPressed: () { Svc.i.rename(c, t.text); Navigator.pop(context); }, child: const Text('Save'))])); });
              }),
            ]));
  });
}

class Chat extends StatefulWidget {
  final Contact c; const Chat(this.c, {super.key});
  @override State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> with WidgetsBindingObserver {
  Contact get c => widget.c;
  final t = TextEditingController();
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    Svc.i.openPeer = c.id; Svc.i.markRead(c);
  }
  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) { Svc.i.openPeer = c.id; Svc.i.markRead(c); } else { Svc.i.openPeer = null; }
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Svc.i.openPeer == c.id) Svc.i.openPeer = null;
    t.dispose(); super.dispose();
  }
  void _call(BuildContext ctx, bool v) {
    L('UI', 'start ${v ? 'video' : 'voice'} call to ${c.id.substring(0, 6)}');
    Navigator.push(ctx, MaterialPageRoute(builder: (_) => CallScreen(c.id, v)));
  }
  void _send() { if (t.text.trim().isEmpty) return; Svc.i.sendText(c, t.text.trim()); t.clear(); }

  @override Widget build(BuildContext context) => AnimatedBuilder(animation: Svc.i, builder: (_, __) {
    final d = dk(context), e = c.established, ms = c.msgs;
    final card = d ? const Color(0xFF1F2C34) : Colors.white;
    final txt = d ? const Color(0xFFE9EDEF) : Colors.black87;
    return Scaffold(
      backgroundColor: d ? const Color(0xFF0B141A) : const Color(0xFFEFEAE2),
      appBar: AppBar(titleSpacing: 0,
        title: Row(children: [avatar(c.name, e ? c.avatar : null, 18), const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            if (e) Text(lastSeen(context, c), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70))]))]),
        actions: [
          IconButton(icon: const Icon(Icons.videocam), onPressed: e ? () => _call(context, true) : null),
          IconButton(icon: const Icon(Icons.call), onPressed: e ? () => _call(context, false) : null),
        ]),
      body: Column(children: [
        Expanded(child: ListView.builder(reverse: true, padding: const EdgeInsets.fromLTRB(10, 4, 10, 8), itemCount: ms.length + 1, itemBuilder: (_, i) {
          if (i == ms.length) {
            return Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 10), padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: d ? const Color(0xFF1F2C34) : const Color(0xFFFFF3C4), borderRadius: BorderRadius.circular(8)),
              child: Text(e ? '🔒 Messages and calls are end-to-end encrypted.' : '🔒 End-to-end encrypted. Delivery ticks, online status, photo and calls unlock after they reply.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: txt))));
          }
          final m = ms[ms.length - 1 - i];
          final prev = ms.length - 2 - i >= 0 ? ms[ms.length - 2 - i] : null;
          final first = prev == null || prev.mine != m.mine;
          final newDay = prev == null || dayLabel(prev.ts) != dayLabel(m.ts);
          final bg = m.mine ? (d ? const Color(0xFF005C4B) : const Color(0xFFD9FDD3)) : card;
          const r = Radius.circular(12);
          final bubble = Align(
            alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
              child: Container(margin: EdgeInsets.only(top: first ? 6 : 2), padding: const EdgeInsets.fromLTRB(9, 6, 8, 5),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.only(
                  topLeft: !m.mine && first ? Radius.zero : r, topRight: m.mine && first ? Radius.zero : r, bottomLeft: r, bottomRight: r)),
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Flexible(child: Text(m.text, style: TextStyle(fontSize: 16, color: txt))),
                  const SizedBox(width: 8),
                  Text(hm(context, m.ts), style: TextStyle(fontSize: 11, color: grey(context))),
                  if (m.mine) Padding(padding: const EdgeInsets.only(left: 3), child: tick(m, e, grey(context))),
                ]))));
          if (!newDay) return bubble;
          return Column(children: [
            Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(8)),
              child: Text(dayLabel(m.ts), style: TextStyle(fontSize: 12, color: grey(context))))),
            bubble]);
        })),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(6, 4, 6, 6), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(24)),
            child: TextField(controller: t, minLines: 1, maxLines: 5, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Message', border: InputBorder.none)))),
          const SizedBox(width: 6),
          CircleAvatar(radius: 24, backgroundColor: wa, child: IconButton(icon: const Icon(Icons.send, color: Colors.white), onPressed: _send)),
        ]))),
      ]));
  });
}