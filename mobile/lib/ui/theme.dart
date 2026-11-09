// Colours, theme and hazard types for the driver app.
//
// Dark map, green accent (after the design reference). Built for a moving cab:
// large text, high contrast, few elements, large tap targets.

import 'package:flutter/material.dart';

class RG {
  static const bg = Color(0xFF0F1214);
  static const surface = Color(0xFF191E22);
  static const surfaceHigh = Color(0xFF252B30);
  static const border = Color(0xFF30373D);
  static const accent = Color(0xFF4CC38A); // railway line, GPS ok, main button
  static const onAccent = Color(0xFF07170F);
  static const danger = Color(0xFFE5484D); // hazard ahead
  static const warn = Color(0xFFF2A33A); // cannot check (no GPS, feed offline)
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
        contentTextStyle: TextStyle(color: RG.text, fontSize: 16),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? RG.accent : RG.surfaceHigh),
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
      orElse: () => HazardType(
          id, id.isEmpty ? 'Hazard' : id[0].toUpperCase() + id.substring(1), '⚠️', ''),
    );

String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String ago(DateTime t, DateTime now) {
  final m = now.difference(t).inMinutes;
  return m < 1 ? 'just now' : '$m min ago';
}
