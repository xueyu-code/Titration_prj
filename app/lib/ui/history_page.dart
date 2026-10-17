import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/ph_sample.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import 'widgets/language_button.dart';
import 'widgets/ph_chart.dart';

/// Stored pH curve for any time range. Works without a connected device.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  /// Length of the selected preset, null for a custom range.
  Duration? _preset;
  late DateTime _from;
  late DateTime _to;
  late Future<List<PhSample>> _samples;

  bool get _validRange => _from.isBefore(_to);

  @override
  void initState() {
    super.initState();
    _applyPreset(const Duration(hours: 1));
  }

  // The methods below only mutate; callers wrap them in setState.

  void _applyPreset(Duration length) {
    final now = ref.read(clockProvider)();
    _preset = length;
    _to = now;
    _from = now.subtract(length);
    _query();
  }

  void _query() {
    if (_validRange) _samples = ref.read(sampleStoreProvider).query(_from, _to);
  }

  void _refresh() {
    final preset = _preset;
    if (preset != null) {
      _applyPreset(preset);
    } else {
      _query();
    }
  }

  Future<void> _pick({required bool start}) async {
    final initial = start ? _from : _to;
    final now = ref.read(clockProvider)();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: now.isAfter(initial) ? now : initial,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      _preset = null;
      if (start) {
        _from = picked;
      } else {
        _to = picked;
      }
      _query();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final presets = [
      (l10n.rangeHours(1), const Duration(hours: 1)),
      (l10n.rangeHours(6), const Duration(hours: 6)),
      (l10n.rangeHours(24), const Duration(hours: 24)),
      (l10n.rangeDays(7), const Duration(days: 7)),
    ];
    final format = DateFormat.yMd(Localizations.localeOf(context).toString())
        .add_Hm();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.historyTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
            onPressed: () => setState(_refresh),
          ),
          const LanguageButton(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final (label, length) in presets)
                          ChoiceChip(
                            label: Text(label),
                            selected: _preset == length,
                            onSelected: (_) =>
                                setState(() => _applyPreset(length)),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.event),
                    title: Text(l10n.rangeStart),
                    trailing: Text(format.format(_from)),
                    onTap: () => _pick(start: true),
                  ),
                  ListTile(
                    leading: const Icon(Icons.event),
                    title: Text(l10n.rangeEnd),
                    trailing: Text(format.format(_to)),
                    onTap: () => _pick(start: false),
                  ),
                  if (!_validRange)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        l10n.rangeInvalid,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_validRange)
            _ResultCard(
              samples: _samples,
              showDate: _to.difference(_from) > const Duration(hours: 24),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.samples, required this.showDate});

  final Future<List<PhSample>> samples;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Card(
      child: SizedBox(
        height: 320,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<List<PhSample>>(
            future: samples,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text(l10n.loadFailed));
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (data.isEmpty) {
                return Center(child: Text(l10n.noDataInRange));
              }
              return PhChart(samples: data, showDate: showDate);
            },
          ),
        ),
      ),
    );
  }
}
