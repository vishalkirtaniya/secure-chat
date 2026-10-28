import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'core.dart';
import 'main.dart' show avatar;
import 'secrets.dart';

class CallScreen extends StatefulWidget {
  final String peer; final bool video; final Map? offer; // offer == null -> we are calling
  const CallScreen(this.peer, this.video, {this.offer, super.key});
  @override State<CallScreen> createState() => _CallState();
}

class _CallState extends State<CallScreen> {
  final s = Svc.i; final lr = RTCVideoRenderer(), rr = RTCVideoRenderer();
  RTCPeerConnection? pc; MediaStream? local; StreamSubscription? sub;
  final ready = Completer<void>();
  bool muted = false, camOff = false, ended = false, speaker = true, showUi = true, connected = false;
  final cand = <String, int>{};

  @override void initState() {
    super.initState();
    L('CALL', 'screen opened: ${widget.offer == null ? 'CALLING' : 'ANSWERING'} ${widget.video ? 'video' : 'voice'} with ${widget.peer.substring(0, 6)}');
    sub = s.sigs.stream.listen(_onSig);
    Pip.init(); Pip.inPip.addListener(_pip); if (widget.video) Pip.call(true);
    _start();
  }

  void _pip() { if (mounted) setState(() {}); }

  Future<void> _start() async {
    final msg = ScaffoldMessenger.of(context);
    try {
      await lr.initialize(); await rr.initialize(); L('CALL', 'renderers ready');
      local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': widget.video ? {'facingMode': 'user'} : false});
      L('CALL', 'got mic${widget.video ? '+camera' : ''}: ${local!.getAudioTracks().length} audio, ${local!.getVideoTracks().length} video tracks');
      lr.srcObject = local;
      if (mounted) setState(() {});

      final hasTurn = !turnPass.startsWith('PASTE_');
      final cfg = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:stun.relay.metered.ca:80'},
          if (hasTurn) {'urls': turnUrls, 'username': turnUser, 'credential': turnPass},
        ],
        if (relayOnly) 'iceTransportPolicy': 'relay',
      };
      L('CALL', hasTurn ? 'TURN configured (relayOnly=$relayOnly)' : 'WARNING: TURN password not set, calls over mobile data will likely fail');
      pc = await createPeerConnection(cfg);

      pc!.onIceCandidate = (c) {
        final type = RegExp(r'typ (\w+)').firstMatch(c.candidate ?? '')?.group(1) ?? '?';
        cand[type] = (cand[type] ?? 0) + 1;
        s.signal(widget.peer, {'t': 'ice', 'c': c.toMap()});
      };
      pc!.onIceGatheringState = (st) => L('ICE', 'gathering: $st  candidates so far: $cand');
      pc!.onSignalingState = (st) => L('RTC', 'signaling: $st');
      pc!.onIceConnectionState = (st) {
        L('ICE', 'connection: $st');
        if (st == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          L('ICE', 'FAILED. local candidates $cand. ${(cand['relay'] ?? 0) == 0 ? 'NO relay candidates: TURN missing, wrong URL/credentials, or blocked' : 'relay candidates exist: check the other phone has the same TURN settings'}');
        }
      };
      pc!.onConnectionState = (st) {
        L('RTC', 'connection: $st');
        if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) { L('CALL', 'ending call: connection failed'); _end(); }
        if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected) { L('CALL', 'CONNECTED, media should now flow'); if (mounted) setState(() => connected = true); }
      };
      pc!.onTrack = (e) {
        L('RTC', 'remote track: kind=${e.track.kind}, streams=${e.streams.length}');
        if (e.streams.isNotEmpty && mounted) setState(() => rr.srcObject = e.streams[0]);
      };

      if (widget.offer == null) {
        for (final t in local!.getTracks()) { await pc!.addTrack(t, local!); }
        final o = await pc!.createOffer(); await pc!.setLocalDescription(o);
        L('CALL', 'offer created and sent');
        s.signal(widget.peer, {'t': 'offer', 'sdp': o.sdp, 'type': o.type, 'v': widget.video});
      } else {
        await pc!.setRemoteDescription(RTCSessionDescription(widget.offer!['sdp'], widget.offer!['type']));
        L('CALL', 'remote offer applied');
        for (final t in local!.getTracks()) { await pc!.addTrack(t, local!); }
        final a = await pc!.createAnswer(); await pc!.setLocalDescription(a);
        s.signal(widget.peer, {'t': 'answer', 'sdp': a.sdp, 'type': a.type});
        L('CALL', 'answer created and sent');
        ready.complete();
        final buf = s.iceBuf.remove(widget.peer) ?? <Map>[];
        L('CALL', 'applying ${buf.length} buffered ICE candidates');
        for (final d in buf) { _ice(d); }
      }
      await Helper.setSpeakerphoneOn(speaker);
      L('CALL', 'setup complete, waiting for connection');
    } catch (e, st) {
      L('CALL', 'SETUP FAILED: $e\n$st');
      msg.showSnackBar(SnackBar(content: Text('Call failed: $e')));
      _end();
    }
  }

  Future<void> _onSig(Map d) async {
    if (d['from'] != widget.peer) return;
    try {
      if (d['t'] == 'answer') {
        await pc?.setRemoteDescription(RTCSessionDescription(d['sdp'], d['type']));
        L('CALL', 'remote answer applied');
        if (!ready.isCompleted) ready.complete();
      } else if (d['t'] == 'ice') { await _ice(d); }
      else if (d['t'] == 'bye') { L('CALL', 'other side hung up'); _end(false); }
    } catch (e) { L('CALL', 'signal handling FAILED (${d['t']}): $e'); }
  }

  Future<void> _ice(Map d) async {
    try {
      await ready.future; final c = d['c'];
      await pc?.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
    } catch (e) { L('ICE', 'addCandidate FAILED: $e'); }
  }

  void _end([bool notify = true]) {
    if (ended) return; ended = true;
    L('CALL', 'ending (notify other side: $notify)');
    if (notify) s.signal(widget.peer, {'t': 'bye'});
    if (mounted) Navigator.of(context).pop();
  }

  @override void dispose() {
    L('CALL', 'cleanup');
    Pip.inPip.removeListener(_pip); Pip.call(false);
    sub?.cancel(); local?.getTracks().forEach((t) => t.stop()); pc?.close(); lr.dispose(); rr.dispose(); super.dispose();
  }

  @override Widget build(BuildContext context) {
    final c = s.contacts[widget.peer]!;
    if (Pip.inPip.value) return Scaffold(backgroundColor: Colors.black, body: RTCVideoView(rr, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover));
    final ui = !widget.video || showUi;          // video calls: tap the screen to hide/show controls
    final head = !connected || ui;               // name stays until you hide the UI
    final top = MediaQuery.of(context).padding.top;
    const ms = Duration(milliseconds: 250);
    Widget btn(IconData i, VoidCallback f, {Color bg = const Color(0x33FFFFFF), bool on = false}) => Container(
        decoration: BoxDecoration(color: on ? Colors.white : bg, shape: BoxShape.circle),
        child: IconButton(iconSize: 28, color: on ? Colors.black : Colors.white, onPressed: f, icon: Icon(i)));
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: Stack(children: [
        Positioned.fill(child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.video ? () { setState(() => showUi = !showUi); L('CALL', 'controls visible=$showUi'); } : null,
          child: widget.video
              ? RTCVideoView(rr, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              : Center(child: avatar(c.name, c.avatar, 70)))),
        Positioned(top: 0, left: 0, right: 0, child: IgnorePointer(child: AnimatedOpacity(duration: ms, opacity: head ? 1 : 0,
          child: Container(width: double.infinity,
            decoration: widget.video ? const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent])) : null,
            child: SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.only(top: 16, bottom: 24), child: Column(children: [
              Text(c.name, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
              if (!connected) const Padding(padding: EdgeInsets.only(top: 4), child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.lock, size: 12, color: Colors.white70), SizedBox(width: 4),
                Text('End-to-end encrypted', style: TextStyle(color: Colors.white70, fontSize: 13))])),
            ]))))))),
        if (widget.video) Positioned(top: top + 8, left: 8, child: IgnorePointer(ignoring: !ui, child: AnimatedOpacity(duration: ms, opacity: ui ? 1 : 0,
            child: IconButton(icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white), onPressed: Pip.enter)))),
        if (widget.video) AnimatedPositioned(duration: ms, top: top + (head ? 90 : 12), right: 16, width: 100, height: 150,
            child: ClipRRect(borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(lr, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))),
        Align(alignment: Alignment.bottomCenter, child: IgnorePointer(ignoring: !ui, child: AnimatedSlide(duration: ms, offset: ui ? Offset.zero : const Offset(0, 1),
          child: AnimatedOpacity(duration: ms, opacity: ui ? 1 : 0, child: Container(
            padding: const EdgeInsets.only(top: 18),
            decoration: const BoxDecoration(color: Color(0xFF1F2C34), borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
            child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.only(bottom: 14),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                btn(speaker ? Icons.volume_up : Icons.volume_down, () async { speaker = !speaker; await Helper.setSpeakerphoneOn(speaker); L('CALL', 'speaker=$speaker'); setState(() {}); }, on: speaker),
                if (widget.video) btn(camOff ? Icons.videocam_off : Icons.videocam, () { camOff = !camOff; local?.getVideoTracks().forEach((t) => t.enabled = !camOff); L('CALL', 'camera off=$camOff'); setState(() {}); }, on: camOff),
                btn(muted ? Icons.mic_off : Icons.mic, () { muted = !muted; local?.getAudioTracks().forEach((t) => t.enabled = !muted); L('CALL', 'mute=$muted'); setState(() {}); }, on: muted),
                btn(Icons.call_end, _end, bg: Colors.red),
              ])))))))),
      ]),
    );
  }
}

// Picture-in-picture bridge to MainActivity.kt
class Pip {
  static const _ch = MethodChannel('pip');
  static final inPip = ValueNotifier<bool>(false);
  static bool _ready = false;
  static void init() {
    if (_ready) return; _ready = true;
    _ch.setMethodCallHandler((c) async {
      if (c.method == 'changed') { inPip.value = c.arguments == true; L('PIP', 'picture-in-picture: ${inPip.value}'); }
    });
  }
  static Future<void> call(bool on) async { try { await _ch.invokeMethod('call', on); } catch (e) { L('PIP', 'call($on) failed: $e'); } }
  static Future<void> enter() async { try { await _ch.invokeMethod('enter'); } catch (e) { L('PIP', 'enter failed: $e'); } }
}