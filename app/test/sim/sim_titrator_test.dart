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

  /// Reagent dispensed into the beaker, in mL: base positive, acid negative.
  /// One entry per tick that dispenses, so a titration dose is one entry.
  final doses = <double>[];
  final _syringes = [SimTitrator.initialMl, SimTitrator.initialMl];

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

  /// Forgets the notifications and doses so far.
  void clear() {
    events.clear();
    raw.clear();
    doses.clear();
  }

  /// Ticks for [duration], or until [until] holds.
  void run(Duration duration, {bool Function()? until}) {
    final end = clock + duration;
    while (clock < end && !(until?.call() ?? false)) {
      clock += step;
      sim.tick(step);
      _trackDoses();
    }
  }

  void _trackDoses() {
    for (final channel in Channel.values) {
      final ml = sim.syringeMl(channel);
      final out = _syringes[channel.index] - ml;
      _syringes[channel.index] = ml;
      if (out > 0) doses.add(channel == Channel.ch2 ? out : -out);
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

  /// Empties a syringe, which homes it, then replaces the sample the reagent
  /// went into. Forgets the notifications.
  void home(Channel channel) {
    clear();
    jogUntilError(channel, Direction.dispense);
    sim.newSample();
    clear();
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

/// Reagent dispensed from both syringes so far, in mL.
double reagentUsed(Rig rig) =>
    2 * SimTitrator.initialMl -
    rig.sim.syringeMl(Channel.ch1) -
    rig.sim.syringeMl(Channel.ch2);

/// Titrates until the app's own completion rule holds (within 0.05 of the
/// target for 5 s) or five minutes have passed. Returns the time it took, or
/// null when it did not complete.
Duration? titrate(Rig rig, double target) {
  final detector = CompletionDetector(target);
  final epoch = DateTime(2026);
  var done = false;
  rig.onEvent = (e) {
    if (e is PhReading) {
      done |= detector.add(epoch.add(rig.clock), e.ph);
    }
  };
  final start = rig.clock;
  rig.send(StartTitration(target));
  rig.run(const Duration(minutes: 5), until: () => done);
  rig.onEvent = null;
  printOnFailure('pH ${rig.sim.samplePh}, clock ${rig.clock}');
  return done ? rig.clock - start : null;
}

/// Titrates to [target] while the electrode sits in the buffers [readings]
/// one after the other, moving on after every dose. The reading thus follows
/// the script whatever is dosed. The calibration is exact, so the device
/// reads the buffers' pH.
void titrateScripted(Rig rig, double target, List<double> readings) {
  rig.send(
    const CalSet(SimTitrator.electrodeSlope, SimTitrator.electrodeOffset),
  );
  rig.sim.bufferPh = readings.first;
  rig.run(const Duration(seconds: 30)); // the probe settles
  rig.clear();

  rig.send(StartTitration(target));
  final end = rig.clock + const Duration(minutes: 5);
  var next = 1, seen = 0;
  while (rig.sim.mode == DeviceMode.titrating && rig.clock < end) {
    rig.run(Rig.step);
    if (rig.doses.length > seen) {
      seen = rig.doses.length;
      if (next < readings.length) rig.sim.bufferPh = readings[next++];
    }
  }
}

void main() {
  const full = SimTitrator.capacityMl;
  const start = SimTitrator.initialMl;

  group('titration', () {
    for (final target in [4.0, 7.0, 10.0]) {
      test('buffered samples converge to pH $target', () {
        var slowest = Duration.zero;
        var most = 0.0;
        for (var seed = 1; seed <= 30; seed++) {
          final rig = Rig(seed: seed);
          final took = titrate(rig, target);
          expect(took, isNotNull, reason: 'seed $seed');
          expect(rig.errors, isEmpty, reason: 'seed $seed');
          if (took! > slowest) slowest = took;
          most = max(most, reagentUsed(rig));
        }
        // Measured over 200 seeds: at most 1:54 and 5.5 mL.
        expect(slowest, lessThan(const Duration(minutes: 3)));
        expect(most, lessThan(6)); // of 8 mL
      });
    }

    test('stop ends a titration that reached its target', () {
      final rig = Rig();
      expect(titrate(rig, 7), isNotNull);

      rig.clear();
      rig.send(const StopAll());
      expect(rig.log, ['idle']);
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('acts on its calibrated reading, not on the true pH', () {
      // The factory calibration reads this electrode about 0.2 pH too low at
      // pH 10, so the sample ends up too basic.
      final factory = Rig();
      expect(titrate(factory, 10), isNotNull);
      expect(factory.sim.samplePh, greaterThan(10.1));

      final calibrated = Rig();
      calibrated.send(
        const CalSet(SimTitrator.electrodeSlope, SimTitrator.electrodeOffset),
      );
      expect(titrate(calibrated, 10), isNotNull);
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

    test('waits for a settled reading, then doses FIRST_DOSE', () {
      final rig = Rig()..send(const StartTitration(10));
      rig.run(const Duration(minutes: 1), until: () => rig.doses.isNotEmpty);

      // SETTLE_SKIP discarded, then SETTLE_N readings 0.5 s apart.
      final earliest =
          SimTitrator.settleSkip +
          SimTitrator.reportInterval * (SimTitrator.settleN - 1);
      expect(rig.clock, greaterThanOrEqualTo(earliest));
      expect(rig.doses.single, closeTo(SimTitrator.firstDoseMl, 1e-9));
    });

    test('holds while the reading is within HOLD_TOL', () {
      final rig = Rig();
      rig.send(
        const CalSet(SimTitrator.electrodeSlope, SimTitrator.electrodeOffset),
      );
      rig.send(StartTitration(round(rig.sim.samplePh, 2)));
      rig.run(const Duration(minutes: 2));
      expect(rig.sim.mode, DeviceMode.titrating);
      expect(rig.doses, isEmpty);
    });

    test('doubles the dose while the reading does not respond', () {
      // The electrode sits in a buffer, so no dose moves the reading.
      final rig = Rig();
      rig.sim.bufferPh = 4;
      rig.run(const Duration(seconds: 20));
      rig.send(const StartTitration(7));
      rig.run(const Duration(minutes: 1));

      expect(
        [for (final ml in rig.doses.take(6)) round(ml, 6)],
        [0.05, 0.1, 0.2, 0.4, 0.5, 0.5], // FIRST_DOSE, doubled, MAX_DOSE
      );
      expect(rig.errors, isEmpty);
    });

    test('the third reversal stops the titration', () {
      final rig = Rig();
      titrateScripted(rig, 7, [4, 10, 4, 10]);

      expect(rig.log, ['titrating', 'error:no_converge', 'idle']);
      // Each reversal halves the dose, down to MIN_DOSE. The second is about
      // 0.05 * (3 / 6) / 2 / 2: the reading moved 6 pH and is 3 off.
      expect(rig.doses, [
        closeTo(SimTitrator.firstDoseMl, 1e-9),
        closeTo(-0.00625, 3e-4),
        closeTo(SimTitrator.minDoseMl, 1e-9),
      ]);
      expect(rig.sim.mode, DeviceMode.idle);
    });

    test('a reversal right after MIN_DOSE stops it at once', () {
      final rig = Rig();
      titrateScripted(rig, 7, [4, 7.05, 6.95]);

      // The second dose is tiny: the reading was just 0.05 from the target.
      expect(rig.log, ['titrating', 'error:no_converge', 'idle']);
      expect(
        [for (final ml in rig.doses) round(ml, 6)],
        [0.05, -SimTitrator.minDoseMl],
      );
    });

    test('an unbuffered sample cannot be titrated to neutral', () {
      var tried = 0;
      var most = 0.0;
      for (var seed = 1; seed <= 30; seed++) {
        final rig = Rig(seed: seed);
        rig.sim.newSample(buffered: false);
        // Close to neutral it is right already; the cliff matters elsewhere.
        if ((rig.sim.samplePh - 7).abs() < 0.5) continue;
        tried++;

        rig.send(const StartTitration(7));
        rig.run(const Duration(minutes: 3), until: () => rig.errors.isNotEmpty);
        expect(rig.log, [
          'titrating',
          'error:no_converge',
          'idle',
        ], reason: 'seed $seed');
        most = max(most, reagentUsed(rig));
      }
      expect(tried, greaterThan(10));
      // Measured over 100 seeds: at most 0.8 mL.
      expect(most, lessThan(1.2));
    });

    for (final target in [4.0, 10.0]) {
      test('an unbuffered sample still converges to pH $target', () {
        var most = 0.0;
        for (var seed = 1; seed <= 10; seed++) {
          final rig = Rig(seed: seed);
          rig.sim.newSample(buffered: false);
          expect(titrate(rig, target), isNotNull, reason: 'seed $seed');
          most = max(most, reagentUsed(rig));
        }
        expect(most, lessThan(0.3)); // a few drops
      });
    }
  });

  group('homing', () {
    test('syringes start partly filled and unhomed', () {
      final rig = Rig();
      expect(start, inExclusiveRange(0, full));
      for (final channel in Channel.values) {
        expect(rig.sim.syringeMl(channel), start);
        expect(rig.sim.isHomed(channel), isFalse);
      }
    });

    for (final command in const <Command>[
      Move(Channel.ch1, Direction.aspirate),
      Jog(Channel.ch1, Direction.aspirate),
    ]) {
      test(
        '${command.toJson()['cmd']} in on an unhomed syringe is refused',
        () {
          final rig = Rig()..send(command);
          expect(rig.log, ['error:unhomed']);
          expect(rig.rawOf('error').single, {
            'evt': 'error',
            'code': 'unhomed',
            'ch': 1,
            'dir': 'in',
          });
          rig.run(const Duration(seconds: 2));
          expect(rig.sim.mode, DeviceMode.idle);
          expect(rig.sim.syringeMl(Channel.ch1), start);
        },
      );

      test('${command.toJson()['cmd']} in ends a titration with unhomed', () {
        final rig = Rig()..send(const StartTitration(10));
        rig.run(const Duration(seconds: 10));
        rig.clear();

        rig.send(command);
        expect(rig.log, ['error:unhomed', 'idle']);
        expect(rig.sim.mode, DeviceMode.idle);

        // The titration is over: it does not dose any more.
        rig.run(const Duration(seconds: 30));
        expect(rig.log, ['error:unhomed', 'idle']);
        expect(rig.doses, isEmpty);
      });
    }

    test('refusing an aspiration also stops a motion', () {
      final rig = Rig()..send(const Jog(Channel.ch2, Direction.dispense));
      rig.send(const Move(Channel.ch1, Direction.aspirate));
      expect(rig.log, ['moving', 'error:unhomed', 'idle']);
      final volume = rig.sim.syringeMl(Channel.ch2);
      rig.run(const Duration(seconds: 2));
      expect(rig.sim.syringeMl(Channel.ch2), volume);
    });

    test('dispensing to the end triggers the switch and homes the syringe', () {
      final rig = Rig();
      rig.jogUntilError(Channel.ch2, Direction.dispense);
      expect(rig.log, ['moving', 'error:limit', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch2), 0);
      expect(rig.sim.isHomed(Channel.ch2), isTrue);
      expect(rig.sim.isHomed(Channel.ch1), isFalse);
      expect(rig.rawOf('error').single, {
        'evt': 'error',
        'code': 'limit',
        'ch': 2,
        'dir': 'out',
      });

      // The switch stays triggered: another dispense is refused at once.
      rig.clear();
      rig.send(const Move(Channel.ch2, Direction.dispense));
      expect(rig.log, ['error:limit']);
      expect(rig.rawOf('error').single['ch'], 2);
      expect(rig.rawOf('error').single['dir'], 'out');
    });

    test('a homed syringe can be aspirated, the other still cannot', () {
      final rig = Rig()..home(Channel.ch2);
      rig.send(const Move(Channel.ch2, Direction.aspirate));
      rig.run(const Duration(seconds: 1));
      expect(rig.log, ['moving', 'idle']);
      expect(rig.sim.syringeMl(Channel.ch2), closeTo(SimTitrator.stepMl, 1e-9));
      expect(rig.sim.isHomed(Channel.ch2), isTrue);

      rig.clear();
      rig.send(const Move(Channel.ch1, Direction.aspirate));
      expect(rig.log, ['error:unhomed']);
    });

    test('a full syringe stops the jog with error limit', () {
      final rig = Rig()..home(Channel.ch1);
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

    test('a titration that runs out of reagent hits the empty switch', () {
      final rig = Rig();
      // Leave about 0.4 mL of base in the syringe, unhomed.
      while (rig.sim.syringeMl(Channel.ch2) > 0.5) {
        rig.send(const Jog(Channel.ch2, Direction.dispense));
        rig.run(Jog.refresh);
      }
      rig.send(const StopAll());
      expect(rig.sim.isHomed(Channel.ch2), isFalse);
      rig.sim.newSample(); // at most pH 9, so the target needs base
      rig.clear();

      rig.send(const StartTitration(10));
      rig.run(const Duration(minutes: 2), until: () => rig.errors.isNotEmpty);
      expect(rig.log, ['titrating', 'error:limit', 'idle']);
      expect(rig.rawOf('error').single, {
        'evt': 'error',
        'code': 'limit',
        'ch': 2,
        'dir': 'out',
      });
      expect(rig.sim.syringeMl(Channel.ch2), 0);
      expect(rig.sim.isHomed(Channel.ch2), isTrue);

      rig.clear();
      rig.send(const Move(Channel.ch2, Direction.aspirate));
      expect(rig.log, ['moving']);
    });

    test(
      'a titration with an empty, homed syringe stops at its first dose',
      () {
        final rig = Rig()..home(Channel.ch2);
        rig.send(const StartTitration(10));
        rig.run(const Duration(minutes: 1), until: () => rig.errors.isNotEmpty);
        expect(rig.log, ['titrating', 'error:limit', 'idle']);
        expect(rig.rawOf('error').single['ch'], 2);
      },
    );
  });

  group('electrode fault', () {
    test('is reported once, after 2 s, and ph keeps coming', () {
      final rig = Rig()..sim.electrodeFault = true;
      rig.run(const Duration(milliseconds: 1900));
      expect(rig.errors, isEmpty);
      expect(rig.sim.sensorFault, isFalse);

      rig.run(const Duration(milliseconds: 100));
      expect(rig.log, ['error:sensor']);
      expect(rig.rawOf('error').single, {'evt': 'error', 'code': 'sensor'});
      expect(rig.sim.sensorFault, isTrue);

      rig.run(const Duration(seconds: 10));
      expect(rig.errors, ['sensor']);
      expect(rig.sim.mode, DeviceMode.idle);

      // 12 s of readings, clearly wrong ones: at the rail, far outside 0-14.
      expect(rig.rawOf('ph'), hasLength(24));
      expect(rig.lastMv, closeTo(SimTitrator.faultMv, 3));
      expect(rig.lastPh, anyOf(lessThan(0), greaterThan(14)));
    });

    test('ends a titration: error first, then idle', () {
      final rig = Rig()..send(const StartTitration(10));
      rig.run(const Duration(seconds: 30), until: () => rig.doses.isNotEmpty);
      rig.clear();

      rig.sim.electrodeFault = true;
      rig.run(const Duration(seconds: 10));
      expect(rig.log, ['error:sensor', 'idle']);
      expect(rig.sim.mode, DeviceMode.idle);
      expect(rig.doses, isEmpty, reason: 'no dose on the bad readings');
    });

    test('its readings do not feed the titration', () {
      // The electrode swings between two buffers, so the wait never settles
      // and after SETTLE_MAX any reading decides: one at the rail must not.
      final rig = Rig()..send(const StartTitration(7));
      for (var i = 0; i < 29; i++) {
        rig.sim.bufferPh = i.isEven ? 4 : 10;
        rig.run(const Duration(seconds: 1));
      }
      rig.run(const Duration(milliseconds: 400)); // 29.4 s into the wait
      expect(rig.doses, isEmpty);
      rig.clear();

      // Readings at 29.5, 30.0 and 30.5 s, the last two past SETTLE_MAX.
      rig.sim.electrodeFault = true;
      rig.run(const Duration(milliseconds: 1500));
      expect(rig.rawOf('ph'), hasLength(3));
      expect(rig.lastMv, closeTo(SimTitrator.faultMv, 3));
      expect(rig.doses, isEmpty);
      expect(rig.log, isEmpty);
      expect(rig.sim.mode, DeviceMode.titrating);

      rig.run(const Duration(seconds: 1)); // the fault trips at 31.4 s
      expect(rig.log, ['error:sensor', 'idle']);
      expect(rig.doses, isEmpty);
    });

    test('does not stop a motion', () {
      final rig = Rig();
      rig.sim.electrodeFault = true;
      for (var i = 0; i < 10; i++) {
        rig.send(const Jog(Channel.ch1, Direction.dispense));
        rig.run(Jog.refresh);
      }
      expect(rig.log, ['moving', 'error:sensor']);
      expect(rig.sim.mode, DeviceMode.moving);
    });

    test('refuses titrate', () {
      final rig = Rig()..sim.electrodeFault = true;
      rig.run(const Duration(seconds: 3));
      rig.clear();

      rig.send(const StartTitration(7));
      expect(rig.log, ['error:sensor']);
      expect(rig.sim.mode, DeviceMode.idle);
      rig.run(const Duration(seconds: 10));
      expect(rig.log, ['error:sensor'], reason: 'once, and no titration');
      expect(rig.doses, isEmpty);
    });

    test('clearing it clears the fault', () {
      final rig = Rig()..sim.electrodeFault = true;
      rig.run(const Duration(seconds: 3));
      expect(rig.sim.sensorFault, isTrue);

      rig.sim.electrodeFault = false;
      rig.clear();
      rig.run(const Duration(seconds: 10));
      expect(rig.sim.sensorFault, isFalse);
      expect(rig.lastMv, closeTo(electrodeMv(rig.sim.samplePh), 1.5));
      rig.send(const StartTitration(7));
      expect(rig.log, ['titrating']);
      rig.send(const StopAll());

      // A short blip is no fault; a new fault is reported again.
      rig.clear();
      rig.sim.electrodeFault = true;
      rig.run(const Duration(milliseconds: 1500));
      rig.sim.electrodeFault = false;
      rig.run(const Duration(seconds: 5));
      expect(rig.errors, isEmpty);
      rig.sim.electrodeFault = true;
      rig.run(const Duration(seconds: 3));
      expect(rig.errors, ['sensor']);
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
      final rig = Rig()..home(Channel.ch1);
      rig.send(const Jog(Channel.ch2, Direction.dispense));
      final before = rig.sim.samplePh;
      rig.run(const Duration(seconds: 1));
      expect(rig.sim.samplePh, greaterThan(before));

      final base = rig.sim.samplePh;
      rig.send(const Jog(Channel.ch1, Direction.aspirate));
      rig.run(const Duration(seconds: 1));
      expect(rig.sim.samplePh, base);
      expect(rig.sim.syringeMl(Channel.ch1), closeTo(0.5, 0.01));
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
      Move(Channel.ch2, Direction.dispense),
      Jog(Channel.ch1, Direction.aspirate),
    ]) {
      test('${command.toJson()['cmd']} ends a titration', () {
        final rig = Rig()..home(Channel.ch1);
        rig.send(const StartTitration(10)); // doses base from channel 2
        rig.run(const Duration(seconds: 30), until: () => rig.doses.isNotEmpty);
        expect(rig.doses, isNotEmpty);
        rig.clear();

        rig.send(command);
        expect(rig.log, ['moving']);
        rig.run(const Duration(seconds: 2));
        expect(rig.log, ['moving', 'idle']);

        // The titration is over: it does not dose any more.
        rig.clear();
        rig.run(const Duration(seconds: 30));
        expect(rig.errors, isEmpty);
        expect(rig.doses, isEmpty);
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

    test('the state and the stored calibration are reported on connect', () {
      final rig = Rig()..sim.connected();
      expect(rig.raw, [
        {'evt': 'state', 's': 'idle'},
        {'evt': 'cal', 'slope': idealSlope, 'offset': 0.0},
      ]);

      rig.send(const CalSet(-57.92, 4.35));
      rig.clear();
      rig.sim.connected();
      expect(rig.rawOf('cal').single, {
        'evt': 'cal',
        'slope': -57.92,
        'offset': 4.35,
      });
    });

    test('sync reports the state and the calibration in every mode', () {
      final rig = Rig()..send(const CalSet(-57.92, 4.35));
      final cal = {'evt': 'cal', 'slope': -57.92, 'offset': 4.35};
      for (final (setup, mode) in [
        (null, 'idle'),
        (const StartTitration(10), 'titrating'),
        (const Jog(Channel.ch1, Direction.dispense), 'moving'),
      ]) {
        if (setup != null) rig.send(setup);
        rig.clear();
        rig.send(const Sync());
        expect(rig.raw, [
          {'evt': 'state', 's': mode},
          cal,
        ]);
        expect(rig.sim.mode.name, mode);
      }
    });

    test('the link going away stops titration and motion', () {
      final rig = Rig()..send(const StartTitration(10));
      rig.run(const Duration(seconds: 30), until: () => rig.doses.isNotEmpty);
      rig.sim.disconnected();
      expect(rig.sim.mode, DeviceMode.idle);
      final volume = rig.sim.syringeMl(Channel.ch2);
      expect(volume, lessThan(start));
      rig.run(const Duration(seconds: 30));
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
      for (final buffered in [true, false]) {
        for (var i = 0; i < 100; i++) {
          rig.sim.newSample(buffered: buffered);
          expect(rig.sim.buffered, buffered);
          expect(rig.sim.samplePh, inInclusiveRange(5.5, 9.0));
        }
      }
    });

    test('only an unbuffered sample swings with a few drops of base', () {
      double after(bool buffered) {
        final rig = Rig()..sim.newSample(buffered: buffered);
        rig.send(const Move(Channel.ch2, Direction.dispense)); // 0.05 mL
        rig.run(const Duration(seconds: 1));
        return rig.sim.samplePh;
      }

      expect(after(true), lessThan(9.5));
      expect(after(false), greaterThan(9.5));
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
  });
}
