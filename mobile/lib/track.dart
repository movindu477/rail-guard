/// Railway track network and along-track distance measurement.
/// Pure Dart: no Flutter or Firebase dependencies, so it can be unit tested
/// directly in test/track_test.dart.
library;

import 'dart:convert';
import 'dart:math';

import 'driver.dart';

/// Mean Earth radius (IUGG), metres. Matches warning.dart.
const double earthRadiusM = 6371008.8;

/// Direction of travel along a route:
///   increasing - moving towards higher chainage (route end)
///   decreasing - moving towards lower chainage (route start)
///   unknown    - standing still, slow movement, or insufficient history
enum TravelDirection { increasing, decreasing, unknown }

/// Position on the railway network.
class TrackPosition {
  /// The route id, e.g. "r0".
  final String routeId;

  /// Chainage in metres from the route's first point.
  final double chainageM;

  /// Perpendicular distance in metres from the snapped coordinate to the track.
  final double offsetM;

  /// Candidate track positions on all routes within the candidate threshold.
  final List<TrackPosition> candidates;

  const TrackPosition({
    required this.routeId,
    required this.chainageM,
    required this.offsetM,
    this.candidates = const [],
  });

  /// The candidate set: if candidates list is non-empty returns it; otherwise returns [this].
  List<TrackPosition> get candidateSet => candidates.isNotEmpty ? candidates : [this];

  /// Set of route IDs in the candidate set.
  Set<String> get candidateRouteIds => candidateSet.map((c) => c.routeId).toSet();

  /// Gets the candidate position for a given route id, if present.
  TrackPosition? candidateForRoute(String rId) {
    for (final c in candidateSet) {
      if (c.routeId == rId) return c;
    }
    return null;
  }

  /// Whether this position shares at least one route in its candidate set with [other].
  bool sharesLineWith(TrackPosition other) =>
      candidateRouteIds.intersection(other.candidateRouteIds).isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackPosition &&
          runtimeType == other.runtimeType &&
          routeId == other.routeId &&
          (chainageM - other.chainageM).abs() < 1e-6 &&
          (offsetM - other.offsetM).abs() < 1e-6;

  @override
  int get hashCode => Object.hash(routeId, chainageM.round(), offsetM.round());

  @override
  String toString() =>
      'TrackPosition(route: $routeId, chainage: ${chainageM.toStringAsFixed(1)} m, offset: ${offsetM.toStringAsFixed(1)} m, candidates: ${candidateRouteIds.join(",")})';
}

/// A point along a route with precalculated cumulative chainage.
class TrackPoint {
  final double lat;
  final double lon;
  final double chainageM;

  const TrackPoint(this.lat, this.lon, this.chainageM);
}

/// A continuous railway route composed of ordered points with monotonic chainage.
class TrackRoute {
  final String id;
  final List<TrackPoint> points;
  final double lengthM;

  const TrackRoute({
    required this.id,
    required this.points,
    required this.lengthM,
  });

  /// Infers travel direction for registered [service] (UP = towards Colombo Fort, DOWN = away).
  /// Compares distance of route start vs end to Colombo Fort (6.9337 N, 79.8500 E).
  TravelDirection directionForService(Service service) {
    if (points.isEmpty) return TravelDirection.unknown;
    const fortLat = 6.9337;
    const fortLon = 79.8500;
    final dStart = _distToFortM(points.first.lat, points.first.lon, fortLat, fortLon);
    final dEnd = _distToFortM(points.last.lat, points.last.lon, fortLat, fortLon);
    final towardsEndIsTowardsColombo = dEnd < dStart;
    final wantsColombo = (service == Service.up);
    if (wantsColombo) {
      return towardsEndIsTowardsColombo ? TravelDirection.increasing : TravelDirection.decreasing;
    } else {
      return towardsEndIsTowardsColombo ? TravelDirection.decreasing : TravelDirection.increasing;
    }
  }
}

double _distToFortM(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * earthRadiusM * asin(sqrt(a));
}

/// An individual segment between point [i] and [i + 1] on [route].
class _Segment {
  final String routeId;
  final int index;
  final TrackPoint p1;
  final TrackPoint p2;
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  _Segment({
    required this.routeId,
    required this.index,
    required this.p1,
    required this.p2,
  })  : minLat = min(p1.lat, p2.lat),
        maxLat = max(p1.lat, p2.lat),
        minLon = min(p1.lon, p2.lon),
        maxLon = max(p1.lon, p2.lon);

  /// Bearing in degrees clockwise from north along this segment (p1 -> p2).
  double get bearingDeg {
    final lat1 = p1.lat * pi / 180, lat2 = p2.lat * pi / 180;
    final dl = (p2.lon - p1.lon) * pi / 180;
    final y = sin(dl) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dl);
    return ((atan2(y, x) * 180 / pi) + 360) % 360;
  }
}

/// Computes the travel direction between two consecutive track fixes.
/// Returns [TravelDirection.unknown] when movement is below [minMovementM] or routes differ.
TravelDirection travelDirectionFromFixes({
  required TrackPosition? previous,
  required TrackPosition? current,
  double minMovementM = 2.0,
}) {
  if (previous == null || current == null) return TravelDirection.unknown;
  if (previous.routeId != current.routeId) return TravelDirection.unknown;
  final diff = current.chainageM - previous.chainageM;
  if (diff.abs() < minMovementM) return TravelDirection.unknown;
  return diff > 0 ? TravelDirection.increasing : TravelDirection.decreasing;
}

class _RouteSnap {
  final String routeId;
  final double chainageM;
  final double offsetM;
  const _RouteSnap({required this.routeId, required this.chainageM, required this.offsetM});
}

/// The spatial network of railway routes with a 0.01° grid index for < 2 ms snapping.
class RailNetwork {
  final Map<String, TrackRoute> routes;
  final double cellSizeDeg;
  final Map<int, List<_Segment>> _grid = {};

  RailNetwork._(this.routes, {this.cellSizeDeg = 0.01}) {
    _buildIndex();
  }

  /// Parses a RailNetwork from the JSON string of `assets/railway_routes.json`.
  factory RailNetwork.fromJson(String jsonStr) =>
      RailNetwork.fromMap(jsonDecode(jsonStr) as Map<String, dynamic>);

  /// Parses a RailNetwork from a decoded JSON map.
  factory RailNetwork.fromMap(Map<String, dynamic> map, {double cellSizeDeg = 0.01}) {
    final rawRoutes = map['routes'] as List<dynamic>? ?? [];
    final routes = <String, TrackRoute>{};

    for (final r in rawRoutes) {
      final rMap = r as Map<String, dynamic>;
      final id = rMap['id'] as String;
      final rawPts = rMap['points'] as List<dynamic>;
      final pts = <TrackPoint>[];
      for (final p in rawPts) {
        final pList = p as List<dynamic>;
        pts.add(TrackPoint(
          (pList[0] as num).toDouble(),
          (pList[1] as num).toDouble(),
          (pList[2] as num).toDouble(),
        ));
      }
      final len = (rMap['length_m'] as num).toDouble();
      routes[id] = TrackRoute(id: id, points: pts, lengthM: len);
    }

    return RailNetwork._(routes, cellSizeDeg: cellSizeDeg);
  }

  int _cellKey(int cx, int cy) => (cx << 16) ^ (cy & 0xFFFF);

  int _cellX(double lon) => (lon / cellSizeDeg).floor();
  int _cellY(double lat) => (lat / cellSizeDeg).floor();

  void _buildIndex() {
    for (final route in routes.values) {
      final pts = route.points;
      for (var i = 0; i < pts.length - 1; i++) {
        final seg = _Segment(
          routeId: route.id,
          index: i,
          p1: pts[i],
          p2: pts[i + 1],
        );
        final minCx = _cellX(seg.minLon);
        final maxCx = _cellX(seg.maxLon);
        final minCy = _cellY(seg.minLat);
        final maxCy = _cellY(seg.maxLat);

        for (var cx = minCx; cx <= maxCx; cx++) {
          for (var cy = minCy; cy <= maxCy; cy++) {
            final key = _cellKey(cx, cy);
            (_grid[key] ??= []).add(seg);
          }
        }
      }
    }
  }

  /// Snaps [lat], [lon] to the nearest point on the track within [maxOffsetM].
  /// Finds all candidate routes whose perpendicular offset is within max(15 m, gpsAccuracyM).
  /// Returns null if no track segment lies within [maxOffsetM] metres.
  TrackPosition? snap(
    double lat,
    double lon, {
    double maxOffsetM = 30.0,
    double? gpsAccuracyM,
  }) {
    final candidateThresholdM = max(15.0, gpsAccuracyM ?? 15.0);
    final searchMarginM = max(maxOffsetM, candidateThresholdM);

    final cx = _cellX(lon);
    final cy = _cellY(lat);

    // Local equirectangular projection centered at query latitude
    final latRad = lat * pi / 180;
    final cosLat = cos(latRad);
    final radM = earthRadiusM * pi / 180;

    double toX(double l) => (l - lon) * radM * cosLat;
    double toY(double p) => (p - lat) * radM;

    final seenSegments = <_Segment>{};
    final bestPerRoute = <String, _RouteSnap>{};

    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final key = _cellKey(cx + dx, cy + dy);
        final segs = _grid[key];
        if (segs == null) continue;

        for (final seg in segs) {
          if (!seenSegments.add(seg)) continue;

          // Quick bounding box check: expand bounding box by searchMarginM
          final latMargin = (searchMarginM / earthRadiusM) * (180 / pi);
          final lonMargin = latMargin / max(0.1, cosLat);
          if (lat < seg.minLat - latMargin || lat > seg.maxLat + latMargin) continue;
          if (lon < seg.minLon - lonMargin || lon > seg.maxLon + lonMargin) continue;

          final ax = toX(seg.p1.lon), ay = toY(seg.p1.lat);
          final bx = toX(seg.p2.lon), by = toY(seg.p2.lat);

          final segDx = bx - ax;
          final segDy = by - ay;
          final l2 = segDx * segDx + segDy * segDy;

          double t;
          double qx, qy;
          if (l2 == 0) {
            t = 0.0;
            qx = ax;
            qy = ay;
          } else {
            // Point P is at (0, 0) in local offset coords
            // Vector from A to P is (-ax, -ay)
            t = ((-ax) * segDx + (-ay) * segDy) / l2;
            t = max(0.0, min(1.0, t));
            qx = ax + t * segDx;
            qy = ay + t * segDy;
          }

          final offset = sqrt(qx * qx + qy * qy);
          final existing = bestPerRoute[seg.routeId];
          if (existing == null || offset < existing.offsetM) {
            final chainage = seg.p1.chainageM + t * (seg.p2.chainageM - seg.p1.chainageM);
            bestPerRoute[seg.routeId] = _RouteSnap(
              routeId: seg.routeId,
              chainageM: chainage,
              offsetM: offset,
            );
          }
        }
      }
    }

    if (bestPerRoute.isEmpty) return null;

    _RouteSnap? bestOverall;
    for (final rSnap in bestPerRoute.values) {
      if (bestOverall == null || rSnap.offsetM < bestOverall.offsetM) {
        bestOverall = rSnap;
      }
    }

    if (bestOverall == null || bestOverall.offsetM > maxOffsetM) {
      return null;
    }

    final candidates = <TrackPosition>[];
    for (final rSnap in bestPerRoute.values) {
      if (rSnap.offsetM <= candidateThresholdM) {
        candidates.add(TrackPosition(
          routeId: rSnap.routeId,
          chainageM: rSnap.chainageM,
          offsetM: rSnap.offsetM,
        ));
      }
    }
    candidates.sort((a, b) => a.offsetM.compareTo(b.offsetM));

    if (candidates.isEmpty) {
      candidates.add(TrackPosition(
        routeId: bestOverall.routeId,
        chainageM: bestOverall.chainageM,
        offsetM: bestOverall.offsetM,
      ));
    }

    return TrackPosition(
      routeId: bestOverall.routeId,
      chainageM: bestOverall.chainageM,
      offsetM: bestOverall.offsetM,
      candidates: candidates,
    );
  }

  /// Signed difference in chainage (b - a) when positions share at least one route in their candidate sets.
  /// When candidate sets overlap on multiple routes, selects the shared route that gives
  /// the shortest along-track distance. Returns null if candidate sets are disjoint.
  double? alongTrack(TrackPosition a, TrackPosition b) => _calcAlongTrack(a, b);

  /// Infers the travel direction on route [position] given the train's [headingDeg].
  /// Returns [TravelDirection.unknown] if [headingDeg] is null or heading is indeterminate.
  TravelDirection travelDirectionFromHeading({
    required TrackPosition position,
    required double? headingDeg,
  }) {
    if (headingDeg == null) return TravelDirection.unknown;
    final route = routes[position.routeId];
    if (route == null || route.points.length < 2) return TravelDirection.unknown;

    // Find the segment enclosing position.chainageM
    final pts = route.points;
    var segIndex = 0;
    for (var i = 0; i < pts.length - 1; i++) {
      if (position.chainageM >= pts[i].chainageM && position.chainageM <= pts[i + 1].chainageM) {
        segIndex = i;
        break;
      }
    }

    final p1 = pts[segIndex], p2 = pts[segIndex + 1];
    final lat1 = p1.lat * pi / 180, lat2 = p2.lat * pi / 180;
    final dl = (p2.lon - p1.lon) * pi / 180;
    final y = sin(dl) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dl);
    final trackBearing = ((atan2(y, x) * 180 / pi) + 360) % 360;

    final diff = ((headingDeg - trackBearing) % 360 + 360) % 360;
    final angleDiff = diff > 180 ? 360 - diff : diff;

    if (angleDiff <= 90) {
      return TravelDirection.increasing;
    } else {
      return TravelDirection.decreasing;
    }
  }
}

/// Standalone helper for alongTrack: signed difference in chainage (b - a)
/// across shared routes, picking the route with minimum distance.
/// Returns null when candidate sets are disjoint.
double? alongTrack(TrackPosition a, TrackPosition b) => _calcAlongTrack(a, b);

double? _calcAlongTrack(TrackPosition a, TrackPosition b) {
  final shared = a.candidateRouteIds.intersection(b.candidateRouteIds);
  if (shared.isEmpty) return null;

  double? bestDiff;
  double minAbs = double.infinity;

  for (final rId in shared) {
    final posA = a.candidateForRoute(rId);
    final posB = b.candidateForRoute(rId);
    if (posA != null && posB != null) {
      final diff = posB.chainageM - posA.chainageM;
      if (diff.abs() < minAbs) {
        minAbs = diff.abs();
        bestDiff = diff;
      }
    }
  }

  return bestDiff;
}
