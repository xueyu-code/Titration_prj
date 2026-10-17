import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:titrator_app/state/locale_controller.dart';
import 'package:titrator_app/state/providers.dart';

void main() {
  Future<(ProviderContainer, SharedPreferences)> setup(
    Map<String, Object> initial,
  ) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return (container, prefs);
  }

  test('follows the system until a language is selected', () async {
    final (container, prefs) = await setup({});
    expect(container.read(localeProvider), isNull);

    container.read(localeProvider.notifier).select(const Locale('zh'));
    expect(container.read(localeProvider), const Locale('zh'));
    expect(prefs.getString('locale'), 'zh');

    container.read(localeProvider.notifier).select(null);
    expect(container.read(localeProvider), isNull);
    expect(prefs.containsKey('locale'), isFalse);
  });

  test('restores the saved language', () async {
    final (container, _) = await setup({'locale': 'en'});
    expect(container.read(localeProvider), const Locale('en'));
  });

  test('l10nFor picks the matching language and falls back to English', () {
    final en = l10nFor(const Locale('en')).titrationDoneTitle;
    expect(l10nFor(const Locale('zh')).titrationDoneTitle, isNot(en));
    expect(l10nFor(const Locale('fr')).titrationDoneTitle, en);
    expect(l10nFor(const Locale('zh', 'TW')).localeName, 'zh');
  });
}
