// Colours, theme and hazard types for the driver app.
//
// Dark map, green accent (after the design reference). Built for a moving cab:
// large text, high contrast, few elements, large tap targets.

import 'package:flutter/material.dart';

import '../warning.dart';

/// Text sizes: one scale for the whole app. Medium weights; bold only where
/// a glance must catch it (alert distance).
class TS {
  static const title = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: RG.text);
  static const body = TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: RG.text);
  static const bodyStrong = TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: RG.text);
  static const small = TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: RG.textDim);
  static const button = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
}

class RG {
  static const bg = Color(0xFF0F1214);
  static const surface = Color(0xFF191E22);
  static const surfaceHigh = Color(0xFF252B30);
  static const border = Color(0xFF30373D);
  static const accent = Color(0xFF4CC38A); // railway line, GPS ok, main button
  static const onAccent = Color(0xFF07170F);
  static const danger = Color(0xFFE5484D); // hazard ahead
  static const warn = Color(0xFFF2A33A); // CAUTION tier; also "cannot check" (no GPS, feed offline)
  static const info = Color(0xFF8C979E); // INFO tier
  static const text = Color(0xFFF1F3F4);
  static const textDim = Color(0xFF9AA4AB);
}

ThemeData railGuardTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: RG.bg,
  colorScheme: const ColorScheme.dark(
    primary: RG.accent,
    onPrimary: RG.onAccent,
    surface: RG.surface,
    error: RG.danger,
  ),
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: RG.surfaceHigh,
    contentTextStyle: TextStyle(color: RG.text, fontSize: 14),
  ),
  switchTheme: SwitchThemeData(
    trackColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected) ? RG.accent : RG.surfaceHigh,
    ),
    thumbColor: const WidgetStatePropertyAll(Colors.white),
    trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
  ),
);

/// What the driver can report. [id] is the Firestore object_type.
class HazardType {
  final String id, label, emoji, hint;
  const HazardType(this.id, this.label, this.emoji, this.hint);
}

const hazardTypes = [
  HazardType('animal', 'Animal', '🐘', 'Elephant, cattle, dog'),
  HazardType('person', 'Person', '🚶', 'On or beside the track'),
  HazardType('vehicle', 'Vehicle', '🚗', 'Car, tuk-tuk, lorry at a crossing'),
  HazardType('obstruction', 'Obstruction', '🪵', 'Fallen tree, rocks, debris'),
];

/// Type info for any object_type, including ones written by hand or by the
/// train unit (e.g. "manual", "test").
HazardType typeInfo(String id) => hazardTypes.firstWhere(
  (t) => t.id == id,
  orElse: () =>
      HazardType(id, id.isEmpty ? 'Hazard' : id[0].toUpperCase() + id.substring(1), '⚠️', ''),
);

/// How bad it is, chosen after the type. [id] is the Firestore severity.
class Severity {
  final String id, label, hint, emoji;
  final Color colour;
  const Severity(this.id, this.label, this.hint, this.emoji, this.colour);
}

const severities = [
  Severity('blocked', 'Line blocked', 'Train cannot pass', '🛑', RG.danger),
  Severity('near', 'Near the line', 'Pass with caution', '⚠️', RG.warn),
];

/// Missing or unknown severity is shown, and treated, as blocked (fail-safe).
Severity severityInfo(Hazard h) => h.blocked
    ? (h.severity == 'blocked'
          ? severities[0]
          : const Severity(
              'blocked',
              'Line blocked (assumed)',
              'Severity not given',
              '🛑',
              RG.danger,
            ))
    : severities[1];

/// Who reported it: a camera detection and a driver's eyes carry different confidence.
String reporterText(Hazard h) {
  final unit = h.unitId == null ? '' : ' · ${h.unitId}';
  switch (h.reportedBy) {
    case 'auto':
      final conf = h.confidence == null ? '' : ', ${(h.confidence! * 100).round()}% confidence';
      return 'Train camera (automatic$conf)$unit';
    case 'driver':
      return 'Driver report$unit';
    default:
      return 'Source unknown$unit';
  }
}

Color levelColour(AlertLevel l) => switch (l) {
  AlertLevel.stop => RG.danger,
  AlertLevel.caution => RG.warn,
  AlertLevel.info => RG.info,
  AlertLevel.none => RG.border,
};

String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String ago(DateTime t, DateTime now) {
  final m = now.difference(t).inMinutes;
  return m < 1 ? 'just now' : '$m min ago';
}
