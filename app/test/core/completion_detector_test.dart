import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/completion_detector.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  DateTime at(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  test('completes after holding the band steadily for 5 s', () {
    final d = CompletionDetector(7.0);
    expect(d.add(at(0), 7.02), isFalse);
    expect(d.add(at(2), 7.01), isFalse);
    expect(d.add(at(4.9), 7.0), isFalse);
    expect(d.add(at(5), 7.01), isTrue);
  });

  test('a slow drift through the band never completes', () {
    final d = CompletionDetector(7.0);
    // 0.01 pH/s: inside the band for 8 s, but 0.05 pH apart over any 5 s.
    for (var s = 0; s <= 8; s++) {
      expect(d.add(at(s), 6.96 + 0.01 * s), isFalse, reason: 'at $s s');
    }
  });

  test('completes 5 s after a drift settles', () {
    final d = CompletionDetector(7.0);
    for (var s = 0; s < 4; s++) {
      expect(d.add(at(s), 6.95 + 0.02 * s), isFalse);
    }
    for (var s = 4; s < 9; s++) {
      expect(d.add(at(s), 7.05), isFalse, reason: 'drift still in the window');
    }
    expect(d.add(at(9), 7.05), isTrue);
  });

  test('a span of exactly maxSpan counts as steady', () {
    final d = CompletionDetector(7.0);
    d.add(at(0), 7.0);
    d.add(at(2), 7.03);
    expect(d.add(at(5), 7.0), isTrue);

    final over = CompletionDetector(7.0);
    over.add(at(0), 7.0);
    over.add(at(2), 7.04);
    expect(over.add(at(5), 7.0), isFalse);
  });

  test('a reading exactly hold old still counts towards the span', () {
    final d = CompletionDetector(7.0);
    d.add(at(0), 7.0);
    expect(d.add(at(5), 7.04), isFalse);
  });

  test('maxSpan is configurable', () {
    final loose = CompletionDetector(7.0, maxSpan: 0.1);
    loose.add(at(0), 6.97);
    loose.add(at(2), 7.04);
    expect(loose.add(at(5), 7.0), isTrue);

    final strict = CompletionDetector(7.0, maxSpan: 0.01);
    strict.add(at(0), 7.0);
    strict.add(at(2), 7.02);
    expect(strict.add(at(5), 7.0), isFalse);
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
    expect(d.add(at(1), 4.09), isTrue);
  });
}
