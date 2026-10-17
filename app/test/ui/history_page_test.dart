import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/ph_sample.dart';
import 'package:titrator_app/data/sample_store.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/ui/history_page.dart';

import 'harness.dart';

class FakeSampleStore implements SampleStore {
  FakeSampleStore(this.data);

  List<PhSample> data;
  final ranges = <Duration>[];

  @override
  Future<List<PhSample>> query(
    DateTime from,
    DateTime to, {
    int maxPoints = 1000,
  }) async {
    ranges.add(to.difference(from));
    return data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final now = DateTime(2026, 1, 1, 12);
  late FakeSampleStore store;

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      testApp(
        const HistoryPage(),
        overrides: [
          sampleStoreProvider.overrideWithValue(store),
          clockProvider.overrideWithValue(() => now),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the last hour', (tester) async {
    store = FakeSampleStore([
      PhSample(now.subtract(const Duration(minutes: 30)), 6.5),
      PhSample(now.subtract(const Duration(minutes: 20)), 7.0),
      PhSample(now.subtract(const Duration(minutes: 10)), 7.5),
    ]);
    await pumpHistory(tester);

    expect(store.ranges, [const Duration(hours: 1)]);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('re-queries when a preset is chosen', (tester) async {
    store = FakeSampleStore([]);
    await pumpHistory(tester);
    expect(find.text('No data in this range'), findsOneWidget);

    await tester.tap(find.text('6 h'));
    await tester.pumpAndSettle();
    expect(store.ranges, [const Duration(hours: 1), const Duration(hours: 6)]);
  });
}
