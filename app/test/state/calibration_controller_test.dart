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

  Future<void> answer(DeviceEvent event) async {
    link.emit(event);
    await settle();
  }

  /// Samples the current buffer and the device accepts it.
  Future<void> acceptPoint() async {
    final ph = buffers[state().index];
    await controller().sample();
    expect(state().phase, CalPhase.sampling);
    await answer(CalPointResult(ph, ok: true));
  }

  test('happy path: start, three points, finish, done', () async {
    expect(state().phase, CalPhase.setup);
    await controller().start(buffers);
    expect(state().phase, CalPhase.measuring);
    expect(state().buffers, buffers);
    expect(state().index, 0);
    expect(link.sent.last, {'cmd': 'cal_start'});

    await controller().sample();
    expect(link.sent.last, {'cmd': 'cal_point', 'ph': 6.86});
    expect(state().phase, CalPhase.sampling);
    // Sampling cannot be started twice.
    await controller().sample();
    expect(link.sent, hasLength(2));

    await answer(const CalPointResult(6.86, ok: true));
    expect(state().phase, CalPhase.measuring);
    expect(state().index, 1);
    expect(state().canFinish, isFalse);

    await acceptPoint();
    expect(link.sent.last, {'cmd': 'cal_point', 'ph': 4.0});
    expect(state().index, 2);
    expect(state().canFinish, isTrue);

    await acceptPoint();
    expect(link.sent.last, {'cmd': 'cal_point', 'ph': 9.18});
    expect(state().allRecorded, isTrue);
    await controller().sample(); // nothing left to sample
    expect(state().phase, CalPhase.measuring);

    await controller().finish();
    expect(state().phase, CalPhase.finishing);
    expect(link.sent.last, {'cmd': 'cal_finish'});

    await answer(const CalDone(ok: true, slope: 98.5, offset: -2.0));
    expect(state().phase, CalPhase.done);
    expect(state().result?.slope, 98.5);
    expect(state().result?.offset, -2.0);
  });

  test('finishing early is allowed from two points', () async {
    await controller().start(buffers);
    await controller().finish(); // no points yet
    expect(state().phase, CalPhase.measuring);

    await acceptPoint();
    await controller().finish(); // one point is not enough
    expect(state().phase, CalPhase.measuring);

    await acceptPoint();
    await controller().finish();
    expect(state().phase, CalPhase.finishing);
  });

  test('a rejected point can be retried', () async {
    await controller().start(buffers);
    await controller().sample();
    await answer(const CalPointResult(6.86, ok: false));
    expect(state().phase, CalPhase.measuring);
    expect(state().index, 0);
    expect(state().issue, CalIssue.pointRejected);

    await controller().sample();
    expect(state().issue, isNull, reason: 'the next action clears the issue');
    await answer(const CalPointResult(6.86, ok: true));
    expect(state().index, 1);
  });

  test('stale or unrelated events are ignored', () async {
    await controller().start(buffers);
    await answer(const CalPointResult(6.86, ok: true));
    await answer(const CalDone(ok: true));
    await answer(const PhReading(7.0));
    expect(state().phase, CalPhase.measuring);
    expect(state().index, 0);
  });

  test('send failures become a link issue', () async {
    link.sendError = const LinkException(LinkFailure.failed);
    await controller().start(buffers);
    expect(state().phase, CalPhase.setup);
    expect(state().issue, CalIssue.link);

    link.sendError = null;
    await controller().start(buffers);
    link.sendError = const LinkException(LinkFailure.failed);
    await controller().sample();
    expect(state().phase, CalPhase.measuring);
    expect(state().issue, CalIssue.link);
  });

  test('an unanswered point or finish times out', () {
    fakeAsync((async) {
      final c = makeContainer();
      final notifier = c.read(calibrationProvider.notifier);
      CalibrationState current() => c.read(calibrationProvider);

      notifier.start(buffers);
      async.flushMicrotasks();
      notifier.sample();
      async.flushMicrotasks();
      expect(current().phase, CalPhase.sampling);

      async.elapse(CalibrationController.answerTimeout * 0.9);
      expect(current().phase, CalPhase.sampling);
      async.elapse(CalibrationController.answerTimeout * 0.2);
      expect(current().phase, CalPhase.measuring);
      expect(current().issue, CalIssue.timeout);

      // Both required points, then finish without an answer.
      for (var i = 0; i < 2; i++) {
        notifier.sample();
        async.flushMicrotasks();
        link.emit(CalPointResult(buffers[i], ok: true));
        async.flushMicrotasks();
      }
      notifier.finish();
      async.flushMicrotasks();
      expect(current().phase, CalPhase.finishing);
      async.elapse(CalibrationController.answerTimeout);
      expect(current().phase, CalPhase.measuring);
      expect(current().issue, CalIssue.timeout);
      expect(current().index, 2);

      c.dispose();
    });
  });

  test('a late answer does not fire the timeout', () {
    fakeAsync((async) {
      final c = makeContainer();
      final notifier = c.read(calibrationProvider.notifier);

      notifier.start(buffers);
      async.flushMicrotasks();
      notifier.sample();
      async.flushMicrotasks();
      link.emit(const CalPointResult(6.86, ok: true));
      async.flushMicrotasks();
      async.elapse(CalibrationController.answerTimeout * 2);
      expect(c.read(calibrationProvider).issue, isNull);

      c.dispose();
    });
  });

  test('a link drop in progress returns to setup', () async {
    await controller().start(buffers);
    await acceptPoint();
    link.emitStatus(LinkStatus.disconnected);
    await settle();
    expect(state().phase, CalPhase.setup);
    expect(state().issue, CalIssue.link);
    expect(state().index, 0);
  });

  test('abort sends cal_abort and resets', () async {
    await controller().start(buffers);
    await controller().abort();
    expect(link.sent.last, {'cmd': 'cal_abort'});
    expect(state().phase, CalPhase.setup);
    expect(state().buffers, isEmpty);

    link.sent.clear();
    await controller().abort(); // nothing to abort
    expect(link.sent, isEmpty);
  });

  test('disposing mid-calibration sends cal_abort', () async {
    await controller().start(buffers);
    await acceptPoint();
    container.dispose();
    await settle();
    expect(link.sent.last, {'cmd': 'cal_abort'});
  });

  test('disposing after completion or before start sends nothing', () async {
    container.dispose();
    await settle();
    expect(link.sent, isEmpty);

    link = FakeDeviceLink();
    container = makeContainer();
    await controller().start(buffers);
    await acceptPoint();
    await acceptPoint();
    await controller().finish();
    await answer(const CalDone(ok: true));
    link.sent.clear();
    container.dispose();
    await settle();
    expect(link.sent, isEmpty);
  });
}
