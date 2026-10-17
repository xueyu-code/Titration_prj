import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import 'providers.dart';

/// User-selected UI language; null follows the system. Persisted in prefs.
final localeProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

class LocaleController extends Notifier<Locale?> {
  static const _key = 'locale';

  @override
  Locale? build() {
    final code = ref.read(prefsProvider).getString(_key);
    return code == null ? null : Locale(code);
  }

  void select(Locale? locale) {
    final prefs = ref.read(prefsProvider);
    if (locale == null) {
      unawaited(prefs.remove(_key));
    } else {
      unawaited(prefs.setString(_key, locale.languageCode));
    }
    state = locale == null ? null : Locale(locale.languageCode);
  }
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
