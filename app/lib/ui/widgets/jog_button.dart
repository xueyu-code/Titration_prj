import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/protocol.dart';
import '../../data/device_link.dart';
import '../../l10n/app_localizations.dart';
import '../../state/device_controller.dart';
import 'snack.dart';

/// Syringe motion button: a tap moves one step, holding keeps the motor
/// running by re-sending [Jog] until release, then sends [StopAll].
class JogButton extends ConsumerStatefulWidget {
  const JogButton({
    super.key,
    required this.channel,
    required this.direction,
    required this.label,
    required this.icon,
    required this.enabled,
  });

  final Channel channel;
  final Direction direction;
  final String label;
  final IconData icon;
  final bool enabled;

  @override
  ConsumerState<JogButton> createState() => _JogButtonState();
}

class _JogButtonState extends ConsumerState<JogButton> {
  // Read once: ref cannot be used in dispose, where a held jog must be stopped.
  late final DeviceController _device;
  Timer? _jogTimer;
  bool _pressed = false;

  bool get _holding => _jogTimer != null;

  @override
  void initState() {
    super.initState();
    _device = ref.read(deviceProvider.notifier);
  }

  @override
  void didUpdateWidget(JogButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _release();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  /// Sends [command]; only user-initiated sends report a failure.
  Future<void> _send(Command command, {bool report = false}) async {
    try {
      await _device.send(command);
    } on LinkException {
      if (report && mounted) {
        showSnack(context, AppLocalizations.of(context).commandFailed);
      }
    }
  }

  void _step() => _send(Move(widget.channel, widget.direction), report: true);

  void _hold() {
    final jog = Jog(widget.channel, widget.direction);
    _send(jog, report: true);
    _jogTimer = Timer.periodic(Jog.refresh, (_) => _send(jog));
    setState(() {});
  }

  /// Ends a hold, if any. Safe to call from dispose.
  void _release() {
    if (!_holding) return;
    _jogTimer!.cancel();
    _jogTimer = null;
    _send(const StopAll());
  }

  void _endHold() {
    if (!_holding) return;
    _release();
    setState(() {});
  }

  void _setPressed(bool value) => setState(() => _pressed = value);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled;
    final active = enabled && (_pressed || _holding);
    final background = !enabled
        ? scheme.onSurface.withValues(alpha: 0.12)
        : active
        ? scheme.primary
        : scheme.secondaryContainer;
    final foreground = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : active
        ? scheme.onPrimary
        : scheme.onSecondaryContainer;

    return GestureDetector(
      onTap: enabled ? _step : null,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onLongPressStart: enabled ? (_) => _hold() : null,
      onLongPressEnd: enabled ? (_) => _endHold() : null,
      onLongPressCancel: enabled ? _endHold : null,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: foreground, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
