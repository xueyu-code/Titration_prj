import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/locale_controller.dart';

/// AppBar action to pick the UI language. Menu values are language codes;
/// the empty string means "follow system" (a null value would read as "dismissed").
class LanguageButton extends ConsumerWidget {
  const LanguageButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(localeProvider)?.languageCode ?? '';

    CheckedPopupMenuItem<String> item(String code, String label) =>
        CheckedPopupMenuItem(
          value: code,
          checked: code == current,
          child: Text(label),
        );

    return PopupMenuButton<String>(
      icon: const Icon(Icons.translate),
      tooltip: l10n.language,
      onSelected: (code) => ref
          .read(localeProvider.notifier)
          .select(code.isEmpty ? null : Locale(code)),
      itemBuilder: (_) => [
        item('', l10n.languageSystem),
        item('zh', '中文'),
        item('en', 'English'),
      ],
    );
  }
}
