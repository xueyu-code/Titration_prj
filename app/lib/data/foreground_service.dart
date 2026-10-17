import 'package:flutter/services.dart';

/// Android foreground service that keeps the app running (BLE, completion
/// detection, notifications) while a titration is in progress with the screen
/// off or the app in the background. Native side: `TitrationService`.
class ForegroundService {
  static const _channel = MethodChannel('titrator/foreground_service');

  /// Starts the service with an ongoing notification, or updates the
  /// notification if it already runs.
  Future<void> start(String title, String text) =>
      _invoke('start', {'title': title, 'text': text});

  /// Stops the service; does nothing if it is not running.
  Future<void> stop() => _invoke('stop');

  /// Best effort: a titration also works without the service as long as the
  /// app stays in the foreground, so a failure is not worth surfacing.
  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // The system refused to start the service.
    } on MissingPluginException {
      // No native side (tests, other platforms).
    }
  }
}
