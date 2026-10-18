import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/state/device_error_text.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/providers.dart';

import 'fakes.dart';

void main() {
  late FakeDeviceLink link;
  late FakeAppNotifier notifier;
  late FakeForegroundService service;
  late ProviderContainer container;
  late DateTime now;

  final t0 = DateTime(2026, 1, 1, 12);
  final l10n = l10nFor(const Locale('en'));

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

  setUp(() {
    link = FakeDeviceLink();
    notifier = FakeAppNotifier();
    service = FakeForegroundService();
    now = t0;
    container = ProviderContainer(
      overrides: [
        deviceLinkProvider.overrideWithValue(link),
        appNotifierProvider.overrideWithValue(notifier),
        foregroundServiceProvider.overrideWithValue(service),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
    // Pin the language: the default follows the system.
    container.read(localeProvider.notifier).select(const Locale('en'));
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
      expect(state().calibration, isNull);
    });

    test('disconnect forgets the device', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await reading(7.0, 1);
      await controller().disconnect();
      expect(state().deviceId, isNull);
      expect(state().link, LinkStatus.disconnected);
      expect(state().ph, isNull);
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

      // The titration is over: late readings must not complete anything.
      expect(notifier.shown, hasLength(1)); // the interruption
      await controller().reconnect();
      await mode(DeviceMode.titrating);
      for (var s = 2.0; s <= 10; s++) {
        await reading(7.0, s);
      }
      expect(notifier.shown, hasLength(1));
      expect(state().completion, isNull);
    });
  });

  group('readings', () {
    test('are exposed', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await reading(6.98, 1);
      expect(state().ph, 6.98);
      expect(state().recent.single.ph, 6.98);
      expect(state().recent.single.time, t0.add(const Duration(seconds: 1)));
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
    });

    /// Minutes (after t0) of the readings kept.
    List<int> keptMinutes() => [
      for (final s in state().recent) s.time.difference(t0).inMinutes,
    ];

    test('recent keeps a running titration whole', () async {
      await titrating(); // starts at t0
      for (final minute in [0, 4, 9, 20, 30]) {
        await reading(7.5, minute * 60.0);
      }
      expect(keptMinutes(), [0, 4, 9, 20, 30]);
    });

    test('recent keeps the finished titration until the cap', () async {
      await titrating();
      await reading(7.0, 0);
      await reading(7.0, 5); // completes
      expect(state().target, isNull);
      for (final minute in [10, 30, 60]) {
        await reading(7.0, minute * 60.0);
      }
      expect(keptMinutes(), [0, 0, 10, 30, 60]);

      // Never more than 60 minutes, whatever the start was.
      await reading(7.0, 61 * 60.0);
      expect(keptMinutes(), [10, 30, 60, 61]);
    });

    test('recent still has the 5 minutes before the titration', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await reading(7.0, 0);
      await reading(7.0, 8 * 60.0);
      expect(keptMinutes(), [8]);

      await controller().startTitration(7.0); // started at minute 8
      await reading(7.0, 10 * 60.0);
      expect(keptMinutes(), [8, 10]);
      await reading(7.0, 14 * 60.0);
      expect(keptMinutes(), [8, 10, 14]);
    });

    test('a fresh connection starts the window over', () async {
      await titrating();
      await reading(7.0, 0);
      await controller().connect('CC:DD', 'Titrator-2');
      await reading(7.0, 0);
      await reading(7.0, 6 * 60.0);
      expect(keptMinutes(), [6]);
    });
  });

  group('calibration', () {
    test('is unknown until the device reports it', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      expect(state().calibration, isNull);
    });

    test('is kept, replaced by a new report and kept after a drop', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      const first = CalApplied(-59.16, 0);
      const second = CalApplied(-57.92, 4.35);

      link.emit(first);
      await settle();
      expect(state().calibration, same(first));

      link.emit(second);
      await settle();
      expect(state().calibration, same(second));

      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(state().calibration, same(second));
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
        expect(state().completion, (
          time: t0.add(const Duration(seconds: 5)),
          target: 7.0,
          ph: 7.01,
        ));
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
      expect(state().completion, isNull);
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
      expect(service.running, isNull);
    });

    test('a start refused by the device clears the target', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await mode(DeviceMode.moving);
      await controller().startTitration(7.0);
      link.emit(const DeviceError('busy'));
      await settle();
      expect(state().target, isNull);
      expect(service.running, isNull);
      expect(notifier.shown, isEmpty, reason: 'the user just tapped start');
    });

    for (final command in const <Command>[
      Jog(Channel.ch1, Direction.dispense),
      Move(Channel.ch2, Direction.aspirate),
    ]) {
      test(
        '${command.toJson()['cmd']} ends the titration in the app',
        () async {
          await titrating();
          await reading(7.0, 0);
          await reading(7.0, 4);

          await controller().send(command);
          expect(state().target, isNull);
          expect(link.sent.last, command.toJson());

          // The device has not reported `moving` yet; readings in the band
          // must not stop the user's motion.
          await reading(7.0, 6);
          await reading(7.0, 12);
          expect(link.sent.where((c) => c['cmd'] == 'stop'), isEmpty);
          expect(notifier.shown, isEmpty);
          expect(state().completion, isNull);

          await mode(DeviceMode.moving);
          expect(state().mode, DeviceMode.moving);
        },
      );
    }

    test('completion survives a failing stop write', () async {
      await titrating();
      link.sendError = const LinkException(LinkFailure.failed);
      await reading(7.0, 0);
      await reading(7.0, 5);
      expect(state().target, isNull);
      expect(notifier.shown, hasLength(1));
    });
  });

  group('foreground service', () {
    /// Ways a titration started by [titrating] can end.
    final endings = <(String, Future<void> Function())>[
      (
        'completion',
        () async {
          await reading(7.0, 0);
          await reading(7.0, 5);
        },
      ),
      ('stop', () => controller().stop()),
      (
        'jog',
        () => controller().send(const Jog(Channel.ch1, Direction.dispense)),
      ),
      (
        'move',
        () => controller().send(const Move(Channel.ch2, Direction.aspirate)),
      ),
      ('the device going idle', () => mode(DeviceMode.idle)),
      (
        'a device error',
        () async {
          link.emit(
            const DeviceError(
              'limit',
              channel: Channel.ch1,
              direction: Direction.dispense,
            ),
          );
          await mode(DeviceMode.idle);
        },
      ),
      (
        'a lost link',
        () async {
          link.emitStatus(LinkStatus.disconnected);
          await settle();
        },
      ),
      ('disconnect', () => controller().disconnect()),
    ];

    for (final (name, end) in endings) {
      test('runs during the titration and stops on $name', () async {
        await controller().connect('AA:BB', 'Titrator-1');
        expect(service.running, isNull);
        await controller().startTitration(7.0);
        expect(service.running, (l10n.modeTitrating, 'Target pH 7.00'));
        await mode(DeviceMode.titrating);
        expect(service.starts, 1);

        await end();
        expect(service.running, isNull);
        expect(service.stops, 1);

        // Whatever follows finds nothing left to stop.
        await mode(DeviceMode.idle);
        link.emitStatus(LinkStatus.disconnected);
        await settle();
        expect(service.stops, 1);
      });
    }

    test('stops when the start cannot be sent', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      link.sendError = const LinkException(LinkFailure.failed);
      await controller().startTitration(7.0).catchError((_) {});
      expect(service.running, isNull);
      expect(service.stops, 1);
    });

    test('is not touched without a titration', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      await controller().send(const Jog(Channel.ch1, Direction.dispense));
      await controller().stop();
      await controller().disconnect();
      expect(service.starts, 0);
      expect(service.stops, 0);
    });

    test('runs again for the next titration', () async {
      await titrating();
      await controller().stop();
      await mode(DeviceMode.idle);
      await controller().startTitration(6.5);
      expect(service.running, (l10n.modeTitrating, 'Target pH 6.50'));
      expect(service.starts, 2);
    });

    test('shows its text in the selected language', () async {
      container.read(localeProvider.notifier).select(const Locale('zh'));
      await titrating();
      expect(service.running, ('滴定中', '目标 pH 7.00'));
    });
  });

  group('interruptions', () {
    test('a lost link notifies', () async {
      await titrating();
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(notifier.shown, [
        (l10n.titrationAbortedTitle, l10n.titrationLinkLost),
      ]);
    });

    test('notifications follow the selected language', () async {
      container.read(localeProvider.notifier).select(const Locale('zh'));
      await titrating();
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      final zh = l10nFor(const Locale('zh'));
      expect(notifier.shown, [
        (zh.titrationAbortedTitle, zh.titrationLinkLost),
      ]);
      expect(zh.titrationAbortedTitle, '滴定已中断');
    });

    for (final error in const [
      DeviceError('limit', channel: Channel.ch1, direction: Direction.dispense),
      DeviceError(
        'unhomed',
        channel: Channel.ch2,
        direction: Direction.aspirate,
      ),
      DeviceError('sensor'),
      DeviceError('no_converge'),
    ]) {
      test('${error.code} notifies once, with the error text', () async {
        await titrating();
        link.emit(error);
        await settle();
        final text = (l10n.titrationAbortedTitle, deviceErrorText(l10n, error));
        expect(notifier.shown, [text]);

        await mode(DeviceMode.idle); // the device reports idle next
        expect(notifier.shown, [text]);
        expect(state().target, isNull);
      });
    }

    test('errors that leave the titration running stay silent', () async {
      await titrating();
      link.emit(const DeviceError('busy'));
      link.emit(const DeviceError('bad_cmd'));
      await settle();
      expect(notifier.shown, isEmpty);
      expect(state().target, 7.0);
    });

    test('stopping by the user stays silent', () async {
      await titrating();
      await controller().stop();
      await mode(DeviceMode.idle);
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(notifier.shown, isEmpty);
    });

    for (final command in const <Command>[
      Jog(Channel.ch1, Direction.aspirate),
      Move(Channel.ch1, Direction.aspirate),
    ]) {
      test('${command.toJson()['cmd']} stays silent', () async {
        await titrating();
        await controller().send(command);
        await mode(DeviceMode.moving);
        // The device may refuse the motion; that is not a titration problem.
        link.emit(
          const DeviceError(
            'unhomed',
            channel: Channel.ch1,
            direction: Direction.aspirate,
          ),
        );
        await mode(DeviceMode.idle);
        link.emitStatus(LinkStatus.disconnected);
        await settle();
        expect(notifier.shown, isEmpty);
      });
    }

    test('disconnecting by the user stays silent', () async {
      await titrating();
      await controller().disconnect();
      await settle();
      expect(notifier.shown, isEmpty);
    });

    test('a drop without a titration stays silent', () async {
      await controller().connect('AA:BB', 'Titrator-1');
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(notifier.shown, isEmpty);
    });

    test('a completed titration is not an interruption', () async {
      await titrating();
      await reading(7.0, 0);
      await reading(7.0, 5);
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(notifier.shown, hasLength(1)); // the completion only
    });
  });

  test('send forwards raw commands', () async {
    await controller().connect('AA:BB', 'Titrator-1');
    await controller().send(const Jog(Channel.ch1, Direction.dispense));
    expect(link.sent.single, {'cmd': 'jog', 'ch': 1, 'dir': 'out'});
  });

  test('moving without a titration leaves the state alone', () async {
    await controller().connect('AA:BB', 'Titrator-1');
    var changes = 0;
    container.listen(deviceProvider, (_, _) => changes++);
    await controller().send(const Jog(Channel.ch1, Direction.dispense));
    await controller().send(const Move(Channel.ch1, Direction.aspirate));
    expect(changes, 0, reason: 'a held jog sends every 300 ms');
  });
}
