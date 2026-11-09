import 'package:flutter_test/flutter_test.dart';

import 'package:railguard_app/warning.dart';

// Approximately Colombo Fort and Maradana stations; check on Google Maps with
// right-click > "Measure distance" between these two points.
const fortLat = 6.9337, fortLon = 79.8500;
const maradanaLat = 6.9290, maradanaLon = 79.8653;
const kandyLat = 7.2914, kandyLon = 80.6350;

void main() {
  group('distanceM', () {
    // Reference values: GeographicLib on the WGS84 ellipsoid (independent of
    // this code), computed for exactly these coordinates.
    test('Fort to Maradana, 1768.9 m', () {
      expect(distanceM(fortLat, fortLon, maradanaLat, maradanaLon), closeTo(1768.9, 5));
    });
    test('Fort to Kandy, 95.31 km', () {
      expect(distanceM(fortLat, fortLon, kandyLat, kandyLon), closeTo(95314.4, 10));
    });
    test('published example: 968.9 km (movable-type.co.uk)', () {
      final d = distanceM(50 + 3 / 60 + 59 / 3600, -(5 + 42 / 60 + 53 / 3600),
          58 + 38 / 60 + 38 / 3600, -(3 + 4 / 60 + 12 / 3600));
      expect(d / 1000, closeTo(968.9, 0.1));
    });
    test('same point is 0, and symmetric', () {
      expect(distanceM(fortLat, fortLon, fortLat, fortLon), 0);
      expect(distanceM(maradanaLat, maradanaLon, fortLat, fortLon),
          closeTo(distanceM(fortLat, fortLon, maradanaLat, maradanaLon), 1e-6));
    });
  });

  group('bearingDeg', () {
    test('Fort to Maradana, 107.1 deg (east-south-east)', () {
      expect(bearingDeg(fortLat, fortLon, maradanaLat, maradanaLon), closeTo(107.09, 1));
    });
    test('Fort to Kandy, 65.4 deg', () {
      expect(bearingDeg(fortLat, fortLon, kandyLat, kandyLon), closeTo(65.43, 1));
    });
    test('published example: 009 07 11', () {
      final b = bearingDeg(50 + 3 / 60 + 59 / 3600, -(5 + 42 / 60 + 53 / 3600),
          58 + 38 / 60 + 38 / 3600, -(3 + 4 / 60 + 12 / 3600));
      expect(b, closeTo(9 + 7 / 60 + 11 / 3600, 0.01));
    });
    // The sign checks: north, east, south, west of Fort.
    test('cardinal directions', () {
      expect(bearingDeg(fortLat, fortLon, fortLat + 0.01, fortLon), closeTo(0, 0.01));
      expect(bearingDeg(fortLat, fortLon, fortLat, fortLon + 0.01), closeTo(90, 0.01));
      expect(bearingDeg(fortLat, fortLon, fortLat - 0.01, fortLon), closeTo(180, 0.01));
      expect(bearingDeg(fortLat, fortLon, fortLat, fortLon - 0.01), closeTo(270, 0.01));
    });
    test('always 0 to 360', () {
      final b = bearingDeg(fortLat, fortLon, fortLat + 0.01, fortLon - 0.0001);
      expect(b, inInclusiveRange(359, 360));
    });
  });

  group('angleDiffDeg', () {
    test('wraps around north', () {
      expect(angleDiffDeg(10, 350), closeTo(20, 1e-9));
      expect(angleDiffDeg(350, 10), closeTo(20, 1e-9));
    });
    test('never more than 180', () {
      expect(angleDiffDeg(0, 180), 180);
      expect(angleDiffDeg(10, 200), closeTo(170, 1e-9));
    });
  });

  group('isAhead', () {
    test('within 45 deg either side is ahead', () {
      expect(isAhead(90, 90), isTrue);
      expect(isAhead(135, 90), isTrue);
      expect(isAhead(45, 90), isTrue);
      expect(isAhead(136, 90), isFalse);
      expect(isAhead(270, 90), isFalse);
    });
    test('across north', () {
      expect(isAhead(20, 350), isTrue);
      expect(isAhead(340, 10), isTrue);
      expect(isAhead(60, 350), isFalse);
    });
    test('unknown heading counts as ahead (fail-safe)', () {
      expect(isAhead(270, null), isTrue);
    });
  });

  group('usableHeading', () {
    test('moving: the GPS heading', () => expect(usableHeading(107, 10), 107));
    test('standing still: unknown', () => expect(usableHeading(107, 0.2), isNull));
    test('-1 from the GPS: unknown', () => expect(usableHeading(-1, 10), isNull));
  });

  group('closestHazardAhead', () {
    final now = DateTime(2026, 11, 9, 12);
    Hazard at(String id, double lat, double lon, {Duration age = Duration.zero}) =>
        Hazard(id: id, latitude: lat, longitude: lon, objectType: 'manual',
            time: now.subtract(age));

    // Train at Fort. About 1 km, 2 km and 5 km due east, and 1 km due west.
    final east1 = at('east1', fortLat, fortLon + 0.009);
    final east2 = at('east2', fortLat, fortLon + 0.018);
    final east5 = at('east5', fortLat, fortLon + 0.045);
    final west1 = at('west1', fortLat, fortLon - 0.009);

    HazardWarning? check(double? heading, List<Hazard> hs, {DateTime? time}) =>
        closestHazardAhead(lat: fortLat, lon: fortLon, headingDeg: heading,
            hazards: hs, now: time ?? now);

    test('picks the closest one ahead', () {
      final w = check(90, [east2, east1, west1])!;
      expect(w.hazard.id, 'east1');
      expect(w.distanceM, closeTo(994.6, 5));   // WGS84 reference 994.6 m
      expect(w.message, 'MANUAL — 993 m ahead');
    });
    test('turned round: the hazard behind is ignored', () {
      expect(check(270, [east1, east2])?.hazard.id, isNull);
      expect(check(270, [east1, west1])!.hazard.id, 'west1');
    });
    test('beyond 3 km is ignored', () {
      expect(check(90, [east5]), isNull);
    });
    test('older than 30 minutes is ignored', () {
      expect(check(90, [at('old', fortLat, fortLon + 0.009, age: const Duration(minutes: 31))]),
          isNull);
      expect(check(90, [at('new', fortLat, fortLon + 0.009, age: const Duration(minutes: 29))]),
          isNotNull);
    });
    test('unknown heading: warns on distance alone, says so', () {
      final w = check(null, [east2, west1])!;
      expect(w.hazard.id, 'west1');
      expect(w.headingKnown, isFalse);
      expect(w.message, endsWith('(direction unknown)'));
    });
    test('unknown report time is kept (fail-safe)', () {
      final h = Hazard(id: 'x', latitude: fortLat, longitude: fortLon + 0.009,
          objectType: 'manual');
      expect(check(90, [h]), isNotNull);
    });
    test('km format', () {
      expect(check(90, [east2])!.message, 'MANUAL — 2.0 km ahead');
    });
  });
}
