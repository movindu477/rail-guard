/// App language preference persistence, fallback resolution, and bundled font
/// selection for Sinhala and Tamil.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _localeStoreKey = 'railguard.locale.v1';

/// Set to true only once every row in outputs/tables/translations_for_review.csv
/// has been reviewed by native Sinhala and Tamil speakers.
const bool translationsReviewed = false;

/// Supported operational locales: English, Sinhala (si), Tamil (ta).
const List<Locale> supportedAppLocales = [
  Locale('en'),
  Locale('si'),
  Locale('ta'),
];

/// Bundled font fallbacks so Sinhala and Tamil glyphs always render even on
/// older Android handsets that lack system Sinhala/Tamil fonts.
const List<String> scriptFontFallbacks = [
  'NotoSansSinhala',
  'NotoSansTamil',
];

/// Resolves [requested] to one of [supportedAppLocales], falling back to
/// English (`en`) for any unknown or unsupported locale.
Locale resolveAppLocale(Locale? requested) {
  if (requested != null) {
    for (final s in supportedAppLocales) {
      if (s.languageCode == requested.languageCode) return s;
    }
  }
  return const Locale('en');
}

/// Primary bundled font family for [locale], or null for English/default.
String? fontFamilyForLocale(Locale? locale) {
  switch (locale?.languageCode) {
    case 'si':
      return 'NotoSansSinhala';
    case 'ta':
      return 'NotoSansTamil';
    default:
      return null;
  }
}

/// Live notifier listened to by RailGuardApp so changing language in Driver
/// details applies immediately across the whole app without a relaunch.
final ValueNotifier<Locale?> appLocaleNotifier = ValueNotifier<Locale?>(null);

/// Loads the driver's saved language choice from shared_preferences.
/// Returns null when none is saved (meaning: follow device locale -> fallback en).
Future<Locale?> loadSavedLocale() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString(_localeStoreKey);
  if (code == null || code.isEmpty) return null;
  for (final s in supportedAppLocales) {
    if (s.languageCode == code) return s;
  }
  return null;
}

/// Persists [locale] in shared_preferences (or clears if null).
Future<void> saveLocale(Locale? locale) async {
  final prefs = await SharedPreferences.getInstance();
  if (locale == null) {
    await prefs.remove(_localeStoreKey);
  } else {
    await prefs.setString(_localeStoreKey, locale.languageCode);
  }
}

/// Applies [locale] immediately to the running app and persists it across restarts.
Future<void> setAppLocale(Locale locale) async {
  final resolved = resolveAppLocale(locale);
  appLocaleNotifier.value = resolved;
  await saveLocale(resolved);
}
