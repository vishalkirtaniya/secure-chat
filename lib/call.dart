import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'core.dart';

class CallScreen extends StatefulWidget {
  final String peer; final bool video; final Map? offer; // offer == null -> we are calling
  const CallScreen(this.peer, this.video, {this.offer, super.key});
  @override State<CallScreen> createState() => _CallState();
}

class _CallState extends State<CallScreen> {
  final s = Svc.i; final lr = RTCVideoRenderer(), rr = RTCVideoRenderer();
  RTCPeerConnection? pc; MediaStream? local; StreamSubscription? sub;
  final ready = Completer<void>(); bool muted = false, camOff = false, ended = false;

  @override void initState() { super.initState(); sub = s.sigs.stream.listen(_onSig); _start(); }

  Future<void> _start() async {
    await lr.initialize(); await rr.initialize();
    local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': widget.video ? {'facingMode': 'user'} : false});
    lr.srcObject = local;
    pc = await createPeerConnection({'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]}); // add your own TURN for strict NATs
    for (final t in local!.getTracks()) { await pc!.addTrack(t, local!); }
    pc!.onIceCandidate = (c) => s.signal(widget.peer, {'t': 'ice', 'c': c.toMap()});
    pc!.onTrack = (e) { if (e.streams.isNotEmpty && mounted) setState(() => rr.srcObject = e.streams[0]); };
    pc!.onConnectionState = (st) { if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) _end(); };
    if (widget.offer == null) {
      final o = await pc!.createOffer(); await pc!.setLocalDescription(o);
      s.signal(widget.peer, {'t': 'offer', 'sdp': o.sdp, 'type': o.type, 'v': widget.video});
    } else {
      await pc!.setRemoteDescription(RTCSessionDescription(widget.offer!['sdp'], widget.offer!['type']));
      final a = await pc!.createAnswer(); await pc!.setLocalDescription(a);
      s.signal(widget.peer, {'t': 'answer', 'sdp': a.sdp, 'type': a.type});
      ready.complete();
      for (final d in s.iceBuf.remove(widget.peer) ?? <Map>[]) { _ice(d); }
    }
  }

  Future<void> _onSig(Map d) async {
    if (d['from'] != widget.peer) return;
    if (d['t'] == 'answer') {
      await pc?.setRemoteDescription(RTCSessionDescription(d['sdp'], d['type']));
      if (!ready.isCompleted) ready.complete();
    } else if (d['t'] == 'ice') { await _ice(d); }
    else if (d['t'] == 'bye') { _end(false); }
  }

  Future<void> _ice(Map d) async {
    await ready.future; final c = d['c'];
    await pc?.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
  }

  void _end([bool notify = true]) {
    if (ended) return; ended = true;
    if (notify) s.signal(widget.peer, {'t': 'bye'});
    if (mounted) Navigator.of(context).pop();
  }

  @override void dispose() {
    sub?.cancel(); local?.getTracks().forEach((t) => t.stop()); pc?.close(); lr.dispose(); rr.dispose(); super.dispose();
  }

  @override Widget build(BuildContext context) {
    final c = s.contacts[widget.peer]!;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: widget.video ? RTCVideoView(rr, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            : Center(child: Text(c.name, style: const TextStyle(color: Colors.white, fontSize: 28)))),
        if (widget.video) Positioned(top: 48, right: 16, width: 110, height: 160,
            child: RTCVideoView(lr, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
        Positioned(bottom: 48, left: 0, right: 0, child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton.filled(onPressed: () { muted = !muted; local?.getAudioTracks().forEach((t) => t.enabled = !muted); setState(() {}); },
              icon: Icon(muted ? Icons.mic_off : Icons.mic)),
          IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), onPressed: _end, icon: const Icon(Icons.call_end)),
          if (widget.video) IconButton.filled(onPressed: () { camOff = !camOff; local?.getVideoTracks().forEach((t) => t.enabled = !camOff); setState(() {}); },
              icon: Icon(camOff ? Icons.videocam_off : Icons.videocam)),
        ])),
      ]),
    );
  }
}
