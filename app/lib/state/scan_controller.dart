import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/protocol.dart';
import 'providers.dart';

@immutable
class ScanState {
  const ScanState({
    this.bleStatus = BleStatus.unknown,
    this.scanning = false,
    this.devices = const [],
  });

  final BleStatus bleStatus;
  final bool scanning;

  /// Titrators (advertising the titrator service) first, then by RSSI.
  /// Unnamed non-titrator devices are hidden.
  final List<DiscoveredDevice> devices;

  ScanState copyWith({
    BleStatus? bleStatus,
    bool? scanning,
    List<DiscoveredDevice>? devices,
  }) => ScanState(
    bleStatus: bleStatus ?? this.bleStatus,
    scanning: scanning ?? this.scanning,
    devices: devices ?? this.devices,
  );
}

final scanProvider = NotifierProvider.autoDispose<ScanController, ScanState>(
  ScanController.new,
);

class ScanController extends Notifier<ScanState> {
  static const scanDuration = Duration(seconds: 15);
  static final _titratorService = Uuid.parse(TitratorUuids.service);

  final _found = <String, DiscoveredDevice>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  Timer? _timer;

  /// [start] found BLE unusable; scan once it becomes ready.
  bool _pending = false;

  @override
  ScanState build() {
    final ble = ref.read(bleProvider);
    final status = ble.statusStream.listen(_onBleStatus);
    ref.onDispose(() {
      status.cancel();
      _halt();
    });
    return ScanState(bleStatus: ble.status);
  }

  /// Requests runtime permissions, then scans until [stop] or a timeout.
  Future<void> start() async {
    // Results are ignored: BleStatus tells whether scanning can work. On
    // Android 12+ location is not declared and simply stays denied.
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    await ref.read(appNotifierProvider).requestPermission();
    if (!ref.mounted) return;

    // The plugin does not re-check permissions after they are granted, so
    // `unknown` / `unauthorized` may be stale: try scanning, errors stop it.
    final blocked = switch (state.bleStatus) {
      BleStatus.unsupported ||
      BleStatus.poweredOff ||
      BleStatus.locationServicesDisabled => true,
      _ => false,
    };
    if (blocked) {
      _pending = true;
    } else {
      _startScan();
    }
  }

  void stop() {
    _pending = false;
    _halt();
    if (state.scanning) state = state.copyWith(scanning: false);
  }

  static bool isTitrator(DiscoveredDevice device) =>
      device.serviceUuids.contains(_titratorService);

  void _onBleStatus(BleStatus status) {
    final ready = status == BleStatus.ready;
    if (!ready) _halt();
    state = state.copyWith(
      bleStatus: status,
      scanning: ready && state.scanning,
    );
    if (ready && _pending) _startScan();
  }

  void _startScan() {
    _pending = false;
    _halt();
    _found.clear();
    state = state.copyWith(scanning: true, devices: const []);
    _scan = ref
        .read(bleProvider)
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen(_onDevice, onError: (Object _) => stop());
    _timer = Timer(scanDuration, stop);
  }

  void _onDevice(DiscoveredDevice device) {
    _found[device.id] = device;
    final visible =
        _found.values.where((d) => isTitrator(d) || d.name.isNotEmpty).toList()
          ..sort((a, b) {
            final titratorA = isTitrator(a);
            if (titratorA != isTitrator(b)) return titratorA ? -1 : 1;
            return b.rssi.compareTo(a.rssi);
          });
    // Receiving advertisements proves BLE works, whatever a stale status says.
    state = state.copyWith(bleStatus: BleStatus.ready, devices: visible);
  }

  void _halt() {
    _scan?.cancel();
    _scan = null;
    _timer?.cancel();
    _timer = null;
  }
}
