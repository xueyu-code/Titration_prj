import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/protocol.dart';
import '../data/device_link.dart';
import '../state/providers.dart';
import '../state/scan_controller.dart';
import 'sim_titrator.dart';

/// [DeviceLink] to a [SimTitrator]: same interface and event decoding as the
/// BLE link, with a realistic delay on connecting and writing.
class SimDeviceLink implements DeviceLink {
  SimDeviceLink(this._sim) {
    _sim.onNotify = _onNotify;
  }

  static const _connectDelay = Duration(milliseconds: 600);
  static const _writeDelay = Duration(milliseconds: 30);
  static const _tickInterval = Duration(milliseconds: 100);

  final SimTitrator _sim;

  final _statusController = StreamController<LinkStatus>.broadcast();
  final _eventController = StreamController<DeviceEvent>.broadcast();

  LinkStatus _status = LinkStatus.disconnected;
  Timer? _clock;

  /// The current connect attempt; lets [disconnect] cancel a pending one.
  Object? _attempt;

  @override
  Stream<LinkStatus> get status => _statusController.stream;

  @override
  Stream<DeviceEvent> get events => _eventController.stream;

  @override
  Future<void> connect(String deviceId) async {
    await disconnect();
    final attempt = _attempt = Object();
    _setStatus(LinkStatus.connecting);
    await Future<void>.delayed(_connectDelay);
    if (!identical(_attempt, attempt)) {
      throw const LinkException(LinkFailure.failed);
    }
    _setStatus(LinkStatus.connected);
    _clock = Timer.periodic(_tickInterval, (_) => _sim.tick(_tickInterval));
    _sim.connected();
  }

  @override
  Future<void> send(Command command) async {
    _requireConnected();
    await Future<void>.delayed(_writeDelay);
    _requireConnected();
    _sim.handle(command.encode());
  }

  @override
  Future<void> disconnect() async {
    _attempt = null;
    _clock?.cancel();
    _clock = null;
    _setStatus(LinkStatus.disconnected);
    _sim.disconnected();
  }

  /// Loses the connection without the app asking for it.
  void dropLink() => unawaited(disconnect());

  @override
  void dispose() {
    unawaited(disconnect());
    _statusController.close();
    _eventController.close();
  }

  void _requireConnected() {
    if (_status != LinkStatus.connected) {
      throw const LinkException(LinkFailure.failed, 'not connected');
    }
  }

  void _onNotify(List<int> bytes) {
    final event = DeviceEvent.decode(bytes);
    if (event != null && _status == LinkStatus.connected) {
      _eventController.add(event);
    }
  }

  void _setStatus(LinkStatus status) {
    if (_status == status) return;
    _status = status;
    _statusController.add(status);
  }
}

/// Scan that finds only the simulated titrator.
class SimScanController extends ScanController {
  static const scanTime = Duration(milliseconds: 800);

  static final device = DiscoveredDevice(
    id: 'SIM:00:00:00:00:01',
    name: 'Titrator-SIM',
    serviceData: const {},
    manufacturerData: Uint8List(0),
    rssi: -42,
    serviceUuids: [Uuid.parse(TitratorUuids.service)],
  );

  Timer? _timer;

  @override
  ScanState build() {
    ref.onDispose(() => _timer?.cancel());
    return const ScanState(bleStatus: BleStatus.ready);
  }

  @override
  Future<void> start() async {
    // The real scan asks for this too; completion notifications need it.
    await ref.read(appNotifierProvider).requestPermission();
    if (!ref.mounted) return;
    _timer?.cancel();
    state = state.copyWith(scanning: true, devices: const []);
    _timer = Timer(scanTime, () {
      state = state.copyWith(scanning: false, devices: [device]);
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    if (state.scanning) state = state.copyWith(scanning: false);
  }
}
