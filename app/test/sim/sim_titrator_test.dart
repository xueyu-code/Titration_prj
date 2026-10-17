import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/calibration.dart';
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

  /// Forgets the notifications so far.
  void clear() {
    events.clear();
    raw.clear();
  }

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

  double? get lastMv => events.whereType<PhReading>().lastOrNull?.mv;

  /// The notifications with the given `evt`, as JSON.
  List<Map<String, Object?>> rawOf(String evt) => [
    for (final e in raw)
      if (e['evt'] == evt) e,
  ];

  /// Holds a jog on [channel] until the device reports an error.
  void jogUntilError(Channel channel, Direction direction) {
    for (var i = 0; i < 200 && errors.isEmpty; i++) {
      send(Jog(channel, direction));
      run(Jog.refresh, until: () => errors.isNotEmpty);
    }
  }
}

/// The voltage of the simulated electrode in a solution of [ph], without
/// noise.
double electrodeMv(double ph) =>
    SimTitrator.electrodeOffset + SimTitrator.electrodeSlope * (ph - 7);

double round(double v, int decimals) {
  final f = pow(10, decimals);
  return (v * f).round() / f;
}

void main() {
  const full = SimTitrator.capacityMl;
  const start = SimTitrator.initialMl;

  group('titration', () {
    /// Titrates until the app's own completion rule holds (within 0.05 of the
    /// target for 5 s) or five minutes have passed.
    bool titrate(Rig rig, double target) {
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
      return done;
    }

    for (final target in [4.0, 7.0, 10.0]) {
      test('converges to pH $target and stops on request', () {
        final rig = Rig();
        expect(titrate(rig, target), isTrue);

        rig.clear();
        rig.send(const StopAll());
        expect(rig.log, ['idle']);
        expect(rig.sim.mode, DeviceMode.idle);
      });
    }

    test('acts on its calibrated reading, not on the true pH', () {
      // The factory calibration reads this electrode about 0.2 pH too low at
      // pH 10, so the sample ends up too basic.
      final factory = Rig();
      expect(titrate(factory, 10), isTrue);
      expect(factory.sim.samplePh, greaterThan(10.1));

      final calibrated = Rig();
      calibrated.send(
        const CalSet(SimTitrator.electrodeSlope, SimTitrator.electrodeOffset),
      );
      expect(titrate(calibrated, 10), isTrue);
      expect(calibrated.sim.samplePh, closeTo(10, 0.1));
    });

    test('doses base below the target and acid above it', () {
      final base = Rig()..send(const StartTitration(10));
      base.run(const Duration(seconds: 30));
      expect(base.sim.syringeMl(Channel.ch2), lessThan(start));
      expect(base.sim.syringeMl(Channel.ch1), start);

      final acid = Rig()..send(const StartTitration(4));
      acid.run(const Duration(seconds: 30));
      expect(acid.sim.syringeMl(Channel.ch1), lessThan(start));
      expect(acid.sim.syringeMl(Channel.ch2), start);
    });

    test('stops with error limit when the reagent is used up', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch2, Direction.dispense); // empty the base
      rig.sim.newSample(); // at most pH 9, so the target needs base
      rig.clear();

      rig.send(const StartTitration(10));
      rig.run(const Duration(seconds: 5));
      expect(rig.log, ['titrating', 'error:limit', 'idle']);
      expect(rig.rawOf('error').single, {
        'evt': 'error',
        'code': 'limit',
        'ch': 2,
        'dir': 'out',
      });
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

      final dispensed = start - rig.sim.syringeMl(Channel.ch1);
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
      expect(rig.sim.syringeMl(Channel.ch2), closeTo(start - 3, 0.1));

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
        closeTo(start - SimTitrator.stepMl, 1e-9),
      );
      expect(rig.sim.syringeMl(Channel.ch2), start);
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
      expect(rig.sim.syringeMl(Channel.ch1), closeTo(start + 0.5, 0.01));
    });

    test('syringes start partly filled: both directions work at once', () {
      final rig = Rig();
      expect(start, inExclusiveRange(0, full));
      expect(rig.sim.syringeMl(Channel.ch1), start);
      expect(rig.sim.syringeMl(Channel.ch2), start);

      for (final direction in Direction.values) {
        rig.send(Move(Channel.ch1, direction));
        rig.run(const Duration(seconds: 1));
      }
      expect(rig.log, ['moving', 'idle', 'moving', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch1), closeTo(start, 1e-9));
    });

    test('a full syringe stops the jog with error limit', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch1, Direction.aspirate);
      expect(rig.log, ['moving', 'error:limit', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch1), full);
      expect(rig.rawOf('error').single, {
        'evt': 'error',
        'code': 'limit',
        'ch': 1,
        'dir': 'in',
      });

      rig.clear();
      rig.send(const Move(Channel.ch1, Direction.aspirate));
      expect(rig.log, ['error:limit']);
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('an empty syringe stops the jog with error limit', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch2, Direction.dispense);
      expect(rig.log, ['moving', 'error:limit', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch2), 0);
      expect(rig.rawOf('error').single, {
        'evt': 'error',
        'code': 'limit',
        'ch': 2,
        'dir': 'out',
      });

      rig.clear();
      rig.send(const Move(Channel.ch2, Direction.dispense));
      expect(rig.log, ['error:limit']);
      expect(rig.rawOf('error').single['ch'], 2);
    });
  });

  group('commands', () {
    test('titrating accepts stop, move and jog only', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.clear();
      rig.send(const StartTitration(5));
      rig.send(const CalSet(-57, 5));
      expect(rig.log, ['error:busy', 'error:busy']);
      expect(rig.sim.mode, DeviceMode.titrating);

      rig.send(const StopAll());
      expect(rig.sim.mode, DeviceMode.idle);
    });

    for (final command in const <Command>[
      Move(Channel.ch1, Direction.dispense),
      Jog(Channel.ch1, Direction.aspirate),
    ]) {
      test('${command.toJson()['cmd']} ends a titration', () {
        final rig = Rig()..send(const StartTitration(10));
        rig.run(const Duration(seconds: 3)); // doses base from channel 2
        final base = rig.sim.syringeMl(Channel.ch2);
        expect(base, lessThan(start));
        rig.clear();

        rig.send(command);
        expect(rig.log, ['moving']);
        rig.run(const Duration(seconds: 2));
        expect(rig.log, ['moving', 'idle']);

        // The titration is over: it does not dose any more.
        rig.run(const Duration(seconds: 10));
        expect(rig.errors, isEmpty);
        expect(rig.sim.syringeMl(Channel.ch2), base);
      });
    }

    test('a jog during a titration runs until it is not refreshed', () {
      final rig = Rig()..send(const StartTitration(10));
      rig.clear();
      for (var i = 0; i < 5; i++) {
        rig.send(const Jog(Channel.ch1, Direction.dispense));
        rig.run(Jog.refresh);
      }
      expect(rig.sim.mode, DeviceMode.moving);
      expect(rig.sim.syringeMl(Channel.ch1), lessThan(start));
      rig.send(const StopAll());
      expect(rig.log, ['moving', 'idle']);
    });

    test('moving accepts move, jog and stop only', () {
      final rig = Rig()..send(const Jog(Channel.ch1, Direction.dispense));
      rig.clear();
      rig.send(const StartTitration(7));
      rig.send(const CalSet(-57, 5));
      expect(rig.log, ['error:busy', 'error:busy']);

      rig.send(const Move(Channel.ch2, Direction.dispense));
      rig.send(const Jog(Channel.ch2, Direction.dispense));
      expect(rig.errors, hasLength(2));
      expect(rig.sim.mode, DeviceMode.moving);
    });

    test('garbage is bad_cmd in every mode', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.clear();
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
      rig.clear();
      for (final json in [
        '{"cmd":"titrate"}',
        '{"cmd":"titrate","target":15}',
        '{"cmd":"move","ch":3,"dir":"in"}',
        '{"cmd":"jog","ch":1,"dir":"sideways"}',
        '{"cmd":"cal_set","slope":"x","offset":0}',
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
      expect(rig.sim.syringeMl(Channel.ch1), start);
    });
  });

  group('calibration', () {
    test('cal_set is stored and confirmed', () {
      final rig = Rig()..send(const CalSet(-57.92, 4.35));
      expect(rig.raw, [
        {'evt': 'cal', 'slope': -57.92, 'offset': 4.35},
      ]);
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('the ends of the protocol range are accepted', () {
      final rig = Rig();
      for (final (slope, offset) in [(-70.0, -100.0), (-40.0, 100.0)]) {
        rig.send(CalSet(slope, offset));
      }
      expect(rig.errors, isEmpty);
      expect(rig.rawOf('cal'), hasLength(2));
    });

    test('values outside the range or malformed are bad_cmd', () {
      final rig = Rig();
      for (final json in [
        '{"cmd":"cal_set","slope":-70.1,"offset":0}',
        '{"cmd":"cal_set","slope":-39.9,"offset":0}',
        '{"cmd":"cal_set","slope":59.16,"offset":0}',
        '{"cmd":"cal_set","slope":-57,"offset":100.1}',
        '{"cmd":"cal_set","slope":-57,"offset":-100.1}',
        '{"cmd":"cal_set","slope":-57}',
        '{"cmd":"cal_set","offset":0}',
        '{"cmd":"cal_set","slope":null,"offset":0}',
        '{"cmd":"cal_set","slope":"-57","offset":0}',
      ]) {
        rig.sim.handle(utf8.encode(json));
      }
      expect(rig.log, List.filled(9, 'error:bad_cmd'));
      expect(rig.rawOf('cal'), isEmpty);

      // Nothing was stored, not even the valid half: the factory defaults
      // still convert.
      rig.run(const Duration(seconds: 2));
      for (final e in rig.events.whereType<PhReading>()) {
        expect(e.ph, closeTo(round(7 + e.mv! / idealSlope, 2), 1e-9));
      }
    });
  });

  group('readings', () {
    test('ph is reported every 500 ms with the electrode voltage', () {
      final rig = Rig()..run(const Duration(seconds: 10));
      final values = rig.rawOf('ph');
      expect(values, hasLength(20));
      for (final e in values) {
        final mv = e['mv']! as double;
        expect(mv, closeTo(electrodeMv(rig.sim.samplePh), 1.5));
        expect(round(mv, 1), mv, reason: 'one decimal');
        final v = e['v']! as double;
        expect(round(v, 2), v, reason: 'two decimals');
      }
    });

    test('the factory calibration reads this electrode slightly off', () {
      final rig = Rig()..run(const Duration(seconds: 5));
      for (final e in rig.events.whereType<PhReading>()) {
        expect(e.ph, closeTo(round(7 + e.mv! / idealSlope, 2), 1e-9));
      }
      expect(rig.lastPh, lessThan(rig.sim.samplePh - 0.05));
    });

    test('cal_set changes the conversion and makes the reading right', () {
      final rig = Rig();
      rig.send(
        const CalSet(SimTitrator.electrodeSlope, SimTitrator.electrodeOffset),
      );
      rig.clear();
      rig.run(const Duration(seconds: 5));
      for (final e in rig.events.whereType<PhReading>()) {
        expect(e.ph, closeTo(rig.sim.samplePh, 0.03));
      }

      // Any stored values are applied as pH = 7 + (mv - offset) / slope.
      rig.send(const CalSet(-50, 20));
      rig.clear();
      rig.run(const Duration(seconds: 2));
      for (final e in rig.events.whereType<PhReading>()) {
        expect(e.ph, closeTo(round(7 + (e.mv! - 20) / -50, 2), 1e-9));
      }
    });

    test('the electrode reads the buffer, then the sample again', () {
      final rig = Rig();
      final sample = rig.sim.samplePh;
      rig.run(const Duration(seconds: 5));
      expect(rig.lastMv, closeTo(electrodeMv(sample), 1.5));

      rig.sim.bufferPh = 4;
      rig.run(const Duration(milliseconds: 500));
      expect(rig.lastMv, greaterThan(electrodeMv(sample)));
      expect(rig.lastMv, lessThan(electrodeMv(4) - 50)); // lagging behind
      rig.run(const Duration(seconds: 20));
      expect(rig.lastMv, closeTo(electrodeMv(4), 1.5));
      expect(rig.sim.electrodeMv, closeTo(electrodeMv(4), 0.1));
      expect(rig.sim.samplePh, sample, reason: 'the beaker is untouched');

      rig.sim.bufferPh = null;
      rig.run(const Duration(seconds: 20));
      expect(rig.lastMv, closeTo(electrodeMv(sample), 1.5));
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
        closeTo(start - SimTitrator.stepMl, 1e-9),
      );
    });

    test('injected errors', () {
      final rig = Rig()..send(const StartTitration(7));
      rig.clear();
      rig.sim.injectError('sensor');
      expect(rig.log, ['error:sensor']);
      expect(rig.sim.mode, DeviceMode.titrating);

      rig.sim.injectError('limit');
      expect(rig.log, ['error:sensor', 'error:limit', 'idle']);
      expect(rig.rawOf('error').last, {'evt': 'error', 'code': 'limit'});
    });
  });
}
