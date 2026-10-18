import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'data/app_notifier.dart';
import 'l10n/app_localizations.dart';
import 'state/locale_controller.dart';
import 'state/providers.dart';
import 'ui/scan_page.dart';

/// Initializes the app and runs it. [overrides] replace providers and
/// [builder] wraps the navigator; both are for the simulator entry point.
Future<void> runTitratorApp({
  List<Override> overrides = const [],
  TransitionBuilder? builder,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifier = AppNotifier();
  await notifier.init();
  runApp(
    ProviderScope(
      overrides: [
        appNotifierProvider.overrideWithValue(notifier),
        ...overrides,
      ],
      child: TitratorApp(builder: builder),
    ),
  );
}

class TitratorApp extends ConsumerWidget {
  const TitratorApp({super.key, this.builder});

  final TransitionBuilder? builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      locale: ref.watch(localeProvider),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: builder,
      home: const ScanPage(),
    );
  }
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: brightness,
  ),
  // Pages space their cards explicitly.
  cardTheme: const CardThemeData(margin: EdgeInsets.zero),
);
