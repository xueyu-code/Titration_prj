import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/providers.dart';

import 'fakes.dart';

void main() {
  late FakeDeviceLink link;
  late FakeSampleStore store;
  late FakeAppNotifier notifier;
  late ProviderContainer container;
  late DateTime now;

  final t0 = DateTime(2026, 1, 1, 12);

  DeviceController controller() => container.read(deviceProvider.notifier);
  DeviceState state() => container.read(deviceProvider);

  /// Delivers a pH reading at [seconds] after t0.
  Future<void> reading(double ph, double seconds) async {
    now = t0.add(Duration(milliseconds: (seconds * 1000).round()));
    link.emit(PhReading(ph));
    await settle();
  }

  Future<void> mode(DeviceMode m) async {
    link.emit(ModeChanged(m));
    await settle();
  }

  /// Connected and titrating towards 7.00.
  Future<void> titrating() async {
    await controller().connect('AA:BB', 'Titrator-1');
    await controller().startTitration(7.0);
    await mode(DeviceMode.titrating);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'locale': 'en'});
    link = FakeDeviceLink();
    store = FakeSampleStore();
    notifier = FakeAppNotifier();
    now = t0;
    container = ProviderContainer(
      overrides: [
        deviceLinkProvider.overrideWithValue(link),
        sampleStoreProvider.overrideWithValue(store),
        appNotifierProvider.overrideWithValue(notifier),
        clockProvider.overrideWithValue(() => now),
        prefsProvider.overrideWithValue(await SharedPreferences.getInstance()),
      ],
    );
    addTearDown(container.dispose);
    container.read(deviceProvider); // build: subscribes to the link
  });

  group('connection', () {
    test('connect succeeds', () async {
      final future = controller().connect('AA:BB', 'Titrator-1');
      expect(state().link, LinkStatus.connecting);
      await future;
      expect(state().connected, isTrue);
      expect(state().deviceId, 'AA:BB');
      expect(state().deviceName, 'Titrator-1');
    });

    test('failed connect keeps the device and rethrows', () async {
      link.connectError = const LinkException(LinkFailure.timeout);
      await expectLater(
        controller().connect('AA:BB', 'Titrator-1'),
        throwsA(isA<LinkException>()),
      );
      expect(state().link, LinkStatus.disconnected);
      expect(state().deviceId, 'AA:BB');
    });

    test('reconnect reuses the last device', () async {
      link.connectError = const LinkException(LinkFailure.failed);
      await controller().connect('AA:BB', 'Titrator-1').catchError((_) {});
      link.connectError = null;
      await controller().reconnect();
      expect(state().connected, isTrue);
      expect(state().deviceName, 'Titrator-1');
    });

    test('connecting to a device starts from a fresh state', () async {
      await titrating();
      await reading(6.5, 1);
      await controller().connect('CC:DD', 'Titrator-2');
      expect(state().ph, isNull);
      expect(state().recent, isEmpty);
      expect(state().target, isNull);
    });

    test('disconnect forgets the device and flushes the store', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await reading(7.0, 1);
      await controller().disconnect();
      expect(state().deviceId, isNull);
      expect(state().link, LinkStatus.disconnected);
      expect(state().ph, isNull);
      expect(store.flushes, greaterThan(0));
    });

    test('an unexpected drop keeps the device and its readings', () async {
      await titrating();
      await reading(6.5, 1);

      link.emitStatus(LinkStatus.disconnected);
      await settle();

      expect(state().link, LinkStatus.disconnected);
      expect(state().deviceId, 'AA:BB');
      expect(state().deviceName, 'Titrator-1');
      expect(state().ph, 6.5);
      expect(state().recent, hasLength(1));
      expect(state().mode, DeviceMode.unknown);
      expect(state().target, isNull);
      expect(store.flushes, 1);

      // The titration is over: late readings must not complete anything.
      await controller().reconnect();
      await mode(DeviceMode.titrating);
      for (var s = 2.0; s <= 10; s++) {
        await reading(7.0, s);
      }
      expect(notifier.shown, isEmpty);
    });
  });

  group('readings', () {
    test('are stored and exposed', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await reading(6.98, 1);
      expect(state().ph, 6.98);
      expect(store.added.single.ph, 6.98);
      expect(store.added.single.time, t0.add(const Duration(seconds: 1)));
    });

    test('recent keeps only the live window', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      for (var minute = 0; minute <= 6; minute++) {
        await reading(7.0 + minute, minute * 60.0);
      }
      // At minute 6 the cutoff is minute 1, which is still inside.
      expect(state().recent.map((s) => s.ph), [
        8.0,
        9.0,
        10.0,
        11.0,
        12.0,
        13.0,
      ]);
      expect(store.added, hasLength(7), reason: 'all readings are persisted');
    });
  });

  group('titration', () {
    test(
      'completes after 5 s in band: stop, one notification, state',
      () async {
        await titrating();
        expect(link.sent.last, {'cmd': 'titrate', 'target': 7.0});

        await reading(7.02, 0);
        await reading(6.99, 2.5);
        await reading(7.0, 4.9);
        expect(state().target, 7.0);
        expect(link.sent, hasLength(1));

        await reading(7.01, 5);
        expect(state().target, isNull);
        expect(state().completedAt, t0.add(const Duration(seconds: 5)));
        expect(link.sent.last, {'cmd': 'stop'});
        final l10n = l10nFor(const Locale('en'));
        expect(notifier.shown, [
          (l10n.titrationDoneTitle, l10n.titrationDoneBody('7.00', '7.01')),
        ]);

        // Further in-band readings (before the device reports idle) do nothing.
        await reading(7.0, 6);
        await reading(7.0, 12);
        expect(notifier.shown, hasLength(1));
        expect(link.sent.where((c) => c['cmd'] == 'stop'), hasLength(1));
      },
    );

    test('an out-of-band reading restarts the hold', () async {
      await titrating();
      await reading(7.0, 0);
      await reading(7.0, 4);
      await reading(7.3, 4.5);
      await reading(7.0, 5);
      await reading(7.0, 9.9);
      expect(state().target, 7.0);
      expect(notifier.shown, isEmpty);

      await reading(7.0, 10);
      expect(state().target, isNull);
      expect(notifier.shown, hasLength(1));
    });

    test('readings only count while the device is titrating', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await controller().startTitration(7.0); // device has not answered yet
      await reading(7.0, 0);
      await reading(7.0, 6);
      expect(notifier.shown, isEmpty);
      expect(state().target, 7.0);
    });

    test('the device stopping by itself clears the target silently', () async {
      await titrating();
      await reading(6.0, 0);
      await mode(DeviceMode.idle);
      expect(state().target, isNull);
      expect(state().mode, DeviceMode.idle);

      for (var s = 1.0; s <= 10; s++) {
        await reading(7.0, s);
      }
      expect(notifier.shown, isEmpty);
      expect(state().completedAt, isNull);
      expect(link.sent, hasLength(1), reason: 'only the start command');
    });

    test('stop clears the target and sends stop', () async {
      await titrating();
      await controller().stop();
      expect(state().target, isNull);
      expect(link.sent.last, {'cmd': 'stop'});
      await reading(7.0, 0);
      await reading(7.0, 6);
      expect(notifier.shown, isEmpty);
    });

    test('a failed start clears the target and rethrows', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      link.sendError = const LinkException(LinkFailure.failed);
      await expectLater(
        controller().startTitration(7.0),
        throwsA(isA<LinkException>()),
      );
      expect(state().target, isNull);
    });

    test('completion survives a failing stop write', () async {
      await titrating();
      link.sendError = const LinkException(LinkFailure.failed);
      await reading(7.0, 0);
      await reading(7.0, 5);
      expect(state().target, isNull);
      expect(notifier.shown, hasLength(1));
    });
  });

  test('send forwards raw commands', () async {
    await controller().connect('AA:BB', 'Titrator-1');
    await controller().send(const Jog(Channel.ch1, Direction.dispense));
    expect(link.sent.single, {'cmd': 'jog', 'ch': 1, 'dir': 'out'});
  });
}
