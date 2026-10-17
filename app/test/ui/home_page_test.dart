import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/ui/home_page.dart';
import 'package:titrator_app/ui/widgets/jog_button.dart';

import 'harness.dart';

void main() {
  late FakeDeviceController device;
  late StreamController<DeviceEvent> events;

  Future<void> pumpHome(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    // Tall surface so the lazily built list shows every card.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        const HomePage(),
        locale: locale,
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
      ph: 7.1,
      completion: (time: DateTime(2026, 1, 1), target: 7, ph: 7.02),
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

  group('syringe buttons', () {
    List<JogButton> buttons(WidgetTester tester) =>
        tester.widgetList<JogButton>(find.byType(JogButton)).toList();

    for (final mode in DeviceMode.values) {
      testWidgets('are enabled while connected, mode ${mode.name}', (
        tester,
      ) async {
        device = FakeDeviceController(
          DeviceState(link: LinkStatus.connected, mode: mode, ph: 7),
        );
        await pumpHome(tester);

        expect(buttons(tester), hasLength(4));
        expect(buttons(tester).every((b) => b.enabled), isTrue);
      });
    }

    testWidgets('are disabled without a connection', (tester) async {
      device = FakeDeviceController(const DeviceState());
      await pumpHome(tester);

      expect(buttons(tester).any((b) => b.enabled), isFalse);
    });

    testWidgets('move the syringe during a titration', (tester) async {
      device = FakeDeviceController(
        const DeviceState(
          link: LinkStatus.connected,
          mode: DeviceMode.titrating,
          ph: 6.5,
          target: 7,
        ),
      );
      await pumpHome(tester);

      await tester.tap(find.text('Aspirate').first);
      await tester.pump();
      final move = device.sent.single as Move;
      expect(move.channel, Channel.ch1);
      expect(move.direction, Direction.aspirate);
    });
  });

  group('limit error', () {
    final cases = <(String, DeviceError, String, String)>[
      (
        'a full syringe',
        const DeviceError(
          'limit',
          channel: Channel.ch1,
          direction: Direction.aspirate,
        ),
        'Channel 1 syringe is full',
        '通道 1 注射器已吸满',
      ),
      (
        'an empty syringe',
        const DeviceError(
          'limit',
          channel: Channel.ch2,
          direction: Direction.dispense,
        ),
        'Channel 2 syringe is empty',
        '通道 2 注射器已排空',
      ),
      (
        'an unspecific limit',
        const DeviceError('limit'),
        'Syringe reached its travel limit',
        '注射器已到达行程极限',
      ),
    ];

    for (final (name, error, en, zh) in cases) {
      for (final (locale, text) in [
        (const Locale('en'), en),
        (const Locale('zh'), zh),
      ]) {
        testWidgets('names $name in ${locale.languageCode}', (tester) async {
          await pumpHome(tester, locale: locale);

          events.add(error);
          await tester.pump(); // deliver the event
          await tester.pump(
            const Duration(milliseconds: 100),
          ); // show the snack bar
          expect(find.text(text), findsOneWidget);
        });
      }
    }
  });
}
