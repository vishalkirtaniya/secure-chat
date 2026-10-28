import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'call.dart';
import 'core.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Svc.i.init();
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal), home: const Home()));
}

Widget avatar(String name, String? a, [double r = 20]) => CircleAvatar(radius: r,
    backgroundImage: a == null ? null : MemoryImage(base64Decode(a)), child: a == null ? Text(name.isEmpty ? '?' : name[0].toUpperCase()) : null);

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }
class _HomeState extends State<Home> {
  bool ringing = false;
  @override void initState() { super.initState(); Svc.i.incoming.addListener(_ring); }

  void _ring() {
    final v = Svc.i.incoming.value;
    if (v == null) { if (ringing) { ringing = false; Navigator.of(context).pop(); } return; }
    ringing = true;
    final c = Svc.i.contacts[v['from']]!; final offer = v['offer'] as Map;
    showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(
      title: Text('${offer['v'] == true ? 'Video' : 'Voice'} call from ${c.name}'),
      actions: [
        TextButton(onPressed: () { Svc.i.signal(c.id, {'t': 'bye'}); Svc.i.iceBuf.remove(c.id); Svc.i.incoming.value = null; }, child: const Text('Decline')),
        FilledButton(onPressed: () {
          Svc.i.incoming.value = null;
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallScreen(c.id, offer['v'] == true, offer: offer)));
        }, child: const Text('Accept')),
      ]));
  }

  void _add() {
    final id = TextEditingController(), nm = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Add contact'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: id, decoration: const InputDecoration(labelText: 'Their ID')),
      TextField(controller: nm, decoration: const InputDecoration(labelText: 'Name')),
    ]), actions: [FilledButton(onPressed: () {
      if (Svc.i.addContact(id.text, nm.text)) Navigator.pop(context);
      else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid ID')));
    }, child: const Text('Add'))]));
  }

  void _profile() {
    final nm = TextEditingController(text: Svc.i.myName);
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(onTap: () async {
          final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 200, imageQuality: 60);
          if (f != null) { Svc.i.setProfile(nm.text, base64Encode(await f.readAsBytes())); if (mounted) Navigator.pop(context); }
        }, child: avatar(Svc.i.myName, Svc.i.myAvatar, 40)),
        TextField(controller: nm, decoration: const InputDecoration(labelText: 'Your name')),
        const SizedBox(height: 8),
        SelectableText('Your ID (share this):\n${Svc.i.myId}'),
        Row(children: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: Svc.i.myId)), child: const Text('Copy ID')),
          const Spacer(),
          FilledButton(onPressed: () { Svc.i.setProfile(nm.text, Svc.i.myAvatar); Navigator.pop(context); }, child: const Text('Save')),
        ]),
      ])));
  }

  @override Widget build(BuildContext context) => AnimatedBuilder(animation: Svc.i, builder: (_, __) {
    final list = Svc.i.contacts.values.toList()..sort((a, b) => (b.msgs.isEmpty ? 0 : b.msgs.last.ts).compareTo(a.msgs.isEmpty ? 0 : a.msgs.last.ts));
    return Scaffold(
      appBar: AppBar(title: const Text('Private Chat'), actions: [IconButton(icon: const Icon(Icons.person), onPressed: _profile)]),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.person_add)),
      body: list.isEmpty ? const Center(child: Text('Add a contact using their ID')) : ListView(children: [
        for (final c in list) ListTile(
          leading: avatar(c.name, c.established ? c.avatar : null), // photo hidden until they reply
          title: Text(c.name), subtitle: Text(c.msgs.isEmpty ? '' : c.msgs.last.text, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Chat(c))),
          onLongPress: () { final t = TextEditingController(text: c.name);
            showDialog(context: context, builder: (_) => AlertDialog(content: TextField(controller: t), actions: [TextButton(onPressed: () { Svc.i.rename(c, t.text); Navigator.pop(context); }, child: const Text('Rename'))])); }),
      ]));
  });
}

class Chat extends StatelessWidget {
  final Contact c; Chat(this.c, {super.key});
  final t = TextEditingController();
  void _call(BuildContext ctx, bool v) => Navigator.push(ctx, MaterialPageRoute(builder: (_) => CallScreen(c.id, v)));

  @override Widget build(BuildContext context) => AnimatedBuilder(animation: Svc.i, builder: (_, __) {
    final e = c.established;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [avatar(c.name, e ? c.avatar : null, 16), const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.name), if (e) Text(c.online ? 'online' : 'offline', style: const TextStyle(fontSize: 12))])]),
        actions: [
          IconButton(icon: const Icon(Icons.call), onPressed: e ? () => _call(context, false) : null),
          IconButton(icon: const Icon(Icons.videocam), onPressed: e ? () => _call(context, true) : null),
        ]),
      body: Column(children: [
        Expanded(child: ListView(reverse: true, padding: const EdgeInsets.all(8), children: [
          for (final m in c.msgs.reversed) Align(
            alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(margin: const EdgeInsets.symmetric(vertical: 3), padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: m.mine ? Colors.teal.shade100 : Colors.grey.shade300, borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(m.text)),
                if (m.mine && e) Padding(padding: const EdgeInsets.only(left: 6), child: Text(m.acked ? '✓✓' : '✓', style: const TextStyle(fontSize: 11))),
              ]))),
        ])),
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: TextField(controller: t, decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder()))),
          IconButton(icon: const Icon(Icons.send), onPressed: () { if (t.text.trim().isEmpty) return; Svc.i.sendText(c, t.text.trim()); t.clear(); }),
        ]))),
      ]));
  });
}
