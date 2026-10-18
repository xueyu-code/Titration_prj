import 'dart:collection';
import 'dart:math';

import 'ph_sample.dart';

/// Decides when a titration has reached its target: the pH must stay within
/// [tolerance] of [target] continuously for [hold], and the readings of that
/// last [hold] must be steady, spanning at most [maxSpan]. [maxSpan] mirrors
/// the firmware's SETTLE_SPAN_PH; tune both together.
class CompletionDetector {
  CompletionDetector(
    this.target, {
    this.tolerance = 0.05,
    this.hold = const Duration(seconds: 5),
    this.maxSpan = 0.03,
  });

  final double target;
  final double tolerance;
  final Duration hold;
  final double maxSpan;

  DateTime? _inBandSince;
  final _window = Queue<PhSample>();

  /// Feeds one reading; returns true once the target is considered reached.
  bool add(DateTime time, double ph) {
    // Epsilon keeps readings exactly on the band edge (e.g. 7.05 vs 7.00) inside.
    if ((ph - target).abs() > tolerance + 1e-9) {
      _inBandSince = null;
      _window.clear();
      return false;
    }
    final since = _inBandSince ??= time;
    _window.add(PhSample(time, ph));
    while (time.difference(_window.first.time) > hold) {
      _window.removeFirst();
    }
    if (time.difference(since) < hold) return false;
    final phs = _window.map((s) => s.ph);
    // Epsilon keeps a span of exactly [maxSpan] (e.g. 7.03 vs 7.00) steady.
    return phs.reduce(max) - phs.reduce(min) <= maxSpan + 1e-9;
  }
}
