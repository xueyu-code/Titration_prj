import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/calibration.dart';

void main() {
  group('CalibrationFit', () {
    /// Voltages of an electrode with the given response.
    List<CalibrationPoint> pointsOf(
      List<double> buffers,
      double slope,
      double offset,
    ) => [for (final ph in buffers) (ph: ph, mv: offset + slope * (ph - 7))];

    test('two points are fitted exactly', () {
      final fit = CalibrationFit.fromPoints([
        (ph: 7.0, mv: 4.0),
        (ph: 4.0, mv: 4.0 + 3 * 57.0),
      ]);
      expect(fit.slope, closeTo(-57.0, 1e-9));
      expect(fit.offset, closeTo(4.0, 1e-9));
    });

    test('points need not be in pH order or include pH 7', () {
      final fit = CalibrationFit.fromPoints(
        pointsOf([9.18, 6.86, 4.0], -58.3, -2.5),
      );
      expect(fit.slope, closeTo(-58.3, 1e-9));
      expect(fit.offset, closeTo(-2.5, 1e-9));
    });

    test('more points are fitted by least squares', () {
      // Residuals of +1, -2, +1 mV around the line mv = -59 * (pH - 7).
      final fit = CalibrationFit.fromPoints([
        (ph: 4.0, mv: 177.0 + 1),
        (ph: 7.0, mv: 0.0 - 2),
        (ph: 10.0, mv: -177.0 + 1),
      ]);
      expect(fit.slope, closeTo(-59.0, 1e-9));
      expect(fit.offset, closeTo(0.0, 1e-9));
    });

    test('efficiency is relative to the ideal slope', () {
      expect(
        CalibrationFit.fromPoints(pointsOf([7, 4], idealSlope, 0)).efficiency,
        closeTo(1.0, 1e-12),
      );
      expect(
        CalibrationFit.fromPoints(pointsOf([7, 4], -50, 0)).efficiency,
        closeTo(50 / 59.16, 1e-12),
      );
    });

    test('needs two distinct buffers', () {
      expect(
        () => CalibrationFit.fromPoints([]),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => CalibrationFit.fromPoints([(ph: 7.0, mv: 1.0)]),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () =>
            CalibrationFit.fromPoints([(ph: 7.0, mv: 1.0), (ph: 7.0, mv: 2.0)]),
        throwsA(isA<AssertionError>()),
      );
    });

    group('acceptable', () {
      bool acceptable(double slope, double offset) =>
          CalibrationFit.fromPoints(pointsOf([6.86, 4.0], slope, offset))
              .acceptable;

      test('an ideal and a typical worn electrode', () {
        expect(acceptable(-59.16, 0), isTrue);
        expect(acceptable(-55, 20), isTrue);
        expect(acceptable(-57.4, -45), isTrue);
      });

      test('slope within 85-105 % of ideal', () {
        expect(acceptable(-50.4, 0), isTrue); // 85.2 %
        expect(acceptable(-50.0, 0), isFalse); // 84.5 %
        expect(acceptable(-62.0, 0), isTrue); // 104.8 %
        expect(acceptable(-62.3, 0), isFalse); // 105.3 %
        expect(acceptable(59.16, 0), isFalse, reason: 'wrong sign');
      });

      test('offset within 60 mV', () {
        expect(acceptable(-59.16, 60), isTrue);
        expect(acceptable(-59.16, -60), isTrue);
        expect(acceptable(-59.16, 61), isFalse);
        expect(acceptable(-59.16, -61), isFalse);
      });
    });
  });

  group('StabilityDetector', () {
    /// Feeds [values] and returns the last answer.
    double? feed(StabilityDetector detector, List<double> values) {
      double? last;
      for (final v in values) {
        last = detector.add(v);
      }
      return last;
    }

    test('needs a full window', () {
      final detector = StabilityDetector();
      for (var i = 0; i < 9; i++) {
        expect(detector.add(12.3), isNull);
      }
      expect(detector.add(12.3), closeTo(12.3, 1e-9));
    });

    test('returns the mean of the window', () {
      final detector = StabilityDetector();
      expect(
        feed(detector, [
          10.0,
          10.2,
          10.4,
          10.6,
          10.8,
          10.0,
          10.2,
          10.4,
          10.6,
          10.8,
        ]),
        closeTo(10.4, 1e-9),
      );
    });

    test('a span above 1 mV is not stable, exactly 1 mV is', () {
      final tight = StabilityDetector();
      expect(
        feed(tight, [
          11.3,
          12.3,
          11.3,
          12.3,
          11.3,
          12.3,
          11.3,
          12.3,
          11.3,
          12.3,
        ]),
        isNotNull,
      );
      final loose = StabilityDetector();
      expect(
        feed(loose, [
          11.3,
          12.4,
          11.3,
          12.3,
          11.3,
          12.3,
          11.3,
          12.3,
          11.3,
          12.3,
        ]),
        isNull,
      );
    });

    test('a disturbance leaves the window and the reading settles', () {
      final detector = StabilityDetector();
      expect(feed(detector, List.filled(9, 50.0)), isNull);
      expect(detector.add(80.0), isNull); // a jump inside the window
      for (var i = 0; i < 8; i++) {
        expect(detector.add(80.0), isNull, reason: 'the 50s are still in');
      }
      expect(detector.add(80.0), 80.0);
    });

    test('a drift is not stable', () {
      final detector = StabilityDetector();
      // 0.2 mV per reading: 1.8 mV across the window.
      final drift = [for (var i = 0; i < 30; i++) i * 0.2];
      for (final v in drift) {
        expect(detector.add(v), isNull);
      }
    });

    test('thresholds are configurable', () {
      final detector = StabilityDetector(count: 3, maxSpan: 0.5);
      expect(feed(detector, [1.0, 1.2, 1.4]), closeTo(1.2, 1e-9));
      expect(detector.add(2.0), isNull);
    });
  });

  test('buffer sets start with the neutral buffer', () {
    for (final set in calibrationBufferSets) {
      expect(set.length, greaterThanOrEqualTo(minCalibrationPoints));
      expect(set.first, inInclusiveRange(6.8, 7.0));
    }
  });
}
