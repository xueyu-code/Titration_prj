import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/state/calibration_controller.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/ui/calibration_page.dart';

import 'harness.dart';

class FakeCalibration extends CalibrationController {
  FakeCalibration(this.initial);

  final CalibrationState initial;
  var sampled = 0;

  @override
  CalibrationState build() => initial;

  @override
  Future<void> sample() async => sampled++;
}

void main() {
  Future<FakeCalibration> pumpCalibration(
    WidgetTester tester,
    CalibrationState state,
  ) async {
    final fake = FakeCalibration(state);
    await tester.pumpWidget(
      testApp(
        const CalibrationPage(),
        overrides: [
          calibrationProvider.overrideWith(() => fake),
          deviceProvider.overrideWith(FakeDeviceController.new),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  const buffers = [6.86, 4.00, 9.18];
  Finder finishButton() =>
      find.widgetWithText(FilledButton, 'Finish calibration');

  testWidgets('lists the buffer sets before starting', (tester) async {
    await pumpCalibration(tester, const CalibrationState());

    expect(find.text('6.86 → 4.00 → 9.18'), findsOneWidget);
    expect(find.text('7.00 → 4.01 → 10.01'), findsOneWidget);
    expect(find.text('Start calibration'), findsOneWidget);
  });

  testWidgets('guides through the current buffer', (tester) async {
    final fake = await pumpCalibration(
      tester,
      const CalibrationState(
        phase: CalPhase.measuring,
        buffers: buffers,
        index: 1,
      ),
    );

    expect(
      find.textContaining('Put it into the pH 4.00 buffer'),
      findsOneWidget,
    );
    expect(
      find.textContaining('pH 9.18 buffer'),
      findsOneWidget,
    ); // pending step
    expect(find.text('At least 2 points are required'), findsOneWidget);
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Sample'));
    expect(fake.sampled, 1);
  });

  testWidgets('allows finishing once enough points are recorded', (
    tester,
  ) async {
    await pumpCalibration(
      tester,
      const CalibrationState(
        phase: CalPhase.measuring,
        buffers: buffers,
        index: 2,
      ),
    );

    expect(find.text('At least 2 points are required'), findsNothing);
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNotNull);
  });
}
