import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/protocol.dart';

enum LinkStatus { disconnected, connecting, connected }

enum LinkFailure { timeout, notTitrator, failed }

class LinkException implements Exception {
  const LinkException(this.reason, [this.detail]);
  final LinkFailure reason;
  final Object? detail;

  @override
  String toString() => 'LinkException($reason, $detail)';
}

/// BLE transport to one titrator at a time. Tests fake it with `implements`.
///
/// Every connection step, command and notification goes to [log], by default
/// logcat (release builds too): `adb logcat -s flutter`, lines start with
/// `titrator:`.
class DeviceLink {
  DeviceLink(this._ble, {void Function(String line)? log})
    : _log = log ?? _logcat;

  final FlutterReactiveBle _ble;
  final void Function(String line) _log;

  static void _logcat(String line) => debugPrint('titrator: $line');

  static final _service = Uuid.parse(TitratorUuids.service);
  static final _command = Uuid.parse(TitratorUuids.command);
  static final _event = Uuid.parse(TitratorUuids.event);
  static const _linkTimeout = Duration(seconds: 10);
  static const _setupTimeout = Duration(seconds: 15);
  static const _mtu = 247;

  /// Messages are at most 100 B (protocol §1) plus the 3 B ATT header.
  static const _minMtu = 103;

  final _statusController = StreamController<LinkStatus>.broadcast();
  final _eventController = StreamController<DeviceEvent>.broadcast();

  LinkStatus _status = LinkStatus.disconnected;
  String? _deviceId;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _notify;

  /// The current connect attempt, from [connect] until [disconnect]. Lets a
  /// superseded attempt notice that it is no longer the current one.
  Completer<void>? _attempt;

  /// Status changes (broadcast). An unexpected drop emits [LinkStatus.disconnected].
  Stream<LinkStatus> get status => _statusController.stream;

  /// Decoded EVT notifications of the current connection (broadcast).
  Stream<DeviceEvent> get events => _eventController.stream;

  /// Connects, requests MTU 247 (a result too small for protocol messages
  /// fails the connection), verifies the titrator service exists and
  /// subscribes to EVT. Completes when ready; throws [LinkException].
  /// The first notification afterwards triggers a [Sync], whose answer brings
  /// the mode and the calibration.
  Future<void> connect(String deviceId) async {
    await disconnect();
    final attempt = _attempt = Completer<void>();
    _deviceId = deviceId;
    _log('connect $deviceId');
    _setStatus(LinkStatus.connecting);
    try {
      await _open(deviceId, attempt).timeout(_setupTimeout);
    } catch (e) {
      _log('connect failed: $e');
      if (identical(_attempt, attempt)) await disconnect();
      throw switch (e) {
        LinkException() => e,
        TimeoutException() => const LinkException(LinkFailure.timeout),
        _ => LinkException(LinkFailure.failed, e),
      };
    }
  }

  /// Writes one command to CMD (with response). Throws [LinkException] when
  /// not connected or the write fails.
  Future<void> send(Command command) async {
    final id = _deviceId;
    if (_status != LinkStatus.connected || id == null) {
      throw const LinkException(LinkFailure.failed, 'not connected');
    }
    final bytes = command.encode();
    _log('tx ${utf8.decode(bytes)}');
    try {
      await _ble.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
          serviceId: _service,
          characteristicId: _command,
          deviceId: id,
        ),
        value: bytes,
      );
    } catch (e) {
      _log('tx failed: $e');
      throw LinkException(LinkFailure.failed, e);
    }
  }

  Future<void> disconnect() async {
    final attempt = _attempt;
    final connection = _connection;
    final notify = _notify;
    _attempt = _connection = _notify = null;
    if (connection != null) _log('disconnect');
    if (attempt != null && !attempt.isCompleted) {
      attempt.completeError(const LinkException(LinkFailure.failed));
    }
    _setStatus(LinkStatus.disconnected);
    // Cancelling the connection subscription disconnects the device.
    await Future.wait([?notify?.cancel(), ?connection?.cancel()]);
  }

  void dispose() {
    unawaited(disconnect());
    _statusController.close();
    _eventController.close();
  }

  Future<void> _open(String id, Completer<void> attempt) async {
    _connection = _ble
        .connectToDevice(id: id, connectionTimeout: _linkTimeout)
        .listen((update) {
          switch (update.connectionState) {
            case DeviceConnectionState.connected:
              if (!attempt.isCompleted) attempt.complete();
            case DeviceConnectionState.disconnected:
              _lost(attempt, update.failure);
            case DeviceConnectionState.connecting ||
                DeviceConnectionState.disconnecting:
          }
        }, onError: (Object e) => _lost(attempt, e));
    await attempt.future;

    final mtu = await _ble.requestMtu(deviceId: id, mtu: _mtu);
    _log('MTU $mtu');
    if (mtu < _minMtu) throw LinkException(LinkFailure.failed, 'MTU $mtu');
    await _ble.discoverAllServices(id);
    final services = await _ble.getDiscoveredServices(id);

    // Nothing below awaits, so no other attempt can interleave.
    if (!identical(_attempt, attempt)) {
      throw const LinkException(LinkFailure.failed);
    }
    if (!services.any((s) => s.id == _service)) {
      throw const LinkException(LinkFailure.notTitrator);
    }
    var synced = false;
    _notify = _ble
        .subscribeToCharacteristic(
          QualifiedCharacteristic(
            serviceId: _service,
            characteristicId: _event,
            deviceId: id,
          ),
        )
        .listen((bytes) {
          _log('rx ${utf8.decode(bytes, allowMalformed: true)}');
          // The `state` and `cal` the device sends on subscribe arrive before
          // Android and the plugin are ready for them and get dropped. The
          // first notification shows the path is up (nothing else does), so
          // ask again now (protocol section 1).
          if (!synced) {
            synced = true;
            unawaited(send(const Sync()).catchError((Object _) {}));
          }
          final event = DeviceEvent.decode(bytes);
          if (event != null) _eventController.add(event);
        }, onError: (Object e) => _lost(attempt, e));
    _log('subscribed');
    _setStatus(LinkStatus.connected);
  }

  /// The connection ended: fails a pending connect, otherwise it is a drop.
  void _lost(Completer<void> attempt, Object? cause) {
    _log(cause == null ? 'lost' : 'lost: $cause');
    if (!attempt.isCompleted) {
      attempt.completeError(LinkException(LinkFailure.failed, cause));
    } else if (identical(_attempt, attempt)) {
      unawaited(disconnect());
    }
  }

  void _setStatus(LinkStatus status) {
    if (_status == status) return;
    _status = status;
    _statusController.add(status);
  }
}
