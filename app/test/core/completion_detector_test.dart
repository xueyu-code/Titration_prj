import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/completion_detector.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  DateTime at(double seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  test('completes after holding the band for 5 s', () {
    final d = CompletionDetector(7.0);
    expect(d.add(at(0), 7.02), isFalse);
    expect(d.add(at(2), 6.98), isFalse);
    expect(d.add(at(4.9), 7.0), isFalse);
    expect(d.add(at(5), 7.01), isTrue);
  });

  test('leaving the band resets the hold', () {
    final d = CompletionDetector(7.0);
    expect(d.add(at(0), 7.0), isFalse);
    expect(d.add(at(4), 7.0), isFalse);
    expect(d.add(at(4.5), 7.2), isFalse);
    expect(d.add(at(5), 7.0), isFalse, reason: 'hold restarts at 5 s');
    expect(d.add(at(9.9), 7.0), isFalse);
    expect(d.add(at(10), 7.0), isTrue);
  });

  test('a single out-of-band reading is enough to reset', () {
    final d = CompletionDetector(7.0);
    d.add(at(0), 7.0);
    d.add(at(3), 7.06);
    expect(d.add(at(5), 7.0), isFalse);
  });

  test('band edges are inclusive', () {
    for (final ph in [7.05, 6.95]) {
      final d = CompletionDetector(7.0);
      d.add(at(0), ph);
      expect(d.add(at(5), ph), isTrue, reason: '$ph is on the edge');
    }
    final outside = CompletionDetector(7.0);
    outside.add(at(0), 7.06);
    expect(outside.add(at(5), 7.06), isFalse);
  });

  test('tolerance and hold are configurable', () {
    final d = CompletionDetector(
      4.0,
      tolerance: 0.1,
      hold: const Duration(seconds: 1),
    );
    d.add(at(0), 4.1);
    expect(d.add(at(1), 3.9), isTrue);
  });
}
