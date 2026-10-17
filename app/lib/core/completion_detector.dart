/// Decides when a titration has reached its target: the pH must stay within
/// [tolerance] of [target] continuously for [hold].
class CompletionDetector {
  CompletionDetector(
    this.target, {
    this.tolerance = 0.05,
    this.hold = const Duration(seconds: 5),
  });

  final double target;
  final double tolerance;
  final Duration hold;

  DateTime? _inBandSince;

  /// Feeds one reading; returns true once the target is considered reached.
  bool add(DateTime time, double ph) {
    // Epsilon keeps readings exactly on the band edge (e.g. 7.05 vs 7.00) inside.
    if ((ph - target).abs() > tolerance + 1e-9) {
      _inBandSince = null;
      return false;
    }
    final since = _inBandSince ??= time;
    return time.difference(since) >= hold;
  }
}
