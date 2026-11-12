// Colours, text styles and hazard types for the driver app.
//
// Light map with white floating cards (after the design reference); red from
// the RailGuard logo for the main action and STOP; blue for location.
// Built for a moving cab: clear contrast, few elements, large tap targets.

import 'package:flutter/material.dart';

import '../warning.dart';

class RG {
  static const bg = Color(0xFFF3F4F6);
  static const surface = Colors.white;
  static const surfaceHigh = Color(0xFFF1F3F6); // icon circles, chips
  static const border = Color(0xFFE4E7EC);
  static const pill = Color(0xFF1E2023); // dark "live" status pill
  static const text = Color(0xFF16181C);
  static const textDim = Color(0xFF6B7280);
  static const brand = Color(0xFFE82529); // logo red: Report, STOP
  static const blue = Color(0xFF2F6BFF); // location, railway line, links
  static const live = Color(0xFF22C55E); // GPS live dot
  static const danger = brand; // STOP tier
  static const warn = Color(0xFFF59E0B); // CAUTION tier; also "cannot check"
  static const info = Color(0xFF64748B); // INFO tier
  static const shadow = Color(0x22000000);
}

/// One text scale for the whole app: medium weights, bold only where a
/// glance must catch it (alert distance).
class TS {
  static const title = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: RG.text);
  static const body = TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: RG.text);
  static const bodyStrong = TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: RG.text);
  static const small = TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: RG.textDim);
  static const label = TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: RG.text);
  static const button = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
}

/// Soft drop shadow for the floating cards and buttons.
const cardShadow = [BoxShadow(color: RG.shadow, blurRadius: 14, offset: Offset(0, 4))];

ThemeData railGuardTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  scaffoldBackgroundColor: RG.bg,
  colorScheme: const ColorScheme.light(
    primary: RG.blue,
    onPrimary: Colors.white,
    surface: RG.surface,
    error: RG.danger,
  ),
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: RG.pill,
    contentTextStyle: TextStyle(color: Colors.white, fontSize: 14),
  ),
);

/// What the driver can report. [id] is the Firestore object_type.
class HazardType {
  final String id, label, hint;
  final IconData icon;
  final Color colour;
  const HazardType(this.id, this.label, this.hint, this.icon, this.colour);
}

const hazardTypes = [
  HazardType('animal', 'Animal', 'Elephant, cattle, dog', Icons.pets, Color(0xFF8B5CF6)),
  HazardType(
    'person',
    'Person',
    'On or beside the track',
    Icons.directions_walk,
    Color(0xFF2F6BFF),
  ),
  HazardType(
    'vehicle',
    'Vehicle',
    'Car, tuk-tuk, lorry at a crossing',
    Icons.directions_car,
    Color(0xFF0EA5E9),
  ),
  HazardType(
    'obstruction',
    'Obstruction',
    'Fallen tree, rocks, debris',
    Icons.landslide,
    Color(0xFFD97706),
  ),
];

/// Type info for any object_type, including ones written by hand or by the
/// train unit (e.g. "manual", "test").
HazardType typeInfo(String id) => hazardTypes.firstWhere(
  (t) => t.id == id,
  orElse: () => HazardType(
    id,
    id.isEmpty ? 'Hazard' : id[0].toUpperCase() + id.substring(1),
    '',
    Icons.warning_amber_rounded,
    RG.info,
  ),
);

/// How bad it is, chosen after the type. [id] is the Firestore severity.
class Severity {
  final String id, label, hint;
  final IconData icon;
  final Color colour;
  const Severity(this.id, this.label, this.hint, this.icon, this.colour);
}

const severities = [
  Severity('blocked', 'Line blocked', 'Train cannot pass', Icons.do_not_disturb_on, RG.danger),
  Severity('near', 'Near the line', 'Pass with caution', Icons.warning_amber_rounded, RG.warn),
];

/// Missing or unknown severity is shown, and treated, as blocked (fail-safe).
Severity severityInfo(Hazard h) => h.blocked
    ? (h.severity == 'blocked'
          ? severities[0]
          : const Severity(
              'blocked',
              'Line blocked (assumed)',
              'Severity not given',
              Icons.do_not_disturb_on,
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
  AlertLevel.none => const Color(0xFF9CA3AF),
};

String levelName(AlertLevel l) => switch (l) {
  AlertLevel.stop => 'STOP',
  AlertLevel.caution => 'CAUTION',
  AlertLevel.info => 'INFO',
  AlertLevel.none => '',
};

String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String ago(DateTime t, DateTime now) {
  final m = now.difference(t).inMinutes;
  return m < 1 ? 'just now' : '$m min ago';
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Mon 10" for the status card.
String dayLabel(DateTime t) => '${_days[t.weekday - 1]} ${t.day}';

/// Round icon in a tinted circle: hazard types, severities, list rows.
Widget iconCircle(IconData icon, Color colour, {double size = 44, bool filled = false}) =>
    Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? colour : colour.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: filled ? Colors.white : colour, size: size * 0.5),
    );
