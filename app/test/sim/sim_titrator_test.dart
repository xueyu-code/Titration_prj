import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/completion_detector.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/sim/sim_titrator.dart';

/// Drives a [SimTitrator] in simulated time and records its notifications.
class Rig {
  Rig({int seed = 1}) {
    sim = SimTitrator(onNotify: _record, random: Random(seed));
  }

  static const step = Duration(milliseconds: 100);

  late final SimTitrator sim;

  /// Decoded notifications, and the same as JSON.
  final events = <DeviceEvent>[];
  final raw = <Map<String, Object?>>[];

  /// Simulated time since the start.
  var clock = Duration.zero;

  /// Called for every notification.
  void Function(DeviceEvent event)? onEvent;

  void _record(List<int> bytes) {
    final event = DeviceEvent.decode(bytes)!;
    events.add(event);
    raw.add(jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);
    onEvent?.call(event);
  }

  void send(Command command) => sim.handle(command.encode());

  /// Ticks for [duration], or until [until] holds.
  void run(Duration duration, {bool Function()? until}) {
    final end = clock + duration;
    while (clock < end && !(until?.call() ?? false)) {
      clock += step;
      sim.tick(step);
    }
  }

  /// State changes and errors in order, e.g. `['moving', 'error:limit']`.
  List<String> get log => [
    for (final e in events)
      ?switch (e) {
        ModeChanged(:final mode) => mode.name,
        DeviceError(:final code) => 'error:$code',
        _ => null,
      },
  ];

  List<String> get errors => [
    for (final e in events)
      if (e is DeviceError) e.code,
  ];

  double? get lastPh => events.whereType<PhReading>().lastOrNull?.ph;

  /// Holds a jog on [channel] until the device reports an error.
  void jogUntilError(Channel channel, Direction direction) {
    for (var i = 0; i < 200 && errors.isEmpty; i++) {
      send(Jog(channel, direction));
      run(Jog.refresh, until: () => errors.isNotEmpty);
    }
  }
}

void main() {
  const full = SimTitrator.capacityMl;

  group('titration', () {
    // The app's own completion rule: within 0.05 of the target for 5 s.
    for (final target in [4.0, 7.0, 10.0]) {
      test('converges to pH $target and stops on request', () {
        final rig = Rig();
        final detector = CompletionDetector(target);
        final epoch = DateTime(2026);
        var done = false;
        rig.onEvent = (e) {
          if (e is PhReading) {
            done |= detector.add(epoch.add(rig.clock), e.ph);
          }
        };

        rig.send(StartTitration(target));
        rig.run(const Duration(minutes: 5), until: () => done);
        printOnFailure('pH ${rig.sim.samplePh}, clock ${rig.clock}');
        expect(done, isTrue);

        rig.events.clear();
        rig.send(const StopAll());
        expect(rig.log, ['idle']);
        expect(rig.sim.mode, DeviceMode.idle);
      });
    }

    test('doses base below the target and acid above it', () {
      final base = Rig()..send(const StartTitration(10));
      base.run(const Duration(seconds: 30));
      expect(base.sim.syringeMl(Channel.ch2), lessThan(full));
      expect(base.sim.syringeMl(Channel.ch1), full);

      final acid = Rig()..send(const StartTitration(4));
      acid.run(const Duration(seconds: 30));
      expect(acid.sim.syringeMl(Channel.ch1), lessThan(full));
      expect(acid.sim.syringeMl(Channel.ch2), full);
    });

    test('stops with error limit when the reagent is used up', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch2, Direction.dispense); // empty the base
      rig.sim.newSample(); // at most pH 9, so the target needs base
      rig.events.clear();

      rig.send(const StartTitration(10));
      rig.run(const Duration(seconds: 5));
      expect(rig.log, ['titrating', 'error:limit', 'idle']);
    });
  });

  group('motion', () {
    test('a jog stops by itself when not refreshed', () {
      final rig = Rig()..send(const Jog(Channel.ch1, Direction.dispense));
      expect(rig.log, ['moving']);

      rig.run(const Duration(milliseconds: 900));
      expect(rig.sim.mode, DeviceMode.moving);
      rig.run(const Duration(milliseconds: 200));
      expect(rig.log, ['moving', 'idle']);

      final dispensed = full - rig.sim.syringeMl(Channel.ch1);
      expect(
        dispensed,
        closeTo(
          SimTitrator.pumpMlPerSecond *
              SimTitrator.jogTimeout.inMilliseconds /
              1000,
          1e-9,
        ),
      );
    });

    test('a refreshed jog keeps moving, stop ends it at once', () {
      final rig = Rig();
      for (var i = 0; i < 20; i++) {
        rig.send(const Jog(Channel.ch2, Direction.dispense));
        rig.run(Jog.refresh);
      }
      expect(rig.sim.mode, DeviceMode.moving);
      expect(rig.sim.syringeMl(Channel.ch2), closeTo(full - 3, 0.1));

      rig.send(const StopAll());
      expect(rig.sim.mode, DeviceMode.idle);
      final volume = rig.sim.syringeMl(Channel.ch2);
      rig.run(const Duration(seconds: 2));
      expect(rig.sim.syringeMl(Channel.ch2), volume);
    });

    test('a move dispenses exactly one step', () {
      final rig = Rig()..send(const Move(Channel.ch1, Direction.dispense));
      rig.run(const Duration(seconds: 1));
      expect(rig.log, ['moving', 'idle']);
      expect(
        rig.sim.syringeMl(Channel.ch1),
        closeTo(full - SimTitrator.stepMl, 1e-9),
      );
      expect(rig.sim.syringeMl(Channel.ch2), full);
    });

    test('dispensing changes the sample, aspirating does not', () {
      final rig = Rig();
      rig.send(const Jog(Channel.ch2, Direction.dispense));
      final before = rig.sim.samplePh;
      rig.run(const Duration(seconds: 1));
      expect(rig.sim.samplePh, greaterThan(before));

      final base = rig.sim.samplePh;
      rig.send(const Jog(Channel.ch1, Direction.aspirate));
      rig.run(const Duration(seconds: 1));
      expect(rig.sim.samplePh, base);
      expect(rig.sim.syringeMl(Channel.ch1), full); // was already full
    });

    test('aspirating a full syringe is a limit error', () {
      final rig = Rig()..send(const Move(Channel.ch1, Direction.aspirate));
      expect(rig.log, ['error:limit']);
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('an empty syringe stops the jog with error limit', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch1, Direction.dispense);
      expect(rig.log, ['moving', 'error:limit', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch1), 0);

      rig.events.clear();
      rig.send(const Move(Channel.ch1, Direction.dispense));
      expect(rig.log, ['error:limit']);
    });

    test('aspirating stops at the full limit', () {
      final rig = Rig();
      for (var i = 0; i < 4; i++) {
        rig.send(const Move(Channel.ch2, Direction.dispense));
        rig.run(const Duration(milliseconds: 200));
      }
      rig.events.clear();
      rig.jogUntilError(Channel.ch2, Direction.aspirate);
      expect(rig.log, ['moving', 'error:limit', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch2), full);
    });
  });

  group('commands', () {
    test('busy while titrating, except stop', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.events.clear();
      for (final command in const [
        Move(Channel.ch1, Direction.dispense),
        Jog(Channel.ch1, Direction.dispense),
        StartTitration(5),
        CalStart(),
      ]) {
        rig.send(command);
      }
      expect(rig.log, List.filled(4, 'error:busy'));
      expect(rig.sim.mode, DeviceMode.titrating);

      rig.send(const StopAll());
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('moving accepts move, jog and stop only', () {
      final rig = Rig()..send(const Jog(Channel.ch1, Direction.dispense));
      rig.events.clear();
      rig.send(const StartTitration(7));
      rig.send(const CalStart());
      expect(rig.log, ['error:busy', 'error:busy']);

      rig.send(const Move(Channel.ch2, Direction.dispense));
      rig.send(const Jog(Channel.ch2, Direction.dispense));
      expect(rig.errors, hasLength(2));
      expect(rig.sim.mode, DeviceMode.moving);
    });

    test('calibrating accepts cal_* and stop only', () {
      final rig = Rig()..send(const CalStart());
      rig.events.clear();
      rig.send(const StartTitration(7));
      rig.send(const Move(Channel.ch1, Direction.dispense));
      expect(rig.log, ['error:busy', 'error:busy']);

      rig.send(const StopAll());
      expect(rig.log.last, 'idle');
    });

    test('garbage is bad_cmd in every mode', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.events.clear();
      for (final bytes in [
        [0xff, 0xfe, 0x00],
        utf8.encode('not json'),
        utf8.encode('[1, 2]'),
        utf8.encode('{"cmd":"fly"}'),
        utf8.encode('{"cmd":7}'),
        utf8.encode('{"cmd":"stop"'),
      ]) {
        rig.sim.handle(bytes);
      }
      expect(rig.log, List.filled(6, 'error:bad_cmd'));

      rig.send(const StopAll());
      rig.events.clear();
      for (final json in [
        '{"cmd":"titrate"}',
        '{"cmd":"titrate","target":15}',
        '{"cmd":"move","ch":3,"dir":"in"}',
        '{"cmd":"jog","ch":1,"dir":"sideways"}',
        '{"cmd":"cal_point","ph":"x"}',
      ]) {
        rig.sim.handle(utf8.encode(json));
      }
      expect(rig.log, List.filled(5, 'error:bad_cmd'));
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('the state is reported on connect', () {
      final rig = Rig()..sim.connected();
      expect(rig.log, ['idle']);
    });

    test('the link going away stops titration and motion', () {
      final rig = Rig()..send(const StartTitration(10));
      rig.run(const Duration(seconds: 3));
      rig.sim.disconnected();
      expect(rig.sim.mode, DeviceMode.idle);
      final volume = rig.sim.syringeMl(Channel.ch2);
      rig.run(const Duration(seconds: 10));
      expect(rig.sim.syringeMl(Channel.ch2), volume);

      rig.send(const Jog(Channel.ch1, Direction.dispense));
      rig.sim.disconnected();
      rig.run(const Duration(seconds: 1));
      expect(rig.sim.syringeMl(Channel.ch1), full);
    });
  });

  group('calibration', () {
    List<Map<String, Object?>> rawOf(Rig rig, String evt) => [
      for (final e in rig.raw)
        if (e['evt'] == evt) e,
    ];

    test('points, a rejected point, finish', () {
      final rig = Rig()..send(const CalStart());
      expect(rig.log, ['calibrating']);

      rig.send(const CalPoint(4));
      rig.run(const Duration(milliseconds: 2800));
      expect(rig.events.whereType<CalPointResult>(), isEmpty);
      rig.run(const Duration(milliseconds: 400));
      expect(rawOf(rig, 'cal_point'), [
        {'evt': 'cal_point', 'ph': 4.0, 'ok': true, 'mv': 177.5},
      ]);

      // Reject exactly one point, then accept the retry.
      rig.sim.rejectNextPoint = true;
      rig.send(const CalPoint(6.86));
      rig.run(SimTitrator.calSampling);
      rig.send(const CalPoint(6.86));
      rig.run(SimTitrator.calSampling);
      final results = rig.events.whereType<CalPointResult>().toList();
      expect([for (final r in results) r.ok], [true, false, true]);
      expect(rig.sim.rejectNextPoint, isFalse);

      rig.events.clear();
      rig.send(const CalFinish());
      expect(rig.log, ['idle']);
      final done = rig.events.whereType<CalDone>().single;
      expect(done.ok, isTrue);
      expect(done.slope, inInclusiveRange(98, 101));
      expect(done.offset!.abs(), lessThanOrEqualTo(5));
      expect(rig.events.first, isA<CalDone>()); // before the state change
    });

    test('finishing without an accepted point fails', () {
      final rig = Rig()..send(const CalStart());
      rig.send(const CalFinish());
      expect(rig.events.whereType<CalDone>().single.ok, isFalse);
      expect(rig.sim.mode, DeviceMode.idle);

      rig.send(const CalStart());
      rig.sim.rejectNextPoint = true;
      rig.send(const CalPoint(7));
      rig.run(SimTitrator.calSampling);
      rig.events.clear();
      rig.send(const CalFinish());
      expect(rig.events.whereType<CalDone>().single.ok, isFalse);
    });

    test('abort and stop leave calibration', () {
      final rig = Rig()..send(const CalStart());
      rig.send(const CalAbort());
      expect(rig.sim.mode, DeviceMode.idle);

      rig.send(const CalStart());
      rig.send(const StopAll());
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('points and finish need a running calibration', () {
      final rig = Rig();
      rig.send(const CalPoint(7));
      rig.send(const CalFinish());
      expect(rig.log, ['error:busy', 'error:busy']);

      rig.send(const CalStart());
      rig.send(const CalPoint(7));
      rig.send(const CalPoint(4)); // still sampling
      rig.send(const CalFinish());
      expect(rig.errors, hasLength(4));
    });

    test('the electrode reads the buffer, then the sample again', () {
      final rig = Rig()..send(const CalStart());
      final sample = rig.sim.samplePh;
      rig.run(const Duration(seconds: 5));
      expect(rig.lastPh, closeTo(sample, 0.05));

      rig.send(const CalPoint(4));
      rig.run(const Duration(milliseconds: 500));
      expect(rig.lastPh, greaterThan(4.5)); // lagging behind
      rig.run(const Duration(seconds: 20));
      expect(rig.lastPh, closeTo(4, 0.05));

      rig.send(const CalAbort());
      rig.run(const Duration(seconds: 20));
      expect(rig.lastPh, closeTo(sample, 0.05));
    });
  });

  group('readings', () {
    test('ph is reported every 500 ms, rounded to 3 decimals', () {
      final rig = Rig()..run(const Duration(seconds: 10));
      final values = rig.raw.where((e) => e['evt'] == 'ph').toList();
      expect(values, hasLength(20));
      for (final e in values) {
        final v = e['v']! as double;
        expect(v, closeTo(rig.sim.samplePh, 0.05));
        expect((v * 1000).roundToDouble() / 1000, v);
      }
    });

    test('a new sample starts between pH 5.5 and 9', () {
      final rig = Rig();
      for (var i = 0; i < 100; i++) {
        rig.sim.newSample();
        expect(rig.sim.samplePh, inInclusiveRange(5.5, 9.0));
      }
    });

    test('a new sample keeps the syringes', () {
      final rig = Rig()..send(const Move(Channel.ch1, Direction.dispense));
      rig.run(const Duration(seconds: 1));
      rig.sim.newSample();
      expect(
        rig.sim.syringeMl(Channel.ch1),
        closeTo(full - SimTitrator.stepMl, 1e-9),
      );
    });

    test('injected errors', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.events.clear();
      rig.sim.injectError('sensor');
      expect(rig.log, ['error:sensor']);
      expect(rig.sim.mode, DeviceMode.titrating);

      rig.sim.injectError('limit');
      expect(rig.log, ['error:sensor', 'error:limit', 'idle']);
    });
  });
}
