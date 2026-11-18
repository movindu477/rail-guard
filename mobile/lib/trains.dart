/// Live presence of other trains on the railway line: pure Dart, no Flutter or
/// Firebase, so it is unit tested in test/trains_test.dart.
///
/// Other trains are shown on the map for situational awareness only — they
/// never feed into hazard alerting (warning.dart).
library;

import 'driver.dart';
import 'warning.dart';

/// Under 60 s is considered live; 60 s to 5 min is shown faded as stale;
/// anything older than 5 min is dropped from the map.
const Duration trainLiveMaxAge = Duration(seconds: 60);
const Duration trainMaxAge = Duration(minutes: 5);

enum TrainFreshness { live, stale, dropped }

/// Freshness of a train position report at [now].
/// A missing timestamp ([lastSeen] == null) is treated as [TrainFreshness.stale],
/// never [TrainFreshness.live], so an unknown age is never shown as current.
TrainFreshness trainFreshness(DateTime? lastSeen, DateTime now) {
  if (lastSeen == null) return TrainFreshness.stale;
  final age = now.difference(lastSeen);
  if (age < trainLiveMaxAge) return TrainFreshness.live;
  if (age <= trainMaxAge) return TrainFreshness.stale;
  return TrainFreshness.dropped;
}

/// Converts m/s from Geolocator to rounded km/h, or null when unknown/negative.
int? speedMpsToKmh(double? speedMps) =>
    speedMps == null || speedMps < 0 ? null : (speedMps * 3.6).round();

/// Human-readable age for the train sheet ("updated 12 s ago", "updated 3 min ago").
String trainUpdatedAgo(DateTime? lastSeen, DateTime now) {
  if (lastSeen == null) return 'update time unknown';
  final secs = now.difference(lastSeen).inSeconds.clamp(0, 99999);
  if (secs < 60) return 'updated $secs s ago';
  return 'updated ${secs ~/ 60} min ago';
}

class OtherTrain {
  final String unitId;
  final String trainNo;
  final String driverName;
  final Service service;
  final double lat;
  final double lon;
  final double? heading;
  final double? speedMps;
  final DateTime? lastSeen;

  const OtherTrain({
    required this.unitId,
    required this.trainNo,
    required this.driverName,
    required this.service,
    required this.lat,
    required this.lon,
    this.heading,
    this.speedMps,
    this.lastSeen,
  });

  /// Speed in km/h (rounded), or null if unknown.
  int? get speedKmh => speedMpsToKmh(speedMps);

  /// Short label for the map marker: train number if set, otherwise unit id.
  String get markerLabel => trainNo.trim().isNotEmpty ? trainNo.trim() : unitId;

  /// e.g. "1005 UP" or "unit-02 UP".
  String get trainLabel => '$markerLabel ${service.short}';

  TrainFreshness freshness(DateTime now) => trainFreshness(lastSeen, now);

  bool isLive(DateTime now) => freshness(now) == TrainFreshness.live;

  double? distanceFrom(double? fromLat, double? fromLon) =>
      fromLat == null || fromLon == null ? null : distanceM(fromLat, fromLon, lat, lon);

  /// Parses a `train_position/{unitId}` map (with [lastSeen] already converted
  /// from Firestore Timestamp if present). Returns null if coordinates are missing.
  static OtherTrain? fromMap(String id, Map<String, dynamic> d, {DateTime? lastSeen}) {
    final lat = d['latitude'], lon = d['longitude'];
    if (lat is! num || lon is! num) return null;
    final unit = (d['unit_id'] as String?)?.trim();
    final heading = d['heading'];
    final speed = d['speed_mps'];
    return OtherTrain(
      unitId: (unit != null && unit.isNotEmpty) ? unit : id,
      trainNo: ((d['train_no'] as String?) ?? '').trim(),
      driverName: ((d['driver_name'] as String?) ?? '').trim(),
      service: serviceFrom(d['service']),
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      heading: heading is num && heading >= 0 ? heading.toDouble() : null,
      speedMps: speed is num && speed >= 0 ? speed.toDouble() : null,
      lastSeen: lastSeen,
    );
  }
}

/// Filters and orders trains for the map and list:
/// - drops this phone's own [ownUnitId]
/// - drops any train older than [trainMaxAge] (5 minutes)
/// - keeps both live (< 60 s) and stale (60 s .. 5 min, or null timestamp) trains
/// - sorts nearest-first from ([lat], [lon]) when a reference position is given.
List<OtherTrain> trainsToShow({
  required Iterable<OtherTrain> trains,
  required String ownUnitId,
  required DateTime now,
  double? lat,
  double? lon,
}) {
  final out = <OtherTrain>[
    for (final t in trains)
      if (t.unitId != ownUnitId && t.freshness(now) != TrainFreshness.dropped) t,
  ];
  if (lat != null && lon != null) {
    out.sort(
      (a, b) => distanceM(lat, lon, a.lat, a.lon).compareTo(distanceM(lat, lon, b.lat, b.lon)),
    );
  }
  return out;
}

/// Conflict classification for another train relative to this train.
enum TrainConflict {
  approaching, // opposite direction, gap closing (or direction unknown fail-safe)
  ahead, // same direction, ahead of us
  behind, // same direction, behind us
  otherLine, // candidate sets disjoint from ours, never approaching
  unknown, // indeterminate
}

class TrainConflictInfo {
  final TrainConflict conflict;
  final double? alongTrackGapM;
  final double? closingSpeedMps;
  final Duration? timeToMeet;
  final bool isDirectionUnknown;
  final String? sharedRouteId;

  const TrainConflictInfo({
    required this.conflict,
    this.alongTrackGapM,
    this.closingSpeedMps,
    this.timeToMeet,
    this.isDirectionUnknown = false,
    this.sharedRouteId,
  });

  /// Combined closing speed in km/h, or null when unknown.
  int? get closingSpeedKmh =>
      closingSpeedMps == null ? null : (closingSpeedMps! * 3.6).round();

  /// Formatted time to meet, or 'unknown' if combined speed is zero or null.
  String get timeToMeetText {
    if (timeToMeet == null || (closingSpeedMps ?? 0) <= 0.05) return 'unknown';
    final totalSecs = timeToMeet!.inSeconds;
    if (totalSecs < 60) return '$totalSecs s';
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    if (mins >= 60) {
      final hours = mins ~/ 60;
      final remMins = mins % 60;
      return '$hours h $remMins min';
    }
    return secs == 0 ? '$mins min' : '$mins min $secs s';
  }
}

/// Classifies conflict between own train and [otherTrain].
TrainConflictInfo classifyTrainConflict({
  required RailNetwork network,
  required TrackPosition ownTrackPos,
  required TravelDirection ownMeasuredDir,
  required Service ownService,
  required double? ownSpeedMps,
  required OtherTrain otherTrain,
  double? otherGpsAccuracyM,
  TravelDirection? otherMeasuredDir,
}) {
  final otherPos = network.snap(
    otherTrain.lat,
    otherTrain.lon,
    gpsAccuracyM: otherGpsAccuracyM,
  );

  if (otherPos == null || !ownTrackPos.sharesLineWith(otherPos)) {
    return const TrainConflictInfo(conflict: TrainConflict.otherLine);
  }

  final shared = ownTrackPos.candidateRouteIds.intersection(otherPos.candidateRouteIds);
  if (shared.isEmpty) {
    return const TrainConflictInfo(conflict: TrainConflict.otherLine);
  }

  // Find the shared route with the shortest along-track distance
  String? bestRouteId;
  double minGap = double.infinity;
  double bestSignedDiff = 0.0;
  for (final rId in shared) {
    final pOwn = ownTrackPos.candidateForRoute(rId);
    final pOther = otherPos.candidateForRoute(rId);
    if (pOwn != null && pOther != null) {
      final diff = pOther.chainageM - pOwn.chainageM;
      if (diff.abs() < minGap) {
        minGap = diff.abs();
        bestSignedDiff = diff;
        bestRouteId = rId;
      }
    }
  }

  if (bestRouteId == null) {
    return const TrainConflictInfo(conflict: TrainConflict.otherLine);
  }

  final route = network.routes[bestRouteId]!;

  // Determine effective direction for own train
  TravelDirection ownDir;
  if ((ownSpeedMps ?? 0) >= 0.5 && ownMeasuredDir != TravelDirection.unknown) {
    ownDir = ownMeasuredDir;
  } else {
    ownDir = route.directionForService(ownService);
  }

  // Determine effective direction for other train
  TravelDirection otherDir;
  final otherSpeed = otherTrain.speedMps ?? 0.0;
  if (otherSpeed >= 0.5) {
    if (otherMeasuredDir != null && otherMeasuredDir != TravelDirection.unknown) {
      otherDir = otherMeasuredDir;
    } else if (otherTrain.heading != null) {
      final pOtherOnRoute = otherPos.candidateForRoute(bestRouteId)!;
      otherDir = network.travelDirectionFromHeading(
        position: pOtherOnRoute,
        headingDeg: otherTrain.heading!,
      );
    } else {
      otherDir = TravelDirection.unknown;
    }
  } else {
    otherDir = route.directionForService(otherTrain.service);
  }

  // Speed and time-to-meet calculations
  final sOwn = (ownSpeedMps != null && ownSpeedMps > 0) ? ownSpeedMps : 0.0;
  final sOther = (otherTrain.speedMps != null && otherTrain.speedMps! > 0) ? otherTrain.speedMps! : 0.0;
  final combinedSpeed = sOwn + sOther;

  Duration? timeToMeet;
  if (combinedSpeed > 0.05) {
    final secs = minGap / combinedSpeed;
    timeToMeet = Duration(seconds: secs.round());
  }

  // Fail-safe: direction not established for either train counts as approaching
  if (ownDir == TravelDirection.unknown || otherDir == TravelDirection.unknown) {
    return TrainConflictInfo(
      conflict: TrainConflict.approaching,
      alongTrackGapM: minGap,
      closingSpeedMps: combinedSpeed,
      timeToMeet: timeToMeet,
      isDirectionUnknown: true,
      sharedRouteId: bestRouteId,
    );
  }

  // Opposite directions:
  final isOpposite = (ownDir == TravelDirection.increasing && otherDir == TravelDirection.decreasing) ||
      (ownDir == TravelDirection.decreasing && otherDir == TravelDirection.increasing);

  if (isOpposite) {
    // Check if gap is closing
    final closing = (ownDir == TravelDirection.increasing && bestSignedDiff > 0) ||
        (ownDir == TravelDirection.decreasing && bestSignedDiff < 0) ||
        (sOwn < 0.5 && sOther < 0.5);

    if (closing) {
      return TrainConflictInfo(
        conflict: TrainConflict.approaching,
        alongTrackGapM: minGap,
        closingSpeedMps: combinedSpeed,
        timeToMeet: timeToMeet,
        sharedRouteId: bestRouteId,
      );
    } else {
      // Diverging / already passed
      return TrainConflictInfo(
        conflict: TrainConflict.behind,
        alongTrackGapM: minGap,
        closingSpeedMps: combinedSpeed,
        sharedRouteId: bestRouteId,
      );
    }
  }

  // Same direction:
  if (ownDir == TravelDirection.increasing) {
    final isAhead = bestSignedDiff > 0;
    return TrainConflictInfo(
      conflict: isAhead ? TrainConflict.ahead : TrainConflict.behind,
      alongTrackGapM: minGap,
      closingSpeedMps: (sOwn - sOther).abs(),
      sharedRouteId: bestRouteId,
    );
  } else {
    final isAhead = bestSignedDiff < 0;
    return TrainConflictInfo(
      conflict: isAhead ? TrainConflict.ahead : TrainConflict.behind,
      alongTrackGapM: minGap,
      closingSpeedMps: (sOwn - sOther).abs(),
      sharedRouteId: bestRouteId,
    );
  }
}
