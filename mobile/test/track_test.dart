// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/warning.dart';

RailNetwork loadTestNetwork() {
  var path = 'assets/railway_routes.json';
  if (!File(path).existsSync()) {
    path = 'mobile/assets/railway_routes.json';
  }
  final jsonStr = File(path).readAsStringSync();
  return RailNetwork.fromJson(jsonStr);
}

void main() {
  late RailNetwork network;

  setUpAll(() {
    network = loadTestNetwork();
  });

  group('Track Snapping (Part 5 - Item 15)', () {
    test('a point exactly on a segment snaps with offset near 0', () {
      final route = network.routes['r7']!;
      final p1 = route.points[10];
      final p2 = route.points[11];

      // Exact midpoint between p1 and p2
      final midLat = 0.5 * (p1.lat + p2.lat);
      final midLon = 0.5 * (p1.lon + p2.lon);

      final pos = network.snap(midLat, midLon);
      expect(pos, isNotNull);
      expect(pos!.routeId, equals('r7'));
      expect(pos.offsetM, closeTo(0.0, 0.5));
      expect(pos.chainageM, closeTo(0.5 * (p1.chainageM + p2.chainageM), 2.0));
    });

    test('a point 15 m off snaps with offset near 15 m', () {
      final route = network.routes['r7']!;
      final p1 = route.points[10];
      final p2 = route.points[11];

      final midLat = 0.5 * (p1.lat + p2.lat);
      final midLon = 0.5 * (p1.lon + p2.lon);

      // Compute perpendicular offset vector
      final latRad = midLat * pi / 180;
      final cosLat = cos(latRad);
      final radM = earthRadiusM * pi / 180;

      final dx = (p2.lon - p1.lon) * radM * cosLat;
      final dy = (p2.lat - p1.lat) * radM;
      final len = sqrt(dx * dx + dy * dy);
      expect(len, greaterThan(0));

      final nx = -dy / len;
      final ny = dx / len;

      const targetOffsetM = 15.0;
      final shiftX = targetOffsetM * nx;
      final shiftY = targetOffsetM * ny;

      final testLat = midLat + (shiftY / radM);
      final testLon = midLon + (shiftX / (radM * cosLat));

      final pos = network.snap(testLat, testLon);
      expect(pos, isNotNull);
      expect(pos!.routeId, equals('r7'));
      expect(pos.offsetM, closeTo(15.0, 0.8));
    });

    test('a point 500 m off returns null', () {
      // 500 m off in the Indian Ocean or deep inland from railway
      final route = network.routes['r7']!;
      final p = route.points[10];

      // Shift by ~500 m (0.0045 degrees) perpendicular to track
      final testLat = p.lat + 0.005;
      final testLon = p.lon + 0.005;

      final pos = network.snap(testLat, testLon, maxOffsetM: 30.0);
      expect(pos, isNull);
    });
  });

  group('Monotonic Chainage (Part 5 - Item 16)', () {
    test('chainage increases monotonically along every route', () {
      for (final route in network.routes.values) {
        expect(route.points.first.chainageM, equals(0.0));
        for (var i = 0; i < route.points.length - 1; i++) {
          final curr = route.points[i];
          final next = route.points[i + 1];
          expect(
            next.chainageM,
            greaterThanOrEqualTo(curr.chainageM),
            reason: 'Route ${route.id} point $i -> ${i + 1} chainage decreased',
          );
        }
        expect(route.points.last.chainageM, closeTo(route.lengthM, 0.2));
      }
    });
  });

  group('Curved Track Proof (Part 5 - Item 17)', () {
    test('along-track distance is measurably longer than straight-line haversine', () {
      final route = network.routes['r7']!;
      // Curve 1 section (points 528 to 543)
      final pA = route.points[528];
      final pB = route.points[543];

      final straightM = distanceM(pA.lat, pA.lon, pB.lat, pB.lon);
      final alongM = (pB.chainageM - pA.chainageM).abs();
      final diffM = alongM - straightM;

      // Central proof: assert the difference and print it
      print('================ CENTRAL PROOF: CURVED SECTION ================');
      print('Point A (Curve 1 start): [${pA.lat}, ${pA.lon}]');
      print('Point B (Curve 1 end):   [${pB.lat}, ${pB.lon}]');
      print('Straight-line haversine: ${straightM.toStringAsFixed(1)} m');
      print('Along-track distance:    ${alongM.toStringAsFixed(1)} m');
      print('Under-read by air:       +${diffM.toStringAsFixed(1)} m (+${((diffM / straightM) * 100).toStringAsFixed(1)}%)');
      print('================================================================');

      expect(straightM, closeTo(300.2, 5.0));
      expect(alongM, closeTo(1646.4, 5.0));
      expect(alongM, greaterThan(straightM * 3)); // over 4x longer!
      expect(diffM, greaterThan(1000.0));
    });
  });

  group('Points on Different Routes (Part 5 - Item 18)', () {
    test('points on different routes return null from alongTrack', () {
      final r0 = network.routes['r0']!;
      final r7 = network.routes['r7']!;

      final posA = network.snap(r0.points[5].lat, r0.points[5].lon)!;
      final posB = network.snap(r7.points[5].lat, r7.points[5].lon)!;

      expect(posA.routeId, equals('r0'));
      expect(posB.routeId, equals('r7'));

      expect(network.alongTrack(posA, posB), isNull);
      expect(alongTrack(posA, posB), isNull);
    });
  });

  group('Travel Direction (Part 5 - Item 19)', () {
    test('derived correctly from increasing, decreasing chainage, and unknown when still', () {
      const pos1 = TrackPosition(routeId: 'r7', chainageM: 1000.0, offsetM: 2.0);
      const pos2Increasing = TrackPosition(routeId: 'r7', chainageM: 1030.0, offsetM: 2.1);
      const pos3Decreasing = TrackPosition(routeId: 'r7', chainageM: 970.0, offsetM: 1.9);
      const pos4Still = TrackPosition(routeId: 'r7', chainageM: 1000.5, offsetM: 2.0);
      const posDifferentRoute = TrackPosition(routeId: 'r0', chainageM: 1050.0, offsetM: 2.0);

      expect(
        travelDirectionFromFixes(previous: pos1, current: pos2Increasing),
        equals(TravelDirection.increasing),
      );
      expect(
        travelDirectionFromFixes(previous: pos1, current: pos3Decreasing),
        equals(TravelDirection.decreasing),
      );
      expect(
        travelDirectionFromFixes(previous: pos1, current: pos4Still),
        equals(TravelDirection.unknown),
      );
      expect(
        travelDirectionFromFixes(previous: pos1, current: posDifferentRoute),
        equals(TravelDirection.unknown),
      );
      expect(
        travelDirectionFromFixes(previous: null, current: pos1),
        equals(TravelDirection.unknown),
      );
    });
  });

  group('Regression Test (Part 5 - Item 20)', () {
    test('with RailNetwork null, hazardsAhead returns byte-identical results to current implementation', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      final hazards = [
        Hazard(
          id: 'h1',
          latitude: 6.9300,
          longitude: 79.8600,
          objectType: 'person',
          severity: 'blocked',
          time: now.subtract(const Duration(minutes: 2)),
        ),
        Hazard(
          id: 'h2',
          latitude: 6.9200,
          longitude: 79.8700,
          objectType: 'animal',
          severity: 'near',
          time: now.subtract(const Duration(minutes: 5)),
        ),
        Hazard(
          id: 'h3_behind',
          latitude: 6.9400,
          longitude: 79.8400,
          objectType: 'vehicle',
          severity: 'blocked',
          time: now.subtract(const Duration(minutes: 1)),
        ),
        Hazard(
          id: 'h4_expired',
          latitude: 6.9310,
          longitude: 79.8550,
          objectType: 'obstruction',
          severity: 'blocked',
          time: now.subtract(const Duration(minutes: 35)),
        ),
      ];

      const lat = 6.9337, lon = 79.8500; // Fort
      const heading = 107.0; // towards Maradana

      // Call hazardsAhead with network explicitly null
      final resultWithNull = hazardsAhead(
        lat: lat,
        lon: lon,
        headingDeg: heading,
        hazards: hazards,
        now: now,
        network: null,
      );

      // Baseline independent reference implementation
      final baseline = <HazardWarning>[];
      for (final h in hazards) {
        if (h.time != null && now.difference(h.time!) > hazardMaxAge) continue;
        final d = distanceM(lat, lon, h.latitude, h.longitude);
        if (d > warnRangeM) continue;
        if (!isAhead(bearingDeg(lat, lon, h.latitude, h.longitude), heading)) continue;
        baseline.add(HazardWarning(h, d, true));
      }
      baseline.sort((a, b) => a.level != b.level
          ? b.level.index.compareTo(a.level.index)
          : a.distanceM.compareTo(b.distanceM));

      expect(resultWithNull.length, equals(baseline.length));
      for (var i = 0; i < baseline.length; i++) {
        final r = resultWithNull[i];
        final b = baseline[i];
        expect(r.hazard.id, equals(b.hazard.id));
        expect(r.distanceM, equals(b.distanceM));
        expect(r.headingKnown, equals(b.headingKnown));
        expect(r.level, equals(b.level));
        expect(r.message, equals(b.message));
        expect(r.alongTrack, isFalse);
        expect(r.onAnotherLine, isFalse);
      }
    });
  });

  group('Never-Quieter Rule on Fallback Path (Fix 1)', () {
    test('on fallback path (snap failed, offset > 15 m, or different route), old STOP or CAUTION is clamped', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      final r7 = network.routes['r7']!;

      final trainPt = r7.points[50];
      const heading = 90.0;

      // Fallback 1: Hazard off-track (> 15 m offset) within 300 m straight-line ahead
      final hazardOffTrack = Hazard(
        id: 'h_off_track',
        latitude: trainPt.lat + 0.001,
        longitude: trainPt.lon + 0.002, // ~220 m east (ahead for heading 90)
        objectType: 'animal',
        severity: 'blocked',
        time: now,
      );

      final hSnap = network.snap(hazardOffTrack.latitude, hazardOffTrack.longitude);
      final isOffTrack = hSnap == null || hSnap.offsetM > 15.0;
      expect(isOffTrack, isTrue, reason: 'Test hazard must be off-track (> 15 m offset)');

      final oldWarnings1 = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: heading,
        hazards: [hazardOffTrack],
        now: now,
        network: null,
      );
      final newWarnings1 = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: heading,
        hazards: [hazardOffTrack],
        now: now,
        network: network,
      );

      expect(oldWarnings1.first.level, equals(AlertLevel.stop));
      expect(newWarnings1.first.level, equals(AlertLevel.stop),
          reason: 'Off-track fallback must clamp to at least old level (STOP)');

      // Fallback 2: Truly disjoint routes (Train on r5, hazard on r76 ~217 m away, candidate sets disjoint)
      final r5 = network.routes['r5']!;
      final r76 = network.routes['r76']!;
      final pTrainR5 = r5.points[245]; // [7.03146, 79.9211]
      final pHazardR76 = r76.points.first; // [7.03341, 79.92119] (~217 m away)
      final straightDist = distanceM(pTrainR5.lat, pTrainR5.lon, pHazardR76.lat, pHazardR76.lon);
      final trainHeading = bearingDeg(pTrainR5.lat, pTrainR5.lon, pHazardR76.lat, pHazardR76.lon);

      final snapR5 = network.snap(pTrainR5.lat, pTrainR5.lon)!;
      final snapR76 = network.snap(pHazardR76.lat, pHazardR76.lon)!;
      expect(snapR5.sharesLineWith(snapR76), isFalse);
      expect(straightDist, lessThan(400.0));

      final diffRouteHazard = Hazard(
        id: 'h_diff_route',
        latitude: pHazardR76.lat,
        longitude: pHazardR76.lon,
        objectType: 'vehicle',
        severity: 'blocked',
        time: now,
      );

      final oldWarnings2 = hazardsAhead(
        lat: pTrainR5.lat,
        lon: pTrainR5.lon,
        headingDeg: trainHeading,
        hazards: [diffRouteHazard],
        now: now,
        network: null,
      );
      final newWarnings2 = hazardsAhead(
        lat: pTrainR5.lat,
        lon: pTrainR5.lon,
        headingDeg: trainHeading,
        hazards: [diffRouteHazard],
        now: now,
        network: network,
      );

      expect(oldWarnings2.first.level, equals(AlertLevel.stop));
      expect(newWarnings2.first.level, equals(AlertLevel.stop),
          reason: 'Different-route fallback must clamp to old level (STOP) while labeling on another line');
      expect(newWarnings2.first.onAnotherLine, isTrue);

      // Fallback 3: Train off-track (> 15 m offset)
      final offTrackTrainLat = trainPt.lat + 0.005; // ~550 m off track
      final offTrackTrainLon = trainPt.lon + 0.005;
      final tSnap = network.snap(offTrackTrainLat, offTrackTrainLon);
      expect(tSnap == null || tSnap.offsetM > 15.0, isTrue);

      final oldWarnings3 = hazardsAhead(
        lat: offTrackTrainLat,
        lon: offTrackTrainLon,
        headingDeg: heading,
        hazards: [hazardOffTrack],
        now: now,
        network: null,
      );
      final newWarnings3 = hazardsAhead(
        lat: offTrackTrainLat,
        lon: offTrackTrainLon,
        headingDeg: heading,
        hazards: [hazardOffTrack],
        now: now,
        network: network,
      );
      expect(newWarnings3.length, equals(oldWarnings3.length));
    });
  });

  group('Along-Track Alert Level Drive (Fix 1 - Item 6)', () {
    test('confident path: hazard 300 m straight-line but 1,646 m along the line comes out as INFO, not STOP', () {
      final route = network.routes['r7']!;
      final trainPt = route.points[528]; // [6.95653, 80.65955]
      final hazardPt = route.points[543]; // [6.95923, 80.65952]
      final now = DateTime(2026, 11, 17, 12, 0, 0);

      final hazard = Hazard(
        id: 'h_curve1_false_stop',
        latitude: hazardPt.lat,
        longitude: hazardPt.lon,
        objectType: 'animal',
        severity: 'blocked',
        time: now,
      );

      // Baseline straight-line bearing method:
      // straight distance = 300.2 m <= 400 m (and blocked), so old method raises STOP
      final oldWarnings = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: null, // standing still / direction unknown
        hazards: [hazard],
        now: now,
        network: null,
      );
      expect(oldWarnings.length, equals(1));
      expect(oldWarnings.first.level, equals(AlertLevel.stop));
      expect(oldWarnings.first.distanceM, closeTo(300.2, 5.0));

      // Confident along-track method:
      // along-track distance = 1,646.4 m (> 1000 m and <= 3000 m), so new method raises INFO!
      final newWarnings = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: null,
        hazards: [hazard],
        now: now,
        network: network,
      );
      expect(newWarnings.length, equals(1));
      final w = newWarnings.first;
      expect(w.level, equals(AlertLevel.info), reason: 'Along-track 1,646 m must lower alert from STOP to INFO');
      expect(w.distanceM, closeTo(1646.4, 5.0));
      expect(w.alongTrack, isTrue);
      expect(w.overrideLevel, isNull, reason: 'Confident path must have no overrideLevel');
    });
  });

  group('Bend Detection Gain (Fix 1 - Item 7)', () {
    test('hazard ~500 m ahead around a curve outside 45 deg cone is raised by new method and missed by old', () {
      final route = network.routes['r7']!;
      final trainPt = route.points[1330]; // [6.90203, 81.05978]
      final nextPt = route.points[1331];  // [6.90143, 81.05971]
      final hazardPt = route.points[1336]; // [6.90226, 81.06259]
      final now = DateTime(2026, 11, 17, 12, 0, 0);

      final trainHeading = bearingDeg(trainPt.lat, trainPt.lon, nextPt.lat, nextPt.lon);
      final straightBearing = bearingDeg(trainPt.lat, trainPt.lon, hazardPt.lat, hazardPt.lon);
      final diffDeg = angleDiffDeg(trainHeading, straightBearing);

      // Verify that the straight-line bearing is well outside the 45 deg cone
      expect(diffDeg, greaterThan(45.0), reason: 'Must be outside the 45 deg cone');
      expect(diffDeg, closeTo(101.3, 5.0));

      final hazard = Hazard(
        id: 'h_blind_bend_500m',
        latitude: hazardPt.lat,
        longitude: hazardPt.lon,
        objectType: 'obstruction',
        severity: 'blocked',
        time: now,
      );

      // 1. Old method: bearing is outside 45 deg cone -> MISSED (empty warnings)
      final oldWarnings = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: trainHeading,
        hazards: [hazard],
        now: now,
        network: null,
      );
      expect(oldWarnings, isEmpty, reason: 'Old method must miss hazard outside 45 deg cone');

      // 2. New method: snapped to route r7, along-track distance ~500 m ahead -> RAISED!
      final newWarnings = hazardsAhead(
        lat: trainPt.lat,
        lon: trainPt.lon,
        headingDeg: trainHeading,
        hazards: [hazard],
        now: now,
        network: network,
        travelDirection: TravelDirection.increasing,
      );
      expect(newWarnings.length, equals(1), reason: 'New method must raise hazard around the curve');
      final w = newWarnings.first;
      expect(w.distanceM, closeTo(495.6, 5.0));
      expect(w.alongTrack, isTrue);
      expect(w.level, equals(AlertLevel.stop), reason: '495 m blocked hazard is STOP');
      expect(w.overrideLevel, isNull);
    });
  });

  group('Parallel-Route Ambiguity (Step 4 - Part 1)', () {
    test('two parallel routes 4 m apart with 8 m GPS accuracy must be treated as the same line', () {
      final r4 = network.routes['r4']!;
      final r2 = network.routes['r2']!;
      final pt = r4.points[105];

      final snapPos = network.snap(pt.lat, pt.lon, gpsAccuracyM: 8.0);
      expect(snapPos, isNotNull);
      expect(snapPos!.candidateRouteIds.contains('r4'), isTrue);
      expect(snapPos.candidateRouteIds.contains('r2'), isTrue);

      final ptR2 = r2.points[5];
      final snapR2 = network.snap(ptR2.lat, ptR2.lon, gpsAccuracyM: 8.0)!;

      expect(snapPos.sharesLineWith(snapR2), isTrue);
    });

    test('two routes 200 m apart must not be treated as the same line', () {
      final r5 = network.routes['r5']!;
      final r76 = network.routes['r76']!;
      final p5 = r5.points[245];
      final p76 = r76.points.first;

      final dist = distanceM(p5.lat, p5.lon, p76.lat, p76.lon);
      expect(dist, closeTo(217.0, 10.0));

      final snap5 = network.snap(p5.lat, p5.lon, gpsAccuracyM: 8.0)!;
      final snap76 = network.snap(p76.lat, p76.lon, gpsAccuracyM: 8.0)!;

      expect(snap5.sharesLineWith(snap76), isFalse);
    });

    test('an overlapping candidate set must not produce an "on another line" downgrade', () {
      final r4 = network.routes['r4']!;
      final r2 = network.routes['r2']!;
      final pTrain = r4.points[105];
      final pHazard = r2.points[5];

      final now = DateTime.utc(2026, 11, 17, 10, 0, 0);
      final hazard = Hazard(
        id: 'h_parallel_line',
        latitude: pHazard.lat,
        longitude: pHazard.lon,
        objectType: 'vehicle',
        severity: 'blocked',
        time: now,
      );

      final warnings = hazardsAhead(
        lat: pTrain.lat,
        lon: pTrain.lon,
        headingDeg: 120.0,
        hazards: [hazard],
        now: now,
        network: network,
        gpsAccuracyM: 8.0,
      );

      expect(warnings, isNotEmpty);
      final w = warnings.first;
      expect(w.onAnotherLine, isFalse);
      expect(w.alongTrack, isTrue);
      expect(w.level, equals(AlertLevel.stop));
    });
  });
}
