import 'dart:async';
import 'dart:math';

import 'app.dart';
import 'core/ph_sample.dart';
import 'data/sample_store.dart';
import 'sim/sim_link.dart';
import 'sim/sim_panel.dart';
import 'sim/sim_titrator.dart';
import 'state/providers.dart';
import 'state/scan_controller.dart';

/// Entry point of the hardware-free build: `flutter run -t lib/main_sim.dart`.
/// The simulated titrator replaces BLE, and its readings go to a separate
/// database so the real history stays untouched.
Future<void> main() async {
  final sim = SimTitrator();
  final link = SimDeviceLink(sim);
  // A relative path resolves against the platform's databases directory.
  final store = SampleStore(path: 'samples_sim.db');

  await runTitratorApp(
    overrides: [
      deviceLinkProvider.overrideWithValue(link),
      sampleStoreProvider.overrideWithValue(store),
      scanProvider.overrideWith(SimScanController.new),
    ],
    builder: (context, child) => SimPanel(sim: sim, link: link, child: child!),
  );
  unawaited(_seedHistory(store));
}

/// Fills an empty history with 24 hours of readings at 2 Hz, so the history
/// page has something to show.
Future<void> _seedHistory(SampleStore store) async {
  final now = DateTime.now();
  final start = now.subtract(const Duration(hours: 24));
  if ((await store.query(start, now, maxPoints: 10)).isNotEmpty) return;

  const interval = Duration(milliseconds: 500);
  const chunk = 7200; // one hour per transaction
  final total =
      const Duration(hours: 24).inMilliseconds ~/ interval.inMilliseconds;
  final random = Random();
  for (var i = 0; i < total; i += chunk) {
    await store.addAll([
      for (var j = i; j < min(i + chunk, total); j++)
        PhSample(start.add(interval * j), _historyPh(interval * j, random)),
    ]);
  }
}

/// A slow drift plus a faster wobble and a little noise.
double _historyPh(Duration t, Random random) {
  final minutes = t.inMilliseconds / 60000;
  final ph =
      7 +
      0.8 * sin(2 * pi * minutes / 180) +
      0.3 * sin(2 * pi * minutes / 17) +
      (random.nextDouble() - 0.5) * 0.02;
  return ph.clamp(0.0, 14.0);
}
