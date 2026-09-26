import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/l10n/app_localizations.dart';

void main() {
  test('Russian counts take all three of its plural forms', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(ru.settingsEpisodeCount(1), '1 серия');
    expect(ru.settingsEpisodeCount(3), '3 серии');
    expect(ru.settingsEpisodeCount(5), '5 серий');
    expect(ru.settingsEpisodeCount(21), '21 серия');
  });

  test('English is the first language, the one an unknown desktop gets', () {
    expect(AppLocalizations.supportedLocales.first, const Locale('en'));
  });
}
