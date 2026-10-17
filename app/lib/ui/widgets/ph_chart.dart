import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/ph_sample.dart';
import '../../l10n/app_localizations.dart';
import '../format.dart';

/// pH over time. [showDate] adds the date to time labels (multi-day ranges).
class PhChart extends StatelessWidget {
  const PhChart({
    super.key,
    required this.samples,
    this.target,
    this.showDate = false,
  });

  final List<PhSample> samples;
  final double? target;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return Center(child: Text(AppLocalizations.of(context).noData));
    }
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);

    // x is milliseconds since the first sample, which keeps the doubles small.
    final start = samples.first.time;
    final spots = [
      for (final s in samples)
        FlSpot(s.time.difference(start).inMilliseconds.toDouble(), s.ph),
    ];
    // Three whole-millisecond intervals give four labels, ends included, with
    // positions that are exact in floating point.
    final xInterval = (math.max(spots.last.x, 3.0) / 3).ceilToDouble();
    final maxX = xInterval * 3;
    final (minY, maxY) = _yRange();
    final ySpan = maxY - minY;
    final yInterval = ySpan <= 2 ? 0.5 : (ySpan <= 6 ? 1.0 : 2.0);

    final axisFormat = DateFormat(showDate ? 'MM-dd HH:mm' : 'HH:mm:ss');
    final tooltipFormat = DateFormat('MM-dd HH:mm:ss');
    DateTime timeAt(double x) => start.add(Duration(milliseconds: x.round()));
    final phLabel = AppLocalizations.of(context).ph;

    final grid = FlLine(color: scheme.outlineVariant, strokeWidth: 0.5);

    return LineChart(
      duration: Duration.zero,
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          horizontalInterval: yInterval,
          verticalInterval: xInterval,
          getDrawingHorizontalLine: (_) => grid,
          getDrawingVerticalLine: (_) => grid,
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: yInterval,
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                child: Text(value.toStringAsFixed(1), style: textStyle),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: xInterval,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                child: Text(axisFormat.format(timeAt(value)), style: textStyle),
              ),
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (target != null)
              HorizontalLine(
                y: target!,
                color: scheme.tertiary,
                strokeWidth: 1.5,
                dashArray: [6, 4],
              ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: scheme.primary,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: scheme.primary.withValues(alpha: 0.1),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItems: (touched) => [
              for (final spot in touched)
                LineTooltipItem(
                  '${tooltipFormat.format(timeAt(spot.x))}\n'
                  '$phLabel ${formatPh(spot.y)}',
                  TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Data (and target) padded by 0.2, at least 1 pH wide, kept within 0-14.
  (double, double) _yRange() {
    var low = samples.first.ph;
    var high = low;
    for (final s in samples) {
      low = math.min(low, s.ph);
      high = math.max(high, s.ph);
    }
    if (target != null) {
      low = math.min(low, target!);
      high = math.max(high, target!);
    }
    final span = (high - low + 0.4).clamp(1.0, 14.0);
    final min = ((low + high - span) / 2).clamp(0.0, 14.0 - span);
    return (min, min + span);
  }
}
