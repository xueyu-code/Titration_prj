import 'app.dart';
import 'sim/sim_link.dart';
import 'sim/sim_panel.dart';
import 'sim/sim_titrator.dart';
import 'state/providers.dart';
import 'state/scan_controller.dart';

/// Entry point of the hardware-free build: `flutter run -t lib/main_sim.dart`.
/// The simulated titrator replaces BLE.
Future<void> main() async {
  final sim = SimTitrator();
  final link = SimDeviceLink(sim);

  await runTitratorApp(
    overrides: [
      deviceLinkProvider.overrideWithValue(link),
      scanProvider.overrideWith(SimScanController.new),
    ],
    builder: (context, child) => SimPanel(sim: sim, link: link, child: child!),
  );
}
