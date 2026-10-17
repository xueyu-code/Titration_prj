import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/completion_detector.dart';
import '../core/ph_sample.dart';
import '../core/protocol.dart';
import '../data/device_link.dart';
import '../l10n/app_localizations.dart';
import 'device_error_text.dart';
import 'locale_controller.dart';
import 'providers.dart';

/// A titration the app saw reach its target.
typedef Completion = ({DateTime time, double target, double ph});

@immutable
class DeviceState {
  const DeviceState({
    this.link = LinkStatus.disconnected,
    this.deviceId,
    this.deviceName,
    this.ph,
    this.mode = DeviceMode.unknown,
    this.recent = const [],
    this.target,
    this.completion,
    this.calibration,
  });

  final LinkStatus link;
  final String? deviceId;
  final String? deviceName;

  /// Latest reading.
  final double? ph;
  final DeviceMode mode;

  /// Recent readings, oldest first; see [DeviceController.liveWindow].
  final List<PhSample> recent;

  /// Target of the titration started from this app, while it runs.
  final double? target;

  /// Replaced each time the app detects a finished titration.
  final Completion? completion;

  /// Calibration stored on the device, once it has reported it.
  final CalApplied? calibration;

  bool get connected => link == LinkStatus.connected;

  /// Same state with the given fields replaced. The device identity never
  /// changes this way (a new device means a fresh state); nullable fields are
  /// passed as getters so that `() => null` can clear them.
  DeviceState copyWith({
    LinkStatus? link,
    double? ph,
    DeviceMode? mode,
    List<PhSample>? recent,
    ValueGetter<double?>? target,
    Completion? completion,
    CalApplied? calibration,
  }) => DeviceState(
    link: link ?? this.link,
    deviceId: deviceId,
    deviceName: deviceName,
    ph: ph ?? this.ph,
    mode: mode ?? this.mode,
    recent: recent ?? this.recent,
    target: target != null ? target() : this.target,
    completion: completion ?? this.completion,
    calibration: calibration ?? this.calibration,
  );
}

/// The session with the connected titrator: connection, live readings and
/// titration completion. Kept alive for the app's lifetime.
final deviceProvider = NotifierProvider<DeviceController, DeviceState>(
  DeviceController.new,
);

class DeviceController extends Notifier<DeviceState> {
  /// [DeviceState.recent] keeps the last [liveWindow], or everything since the
  /// latest titration started from this app if that is longer, but never more
  /// than [maxLiveWindow].
  static const liveWindow = Duration(minutes: 5);
  static const maxLiveWindow = Duration(minutes: 60);

  /// Errors after which the device has stopped the titration by itself.
  static const _titrationErrors = {'limit', 'unhomed', 'sensor', 'no_converge'};

  /// Present while a titration started from this app runs; the foreground
  /// service runs exactly as long.
  CompletionDetector? _detector;

  /// When the latest titration started from this app began.
  DateTime? _titrationStart;

  DeviceLink get _link => ref.read(deviceLinkProvider);

  AppLocalizations get _l10n => l10nFor(ref.read(localeProvider));

  @override
  DeviceState build() {
    // Plain subscriptions, not ref.listen: Riverpod pauses listeners of
    // invisible widgets, and completion must be detected in the background.
    final link = _link;
    final subscriptions = [
      link.status.listen(_onStatus),
      link.events.listen(_onEvent),
    ];
    ref.onDispose(() {
      for (final s in subscriptions) {
        s.cancel();
      }
    });
    return const DeviceState();
  }

  /// Throws [LinkException] on failure.
  Future<void> connect(String deviceId, String name) async {
    _forget();
    _titrationStart = null;
    state = DeviceState(
      link: LinkStatus.connecting,
      deviceId: deviceId,
      deviceName: name,
    );
    try {
      await _link.connect(deviceId);
    } catch (_) {
      state = state.copyWith(link: LinkStatus.disconnected);
      rethrow;
    }
    state = state.copyWith(link: LinkStatus.connected);
  }

  /// Reconnects to the last device. Throws [LinkException] on failure.
  Future<void> reconnect() => connect(state.deviceId!, state.deviceName ?? '');

  /// Disconnects and forgets the device.
  Future<void> disconnect() async {
    _forget();
    await _link.disconnect();
    state = const DeviceState();
  }

  Future<void> startTitration(double target) async {
    _detector = CompletionDetector(target);
    _titrationStart = ref.read(clockProvider)();
    state = state.copyWith(target: () => target);
    final l10n = _l10n;
    unawaited(
      ref
          .read(foregroundServiceProvider)
          .start(
            l10n.modeTitrating,
            l10n.targetPhValue(target.toStringAsFixed(2)),
          ),
    );
    try {
      await _link.send(StartTitration(target));
    } catch (_) {
      _clearTarget();
      rethrow;
    }
  }

  /// Stops titration and any motion.
  Future<void> stop() {
    _clearTarget();
    return _link.send(const StopAll());
  }

  /// Sends a raw command (move / jog). Throws [LinkException].
  ///
  /// Moving a syringe ends a running titration on the device, so the app
  /// forgets it first: the completion detector must not stop that motion.
  Future<void> send(Command command) {
    if (_detector != null && (command is Move || command is Jog)) {
      _clearTarget();
    }
    return _link.send(command);
  }

  void _onStatus(LinkStatus status) {
    // Anything but an established connection going away is handled by
    // connect() / disconnect() themselves.
    if (status != LinkStatus.disconnected || !state.connected) return;
    final interrupted = _detector != null;
    _forget();
    state = state.copyWith(
      link: LinkStatus.disconnected,
      mode: DeviceMode.unknown,
      target: () => null,
    );
    // The device stops by itself when the link drops.
    if (interrupted) _notifyInterrupted((l10n) => l10n.titrationLinkLost);
  }

  void _onEvent(DeviceEvent event) {
    switch (event) {
      case PhReading(:final ph):
        _onReading(ph);
      case ModeChanged(:final mode):
        // The device left titrating by itself (limit, error) or on request.
        final stopped =
            state.mode == DeviceMode.titrating && mode != DeviceMode.titrating;
        if (stopped) _forget();
        state = state.copyWith(mode: mode, target: stopped ? () => null : null);
      case final CalApplied calibration:
        state = state.copyWith(calibration: calibration);
      case final DeviceError error when _detector != null:
        if (state.mode != DeviceMode.titrating) {
          // The device refused to start (e.g. busy).
          _clearTarget();
        } else if (_titrationErrors.contains(error.code)) {
          // The titration ends when the device reports idle next.
          _notifyInterrupted((l10n) => deviceErrorText(l10n, error));
        }
      default:
    }
  }

  void _onReading(double ph) {
    final now = ref.read(clockProvider)();
    final sample = PhSample(now, ph);
    final cutoff = _liveCutoff(now);
    state = state.copyWith(
      ph: ph,
      recent: [
        ...state.recent.skipWhile((s) => s.time.isBefore(cutoff)),
        sample,
      ],
    );
    final detector = _detector;
    if (detector != null &&
        state.mode == DeviceMode.titrating &&
        detector.add(now, ph)) {
      _complete(detector.target, ph, now);
    }
  }

  /// Oldest time [DeviceState.recent] keeps at [now].
  DateTime _liveCutoff(DateTime now) {
    final window = now.subtract(liveWindow);
    final start = _titrationStart;
    final cutoff = start != null && start.isBefore(window) ? start : window;
    final limit = now.subtract(maxLiveWindow);
    return cutoff.isBefore(limit) ? limit : cutoff;
  }

  /// Called once per titration: the detector and target are cleared first, so
  /// later readings cannot trigger it again.
  void _complete(double target, double ph, DateTime now) {
    _forget();
    state = state.copyWith(
      target: () => null,
      completion: (time: now, target: target, ph: ph),
    );
    // Best effort: a lost link already stops the device.
    unawaited(_link.send(const StopAll()).onError((_, _) {}));
    final l10n = _l10n;
    _notify(
      l10n.titrationDoneTitle,
      l10n.titrationDoneBody(target.toStringAsFixed(2), ph.toStringAsFixed(2)),
    );
  }

  void _notifyInterrupted(String Function(AppLocalizations l10n) body) {
    final l10n = _l10n;
    _notify(l10n.titrationAbortedTitle, body(l10n));
  }

  void _notify(String title, String body) =>
      unawaited(ref.read(appNotifierProvider).show(title, body));

  /// Forgets the running titration, if any, and stops the foreground service
  /// that kept the app alive for it.
  void _forget() {
    if (_detector == null) return;
    _detector = null;
    unawaited(ref.read(foregroundServiceProvider).stop());
  }

  void _clearTarget() {
    _forget();
    state = state.copyWith(target: () => null);
  }
}
