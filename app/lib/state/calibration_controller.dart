import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/calibration.dart';
import '../core/protocol.dart';
import '../data/device_link.dart';
import 'providers.dart';

enum CalPhase {
  /// Choosing the buffer set.
  setup,

  /// Waiting for the user to put the probe in `buffers[index]` and tap record.
  measuring,

  /// Waiting for the electrode voltage in `buffers[index]` to settle.
  sampling,

  /// Fit sent to the device, waiting for its confirmation.
  applying,

  /// Finished; see [CalibrationState.fit].
  done,
}

enum CalIssue {
  /// The reading did not settle in time; the user may retry.
  unstable,

  /// The fit is outside the acceptable range; see [CalibrationState.fit].
  outOfRange,

  /// The device did not confirm in time.
  timeout,

  /// The device refused the parameters.
  rejected,

  /// Link dropped or a command failed.
  link,
}

@immutable
class CalibrationState {
  const CalibrationState({
    this.phase = CalPhase.setup,
    this.buffers = const [],
    this.points = const [],
    this.mv,
    this.fit,
    this.issue,
  });

  final CalPhase phase;

  /// Chosen buffer set, empty during setup.
  final List<double> buffers;

  /// Recorded points, in the order of [buffers].
  final List<CalibrationPoint> points;

  /// Latest electrode voltage from the device.
  final double? mv;

  /// Fit of the recorded points, once the user finished.
  final CalibrationFit? fit;

  /// Problem with the last action, cleared by the next one.
  final CalIssue? issue;

  /// Current buffer; equals `buffers.length` when every point is recorded.
  int get index => points.length;

  bool get allRecorded => index >= buffers.length;

  bool get canFinish =>
      phase == CalPhase.measuring && index >= minCalibrationPoints;

  /// Work that would be lost by leaving the page.
  bool get inProgress => switch (phase) {
    CalPhase.measuring || CalPhase.sampling || CalPhase.applying => true,
    CalPhase.setup || CalPhase.done => false,
  };

  /// [issue] describes the transition that produced the new state, so it is
  /// not carried over.
  CalibrationState copyWith({
    CalPhase? phase,
    List<CalibrationPoint>? points,
    double? mv,
    CalibrationFit? fit,
    CalIssue? issue,
  }) => CalibrationState(
    phase: phase ?? this.phase,
    buffers: buffers,
    points: points ?? this.points,
    mv: mv ?? this.mv,
    fit: fit ?? this.fit,
    issue: issue,
  );
}

/// Calibration wizard, scoped to the calibration page. The device has no
/// calibration mode: the app records the electrode voltage in each buffer,
/// fits slope and offset, and writes them with `cal_set`.
final calibrationProvider =
    NotifierProvider.autoDispose<CalibrationController, CalibrationState>(
      CalibrationController.new,
    );

class CalibrationController extends Notifier<CalibrationState> {
  /// Longest wait for a stable reading in one buffer.
  static const sampleTimeout = Duration(seconds: 60);

  /// Longest wait for the device to confirm `cal_set`.
  static const applyTimeout = Duration(seconds: 5);

  DeviceLink get _link => ref.read(deviceLinkProvider);

  /// Runs while sampling or applying.
  Timer? _timer;

  /// Present while sampling.
  StabilityDetector? _detector;

  @override
  CalibrationState build() {
    final link = _link;
    final subscriptions = [
      link.events.listen(_onEvent),
      link.status.listen(_onStatus),
    ];
    ref.onDispose(() {
      for (final s in subscriptions) {
        s.cancel();
      }
      _timer?.cancel();
    });
    return const CalibrationState();
  }

  /// Moves to the first buffer of the chosen set.
  void start(List<double> buffers) {
    state = CalibrationState(
      phase: CalPhase.measuring,
      buffers: buffers,
      mv: state.mv,
    );
  }

  /// Records the electrode voltage in the current buffer once it is stable.
  void record() {
    final s = state;
    if (s.phase != CalPhase.measuring || s.allRecorded) return;
    _detector = StabilityDetector();
    _timer = Timer(sampleTimeout, () => _fail(CalIssue.unstable));
    state = s.copyWith(phase: CalPhase.sampling);
  }

  /// Fits the recorded points and, if the electrode is acceptable, writes the
  /// result to the device.
  Future<void> finish() async {
    if (!state.canFinish) return;
    final fit = CalibrationFit.fromPoints(state.points);
    if (!fit.acceptable) {
      state = state.copyWith(fit: fit, issue: CalIssue.outOfRange);
      return;
    }
    state = state.copyWith(phase: CalPhase.applying, fit: fit);
    _timer = Timer(applyTimeout, () => _fail(CalIssue.timeout));
    try {
      await _link.send(CalSet(fit.slope, fit.offset));
    } on LinkException {
      _fail(CalIssue.link);
    }
  }

  /// Discards everything recorded and returns to setup.
  void abort() {
    _stopWaiting();
    state = CalibrationState(mv: state.mv);
  }

  /// Back to measuring so the user can retry.
  void _fail(CalIssue issue) {
    _stopWaiting();
    if (!ref.mounted) return;
    state = state.copyWith(phase: CalPhase.measuring, issue: issue);
  }

  void _stopWaiting() {
    _timer?.cancel();
    _detector = null;
  }

  void _onEvent(DeviceEvent event) {
    switch ((event, state.phase)) {
      case (PhReading(:final mv?), _):
        _onVoltage(mv);
      case (CalApplied(), CalPhase.applying):
        _stopWaiting();
        state = state.copyWith(phase: CalPhase.done);
      case (DeviceError(), CalPhase.applying):
        _fail(CalIssue.rejected);
      default:
    }
  }

  /// Shows the live voltage; while sampling also looks for it to settle.
  void _onVoltage(double mv) {
    final s = state;
    final settled = s.phase == CalPhase.sampling ? _detector?.add(mv) : null;
    if (settled == null) {
      // A reading is no new action: keep the issue on display.
      state = s.copyWith(mv: mv, issue: s.issue);
      return;
    }
    _stopWaiting();
    state = s.copyWith(
      phase: CalPhase.measuring,
      points: [...s.points, (ph: s.buffers[s.index], mv: settled)],
      mv: mv,
    );
  }

  void _onStatus(LinkStatus status) {
    if (status == LinkStatus.disconnected && state.inProgress) {
      _stopWaiting();
      state = const CalibrationState(issue: CalIssue.link);
    }
  }
}
