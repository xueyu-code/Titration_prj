import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/app.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/scan_controller.dart';

import 'ui/harness.dart' show FakeLocale;

class FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState(bleStatus: BleStatus.poweredOff);

  @override
  Future<void> start() async {}

  @override
  void stop() {}
}

void main() {
  testWidgets('scan page follows the selected language', (tester) async {
    final overrides = <Override>[
      localeProvider.overrideWith(FakeLocale.new),
      scanProvider.overrideWith(FakeScan.new),
    ];
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const TitratorApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Titrator'), findsOneWidget);
    expect(find.textContaining('Bluetooth is off'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.translate));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '中文'));
    await tester.pumpAndSettle();

    expect(find.text('滴定仪'), findsOneWidget);
    expect(find.textContaining('蓝牙未开启'), findsOneWidget);
  });
}
