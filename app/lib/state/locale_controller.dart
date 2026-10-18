import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';

/// User-selected UI language; null follows the system. Not persisted: every
/// launch starts by following the system.
final localeProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() => null;

  void select(Locale? locale) =>
      state = locale == null ? null : Locale(locale.languageCode);
}

/// Localized strings outside the widget tree (e.g. system notifications),
/// resolved the same way MaterialApp resolves them.
AppLocalizations l10nFor(Locale? selected) {
  final code = (selected ?? PlatformDispatcher.instance.locale).languageCode;
  final locale = AppLocalizations.supportedLocales.firstWhere(
    (l) => l.languageCode == code,
    orElse: () => const Locale('en'),
  );
  return lookupAppLocalizations(locale);
}
