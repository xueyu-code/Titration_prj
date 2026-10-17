import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications (flutter_local_notifications).
class AppNotifier {
  static const _channel = AndroidNotificationChannel(
    'titration',
    'Titration',
    importance: Importance.high,
  );
  static const _notificationId = 1;

  final _plugin = FlutterLocalNotificationsPlugin();

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Initializes the plugin and the Android channel. Call once before runApp.
  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _android?.createNotificationChannel(_channel);
  }

  /// Asks for POST_NOTIFICATIONS on Android 13+.
  Future<void> requestPermission() async {
    await _android?.requestNotificationsPermission();
  }

  Future<void> show(String title, String body) => _plugin.show(
    id: _notificationId,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
