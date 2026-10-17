import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/ui/home_page.dart';

import 'harness.dart';

void main() {
  late FakeDeviceController device;
  late StreamController<DeviceEvent> events;

  Future<void> pumpHome(WidgetTester tester) async {
    // Tall surface so the lazily built list shows every card.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        const HomePage(),
        overrides: [
          deviceProvider.overrideWith(() => device),
          deviceEventsProvider.overrideWith((ref) => events.stream),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder startButton() => find.widgetWithText(FilledButton, 'Start titration');
  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<FilledButton>(button).onPressed != null;

  setUp(() {
    device = FakeDeviceController();
    events = StreamController<DeviceEvent>.broadcast();
    addTearDown(events.close);
  });

  testWidgets('starts titration with the entered target', (tester) async {
    await pumpHome(tester);
    expect(find.text('7.00'), findsWidgets); // pH reading and default target
    expect(enabled(tester, startButton()), isTrue);

    await tester.enterText(find.byType(TextField), '6.5');
    await tester.pump();
    await tester.tap(startButton());
    await tester.pump();

    final start = device.sent.single as StartTitration;
    expect(start.target, 6.5);
  });

  testWidgets('rejects invalid targets', (tester) async {
    await pumpHome(tester);

    await tester.enterText(find.byType(TextField), '15');
    await tester.pump();
    expect(find.text('Enter a pH between 0 and 14'), findsOneWidget);
    expect(enabled(tester, startButton()), isFalse);

    // A third decimal is refused by the input formatter.
    await tester.enterText(find.byType(TextField), '7.12');
    await tester.enterText(find.byType(TextField), '7.123');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '7.12',
    );
    expect(find.text('Enter a pH between 0 and 14'), findsNothing);
  });

  testWidgets('offers reconnect when the link is lost', (tester) async {
    device = FakeDeviceController(const DeviceState());
    await pumpHome(tester);

    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(enabled(tester, startButton()), isFalse);
  });

  testWidgets('announces completion and device errors', (tester) async {
    await pumpHome(tester);

    device.state = DeviceState(
      link: LinkStatus.connected,
      mode: DeviceMode.idle,
      ph: 7.02,
      target: 7,
      completedAt: DateTime(2026, 1, 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('Titration complete'), findsOneWidget);
    expect(
      find.text('Target pH 7.00 reached, current pH 7.02.'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    events.add(const DeviceError('busy'));
    await tester.pump(); // deliver the event
    await tester.pump(const Duration(milliseconds: 100)); // show the snack bar
    expect(
      find.text('Device is busy, stop the current operation first'),
      findsOneWidget,
    );
  });
}
