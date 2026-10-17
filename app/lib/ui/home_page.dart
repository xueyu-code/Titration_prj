import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol.dart';
import '../data/device_link.dart';
import '../l10n/app_localizations.dart';
import '../state/device_controller.dart';
import '../state/device_error_text.dart';
import '../state/providers.dart';
import 'calibration_page.dart';
import 'format.dart';
import 'widgets/confirm_dialog.dart';
import 'widgets/jog_button.dart';
import 'widgets/language_button.dart';
import 'widgets/ph_chart.dart';
import 'widgets/snack.dart';

/// Main control panel of a connected titrator.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _targetField = TextEditingController(text: '7.00');

  /// Set while the page closes, so the dropped link does not flash a banner.
  bool _leaving = false;

  DeviceController get _device => ref.read(deviceProvider.notifier);

  /// The entered target, or null if it is not a pH between 0 and 14.
  double? get _target {
    final value = double.tryParse(_targetField.text);
    return value != null && value >= 0 && value <= 14 ? value : null;
  }

  @override
  void dispose() {
    _targetField.dispose();
    super.dispose();
  }

  /// Runs a device command and reports a link failure.
  Future<void> _run(Future<void> Function() command) async {
    try {
      await command();
    } on LinkException {
      if (mounted) {
        showSnack(context, AppLocalizations.of(context).commandFailed);
      }
    }
  }

  Future<void> _reconnect() async {
    try {
      await _device.reconnect();
    } on LinkException catch (e) {
      if (mounted) showLinkError(context, e);
    }
  }

  /// Disconnects and leaves, after confirmation if a titration is running.
  Future<void> _leave() async {
    final device = _device;
    if (ref.read(deviceProvider).mode == DeviceMode.titrating) {
      final l10n = AppLocalizations.of(context);
      final ok = await confirm(
        context,
        message: l10n.disconnectWhileTitrating,
        confirmLabel: l10n.stopAndDisconnect,
      );
      if (!ok) return;
      await _run(device.stop);
    }
    setState(() => _leaving = true);
    await device.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  void _showCompleted(Completion completion) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.titrationDoneTitle),
        content: Text(
          l10n.titrationDoneBody(
            formatPh(completion.target),
            formatPh(completion.ph),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  void _showDeviceError(DeviceError error) {
    showSnack(context, deviceErrorText(AppLocalizations.of(context), error));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(deviceProvider);

    ref.listen(deviceProvider.select((s) => s.completion), (prev, next) {
      if (next != null && next != prev) _showCompleted(next);
    });
    ref.listen(deviceEventsProvider, (_, next) {
      final event = next.value;
      if (event is DeviceError) _showDeviceError(event);
    });

    final idle = state.mode == DeviceMode.idle;
    final cards = <Widget>[
      if (!state.connected && !_leaving)
        _ConnectionBanner(
          connecting: state.link == LinkStatus.connecting,
          onReconnect: _reconnect,
        ),
      _PhCard(state),
      _ChartCard(state),
      _TitrationCard(
        state: state,
        field: _targetField,
        target: _target,
        onChanged: () => setState(() {}),
        onStart: (target) => _run(() => _device.startTitration(target)),
        onStop: () => _run(_device.stop),
      ),
      _SyringeCard(enabled: state.connected),
      OutlinedButton.icon(
        icon: const Icon(Icons.tune),
        label: Text(l10n.calibrate),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: state.connected && idle
            ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CalibrationPage(),
                ),
              )
            : null,
      ),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(state.deviceName ?? l10n.appTitle),
          actions: [
            const LanguageButton(),
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: l10n.disconnect,
              onPressed: _leave,
            ),
          ],
        ),
        body: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: cards.length,
          itemBuilder: (_, i) => cards[i],
          separatorBuilder: (_, _) => const SizedBox(height: 12),
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatefulWidget {
  const _ConnectionBanner({
    required this.connecting,
    required this.onReconnect,
  });

  /// The state layer is already reconnecting.
  final bool connecting;
  final Future<void> Function() onReconnect;

  @override
  State<_ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<_ConnectionBanner> {
  bool _busy = false;

  Future<void> _reconnect() async {
    setState(() => _busy = true);
    await widget.onReconnect();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final busy = _busy || widget.connecting;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.link_off, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.connectionLost,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            FilledButton(
              onPressed: busy ? null : _reconnect,
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.reconnect),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhCard extends StatelessWidget {
  const _PhCard(this.state);

  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final target = state.target;
    final titrating = state.mode == DeviceMode.titrating;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.ph,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              formatPh(state.ph),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                Chip(label: Text(_modeLabel(l10n, state.mode))),
                if (titrating && target != null)
                  Chip(label: Text(l10n.targetPhValue(formatPh(target)))),
              ],
            ),
            if (state.calibration case final calibration?) ...[
              const SizedBox(height: 8),
              Text(
                calibration.isFactory
                    ? l10n.calFactory
                    : l10n.calSummary(
                        (calibration.efficiency * 100).toStringAsFixed(1),
                        formatSignedMv(calibration.offset),
                      ),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _modeLabel(AppLocalizations l10n, DeviceMode mode) =>
      switch (mode) {
        DeviceMode.idle => l10n.modeIdle,
        DeviceMode.titrating => l10n.modeTitrating,
        DeviceMode.moving => l10n.modeMoving,
        DeviceMode.unknown => l10n.modeUnknown,
      };
}

class _ChartCard extends StatelessWidget {
  const _ChartCard(this.state);

  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(context).liveCurveTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: PhChart(samples: state.recent, target: state.target),
            ),
          ],
        ),
      ),
    );
  }
}

/// Accepts at most two integer digits and two decimals, e.g. "7.05".
class _PhInputFormatter extends TextInputFormatter {
  static final _pattern = RegExp(r'^\d{0,2}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => _pattern.hasMatch(newValue.text) ? newValue : oldValue;
}

class _TitrationCard extends StatelessWidget {
  const _TitrationCard({
    required this.state,
    required this.field,
    required this.target,
    required this.onChanged,
    required this.onStart,
    required this.onStop,
  });

  final DeviceState state;
  final TextEditingController field;

  /// Valid parsed value of [field], or null.
  final double? target;
  final VoidCallback onChanged;
  final void Function(double target) onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final titrating = state.mode == DeviceMode.titrating;
    final value = target;
    final canStart =
        state.connected && state.mode == DeviceMode.idle && value != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: field,
              enabled: !titrating,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [_PhInputFormatter()],
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                labelText: l10n.targetPh,
                errorText: value == null ? l10n.targetPhInvalid : null,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (titrating)
              FilledButton.tonal(
                onPressed: onStop,
                child: Text(l10n.stopTitration),
              )
            else
              FilledButton(
                onPressed: canStart ? () => onStart(value) : null,
                child: Text(l10n.startTitration),
              ),
          ],
        ),
      ),
    );
  }
}

class _SyringeCard extends StatelessWidget {
  const _SyringeCard({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    Widget row(Channel channel, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: JogButton(
                channel: channel,
                direction: Direction.aspirate,
                label: l10n.aspirate,
                icon: Icons.download,
                enabled: enabled,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: JogButton(
                channel: channel,
                direction: Direction.dispense,
                label: l10n.dispense,
                icon: Icons.upload,
                enabled: enabled,
              ),
            ),
          ],
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(Channel.ch1, l10n.channelAcid),
            const SizedBox(height: 16),
            row(Channel.ch2, l10n.channelBase),
            const SizedBox(height: 12),
            Text(
              l10n.jogHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
