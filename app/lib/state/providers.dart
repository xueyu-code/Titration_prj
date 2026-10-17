import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/protocol.dart';
import '../data/app_notifier.dart';
import '../data/device_link.dart';

/// Overridden in main() with the instance loaded before runApp.
final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('prefsProvider must be overridden'),
);

/// Overridden in main() with the initialized instance.
final appNotifierProvider = Provider<AppNotifier>(
  (ref) => throw UnimplementedError('appNotifierProvider must be overridden'),
);

/// Wall clock; tests override it to drive time-based logic.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final bleProvider = Provider<FlutterReactiveBle>((ref) => FlutterReactiveBle());

final deviceLinkProvider = Provider<DeviceLink>((ref) {
  final link = DeviceLink(ref.watch(bleProvider));
  ref.onDispose(link.dispose);
  return link;
});

/// Raw device events, for UI side effects such as error snack bars.
final deviceEventsProvider = StreamProvider<DeviceEvent>(
  (ref) => ref.watch(deviceLinkProvider).events,
);
