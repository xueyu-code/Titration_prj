import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/state/calibration_controller.dart';
import 'package:titrator_app/state/providers.dart';

import 'fakes.dart';

void main() {
  const buffers = [6.86, 4.00, 9.18];

  /// Spacing of the readings, as the firmware reports them.
  const reading = Duration(milliseconds: 500);

  // Electrode voltages in those buffers for a slope of -57.4 and an offset
  // of 6.5 mV.
  const mvs = [14.5, 178.7, -118.6];

  late FakeDeviceLink link;
  late ProviderContainer container;

  CalibrationController controller() =>
      container.read(calibrationProvider.notifier);
  CalibrationState state() => container.read(calibrationProvider);

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [deviceLinkProvider.overrideWithValue(link)],
    );
    c.listen(calibrationProvider, (_, _) {}); // keep the autoDispose alive
    return c;
  }

  setUp(() {
    link = FakeDeviceLink();
    container = makeContainer();
    addTearDown(container.dispose);
  });

  /// Delivers [count] readings of [mv].
  Future<void> feed(double mv, [int count = 1]) async {
    for (var i = 0; i < count; i++) {
      link.emit(PhReading(7.0, mv: mv));
    }
    await settle();
  }

  /// Records the current buffer with a steady voltage of [mv].
  Future<void> recordPoint(double mv) async {
    controller().record();
    expect(state().phase, CalPhase.sampling);
    await feed(mv, 10);
    expect(state().phase, CalPhase.measuring);
  }

  /// Starts a calibration with [buffers] and records the first points, one
  /// steady voltage each.
  Future<void> recordPoints(List<double> voltages) async {
    controller().start(buffers);
    for (final mv in voltages) {
      await recordPoint(mv);
    }
  }

  test('happy path: three points, fit, apply, done', () async {
    expect(state().phase, CalPhase.setup);
    controller().start(buffers);
    expect(state().phase, CalPhase.measuring);
    expect(state().buffers, buffers);
    expect(state().points, isEmpty);

    controller().record();
    expect(state().phase, CalPhase.sampling);
    await feed(mvs[0], 9);
    expect(state().phase, CalPhase.sampling, reason: 'window not full yet');
    await feed(mvs[0]);
    expect(state().phase, CalPhase.measuring);
    expect(state().points.single.ph, 6.86);
    expect(state().points.single.mv, closeTo(14.5, 1e-9));
    expect(state().index, 1);
    expect(state().canFinish, isFalse);

    await recordPoint(mvs[1]);
    expect(state().points.last.ph, 4.0);
    expect(state().points.last.mv, closeTo(178.7, 1e-9));
    expect(state().canFinish, isTrue);

    await recordPoint(mvs[2]);
    expect(state().allRecorded, isTrue);
    controller().record(); // nothing left to record
    expect(state().phase, CalPhase.measuring);

    expect(link.sent, isEmpty, reason: 'nothing is sent before finishing');
    final finishing = controller().finish();
    expect(state().phase, CalPhase.applying);
    await finishing;
    final sent = link.sent.single;
    expect(sent['cmd'], 'cal_set');
    expect(sent['slope'], closeTo(-57.4, 0.1));
    expect(sent['offset'], closeTo(6.5, 0.1));

    link.emit(const CalApplied(-57.4, 6.5));
    await settle();
    expect(state().phase, CalPhase.done);
    expect(state().fit?.slope, closeTo(-57.4, 0.1));
    expect(state().fit?.offset, closeTo(6.5, 0.1));
    expect(state().issue, isNull);
  });

  test('the live voltage follows the readings in every phase', () async {
    await feed(3.0);
    expect(state().mv, 3.0, reason: 'setup');

    controller().start(buffers);
    expect(state().mv, 3.0, reason: 'kept across the phase change');
    await feed(4.5);
    expect(state().mv, 4.5);

    link.emit(const PhReading(7.0)); // no voltage reported
    await settle();
    expect(state().mv, 4.5);
  });

  test('a reading is recorded only after it has settled', () async {
    controller().start(buffers);
    controller().record();
    for (var i = 0; i < 10; i++) {
      await feed(i.isEven ? 10.0 : 15.0);
    }
    expect(state().phase, CalPhase.sampling);
    expect(state().points, isEmpty);

    // The mean of the settled window is recorded, not the last reading.
    for (final mv in [20.0, 20.2, 19.8, 20.0, 20.4, 19.6, 20.0, 20.0, 20.2]) {
      await feed(mv);
    }
    expect(state().phase, CalPhase.sampling, reason: 'one old reading left');
    await feed(19.8);
    expect(state().phase, CalPhase.measuring);
    expect(state().points.single.mv, closeTo(20.0, 1e-9));
  });

  test('steady readings outside sampling are not recorded', () async {
    await feed(10.0, 20);
    expect(state().phase, CalPhase.setup);
    controller().start(buffers);
    await feed(10.0, 20);
    expect(state().phase, CalPhase.measuring);
    expect(state().points, isEmpty);
  });

  test('finishing needs two points', () async {
    controller().start(buffers);
    await controller().finish();
    expect(state().phase, CalPhase.measuring);

    await recordPoint(mvs[0]);
    await controller().finish();
    expect(state().phase, CalPhase.measuring);
    expect(link.sent, isEmpty);

    await recordPoint(mvs[1]);
    await controller().finish();
    expect(state().phase, CalPhase.applying);
  });

  group('electrode outside the acceptable range', () {
    test('a weak slope is reported with the fit and nothing is sent', () async {
      await recordPoints([5.6, 120.0]); // slope -40, 68 % efficiency
      await controller().finish();

      expect(state().phase, CalPhase.measuring);
      expect(state().issue, CalIssue.outOfRange);
      expect(state().fit?.slope, closeTo(-40, 1e-9));
      expect(state().fit?.acceptable, isFalse);
      expect(link.sent, isEmpty);
      expect(state().points, hasLength(2), reason: 'points are kept');

      controller().record();
      expect(state().issue, isNull, reason: 'the next action clears it');

      controller().abort();
      expect(state().phase, CalPhase.setup);
      expect(state().fit, isNull);
    });

    test('a large offset is reported too', () async {
      // Slope -57.4 around an offset of 80 mV.
      await recordPoints([88.0, 252.2]);
      await controller().finish();
      expect(state().issue, CalIssue.outOfRange);
      expect(state().fit?.offset, closeTo(80, 0.1));
    });
  });

  group('unstable reading', () {
    test('times out and can be retried', () {
      fakeAsync((async) {
        final c = makeContainer();
        final notifier = c.read(calibrationProvider.notifier);
        CalibrationState current() => c.read(calibrationProvider);

        notifier.start(buffers);
        notifier.record();
        // A reading that keeps jumping, twice a second.
        var high = false;
        void jitter(Duration span) {
          for (var t = Duration.zero; t < span; t += reading) {
            high = !high;
            link.emit(PhReading(7.0, mv: high ? 10.0 : 14.0));
            async.elapse(reading);
          }
        }

        jitter(CalibrationController.sampleTimeout * 0.9);
        expect(current().phase, CalPhase.sampling);
        jitter(CalibrationController.sampleTimeout * 0.2);
        expect(current().phase, CalPhase.measuring);
        expect(current().issue, CalIssue.unstable);
        expect(current().points, isEmpty);

        // Readings keep the message on display.
        link.emit(const PhReading(7.0, mv: 12.0));
        async.flushMicrotasks();
        expect(current().issue, CalIssue.unstable);
        expect(current().mv, 12.0);

        // Retry on a steady reading.
        notifier.record();
        expect(current().issue, isNull);
        for (var i = 0; i < 10; i++) {
          link.emit(const PhReading(7.0, mv: 12.0));
          async.elapse(reading);
        }
        expect(current().phase, CalPhase.measuring);
        expect(current().points.single.mv, closeTo(12.0, 1e-9));

        // The timer is gone: no late failure.
        async.elapse(CalibrationController.sampleTimeout * 2);
        expect(current().issue, isNull);
        expect(current().points, hasLength(1));

        c.dispose();
      });
    });
  });

  group('applying', () {
    test('an unanswered cal_set times out and can be retried', () {
      fakeAsync((async) {
        final c = makeContainer();
        final notifier = c.read(calibrationProvider.notifier);
        CalibrationState current() => c.read(calibrationProvider);

        notifier.start(buffers);
        for (final mv in mvs.take(2)) {
          notifier.record();
          for (var i = 0; i < 10; i++) {
            link.emit(PhReading(7.0, mv: mv));
            async.elapse(reading);
          }
        }
        notifier.finish();
        async.flushMicrotasks();
        expect(current().phase, CalPhase.applying);

        async.elapse(CalibrationController.applyTimeout * 0.9);
        expect(current().phase, CalPhase.applying);
        async.elapse(CalibrationController.applyTimeout * 0.2);
        expect(current().phase, CalPhase.measuring);
        expect(current().issue, CalIssue.timeout);
        expect(current().points, hasLength(2));

        // A late confirmation is not mistaken for the next one.
        link.emit(const CalApplied(-57.4, 6.5));
        async.flushMicrotasks();
        expect(current().phase, CalPhase.measuring);

        notifier.finish();
        async.flushMicrotasks();
        expect(current().phase, CalPhase.applying);
        expect(link.sent, hasLength(2));
        link.emit(const CalApplied(-57.4, 6.5));
        async.flushMicrotasks();
        expect(current().phase, CalPhase.done);
        async.elapse(CalibrationController.applyTimeout * 2);
        expect(current().phase, CalPhase.done);

        c.dispose();
      });
    });

    test('a device error means the parameters were rejected', () async {
      await recordPoints(mvs.take(2).toList());
      await controller().finish();
      link.emit(const DeviceError('bad_cmd'));
      await settle();

      expect(state().phase, CalPhase.measuring);
      expect(state().issue, CalIssue.rejected);
      expect(state().points, hasLength(2));
    });

    test('a failed write is a link issue', () async {
      await recordPoints(mvs.take(2).toList());
      link.sendError = const LinkException(LinkFailure.failed);
      await controller().finish();

      expect(state().phase, CalPhase.measuring);
      expect(state().issue, CalIssue.link);
    });
  });

  test('stale or unrelated events are ignored', () async {
    controller().start(buffers);
    controller().record();
    link.emit(const CalApplied(-57.4, 6.5));
    link.emit(const DeviceError('limit'));
    link.emit(const ModeChanged(DeviceMode.moving));
    await settle();
    expect(state().phase, CalPhase.sampling);
    expect(state().issue, isNull);
  });

  group('link', () {
    test('a drop while sampling returns to setup', () async {
      await recordPoints([mvs[0]]);
      controller().record();
      link.emitStatus(LinkStatus.disconnected);
      await settle();

      expect(state().phase, CalPhase.setup);
      expect(state().issue, CalIssue.link);
      expect(state().points, isEmpty);
    });

    test('a drop while applying returns to setup', () async {
      await recordPoints(mvs.take(2).toList());
      await controller().finish();
      link.emitStatus(LinkStatus.disconnected);
      await settle();

      expect(state().phase, CalPhase.setup);
      expect(state().issue, CalIssue.link);
    });

    test('a drop before starting or after finishing changes nothing', () async {
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(state().issue, isNull);

      await recordPoints(mvs.take(2).toList());
      await controller().finish();
      link.emit(const CalApplied(-57.4, 6.5));
      await settle();
      link.emitStatus(LinkStatus.disconnected);
      await settle();
      expect(state().phase, CalPhase.done);
      expect(state().issue, isNull);
    });
  });

  test('abort discards everything and stops waiting', () {
    fakeAsync((async) {
      final c = makeContainer();
      final notifier = c.read(calibrationProvider.notifier);
      CalibrationState current() => c.read(calibrationProvider);

      notifier.start(buffers);
      notifier.record();
      notifier.abort();
      expect(current().phase, CalPhase.setup);
      expect(current().buffers, isEmpty);

      for (var i = 0; i < 10; i++) {
        link.emit(const PhReading(7.0, mv: 10.0));
        async.elapse(reading);
      }
      async.elapse(CalibrationController.sampleTimeout * 2);
      expect(current().phase, CalPhase.setup);
      expect(current().points, isEmpty);
      expect(current().issue, isNull);

      c.dispose();
    });
  });

  test('disposing mid-calibration sends nothing and stops the timers', () {
    fakeAsync((async) {
      final c = makeContainer();
      final notifier = c.read(calibrationProvider.notifier);
      notifier.start(buffers);
      notifier.record();
      c.dispose();
      async.elapse(CalibrationController.sampleTimeout * 2);
      expect(link.sent, isEmpty);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
