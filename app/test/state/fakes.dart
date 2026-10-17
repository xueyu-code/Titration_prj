import 'dart:async';

import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/app_notifier.dart';
import 'package:titrator_app/data/device_link.dart';

/// Lets queued stream events and microtasks run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

class FakeDeviceLink implements DeviceLink {
  final _status = StreamController<LinkStatus>.broadcast();
  final _events = StreamController<DeviceEvent>.broadcast();

  /// Commands passed to [send], as wire JSON.
  final sent = <Map<String, Object>>[];

  Object? connectError;
  Object? sendError;

  @override
  Stream<LinkStatus> get status => _status.stream;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  void emit(DeviceEvent event) => _events.add(event);

  void emitStatus(LinkStatus status) => _status.add(status);

  @override
  Future<void> connect(String deviceId) async {
    if (connectError case final error?) throw error;
    _status.add(LinkStatus.connected);
  }

  @override
  Future<void> send(Command command) async {
    if (sendError case final error?) throw error;
    sent.add(command.toJson());
  }

  @override
  Future<void> disconnect() async => _status.add(LinkStatus.disconnected);

  @override
  void dispose() {
    _status.close();
    _events.close();
  }
}

class FakeAppNotifier implements AppNotifier {
  /// (title, body) of every notification shown.
  final shown = <(String, String)>[];

  @override
  Future<void> init() async {}

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> show(String title, String body) async =>
      shown.add((title, body));
}
