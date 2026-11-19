// Localization tests (Step 7): ARB completeness, non-empty translations,
// live locale switching, unknown-locale fallback to English, font selection,
// and shared_preferences persistence.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/l10n/app_localizations.dart';
import 'package:railguard_app/locale_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _loadArb(String filename) {
  var path = 'lib/l10n/$filename';
  if (!File(path).existsSync()) {
    path = 'mobile/lib/l10n/$filename';
  }
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('ARB completeness & integrity (Step 7)', () {
    late Map<String, dynamic> en;
    late Map<String, dynamic> si;
    late Map<String, dynamic> ta;

    setUpAll(() {
      en = _loadArb('app_en.arb');
      si = _loadArb('app_si.arb');
      ta = _loadArb('app_ta.arb');
    });

    test('every key present in app_en.arb exists in both app_si.arb and app_ta.arb', () {
      final enKeys = en.keys.where((k) => !k.startsWith('@')).toList();
      expect(enKeys, isNotEmpty);

      for (final key in enKeys) {
        expect(si.containsKey(key), isTrue, reason: 'Missing key "$key" in app_si.arb');
        expect(ta.containsKey(key), isTrue, reason: 'Missing key "$key" in app_ta.arb');
      }
    });

    test('no key has an empty value in app_en.arb, app_si.arb or app_ta.arb', () {
      for (final entry in [('en', en), ('si', si), ('ta', ta)]) {
        final (lang, map) = entry;
        for (final k in map.keys.where((k) => !k.startsWith('@'))) {
          final v = map[k];
          expect(v, isA<String>(), reason: '$lang[$k] must be a String');
          expect((v as String).trim(), isNotEmpty, reason: '$lang[$k] must not be empty');
        }
      }
    });
  });

  group('Locale resolution, switching & persistence (Step 7)', () {
    test('switching locale changes the resolved operational strings', () async {
      final enL10n = await AppLocalizations.delegate.load(const Locale('en'));
      final siL10n = await AppLocalizations.delegate.load(const Locale('si'));
      final taL10n = await AppLocalizations.delegate.load(const Locale('ta'));

      expect(enL10n.alertStop, equals('STOP'));
      expect(siL10n.alertStop, equals('නවත්වන්න'));
      expect(taL10n.alertStop, equals('நிறுத்து'));

      expect(siL10n.btnAcknowledge, isNot(equals(enL10n.btnAcknowledge)));
      expect(taL10n.btnAcknowledge, isNot(equals(enL10n.btnAcknowledge)));
      expect(siL10n.btnAcknowledge, isNot(equals(taL10n.btnAcknowledge)));

      expect(siL10n.statusCannotCheckNoSignal, isNot(equals(enL10n.statusCannotCheckNoSignal)));
      expect(taL10n.statusCannotCheckNoSignal, isNot(equals(enL10n.statusCannotCheckNoSignal)));
    });

    test('unknown locale falls back to English', () async {
      expect(resolveAppLocale(const Locale('fr')), equals(const Locale('en')));
      expect(resolveAppLocale(const Locale('de', 'DE')), equals(const Locale('en')));
      expect(resolveAppLocale(null), equals(const Locale('en')));

      // Supported locales resolve cleanly even with country codes
      expect(resolveAppLocale(const Locale('si', 'LK')), equals(const Locale('si')));
      expect(resolveAppLocale(const Locale('ta', 'LK')), equals(const Locale('ta')));

      final fallbackL10n = await AppLocalizations.delegate.load(
        resolveAppLocale(const Locale('fr')),
      );
      expect(fallbackL10n.alertStop, equals('STOP'));
      expect(fallbackL10n.btnAcknowledge, equals('ACKNOWLEDGE'));
    });

    test('bundled fonts are selected for Sinhala and Tamil locales', () {
      expect(fontFamilyForLocale(const Locale('si')), equals('NotoSansSinhala'));
      expect(fontFamilyForLocale(const Locale('ta')), equals('NotoSansTamil'));
      expect(fontFamilyForLocale(const Locale('en')), isNull);
    });

    test('saved locale persists in shared_preferences across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadSavedLocale(), isNull);

      await setAppLocale(const Locale('si'));
      expect(appLocaleNotifier.value, equals(const Locale('si')));
      expect(await loadSavedLocale(), equals(const Locale('si')));

      await setAppLocale(const Locale('ta'));
      expect(appLocaleNotifier.value, equals(const Locale('ta')));
      expect(await loadSavedLocale(), equals(const Locale('ta')));

      await setAppLocale(const Locale('en'));
      expect(await loadSavedLocale(), equals(const Locale('en')));
    });
  });
}
