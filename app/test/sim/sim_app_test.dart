import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/app.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/sim/sim_link.dart';
import 'package:titrator_app/sim/sim_panel.dart';
import 'package:titrator_app/sim/sim_titrator.dart';
import 'package:titrator_app/state/calibration_controller.dart';
import 'package:titrator_app/state/device_controller.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/state/scan_controller.dart';

import '../state/fakes.dart';
import '../ui/harness.dart' show FakeLocale;

/// The simulator wired into the real app, as main_sim.dart does.
void main() {
  late SimTitrator sim;
  late SimDeviceLink link;

  /// Starts the app on the simulator and connects to it.
  Future<ProviderContainer> pumpConnected(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    link = SimDeviceLink(sim);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          localeProvider.overrideWith(FakeLocale.new),
          appNotifierProvider.overrideWithValue(FakeAppNotifier()),
          deviceLinkProvider.overrideWithValue(link),
          scanProvider.overrideWith(SimScanController.new),
        ],
        child: TitratorApp(
          builder: (context, child) =>
              SimPanel(sim: sim, link: link, child: child!),
        ),
      ),
    );

    // Scan page lists the simulated device.
    await tester.pump();
    await tester.pump(SimScanController.scanTime);
    await tester.tap(find.text('Titrator-SIM'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Start titration'), findsOneWidget);
    expect(sim.mode, DeviceMode.idle);
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> shutDown(WidgetTester tester) async {
    link.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  setUp(() => sim = SimTitrator(random: Random(3)));

  testWidgets('scan, connect, control, fault injection', (tester) async {
    await pumpConnected(tester);

    // Start a titration from the app.
    await tester.tap(find.text('Start titration'));
    await tester.pump(const Duration(seconds: 1));
    expect(sim.mode, DeviceMode.titrating);

    // The panel opens above the navigator and drops the link.
    await tester.tap(find.text('SIM'));
    await tester.pump();
    expect(find.textContaining('针筒1'), findsOneWidget);
    await tester.tap(find.text('掉线'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Connection lost'), findsOneWidget);
    expect(sim.mode, DeviceMode.idle);

    await shutDown(tester);
  });

  testWidgets('the panel toggles the electrode fault and renews the sample', (
    tester,
  ) async {
    await pumpConnected(tester);
    await tester.tap(find.text('SIM'));
    await tester.pump();
    expect(find.textContaining('有缓冲样品'), findsOneWidget);
    expect(sim.buffered, isTrue);

    await tester.tap(find.widgetWithText(FilterChip, '电极异常'));
    expect(sim.electrodeFault, isTrue);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, '电极异常'));
    expect(sim.electrodeFault, isFalse);

    await tester.tap(find.widgetWithText(ActionChip, '新样品（无缓冲）'));
    await tester.pump();
    expect(sim.buffered, isFalse);
    expect(find.textContaining('无缓冲样品'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, '新样品（有缓冲）'));
    expect(sim.buffered, isTrue);

    await shutDown(tester);
  });

  testWidgets('the panel moves the electrode and shows its voltage', (
    tester,
  ) async {
    await pumpConnected(tester);
    await tester.tap(find.text('SIM'));
    await tester.pump();
    expect(find.textContaining('电极 '), findsOneWidget);
    expect(find.textContaining(' mV'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '9.18'));
    expect(sim.bufferPh, 9.18);
    await tester.tap(find.widgetWithText(ChoiceChip, '样品'));
    expect(sim.bufferPh, isNull);

    await shutDown(tester);
  });

  testWidgets('calibration in buffers makes the readings accurate', (
    tester,
  ) async {
    final container = await pumpConnected(tester);
    double ph() => container.read(deviceProvider).ph!;

    // The factory calibration misreads this electrode by about 0.2 pH here.
    sim.bufferPh = 9.18;
    await tester.pump(const Duration(seconds: 15));
    expect((ph() - 9.18).abs(), greaterThan(0.1));
    sim.bufferPh = null;

    await tester.tap(find.text('pH calibration'));
    await tester.pump(); // the route needs a frame to be built
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Start calibration')); // 6.86 / 4.00 / 9.18
    await tester.pump();

    // The user dips the probe in each buffer and taps Record; the app waits
    // for the reading to settle by itself.
    for (final (i, buffer) in [6.86, 4.00, 9.18].indexed) {
      sim.bufferPh = buffer;
      await tester.pump(const Duration(seconds: 15));
      await tester.tap(find.widgetWithText(FilledButton, 'Record'));
      for (var t = 0; t < 40; t++) {
        if (container.read(calibrationProvider).points.length > i) break;
        await tester.pump(const Duration(seconds: 1));
      }
      expect(container.read(calibrationProvider).points, hasLength(i + 1));
    }

    await tester.tap(find.text('Finish calibration'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Calibration successful'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'Slope: -57\.[3-5] mV/pH')),
      findsOneWidget,
    );
    expect(find.textContaining(RegExp(r'Offset: 6\.[3-7] mV')), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The parameters are on the device: the readings are right now.
    sim.bufferPh = 9.18;
    await tester.pump(const Duration(seconds: 15));
    expect(ph(), closeTo(9.18, 0.03));
    sim.bufferPh = 4.0;
    await tester.pump(const Duration(seconds: 15));
    expect(ph(), closeTo(4.0, 0.03));

    await shutDown(tester);
  });
}
