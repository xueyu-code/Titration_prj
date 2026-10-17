import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol.dart';
import '../data/device_link.dart';
import 'providers.dart';

/// Standard buffer sets, neutral buffer first.
const calibrationBufferSets = <List<double>>[
  [6.86, 4.00, 9.18],
  [7.00, 4.01, 10.01],
];

/// Points required before the user may finish.
const minCalibrationPoints = 2;

enum CalPhase {
  /// Choosing the buffer set.
  setup,

  /// Waiting for the user to place the probe in `buffers[index]` and tap sample.
  measuring,

  /// Device is sampling `buffers[index]`.
  sampling,

  /// Device is computing the calibration.
  finishing,

  /// Finished; see [CalibrationState.result].
  done,
}

enum CalIssue {
  /// Device rejected the point (reading unstable / out of range); user may retry.
  pointRejected,

  /// Device did not answer in time.
  timeout,

  /// Link dropped or a command failed.
  link,
}

@immutable
class CalibrationState {
  const CalibrationState({
    this.phase = CalPhase.setup,
    this.buffers = const [],
    this.index = 0,
    this.issue,
    this.result,
  });

  final CalPhase phase;

  /// Chosen buffer set, empty during setup.
  final List<double> buffers;

  /// Current buffer; equals `buffers.length` when every point is recorded.
  /// Also the number of accepted points.
  final int index;

  /// Problem with the last action, cleared by the next one.
  final CalIssue? issue;

  final CalDone? result;

  bool get allRecorded => index >= buffers.length;

  bool get canFinish =>
      phase == CalPhase.measuring && index >= minCalibrationPoints;

  /// Waiting on, or about to wait on, the device.
  bool get inProgress => switch (phase) {
    CalPhase.measuring || CalPhase.sampling || CalPhase.finishing => true,
    CalPhase.setup || CalPhase.done => false,
  };

  /// [issue] describes the transition that produced the new state, so it is
  /// not carried over.
  CalibrationState copyWith({
    CalPhase? phase,
    int? index,
    CalIssue? issue,
    CalDone? result,
  }) => CalibrationState(
    phase: phase ?? this.phase,
    buffers: buffers,
    index: index ?? this.index,
    issue: issue,
    result: result ?? this.result,
  );
}

/// Calibration wizard, scoped to the calibration page. Sends `cal_abort` if
/// disposed while a calibration is in progress.
final calibrationProvider =
    NotifierProvider.autoDispose<CalibrationController, CalibrationState>(
      CalibrationController.new,
    );

class CalibrationController extends Notifier<CalibrationState> {
  static const answerTimeout = Duration(seconds: 60);

  DeviceLink get _link => ref.read(deviceLinkProvider);

  /// Runs while waiting for the device's answer to cal_point / cal_finish.
  Timer? _timer;

  @override
  CalibrationState build() {
    final link = _link;
    final subscriptions = [
      link.events.listen(_onEvent),
      link.status.listen(_onStatus),
    ];
    // State cannot be read while disposing, so keep track of it.
    var inProgress = false;
    listenSelf((_, next) => inProgress = next.inProgress);
    ref.onDispose(() {
      for (final s in subscriptions) {
        s.cancel();
      }
      _timer?.cancel();
      if (inProgress) _abortDevice(link);
    });
    return const CalibrationState();
  }

  /// Sends `cal_start` with the chosen set and moves to the first buffer.
  Future<void> start(List<double> buffers) async {
    try {
      await _link.send(const CalStart());
    } on LinkException {
      if (ref.mounted) state = const CalibrationState(issue: CalIssue.link);
      return;
    }
    if (ref.mounted) {
      state = CalibrationState(phase: CalPhase.measuring, buffers: buffers);
    }
  }

  /// Sends `cal_point` for the current buffer and waits for the result.
  Future<void> sample() async {
    final s = state;
    if (s.phase != CalPhase.measuring || s.allRecorded) return;
    state = s.copyWith(phase: CalPhase.sampling);
    await _request(CalPoint(s.buffers[s.index]));
  }

  /// Sends `cal_finish` and waits for `cal_done`.
  Future<void> finish() async {
    if (!state.canFinish) return;
    state = state.copyWith(phase: CalPhase.finishing);
    await _request(const CalFinish());
  }

  /// Sends `cal_abort` if in progress and returns to setup.
  Future<void> abort() async {
    final wasInProgress = state.inProgress;
    _timer?.cancel();
    state = const CalibrationState();
    if (wasInProgress) await _abortDevice(_link);
  }

  /// Sends [command] and starts the answer timer; the reply arrives through
  /// [_onEvent]. A failed send returns to the measuring phase.
  Future<void> _request(Command command) async {
    _timer?.cancel();
    _timer = Timer(answerTimeout, () => _fail(CalIssue.timeout));
    try {
      await _link.send(command);
    } on LinkException {
      _fail(CalIssue.link);
    }
  }

  /// Back to measuring so the user can retry.
  void _fail(CalIssue issue) {
    _timer?.cancel();
    if (!ref.mounted) return;
    state = state.copyWith(phase: CalPhase.measuring, issue: issue);
  }

  void _onEvent(DeviceEvent event) {
    switch ((event, state.phase)) {
      case (CalPointResult(:final ok), CalPhase.sampling):
        _timer?.cancel();
        state = state.copyWith(
          phase: CalPhase.measuring,
          index: ok ? state.index + 1 : null,
          issue: ok ? null : CalIssue.pointRejected,
        );
      case (final CalDone done, CalPhase.finishing):
        _timer?.cancel();
        state = state.copyWith(phase: CalPhase.done, result: done);
      default:
    }
  }

  void _onStatus(LinkStatus status) {
    if (status == LinkStatus.disconnected && state.inProgress) {
      _timer?.cancel();
      state = const CalibrationState(issue: CalIssue.link);
    }
  }

  Future<void> _abortDevice(DeviceLink link) =>
      link.send(const CalAbort()).onError((_, _) {});
}
