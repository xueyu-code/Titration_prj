import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/ui/widgets/jog_button.dart';

import 'harness.dart';

void main() {
  late FakeDeviceController device;

  Widget button({bool enabled = true}) => testApp(
    Center(
      child: JogButton(
        channel: Channel.ch1,
        direction: Direction.aspirate,
        label: 'Aspirate',
        icon: Icons.download,
        enabled: enabled,
      ),
    ),
    overrides: [deviceProvider.overrideWith(() => device)],
  );

  setUp(() => device = FakeDeviceController());

  testWidgets('tap sends one step', (tester) async {
    await tester.pumpWidget(button());
    await tester.tap(find.text('Aspirate'));
    await tester.pump();

    expect(device.sent.single, isA<Move>());
    final move = device.sent.single as Move;
    expect(move.channel, Channel.ch1);
    expect(move.direction, Direction.aspirate);
  });

  testWidgets('hold re-sends jog and stops on release', (tester) async {
    await tester.pumpWidget(button());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Aspirate')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(device.sentNames, ['jog']);

    await tester.pump(Jog.refresh);
    await tester.pump(Jog.refresh);
    expect(device.sentNames, ['jog', 'jog', 'jog']);

    await gesture.up();
    await tester.pump(Jog.refresh * 3);
    expect(device.sentNames, ['jog', 'jog', 'jog', 'stop']);
  });

  testWidgets('stops when disabled while held', (tester) async {
    await tester.pumpWidget(button());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Aspirate')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

    await tester.pumpWidget(button(enabled: false));
    await tester.pump(Jog.refresh * 3);
    expect(device.sentNames, ['jog', 'stop']);

    await gesture.up();
  });

  testWidgets('does nothing when disabled', (tester) async {
    await tester.pumpWidget(button(enabled: false));
    await tester.tap(find.text('Aspirate'));
    await tester.pump();

    expect(device.sent, isEmpty);
  });
}
