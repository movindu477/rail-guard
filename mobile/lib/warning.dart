/// Warning maths for GPS hazard alerts: pure Dart, no Flutter or Firebase,
/// so it is unit tested in test/warning_test.dart.
///
/// Rule carried over from the camera pipeline: warn when unsure. If the
/// train's heading is unknown (standing or slow), every hazard within range
/// counts as ahead, so the warning falls back to distance alone.
library;

import 'dart:math';

/// Mean Earth radius (IUGG), metres. A sphere is within ~0.1% of the WGS84
/// ellipsoid at Sri Lankan latitudes: about 1 m over 2 km.
const double earthRadiusM = 6371008.8;

/// Hazards this far ahead or nearer are shown.
const double warnRangeM = 3000;

/// Within this many degrees either side of the heading counts as ahead.
const double aheadHalfAngleDeg = 45;

/// Reports older than this are ignored.
const Duration hazardMaxAge = Duration(minutes: 30);

/// Below this speed (m/s) the GPS heading is not trusted: it comes from
/// movement, so a standing train reads -1 or a frozen value.
const double minSpeedForHeadingMps = 1.0;

double _rad(double deg) => deg * pi / 180;
double _deg(double rad) => rad * 180 / pi;

/// Great-circle distance in metres (haversine).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1), p2 = _rad(lat2);
  final dp = p2 - p1, dl = _rad(lon2 - lon1);
  final h = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2);
  return 2 * earthRadiusM * asin(sqrt(min(1.0, h)));
}

/// Initial bearing from point 1 to point 2, degrees clockwise from north, 0 to 360.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1), p2 = _rad(lat2), dl = _rad(lon2 - lon1);
  final y = sin(dl) * cos(p2);
  final x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  return (_deg(atan2(y, x)) + 360) % 360;
}

/// Smallest angle between two directions, 0 to 180 degrees.
double angleDiffDeg(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// The GPS heading if it can be trusted, otherwise null (unknown).
double? usableHeading(double headingDeg, double speedMps) =>
    headingDeg < 0 || speedMps < minSpeedForHeadingMps ? null : headingDeg;

/// True if a hazard at [bearingToHazard] is ahead of a train heading
/// [headingDeg]. Unknown heading (null) counts as ahead: fail-safe.
bool isAhead(double bearingToHazard, double? headingDeg) =>
    headingDeg == null || angleDiffDeg(bearingToHazard, headingDeg) <= aheadHalfAngleDeg;

class Hazard {
  final String id;
  final double latitude;
  final double longitude;
  final String objectType;
  final DateTime? time; // null = unknown, kept (warn when unsure)
  /// 'blocked' (train cannot pass) or 'near' (pass with caution). Anything
  /// else, including missing, is treated as blocked: warn when unsure.
  final String severity;
  final String reportedBy; // 'auto' (train camera), 'driver', or '' (unknown)
  final String? unitId; // train unit that reported it
  final double? cameraDistanceM; // auto reports: camera's distance to the object
  final double? confidence; // auto reports: detector confidence

  const Hazard({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.objectType,
    this.time,
    this.severity = '',
    this.reportedBy = '',
    this.unitId,
    this.cameraDistanceM,
    this.confidence,
  });

  bool get blocked => severity != 'near';
}

// ---------------------------------------------------------------- tiers

/// Alert tiers for a following train, lowest first.
///   info     within 3 km: grey banner, no sound
///   caution  within 1 km: orange, one beep, short vibration
///   stop     within 400 m, or within 1 km if the line is blocked:
///            full screen, repeating alarm until acknowledged
enum AlertLevel { none, info, caution, stop }

const double infoRangeM = warnRangeM; // 3 km
const double cautionRangeM = 1000;
const double stopRangeM = 400;

AlertLevel alertLevel(double distanceM, {required bool blocked}) {
  if (distanceM <= stopRangeM) return AlertLevel.stop;
  if (distanceM <= cautionRangeM) return blocked ? AlertLevel.stop : AlertLevel.caution;
  if (distanceM <= infoRangeM) return AlertLevel.info;
  return AlertLevel.none;
}

class HazardWarning {
  final Hazard hazard;
  final double distanceM;
  final bool headingKnown; // false: shown on distance alone, direction not checked

  const HazardWarning(this.hazard, this.distanceM, this.headingKnown);

  AlertLevel get level => alertLevel(distanceM, blocked: hazard.blocked);

  /// e.g. "ANIMAL — 1.8 km ahead", or "ANIMAL — 1.8 km (direction unknown)".
  String get message =>
      '${hazard.objectType.toUpperCase()} — ${formatDistance(distanceM)}'
      '${headingKnown ? ' ahead' : ' (direction unknown)'}';
}

/// "850 m" below a kilometre, "1.8 km" above.
String formatDistance(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

/// Every hazard within [warnRangeM], ahead (or heading unknown) and not older
/// than [hazardMaxAge], most urgent first (highest level, then nearest).
List<HazardWarning> hazardsAhead({
  required double lat,
  required double lon,
  required double? headingDeg,
  required Iterable<Hazard> hazards,
  required DateTime now,
}) {
  final out = <HazardWarning>[];
  for (final h in hazards) {
    if (h.time != null && now.difference(h.time!) > hazardMaxAge) continue;
    final d = distanceM(lat, lon, h.latitude, h.longitude);
    if (d > warnRangeM) continue;
    if (!isAhead(bearingDeg(lat, lon, h.latitude, h.longitude), headingDeg)) continue;
    out.add(HazardWarning(h, d, headingDeg != null));
  }
  out.sort(
    (a, b) => a.level != b.level
        ? b.level.index.compareTo(a.level.index)
        : a.distanceM.compareTo(b.distanceM),
  );
  return out;
}

/// The nearest hazard that is within [warnRangeM], ahead (or heading
/// unknown) and not older than [hazardMaxAge]; null if there is none.
HazardWarning? closestHazardAhead({
  required double lat,
  required double lon,
  required double? headingDeg,
  required Iterable<Hazard> hazards,
  required DateTime now,
}) {
  final all = hazardsAhead(lat: lat, lon: lon, headingDeg: headingDeg, hazards: hazards, now: now);
  if (all.isEmpty) return null;
  return all.reduce((a, b) => b.distanceM < a.distanceM ? b : a);
}

/// Fires each level once per hazard: [raised] returns the hazards whose level
/// went above anything already announced for them. Moving back out and in
/// again (GPS noise at a boundary) does not repeat the sound.
class AlertTracker {
  final Map<String, AlertLevel> _announced = {};

  List<HazardWarning> raised(Iterable<HazardWarning> current) {
    final out = <HazardWarning>[];
    for (final w in current) {
      final before = _announced[w.hazard.id] ?? AlertLevel.none;
      if (w.level.index > before.index) {
        _announced[w.hazard.id] = w.level;
        out.add(w);
      }
    }
    return out;
  }

  AlertLevel announced(String hazardId) => _announced[hazardId] ?? AlertLevel.none;

  /// Drop hazards no longer active (cleared, expired), so memory stays small.
  void keepOnly(Set<String> activeIds) =>
      _announced.removeWhere((id, _) => !activeIds.contains(id));
}
