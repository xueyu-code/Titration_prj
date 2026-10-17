import 'dart:collection';
import 'dart:math';

/// Standard buffer sets, neutral buffer first.
const calibrationBufferSets = <List<double>>[
  [6.86, 4.00, 9.18],
  [7.00, 4.01, 10.01],
];

/// Points required before the user may finish.
const minCalibrationPoints = 2;

/// Slope of an ideal electrode at 25 °C, in mV per pH unit.
const idealSlope = -59.16;

/// One calibration point: the buffer's pH and the electrode voltage in it.
typedef CalibrationPoint = ({double ph, double mv});

/// The electrode response `mv = offset + slope · (pH − 7)` fitted to the
/// calibration points.
final class CalibrationFit {
  const CalibrationFit._(this.slope, this.offset);

  /// Least-squares fit; exact for two points. Needs at least two distinct
  /// buffer pH values.
  factory CalibrationFit.fromPoints(List<CalibrationPoint> points) {
    assert(
      points.map((p) => p.ph).toSet().length >= 2,
      'needs two distinct buffer pH values',
    );
    final meanX = _mean(points.map((p) => p.ph - 7));
    final meanY = _mean(points.map((p) => p.mv));
    var sxx = 0.0, sxy = 0.0;
    for (final p in points) {
      final dx = p.ph - 7 - meanX;
      sxx += dx * dx;
      sxy += dx * (p.mv - meanY);
    }
    final slope = sxy / sxx;
    return CalibrationFit._(slope, meanY - slope * meanX);
  }

  /// Acceptable electrode: slope within these fractions of [idealSlope] and
  /// an offset of at most [maxOffset] mV.
  static const minEfficiency = 0.85;
  static const maxEfficiency = 1.05;
  static const maxOffset = 60.0;

  /// mV per pH unit, negative.
  final double slope;

  /// mV at pH 7.
  final double offset;

  /// Slope relative to the ideal one, 1.0 being perfect.
  double get efficiency => slope / idealSlope;

  bool get acceptable =>
      efficiency >= minEfficiency &&
      efficiency <= maxEfficiency &&
      offset.abs() <= maxOffset;
}

/// Tells when the electrode voltage has settled: the last [count] readings
/// span at most [maxSpan] mV.
class StabilityDetector {
  StabilityDetector({this.count = 10, this.maxSpan = 1.0});

  final int count;
  final double maxSpan;

  final _window = Queue<double>();

  /// Feeds one reading; returns the mean of the last [count] readings once
  /// they are stable, otherwise null.
  double? add(double mv) {
    _window.add(mv);
    if (_window.length > count) _window.removeFirst();
    if (_window.length < count) return null;
    // Epsilon keeps a span of exactly [maxSpan] (e.g. 12.3 vs 11.3) stable.
    if (_window.reduce(max) - _window.reduce(min) > maxSpan + 1e-9) return null;
    return _mean(_window);
  }
}

double _mean(Iterable<double> values) =>
    values.reduce((a, b) => a + b) / values.length;
