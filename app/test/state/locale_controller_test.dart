import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/state/locale_controller.dart';

void main() {
  test('follows the system until a language is selected', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(localeProvider), isNull);

    container.read(localeProvider.notifier).select(const Locale('zh'));
    expect(container.read(localeProvider), const Locale('zh'));

    container.read(localeProvider.notifier).select(null);
    expect(container.read(localeProvider), isNull);
  });

  test('l10nFor picks the matching language and falls back to English', () {
    final en = l10nFor(const Locale('en')).titrationDoneTitle;
    expect(l10nFor(const Locale('zh')).titrationDoneTitle, isNot(en));
    expect(l10nFor(const Locale('fr')).titrationDoneTitle, en);
    expect(l10nFor(const Locale('zh', 'TW')).localeName, 'zh');
  });
}
