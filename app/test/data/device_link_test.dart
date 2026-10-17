import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';

final _service = Uuid.parse(TitratorUuids.service);

class FakeService implements Service {
  FakeService(this.id);

  @override
  final Uuid id;

  @override
  String get deviceId => 'dev';

  @override
  List<Characteristic> get characteristics => const [];
}

/// Only the calls DeviceLink makes are implemented.
class FakeBle implements FlutterReactiveBle {
  /// One entry per connectToDevice call; the last is the current connection.
  final connections = <StreamController<ConnectionStateUpdate>>[];
  final notifications = StreamController<List<int>>.broadcast();
  final writes = <(QualifiedCharacteristic, List<int>)>[];

  var services = [_service];
  int? requestedMtu;

  /// MTU the fake device grants; null grants what was requested.
  int? grantedMtu;
  bool mtuFails = false;
  Object? writeError;
  int cancelledConnections = 0;

  StreamController<ConnectionStateUpdate> get connection => connections.last;

  void update(DeviceConnectionState state) => connection.add(
    ConnectionStateUpdate(
      deviceId: 'dev',
      connectionState: state,
      failure: null,
    ),
  );

  @override
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    final controller = StreamController<ConnectionStateUpdate>(
      onCancel: () => cancelledConnections++,
    );
    connections.add(controller);
    return controller.stream;
  }

  @override
  Future<int> requestMtu({required String deviceId, required int mtu}) async {
    requestedMtu = mtu;
    if (mtuFails) throw Exception('mtu');
    return grantedMtu ?? mtu;
  }

  @override
  Future<void> discoverAllServices(String deviceId) async {}

  @override
  Future<List<Service>> getDiscoveredServices(String deviceId) async => [
    for (final id in services) FakeService(id),
  ];

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) => notifications.stream;

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) async {
    if (writeError case final error?) throw error;
    writes.add((characteristic, value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeBle ble;
  late DeviceLink link;
  late List<LinkStatus> statuses;
  late List<DeviceEvent> events;

  setUp(() {
    ble = FakeBle();
    link = DeviceLink(ble);
    statuses = [];
    events = [];
    link.status.listen(statuses.add);
    link.events.listen(events.add);
    addTearDown(link.dispose);
  });

  /// Starts connecting and lets the fake device report `connected`.
  Future<void> connected() async {
    final future = link.connect('dev');
    await settle();
    ble.update(DeviceConnectionState.connected);
    await future;
    await settle();
  }

  test('connect: negotiates MTU, subscribes, then reports connected', () async {
    await connected();
    expect(statuses, [LinkStatus.connecting, LinkStatus.connected]);
    expect(ble.requestedMtu, 247);

    ble.notifications.add(utf8.encode('{"evt":"ph","v":6.98}'));
    ble.notifications.add(utf8.encode('garbage'));
    ble.notifications.add(utf8.encode('{"evt":"state","s":"idle"}'));
    await settle();
    expect(events, [isA<PhReading>(), isA<ModeChanged>()]);
  });

  group('connect: MTU', () {
    /// Connecting fails with [LinkFailure.failed] and leaves nothing open.
    Future<void> expectRejected() async {
      final future = link.connect('dev');
      final result = expectLater(
        future,
        throwsA(
          isA<LinkException>().having(
            (e) => e.reason,
            'reason',
            LinkFailure.failed,
          ),
        ),
      );
      await settle();
      ble.update(DeviceConnectionState.connected);
      await result;
      await settle();
      expect(statuses.last, LinkStatus.disconnected);
      expect(ble.cancelledConnections, 1);
    }

    test('103 bytes is enough', () async {
      ble.grantedMtu = 103;
      await connected();
      expect(statuses.last, LinkStatus.connected);
    });

    test('less than 103 bytes fails the connection', () async {
      ble.grantedMtu = 102;
      await expectRejected();
    });

    test('a failing MTU request fails the connection', () async {
      ble.mtuFails = true;
      await expectRejected();
    });
  });

  test('connect: a device without the titrator service is rejected', () async {
    ble.services = [Uuid.parse('0000180f-0000-1000-8000-00805f9b34fb')];
    final future = link.connect('dev');
    final result = expectLater(
      future,
      throwsA(
        isA<LinkException>().having(
          (e) => e.reason,
          'reason',
          LinkFailure.notTitrator,
        ),
      ),
    );
    await settle();
    ble.update(DeviceConnectionState.connected);
    await result;
    await settle();
    expect(statuses.last, LinkStatus.disconnected);
    expect(ble.cancelledConnections, 1);
  });

  test('connect: dropping before ready fails', () async {
    final future = link.connect('dev');
    final result = expectLater(
      future,
      throwsA(
        isA<LinkException>().having(
          (e) => e.reason,
          'reason',
          LinkFailure.failed,
        ),
      ),
    );
    await settle();
    ble.update(DeviceConnectionState.disconnected);
    await result;
    expect(statuses, [LinkStatus.connecting, LinkStatus.disconnected]);
  });

  test('connect: gives up after 15 s', () async {
    final async = FakeAsync();
    Object? error;
    async.run((_) {
      link.connect('dev').catchError((Object e) => error = e);
    });
    async.flushMicrotasks(); // the 15 s clock starts after the first await
    async.elapse(const Duration(seconds: 14));
    expect(error, isNull);
    async.elapse(const Duration(seconds: 2));
    // Stream cancellation completes in the real zone.
    await settle();
    async.flushMicrotasks();
    expect(
      error,
      isA<LinkException>().having(
        (e) => e.reason,
        'reason',
        LinkFailure.timeout,
      ),
    );
    expect(statuses.last, LinkStatus.disconnected);
    expect(ble.cancelledConnections, 1);
  });

  test('connect: a newer attempt supersedes a pending one', () async {
    final first = link.connect('dev');
    final firstResult = expectLater(first, throwsA(isA<LinkException>()));
    await settle();
    final second = link.connect('dev');
    await settle();
    await firstResult;

    ble.update(DeviceConnectionState.connected); // answers the second attempt
    await second;
    await settle();
    expect(ble.connections, hasLength(2));
    expect(statuses.last, LinkStatus.connected);
  });

  test('an unexpected drop emits disconnected', () async {
    await connected();
    ble.update(DeviceConnectionState.disconnected);
    await settle();
    expect(statuses.last, LinkStatus.disconnected);
    expect(ble.cancelledConnections, 1);
    await expectLater(
      link.send(const StopAll()),
      throwsA(isA<LinkException>()),
    );
  });

  test('a connection stream error is a drop too', () async {
    await connected();
    ble.connection.addError(Exception('boom'));
    await settle();
    expect(statuses.last, LinkStatus.disconnected);
  });

  test('send writes the encoded command to the CMD characteristic', () async {
    await connected();
    await link.send(const StartTitration(7));
    final (characteristic, value) = ble.writes.single;
    expect(characteristic.deviceId, 'dev');
    expect(characteristic.serviceId, _service);
    expect(characteristic.characteristicId, Uuid.parse(TitratorUuids.command));
    expect(jsonDecode(utf8.decode(value)), {'cmd': 'titrate', 'target': 7.0});
  });

  test('send fails when not connected or when the write fails', () async {
    await expectLater(
      link.send(const StopAll()),
      throwsA(isA<LinkException>()),
    );
    await connected();
    ble.writeError = Exception('gatt');
    await expectLater(
      link.send(const StopAll()),
      throwsA(
        isA<LinkException>().having((e) => e.detail, 'detail', isException),
      ),
    );
  });

  test('disconnect cancels the connection and reports once', () async {
    await connected();
    await link.disconnect();
    await link.disconnect();
    await settle();
    expect(statuses.last, LinkStatus.disconnected);
    expect(statuses.where((s) => s == LinkStatus.disconnected), hasLength(1));
    expect(ble.cancelledConnections, 1);
  });

  test('reconnecting replaces the previous connection', () async {
    await connected();
    final future = link.connect('dev');
    await settle();
    expect(ble.cancelledConnections, 1);
    ble.update(DeviceConnectionState.connected);
    await future;
    await settle();
    expect(statuses.last, LinkStatus.connected);
  });
}
