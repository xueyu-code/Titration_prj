import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/l10n/app_localizations.dart';
import 'package:titrator_app/state/device_controller.dart';

/// Hosts [child] with localization and the given provider overrides.
Widget testApp(
  Widget child, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

const connectedIdle = DeviceState(
  link: LinkStatus.connected,
  mode: DeviceMode.idle,
  ph: 7.0,
);

/// Device session without BLE: records the commands the UI sends.
class FakeDeviceController extends DeviceController {
  FakeDeviceController([this.initial = connectedIdle]);

  final DeviceState initial;
  final sent = <Command>[];

  /// Wire names of the recorded commands, e.g. `['jog', 'stop']`.
  List<Object?> get sentNames => [for (final c in sent) c.toJson()['cmd']];

  @override
  DeviceState build() => initial;

  @override
  Future<void> send(Command command) async => sent.add(command);

  @override
  Future<void> startTitration(double target) async =>
      sent.add(StartTitration(target));

  @override
  Future<void> stop() async => sent.add(const StopAll());
}
