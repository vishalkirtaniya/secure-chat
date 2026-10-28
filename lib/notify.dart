import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'core.dart' show L;

// false = notification only says "New message" (nothing readable on the lock screen).
const showPreview = false;

class _Obs with WidgetsBindingObserver {
  @override void didChangeAppLifecycleState(AppLifecycleState s) { Notif.foreground = s == AppLifecycleState.resumed; }
}

class Notif {
  static final _p = FlutterLocalNotificationsPlugin();
  static bool foreground = true; // app is on screen

  static Future<void> init() async {
    try {
      WidgetsBinding.instance.addObserver(_Obs());
      await _p.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      final a = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final ok = await a?.requestNotificationsPermission();
      L('NOTIF', 'permission granted: $ok');
      await a?.createNotificationChannel(const AndroidNotificationChannel('msgs', 'Messages', importance: Importance.high));
      await a?.createNotificationChannel(const AndroidNotificationChannel('calls', 'Calls', importance: Importance.max));
      await _keepAlive();
      L('NOTIF', 'ready');
    } catch (e) { L('NOTIF', 'init FAILED: $e'); }
  }

  // A foreground service keeps the app (and its connection to your relay) alive in the background.
  static Future<void> _keepAlive() async {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'keepalive', channelName: 'Connection',
        channelDescription: 'Keeps the private connection open so messages and calls reach you.', onlyAlertOnce: true),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), allowWakeLock: true, allowWifiLock: true),
    );
    if (await FlutterForegroundTask.isRunningService) { L('NOTIF', 'keep-alive already running'); return; }
    final r = await FlutterForegroundTask.startService(
      serviceId: 256, serviceTypes: [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'Private Chat', notificationText: 'Connected. Waiting for messages.', callback: _startCallback);
    L('NOTIF', 'keep-alive start result: $r');
  }

  static Future<void> show(int id, String title, String body, {bool call = false}) async {
    try {
      await _p.show(id: id, title: title, body: body, notificationDetails: NotificationDetails(android: AndroidNotificationDetails(
        call ? 'calls' : 'msgs', call ? 'Calls' : 'Messages',
        importance: call ? Importance.max : Importance.high, priority: Priority.high,
        category: call ? AndroidNotificationCategory.call : AndroidNotificationCategory.message,
        fullScreenIntent: call, autoCancel: !call, timeoutAfter: call ? 45000 : null)));
      L('NOTIF', 'shown: ${call ? 'call' : 'message'}');
    } catch (e) { L('NOTIF', 'show FAILED: $e'); }
  }

  static Future<void> cancel(int id) async { try { await _p.cancel(id: id); } catch (_) {} }
}

@pragma('vm:entry-point')
void _startCallback() { FlutterForegroundTask.setTaskHandler(_Handler()); }

class _Handler extends TaskHandler {
  @override Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override void onRepeatEvent(DateTime timestamp) {}
  @override Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}