import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/completion_detector.dart';
import '../core/ph_sample.dart';
import '../core/protocol.dart';
import '../data/device_link.dart';
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
  });

  final LinkStatus link;
  final String? deviceId;
  final String? deviceName;

  /// Latest reading.
  final double? ph;
  final DeviceMode mode;

  /// Readings of the last [DeviceController.liveWindow], oldest first.
  final List<PhSample> recent;

  /// Target of the titration started from this app, while it runs.
  final double? target;

  /// Replaced each time the app detects a finished titration.
  final Completion? completion;

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
  }) => DeviceState(
    link: link ?? this.link,
    deviceId: deviceId,
    deviceName: deviceName,
    ph: ph ?? this.ph,
    mode: mode ?? this.mode,
    recent: recent ?? this.recent,
    target: target != null ? target() : this.target,
    completion: completion ?? this.completion,
  );
}

/// The session with the connected titrator: connection, live readings and
/// titration completion. Kept alive for the app's lifetime.
final deviceProvider = NotifierProvider<DeviceController, DeviceState>(
  DeviceController.new,
);

class DeviceController extends Notifier<DeviceState> {
  static const liveWindow = Duration(minutes: 5);

  /// Present while a titration started from this app runs.
  CompletionDetector? _detector;

  DeviceLink get _link => ref.read(deviceLinkProvider);

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
    _detector = null;
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
    _detector = null;
    await _link.disconnect();
    state = const DeviceState();
  }

  Future<void> startTitration(double target) async {
    _detector = CompletionDetector(target);
    state = state.copyWith(target: () => target);
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
    _detector = null;
    state = state.copyWith(
      link: LinkStatus.disconnected,
      mode: DeviceMode.unknown,
      target: () => null,
    );
  }

  void _onEvent(DeviceEvent event) {
    switch (event) {
      case PhReading(:final ph):
        _onReading(ph);
      case ModeChanged(:final mode):
        // The device left titrating by itself (limit, error) or on request.
        final stopped =
            state.mode == DeviceMode.titrating && mode != DeviceMode.titrating;
        if (stopped) _detector = null;
        state = state.copyWith(mode: mode, target: stopped ? () => null : null);
      case DeviceError()
          when state.target != null && state.mode != DeviceMode.titrating:
        // The device refused to start (e.g. busy).
        _clearTarget();
      default:
    }
  }

  void _onReading(double ph) {
    final now = ref.read(clockProvider)();
    final sample = PhSample(now, ph);
    final cutoff = now.subtract(liveWindow);
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

  /// Called once per titration: the detector and target are cleared first, so
  /// later readings cannot trigger it again.
  void _complete(double target, double ph, DateTime now) {
    _detector = null;
    state = state.copyWith(
      target: () => null,
      completion: (time: now, target: target, ph: ph),
    );
    // Best effort: a lost link already stops the device.
    unawaited(_link.send(const StopAll()).onError((_, _) {}));
    final l10n = l10nFor(ref.read(localeProvider));
    unawaited(
      ref
          .read(appNotifierProvider)
          .show(
            l10n.titrationDoneTitle,
            l10n.titrationDoneBody(
              target.toStringAsFixed(2),
              ph.toStringAsFixed(2),
            ),
          ),
    );
  }

  void _clearTarget() {
    _detector = null;
    state = state.copyWith(target: () => null);
  }
}
