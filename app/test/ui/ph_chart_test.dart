import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/ph_sample.dart';
import 'package:titrator_app/ui/widgets/ph_chart.dart';

import 'harness.dart';

void main() {
  Widget chart(List<PhSample> samples) => testApp(
    SizedBox(height: 200, child: PhChart(samples: samples, target: 7)),
  );

  testWidgets('shows a placeholder without data', (tester) async {
    await tester.pumpWidget(chart(const []));
    await tester.pumpAndSettle();

    expect(find.text('No data'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('draws a line chart for samples', (tester) async {
    final t0 = DateTime(2026, 1, 1, 12);
    await tester.pumpWidget(
      chart([
        for (var i = 0; i < 5; i++)
          PhSample(t0.add(Duration(seconds: i)), 6.5 + i * 0.1),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('No data'), findsNothing);
    final data = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(data.lineBarsData.single.spots, hasLength(5));
    expect(data.extraLinesData.horizontalLines.single.y, 7);
    expect(data.minY, lessThan(6.5));
    expect(data.maxY, greaterThan(7));
  });
}
