/// Warning maths for GPS hazard alerts: pure Dart, no Flutter or Firebase,
/// so it is unit tested in test/warning_test.dart.
///
/// Rule carried over from the camera pipeline: warn when unsure. If the
/// train's heading is unknown (standing or slow), every hazard within range
/// counts as ahead, so the warning falls back to distance alone.
library;

import 'dart:math';

import 'track.dart';
export 'track.dart';

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

  // Lifecycle fields (Step 5)
  final String status; // 'active' or 'cleared'
  final String? reportedByUid; // Firebase Auth uid of reporting driver, if any
  final List<String> confirmedByUids; // drivers who answered "Still there"
  final List<String> notSeenByUids; // drivers who answered "Did not see"
  final List<String> clearedByUids; // drivers who answered "Cleared"
  final String? clearedBy; // unit id that finalized the clear
  final String? clearedByUid; // driver uid that finalized the clear
  final DateTime? clearedAt;

  /// True when this report is queued locally and has not yet been confirmed by Firestore.
  final bool pendingSend;

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
    this.status = 'active',
    this.reportedByUid,
    this.confirmedByUids = const [],
    this.notSeenByUids = const [],
    this.clearedByUids = const [],
    this.clearedBy,
    this.clearedByUid,
    this.clearedAt,
    this.pendingSend = false,
  });

  bool get blocked => severity != 'near';
  bool get isAutoReport => reportedBy == 'auto';
  bool get isActive => status == 'active';
  int get confirmedCount => confirmedByUids.length;
  int get notSeenCount => notSeenByUids.length;
  int get clearedVotesCount => clearedByUids.length;

  Hazard copyWith({
    DateTime? time,
    String? status,
    String? reportedByUid,
    List<String>? confirmedByUids,
    List<String>? notSeenByUids,
    List<String>? clearedByUids,
    String? clearedBy,
    String? clearedByUid,
    DateTime? clearedAt,
    bool? pendingSend,
  }) => Hazard(
    id: id,
    latitude: latitude,
    longitude: longitude,
    objectType: objectType,
    time: time ?? this.time,
    severity: severity,
    reportedBy: reportedBy,
    unitId: unitId,
    cameraDistanceM: cameraDistanceM,
    confidence: confidence,
    status: status ?? this.status,
    reportedByUid: reportedByUid ?? this.reportedByUid,
    confirmedByUids: confirmedByUids ?? this.confirmedByUids,
    notSeenByUids: notSeenByUids ?? this.notSeenByUids,
    clearedByUids: clearedByUids ?? this.clearedByUids,
    clearedBy: clearedBy ?? this.clearedBy,
    clearedByUid: clearedByUid ?? this.clearedByUid,
    clearedAt: clearedAt ?? this.clearedAt,
    pendingSend: pendingSend ?? this.pendingSend,
  );
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
  final bool alongTrack; // true if distance was measured along the railway line
  final bool onAnotherLine; // true if hazard snapped to a different route
  final AlertLevel? overrideLevel;

  const HazardWarning(
    this.hazard,
    this.distanceM,
    this.headingKnown, {
    this.alongTrack = false,
    this.onAnotherLine = false,
    this.overrideLevel,
  });

  AlertLevel get level => overrideLevel ?? alertLevel(distanceM, blocked: hazard.blocked);

  /// e.g. "ANIMAL — 1.8 km along the line", or "ANIMAL — 1.8 km ahead", or "ANIMAL — 1.8 km (on another line)".
  String get message {
    final distStr = formatDistance(distanceM);
    if (onAnotherLine) {
      return '${hazard.objectType.toUpperCase()} — $distStr (on another line)';
    }
    if (alongTrack) {
      return '${hazard.objectType.toUpperCase()} — $distStr along the line';
    }
    return '${hazard.objectType.toUpperCase()} — $distStr'
        '${headingKnown ? ' ahead' : ' (direction unknown)'}';
  }
}

/// "850 m" below a kilometre, "1.8 km" above.
String formatDistance(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

/// Every hazard within [warnRangeM], ahead (or heading unknown) and not older
/// than [hazardMaxAge], most urgent first (highest level, then nearest).
///
/// When [network] is null, falls back byte-identically to the bearing and
/// haversine straight-line method.
List<HazardWarning> hazardsAhead({
  required double lat,
  required double lon,
  required double? headingDeg,
  required Iterable<Hazard> hazards,
  required DateTime now,
  RailNetwork? network,
  TravelDirection? travelDirection,
  double? gpsAccuracyM,
}) {
  // If no network is provided, behave exactly as before (regression requirement).
  if (network == null) {
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

  // Snap the train. If train snap fails or offset > max(15.0, gpsAccuracyM), along-track cannot
  // be used confidently: fall back to bearing & haversine for everything.
  final trainPos = network.snap(lat, lon, gpsAccuracyM: gpsAccuracyM);
  final isTrainConfident =
      trainPos != null && trainPos.offsetM <= max(15.0, gpsAccuracyM ?? 15.0);
  if (!isTrainConfident) {
    final out = <HazardWarning>[];
    for (final h in hazards) {
      if (h.time != null && now.difference(h.time!) > hazardMaxAge) continue;
      final d = distanceM(lat, lon, h.latitude, h.longitude);
      if (d > warnRangeM) continue;
      if (!isAhead(bearingDeg(lat, lon, h.latitude, h.longitude), headingDeg)) continue;
      out.add(HazardWarning(h, d, headingDeg != null, alongTrack: false));
    }
    out.sort(
      (a, b) => a.level != b.level
          ? b.level.index.compareTo(a.level.index)
          : a.distanceM.compareTo(b.distanceM),
    );
    return out;
  }

  // Work out travel direction along the route if not provided
  final dir = travelDirection ??
      network.travelDirectionFromHeading(
        position: trainPos,
        headingDeg: headingDeg,
      );

  final out = <HazardWarning>[];

  for (final h in hazards) {
    if (h.time != null && now.difference(h.time!) > hazardMaxAge) continue;

    // Calculate baseline straight-line bearing and haversine outcome
    final straightD = distanceM(lat, lon, h.latitude, h.longitude);
    final oldBearing = bearingDeg(lat, lon, h.latitude, h.longitude);
    final oldAhead = isAhead(oldBearing, headingDeg);
    final oldLevel = (straightD <= warnRangeM && oldAhead)
        ? alertLevel(straightD, blocked: h.blocked)
        : AlertLevel.none;

    // Snap the hazard to the railway network
    final hazardPos = network.snap(h.latitude, h.longitude);
    final isHazardConfident = hazardPos != null && hazardPos.offsetM <= 15.0;

    // Confident means: train and hazard candidate sets overlap, both within tolerance.
    final sharedRoutes = (hazardPos != null && isHazardConfident)
        ? trainPos.candidateRouteIds.intersection(hazardPos.candidateRouteIds)
        : <String>{};
    final isConfident = sharedRoutes.isNotEmpty;

    if (isConfident) {
      // Find candidate on the shared route that gives the shortest distance
      double? bestDiff;
      double minAbs = double.infinity;
      String? chosenRoute;

      for (final rId in sharedRoutes) {
        final tCand = trainPos.candidateForRoute(rId);
        final hCand = hazardPos!.candidateForRoute(rId);
        if (tCand != null && hCand != null) {
          final diff = hCand.chainageM - tCand.chainageM;
          if (diff.abs() < minAbs) {
            minAbs = diff.abs();
            bestDiff = diff;
            chosenRoute = rId;
          }
        }
      }

      final diff = bestDiff!;
      final alongD = diff.abs();

      var routeDir = dir;
      if (chosenRoute != null && chosenRoute != trainPos.routeId) {
        final tCand = trainPos.candidateForRoute(chosenRoute);
        if (tCand != null && headingDeg != null) {
          routeDir = network.travelDirectionFromHeading(
            position: tCand,
            headingDeg: headingDeg,
          );
        }
      }

      final bool isAheadOnTrack;
      if (routeDir == TravelDirection.increasing) {
        isAheadOnTrack = diff > 0;
      } else if (routeDir == TravelDirection.decreasing) {
        isAheadOnTrack = diff < 0;
      } else {
        // Travel direction unknown (standing or slow) -> every hazard on route counts as ahead
        isAheadOnTrack = true;
      }

      if (isAheadOnTrack && alongD <= warnRangeM) {
        // In the confident path, alertLevel() runs on along-track distance with NO override.
        final level = alertLevel(alongD, blocked: h.blocked);
        if (level != AlertLevel.none) {
          out.add(HazardWarning(
            h,
            alongD,
            routeDir != TravelDirection.unknown,
            alongTrack: true,
          ));
        }
      }
      // If not ahead on track or beyond warnRangeM, hazard is not alerted.
      continue;
    }

    // Fallback path: along-track was not used (offsets too large, snap failed, or disjoint candidate sets).
    // Keep the never-quieter clamp only where along-track was not used.
    if (hazardPos != null && !trainPos.sharesLineWith(hazardPos)) {
      // Hazard candidate set is disjoint from train's -> downgrade to INFO and label "on another line"
      if (straightD <= warnRangeM || oldLevel == AlertLevel.stop || oldLevel == AlertLevel.caution) {
        var level = AlertLevel.info;
        if (oldLevel == AlertLevel.stop) {
          level = AlertLevel.stop;
        } else if (oldLevel == AlertLevel.caution) {
          level = AlertLevel.caution;
        }
        out.add(HazardWarning(
          h,
          straightD,
          headingDeg != null,
          alongTrack: false,
          onAnotherLine: true,
          overrideLevel: level,
        ));
      }
    } else {
      // Hazard snap failed or hazard offset > 15 m.
      // The old straight-line behaviour and clamp both stand.
      if (straightD <= warnRangeM && oldAhead) {
        out.add(HazardWarning(
          h,
          straightD,
          headingDeg != null,
          alongTrack: false,
        ));
      } else if (oldLevel == AlertLevel.stop || oldLevel == AlertLevel.caution) {
        out.add(HazardWarning(
          h,
          straightD,
          headingDeg != null,
          alongTrack: false,
          overrideLevel: oldLevel,
        ));
      }
    }
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
  RailNetwork? network,
  TravelDirection? travelDirection,
}) {
  final all = hazardsAhead(
    lat: lat,
    lon: lon,
    headingDeg: headingDeg,
    hazards: hazards,
    now: now,
    network: network,
    travelDirection: travelDirection,
  );
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
