import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/app.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/sim/sim_link.dart';
import 'package:titrator_app/sim/sim_panel.dart';
import 'package:titrator_app/sim/sim_titrator.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/state/scan_controller.dart';

import '../state/fakes.dart';
import '../ui/harness.dart' show FakeLocale;

/// The simulator wired into the real app, as main_sim.dart does.
void main() {
  testWidgets('scan, connect, control, fault injection', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sim = SimTitrator();
    final link = SimDeviceLink(sim);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          localeProvider.overrideWith(FakeLocale.new),
          appNotifierProvider.overrideWithValue(FakeAppNotifier()),
          sampleStoreProvider.overrideWithValue(FakeSampleStore()),
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

    link.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
