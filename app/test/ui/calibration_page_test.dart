import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/calibration.dart';
import 'package:titrator_app/state/calibration_controller.dart';
import 'package:titrator_app/ui/calibration_page.dart';

import 'harness.dart';

class FakeCalibration extends CalibrationController {
  FakeCalibration(this.initial);

  final CalibrationState initial;

  /// Controller calls in order, e.g. `['record', 'abort']`.
  final calls = <String>[];
  List<double>? started;

  @override
  CalibrationState build() => initial;

  @override
  void start(List<double> buffers) {
    calls.add('start');
    started = buffers;
  }

  @override
  void record() => calls.add('record');

  @override
  Future<void> finish() async => calls.add('finish');

  @override
  void abort() => calls.add('abort');
}

void main() {
  /// Shows the page as the root of the app, or pushed on top of a start page
  /// when [pushed] (so that leaving it can be observed).
  Future<FakeCalibration> pumpCalibration(
    WidgetTester tester,
    CalibrationState state, {
    bool pushed = false,
    Locale locale = const Locale('en'),
  }) async {
    // Tall surface so the scrolling page shows everything.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeCalibration(state);
    await tester.pumpWidget(
      testApp(
        pushed
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CalibrationPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              )
            : const CalibrationPage(),
        locale: locale,
        overrides: [calibrationProvider.overrideWith(() => fake)],
      ),
    );
    if (pushed) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }
    // Not pumpAndSettle: a progress indicator never settles.
    await tester.pump();
    return fake;
  }

  const buffers = [6.86, 4.00, 9.18];
  const recorded = <CalibrationPoint>[
    (ph: 6.86, mv: 14.5),
    (ph: 4.0, mv: 178.7),
  ];
  Finder finishButton() =>
      find.widgetWithText(FilledButton, 'Finish calibration');

  CalibrationState measuring({
    int points = 1,
    double? mv = 175.3,
    CalibrationFit? fit,
    CalIssue? issue,
  }) => CalibrationState(
    phase: CalPhase.measuring,
    buffers: buffers,
    points: recorded.take(points).toList(),
    mv: mv,
    fit: fit,
    issue: issue,
  );

  testWidgets('lists the buffer sets before starting', (tester) async {
    final fake = await pumpCalibration(tester, const CalibrationState());

    expect(find.text('6.86 → 4.00 → 9.18'), findsOneWidget);
    expect(find.text('7.00 → 4.01 → 10.01'), findsOneWidget);

    await tester.tap(find.text('7.00 → 4.01 → 10.01'));
    await tester.tap(find.text('Start calibration'));
    expect(fake.started, [7.00, 4.01, 10.01]);
  });

  testWidgets('guides through the current buffer and shows the voltages', (
    tester,
  ) async {
    final fake = await pumpCalibration(tester, measuring());

    expect(
      find.textContaining('Put it into the pH 4.00 buffer'),
      findsOneWidget,
    );
    expect(find.textContaining('Tap Record'), findsOneWidget);
    expect(
      find.textContaining('pH 9.18 buffer'),
      findsOneWidget,
    ); // pending step
    expect(find.text('175.3 mV'), findsOneWidget, reason: 'live voltage');
    expect(find.text('14.5 mV'), findsOneWidget, reason: 'recorded point');
    expect(find.text('At least 2 points are required'), findsOneWidget);
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Record'));
    expect(fake.calls, ['record']);
  });

  testWidgets('shows a dash until the first voltage arrives', (tester) async {
    await pumpCalibration(tester, measuring(points: 0, mv: null));
    expect(find.text('-- mV'), findsOneWidget);
  });

  testWidgets('waits for a stable reading while sampling', (tester) async {
    await pumpCalibration(
      tester,
      CalibrationState(
        phase: CalPhase.sampling,
        buffers: buffers,
        points: recorded.take(1).toList(),
        mv: 176.0,
      ),
    );

    expect(find.textContaining('Waiting for a stable reading'), findsOneWidget);
    expect(find.text('Record'), findsNothing);
    expect(find.text('176.0 mV'), findsOneWidget);
  });

  testWidgets('allows finishing once enough points are recorded', (
    tester,
  ) async {
    final fake = await pumpCalibration(tester, measuring(points: 2));

    expect(find.text('At least 2 points are required'), findsNothing);
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNotNull);
    await tester.tap(finishButton());
    expect(fake.calls, ['finish']);
  });

  for (final (issue, text) in [
    (CalIssue.unstable, 'did not become stable'),
    (CalIssue.timeout, 'Device did not respond'),
    (CalIssue.rejected, 'Device rejected the parameters'),
    (CalIssue.link, 'Connection problem'),
  ]) {
    testWidgets('explains the issue ${issue.name}', (tester) async {
      await pumpCalibration(tester, measuring(issue: issue));
      expect(find.textContaining(text), findsOneWidget);
    });
  }

  testWidgets('shows an unacceptable fit and offers to start over', (
    tester,
  ) async {
    final fit = CalibrationFit.fromPoints(const [
      (ph: 7.0, mv: 70.0),
      (ph: 4.0, mv: 214.0), // slope -48 mV/pH, offset 70 mV
    ]);
    final fake = await pumpCalibration(
      tester,
      measuring(points: 2, fit: fit, issue: CalIssue.outOfRange),
    );

    expect(find.text('Slope: -48.0 mV/pH (81.1 %)'), findsOneWidget);
    expect(find.text('Offset: 70.0 mV'), findsOneWidget);
    expect(find.textContaining('outside the acceptable range'), findsOneWidget);
    expect(find.textContaining('85–105 %'), findsOneWidget);
    expect(find.textContaining('±60 mV'), findsOneWidget);

    await tester.tap(find.text('Calibrate again'));
    expect(fake.calls, ['abort']);
  });

  testWidgets('the fit is only shown with the out-of-range message', (
    tester,
  ) async {
    final fit = CalibrationFit.fromPoints(recorded);
    await pumpCalibration(tester, measuring(points: 2, fit: fit));
    expect(find.textContaining('Slope'), findsNothing);
    expect(find.text('Calibrate again'), findsNothing);
  });

  testWidgets('shows progress while writing to the device', (tester) async {
    await pumpCalibration(
      tester,
      CalibrationState(
        phase: CalPhase.applying,
        buffers: buffers,
        points: recorded,
        fit: CalibrationFit.fromPoints(recorded),
      ),
    );
    expect(find.text('Writing to the device…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('reports the written parameters', (tester) async {
    final fit = CalibrationFit.fromPoints(const [
      (ph: 7.0, mv: 4.4),
      (ph: 4.0, mv: 4.4 + 3 * 57.9), // slope -57.9 mV/pH, offset 4.4 mV
    ]);
    await pumpCalibration(
      tester,
      CalibrationState(
        phase: CalPhase.done,
        buffers: buffers,
        points: recorded,
        fit: fit,
      ),
    );

    expect(find.text('Calibration successful'), findsOneWidget);
    expect(find.text('Slope: -57.9 mV/pH (97.9 %)'), findsOneWidget);
    expect(find.text('Offset: 4.4 mV'), findsOneWidget);
    expect(
      find.text('The parameters were written to the device.'),
      findsOneWidget,
    );
  });

  testWidgets('is localized', (tester) async {
    await pumpCalibration(tester, measuring(), locale: const Locale('zh'));
    expect(find.text('175.3 mV'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.textContaining('点击“记录”'), findsOneWidget);
  });

  group('leaving', () {
    testWidgets('mid-calibration asks before discarding', (tester) async {
      final fake = await pumpCalibration(tester, measuring(), pushed: true);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard this calibration?'), findsOneWidget);
      expect(find.text('Calibrate'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(fake.calls, ['abort']);
      expect(
        find.text('open'),
        findsOneWidget,
        reason: 'back on the start page',
      );
    });

    testWidgets('can be cancelled', (tester) async {
      final fake = await pumpCalibration(tester, measuring(), pushed: true);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, isEmpty);
      expect(find.text('pH calibration'), findsOneWidget);
    });

    testWidgets('during setup does not ask', (tester) async {
      await pumpCalibration(tester, const CalibrationState(), pushed: true);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard this calibration?'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
