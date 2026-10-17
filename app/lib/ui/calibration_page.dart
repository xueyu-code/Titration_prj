import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/calibration.dart';
import '../l10n/app_localizations.dart';
import '../state/calibration_controller.dart';
import 'format.dart';
import 'widgets/confirm_dialog.dart';
import 'widgets/language_button.dart';

/// Guided multi-point pH calibration.
class CalibrationPage extends ConsumerWidget {
  const CalibrationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final cal = ref.watch(calibrationProvider);
    final controller = ref.read(calibrationProvider.notifier);

    return PopScope(
      canPop: !cal.inProgress,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirm(
          context,
          message: l10n.calDiscardMessage,
          confirmLabel: l10n.calDiscard,
        );
        if (discard && context.mounted) _abortAndLeave(context, controller);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.calibrate),
          actions: const [LanguageButton()],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: switch (cal.phase) {
            CalPhase.setup => _SetupView(
              issue: cal.issue,
              onStart: controller.start,
            ),
            CalPhase.measuring ||
            CalPhase.sampling => _MeasureView(cal: cal, controller: controller),
            CalPhase.applying => _Progress(l10n.calApplying),
            CalPhase.done => _ResultView(cal.fit!),
          },
        ),
      ),
    );
  }
}

void _abortAndLeave(BuildContext context, CalibrationController controller) {
  controller.abort();
  Navigator.of(context).pop();
}

String _issueText(AppLocalizations l10n, CalIssue issue) => switch (issue) {
  CalIssue.unstable => l10n.calUnstable,
  CalIssue.outOfRange => l10n.calOutOfRange(
    (CalibrationFit.minEfficiency * 100).round(),
    (CalibrationFit.maxEfficiency * 100).round(),
    CalibrationFit.maxOffset.round(),
  ),
  CalIssue.timeout => l10n.calTimeout,
  CalIssue.rejected => l10n.calRejected,
  CalIssue.link => l10n.calLink,
};

class _IssueText extends StatelessWidget {
  const _IssueText(this.issue);

  final CalIssue issue;

  @override
  Widget build(BuildContext context) => Text(
    _issueText(AppLocalizations.of(context), issue),
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  );
}

class _SetupView extends StatefulWidget {
  const _SetupView({required this.issue, required this.onStart});

  final CalIssue? issue;
  final void Function(List<double> buffers) onStart;

  @override
  State<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<_SetupView> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final issue = widget.issue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.calIntro),
                const SizedBox(height: 16),
                Text(
                  l10n.calBufferSet,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                RadioGroup<int>(
                  groupValue: _selected,
                  onChanged: (i) => setState(() => _selected = i ?? _selected),
                  child: Column(
                    children: [
                      for (var i = 0; i < calibrationBufferSets.length; i++)
                        RadioListTile<int>(
                          value: i,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            calibrationBufferSets[i].map(formatPh).join(' → '),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (issue != null) _IssueText(issue),
        FilledButton(
          onPressed: () => widget.onStart(calibrationBufferSets[_selected]),
          child: Text(l10n.calStart),
        ),
      ],
    );
  }
}

class _MeasureView extends StatelessWidget {
  const _MeasureView({required this.cal, required this.controller});

  final CalibrationState cal;
  final CalibrationController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sampling = cal.phase == CalPhase.sampling;
    final issue = cal.issue;
    final fit = cal.fit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 12,
              children: [
                for (var i = 0; i < cal.buffers.length; i++)
                  _StepTile(
                    buffer: cal.buffers[i],
                    status: i < cal.index
                        ? _StepStatus.done
                        : (i == cal.index
                              ? _StepStatus.current
                              : _StepStatus.pending),
                    mv: i < cal.index ? cal.points[i].mv : null,
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  l10n.calElectrode,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  l10n.calMv(formatMv(cal.mv)),
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (issue != null) _IssueText(issue),
        if (issue == CalIssue.outOfRange && fit != null) _FitLines(fit),
        if (cal.allRecorded)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
              Text(l10n.calAllRecorded),
            ],
          )
        else
          FilledButton(
            onPressed: sampling ? null : controller.record,
            child: sampling
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      Flexible(child: Text(l10n.calSampling)),
                    ],
                  )
                : Text(l10n.calRecord),
          ),
        FilledButton.tonal(
          onPressed: cal.canFinish ? controller.finish : null,
          child: Text(l10n.calFinish),
        ),
        if (issue == CalIssue.outOfRange)
          OutlinedButton(
            onPressed: controller.abort,
            child: Text(l10n.calAgain),
          ),
        if (cal.index < minCalibrationPoints)
          Text(
            l10n.calMinPoints(minCalibrationPoints),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        TextButton(
          onPressed: () => _abortAndLeave(context, controller),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}

enum _StepStatus { done, current, pending }

/// One buffer solution in the calibration sequence; the current one shows
/// the instructions.
class _StepTile extends StatelessWidget {
  const _StepTile({required this.buffer, required this.status, this.mv});

  final double buffer;
  final _StepStatus status;

  /// Recorded electrode voltage of a finished step.
  final double? mv;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = status == _StepStatus.current;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Icon(
          switch (status) {
            _StepStatus.done => Icons.check_circle,
            _StepStatus.current => Icons.radio_button_checked,
            _StepStatus.pending => Icons.radio_button_unchecked,
          },
          color: status == _StepStatus.pending
              ? scheme.outline
              : scheme.primary,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                l10n.calStepTitle(formatPh(buffer)),
                style: current
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.bodyLarge?.copyWith(
                        color: status == _StepStatus.pending
                            ? scheme.onSurfaceVariant
                            : null,
                      ),
              ),
              if (current) Text(l10n.calInstructions(formatPh(buffer))),
            ],
          ),
        ),
        if (mv != null) Text(l10n.calMv(formatMv(mv))),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 64),
    child: Column(
      spacing: 24,
      children: [
        const CircularProgressIndicator(),
        Text(message, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

/// Slope and offset of a fit.
class _FitLines extends StatelessWidget {
  const _FitLines(this.fit);

  final CalibrationFit fit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Text(
          l10n.calSlope(
            fit.slope.toStringAsFixed(1),
            (fit.efficiency * 100).toStringAsFixed(1),
          ),
        ),
        Text(l10n.calOffset(formatMv(fit.offset))),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView(this.fit);

  final CalibrationFit fit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Icon(Icons.check_circle, size: 64, color: color),
          Text(
            l10n.calSuccess,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(color: color),
          ),
          _FitLines(fit),
          Text(
            l10n.calApplied,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.done),
          ),
        ],
      ),
    );
  }
}
