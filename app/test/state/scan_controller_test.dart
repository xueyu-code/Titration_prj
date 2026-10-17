import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/state/scan_controller.dart';

import 'fakes.dart';

class FakeBle implements FlutterReactiveBle {
  FakeBle(this.status);

  @override
  BleStatus status;

  final _statuses = StreamController<BleStatus>.broadcast();
  StreamController<DiscoveredDevice>? scan;
  int scans = 0;
  bool scanning = false;

  @override
  Stream<BleStatus> get statusStream async* {
    yield status;
    yield* _statuses.stream;
  }

  void setStatus(BleStatus s) {
    status = s;
    _statuses.add(s);
  }

  @override
  Stream<DiscoveredDevice> scanForDevices({
    required List<Uuid> withServices,
    ScanMode scanMode = ScanMode.balanced,
    bool requireLocationServicesEnabled = true,
  }) {
    scans++;
    scanning = true;
    return (scan = StreamController<DiscoveredDevice>(
      onCancel: () => scanning = false,
    )).stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DiscoveredDevice device(
  String id,
  String name,
  int rssi, {
  bool titrator = false,
}) => DiscoveredDevice(
  id: id,
  name: name,
  serviceData: const {},
  manufacturerData: Uint8List(0),
  rssi: rssi,
  serviceUuids: [if (titrator) Uuid.parse(TitratorUuids.service)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBle ble;
  late FakeAppNotifier notifier;
  late ProviderContainer container;

  ScanController controller() => container.read(scanProvider.notifier);
  ScanState state() => container.read(scanProvider);

  void create(BleStatus status) {
    ble = FakeBle(status);
    notifier = FakeAppNotifier();
    container = ProviderContainer(
      overrides: [
        bleProvider.overrideWithValue(ble),
        appNotifierProvider.overrideWithValue(notifier),
      ],
    );
    addTearDown(container.dispose);
    container.listen(scanProvider, (_, _) {}); // keep the autoDispose alive
  }

  setUp(() {
    // permission_handler: every permission request is answered with "nothing".
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (call) async => <int, int>{},
        );
  });

  test('exposes the BLE status', () async {
    create(BleStatus.poweredOff);
    await settle();
    expect(state().bleStatus, BleStatus.poweredOff);
    ble.setStatus(BleStatus.ready);
    await settle();
    expect(state().bleStatus, BleStatus.ready);
  });

  test('lists titrators first, then by signal; hides unnamed others', () async {
    create(BleStatus.ready);
    await settle();
    await controller().start();
    expect(state().scanning, isTrue);
    expect(ble.scans, 1);

    ble.scan!
      ..add(device('a', 'Phone', -40))
      ..add(device('b', '', -30))
      ..add(device('c', 'Titrator-1', -80, titrator: true))
      ..add(device('d', 'Watch', -60))
      ..add(device('e', '', -90, titrator: true))
      ..add(device('d', 'Watch', -35)); // same device, newer reading
    await settle();

    expect(state().devices.map((d) => d.id), ['c', 'e', 'd', 'a']);
    expect(ScanController.isTitrator(state().devices.first), isTrue);
    expect(ScanController.isTitrator(state().devices.last), isFalse);
  });

  testWidgets('stops after the scan duration', (tester) async {
    create(BleStatus.ready);
    await tester.pump();
    await controller().start();
    await tester.pump(ScanController.scanDuration - const Duration(seconds: 1));
    expect(state().scanning, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(state().scanning, isFalse);
    expect(ble.scanning, isFalse);
  });

  test('start clears the previous results', () async {
    create(BleStatus.ready);
    await settle();
    await controller().start();
    ble.scan!.add(device('a', 'Phone', -40));
    await settle();
    expect(state().devices, hasLength(1));

    await controller().start();
    expect(ble.scans, 2);
    expect(state().devices, isEmpty);
    expect(state().scanning, isTrue);
  });

  test('a scan error stops scanning', () async {
    create(BleStatus.ready);
    await settle();
    await controller().start();
    ble.scan!.addError(Exception('permission'));
    await settle();
    expect(state().scanning, isFalse);
  });

  test('stop ends the scan', () async {
    create(BleStatus.ready);
    await settle();
    await controller().start();
    controller().stop();
    expect(state().scanning, isFalse);
    expect(ble.scanning, isFalse);
  });

  test('waits for Bluetooth to be switched on, then scans', () async {
    create(BleStatus.poweredOff);
    await settle();
    await controller().start();
    expect(state().scanning, isFalse);
    expect(ble.scans, 0);

    ble.setStatus(BleStatus.ready);
    await settle();
    expect(state().scanning, isTrue);
    expect(ble.scans, 1);
  });

  test(
    'losing Bluetooth mid-scan stops it, regaining does not restart',
    () async {
      create(BleStatus.ready);
      await settle();
      await controller().start();
      ble.setStatus(BleStatus.poweredOff);
      await settle();
      expect(state().scanning, isFalse);
      expect(ble.scanning, isFalse);

      ble.setStatus(BleStatus.ready);
      await settle();
      expect(state().scanning, isFalse);
      expect(ble.scans, 1);
    },
  );

  test('a stale unauthorized status does not block the first scan', () async {
    create(BleStatus.unauthorized);
    await settle();
    await controller().start();
    expect(ble.scans, 1);
    ble.scan!.add(device('c', 'Titrator-1', -50, titrator: true));
    await settle();
    expect(state().bleStatus, BleStatus.ready);
  });

  test('disposing cancels the scan', () async {
    create(BleStatus.ready);
    await settle();
    await controller().start();
    container.dispose();
    expect(ble.scanning, isFalse);
  });
}
