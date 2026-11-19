// Hazard lifecycle tests: pass detection ("Still there?"), driver clear vs
// two-driver camera clear, "Did not see" fail-safe, "Still there" expiry
// extension, and confirmation count formatting. Pure Dart, runs offline.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/lifecycle.dart';
import 'package:railguard_app/warning.dart';

final _t0 = DateTime.utc(2026, 11, 18, 10, 0, 0);

RailNetwork _loadNetwork() {
  var path = 'assets/railway_routes.json';
  if (!File(path).existsSync()) {
    path = 'mobile/assets/railway_routes.json';
  }
  return RailNetwork.fromJson(File(path).readAsStringSync());
}

Hazard _hazard({
  String id = 'h-1',
  double lat = 6.95653,
  double lon = 80.65955,
  String objectType = 'animal',
  String severity = 'blocked',
  String reportedBy = 'driver',
  String? unitId = 'unit-02',
  String? reportedByUid = 'uid-reporter',
  DateTime? time,
  List<String> confirmedByUids = const [],
  List<String> notSeenByUids = const [],
  List<String> clearedByUids = const [],
}) => Hazard(
  id: id,
  latitude: lat,
  longitude: lon,
  objectType: objectType,
  severity: severity,
  reportedBy: reportedBy,
  unitId: unitId,
  reportedByUid: reportedByUid,
  time: time ?? _t0,
  confirmedByUids: confirmedByUids,
  notSeenByUids: notSeenByUids,
  clearedByUids: clearedByUids,
);

void main() {
  group('Hazard lifecycle rules (Step 5)', () {
    test('one clear removes a driver report and sets status, cleared_by, cleared_at, uid', () {
      final h = _hazard(reportedBy: 'driver');
      final t1 = _t0.add(const Duration(minutes: 5));

      final res = applyHazardAnswer(
        hazard: h,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-1',
        unitId: 'unit-01',
        now: t1,
      );

      expect(res.becameCleared, isTrue);
      expect(res.hazard.status, equals('cleared'));
      expect(res.hazard.isActive, isFalse);
      expect(isHazardActiveOnMap(res.hazard, t1), isFalse);
      expect(res.hazard.clearedBy, equals('unit-01'));
      expect(res.hazard.clearedByUid, equals('uid-driver-1'));
      expect(res.hazard.clearedAt, equals(t1));

      // Verify Firestore update payload (sets status: 'cleared', never deletes)
      expect(res.firestoreUpdate['status'], equals('cleared'));
      expect(res.firestoreUpdate['cleared_by'], equals('unit-01'));
      expect(res.firestoreUpdate['cleared_by_uid'], equals('uid-driver-1'));
      expect(res.firestoreUpdate['cleared_at'], equals(t1));
    });

    test('one clear does not remove an auto (camera-reported) hazard', () {
      final h = _hazard(reportedBy: 'auto', unitId: 'unit-02');
      final t1 = _t0.add(const Duration(minutes: 3));

      final res = applyHazardAnswer(
        hazard: h,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-1',
        unitId: 'unit-01',
        now: t1,
      );

      expect(res.becameCleared, isFalse);
      expect(res.hazard.status, equals('active'));
      expect(isHazardActiveOnMap(res.hazard, t1), isTrue);
      expect(res.hazard.clearedVotesCount, equals(1));
      expect(res.hazard.clearedByUids, equals(['uid-driver-1']));
      expect(res.firestoreUpdate.containsKey('status'), isFalse);
    });

    test('two independent clears remove an auto (camera-reported) hazard', () {
      final h0 = _hazard(reportedBy: 'auto', unitId: 'unit-03');
      final t1 = _t0.add(const Duration(minutes: 3));
      final t2 = _t0.add(const Duration(minutes: 7));

      final first = applyHazardAnswer(
        hazard: h0,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-1',
        unitId: 'unit-01',
        now: t1,
      );
      expect(first.becameCleared, isFalse);
      expect(first.hazard.status, equals('active'));

      final second = applyHazardAnswer(
        hazard: first.hazard,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-2',
        unitId: 'unit-02',
        now: t2,
      );
      expect(second.becameCleared, isTrue);
      expect(second.hazard.status, equals('cleared'));
      expect(isHazardActiveOnMap(second.hazard, t2), isFalse);
      expect(second.hazard.clearedByUids, equals(['uid-driver-1', 'uid-driver-2']));
      expect(second.firestoreUpdate['status'], equals('cleared'));
      expect(second.firestoreUpdate['cleared_by'], equals('unit-02'));
      expect(second.firestoreUpdate['cleared_by_uid'], equals('uid-driver-2'));
      expect(second.firestoreUpdate['cleared_at'], equals(t2));
    });

    test('a driver cannot clear their own report twice to satisfy the two-driver rule', () {
      final h0 = _hazard(
        reportedBy: 'auto',
        unitId: 'unit-01',
        reportedByUid: 'uid-driver-1',
      );
      final t1 = _t0.add(const Duration(minutes: 2));
      final t2 = _t0.add(const Duration(minutes: 4));

      final first = applyHazardAnswer(
        hazard: h0,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-1',
        unitId: 'unit-01',
        now: t1,
      );
      expect(first.becameCleared, isFalse);
      expect(first.hazard.clearedVotesCount, equals(1));

      // Same driver attempts a second clear
      final secondSameDriver = applyHazardAnswer(
        hazard: first.hazard,
        answer: HazardPassAnswer.cleared,
        driverUid: 'uid-driver-1',
        unitId: 'unit-01',
        now: t2,
      );
      expect(secondSameDriver.becameCleared, isFalse);
      expect(secondSameDriver.hazard.status, equals('active'));
      expect(secondSameDriver.hazard.clearedVotesCount, equals(1));
      expect(isHazardActiveOnMap(secondSameDriver.hazard, t2), isTrue);
    });

    test('Did not see never clears a driver report or an auto report', () {
      var driverHazard = _hazard(reportedBy: 'driver');
      var autoHazard = _hazard(reportedBy: 'auto');
      final t1 = _t0.add(const Duration(minutes: 5));

      for (var i = 1; i <= 5; i++) {
        final dRes = applyHazardAnswer(
          hazard: driverHazard,
          answer: HazardPassAnswer.didNotSee,
          driverUid: 'uid-d-$i',
          unitId: 'unit-0$i',
          now: t1,
        );
        expect(dRes.becameCleared, isFalse);
        expect(dRes.hazard.status, equals('active'));
        expect(dRes.firestoreUpdate.containsKey('status'), isFalse);
        driverHazard = dRes.hazard;

        final aRes = applyHazardAnswer(
          hazard: autoHazard,
          answer: HazardPassAnswer.didNotSee,
          driverUid: 'uid-a-$i',
          unitId: 'unit-0$i',
          now: t1,
        );
        expect(aRes.becameCleared, isFalse);
        expect(aRes.hazard.status, equals('active'));
        expect(aRes.firestoreUpdate.containsKey('status'), isFalse);
        autoHazard = aRes.hazard;
      }

      expect(driverHazard.notSeenCount, equals(5));
      expect(autoHazard.notSeenCount, equals(5));
      expect(isHazardActiveOnMap(driverHazard, t1), isTrue);
      expect(isHazardActiveOnMap(autoHazard, t1), isTrue);
    });

    test('Still there appends confirmation and extends the 30-minute expiry backstop', () {
      final h0 = _hazard(reportedBy: 'driver', time: _t0);

      // Without confirmation, hazard expires at t0 + 35 min (> 30 min)
      final tAfterOriginalExpiry = _t0.add(const Duration(minutes: 35));
      expect(isHazardExpired(h0, tAfterOriginalExpiry), isTrue);
      expect(isHazardActiveOnMap(h0, tAfterOriginalExpiry), isFalse);

      // Driver confirms "Still there" at t0 + 20 min
      final tConfirm = _t0.add(const Duration(minutes: 20));
      final res = applyHazardAnswer(
        hazard: h0,
        answer: HazardPassAnswer.stillThere,
        driverUid: 'uid-driver-2',
        unitId: 'unit-02',
        now: tConfirm,
      );

      expect(res.becameCleared, isFalse);
      expect(res.hazard.status, equals('active'));
      expect(res.hazard.confirmedCount, equals(1));
      expect(res.hazard.time, equals(tConfirm));
      expect(res.firestoreUpdate['timestamp'], equals(tConfirm));

      // At t0 + 35 min (15 min after confirmation), hazard is STILL active
      expect(isHazardExpired(res.hazard, tAfterOriginalExpiry), isFalse);
      expect(isHazardActiveOnMap(res.hazard, tAfterOriginalExpiry), isTrue);

      // Time expiry backstop still triggers 31 min after confirmation (t0 + 51 min)
      final tBackstop = tConfirm.add(const Duration(minutes: 31));
      expect(isHazardExpired(res.hazard, tBackstop), isTrue);
      expect(isHazardActiveOnMap(res.hazard, tBackstop), isFalse);
    });

    test('confirmation count labels format singular and plural accurately', () {
      expect(confirmedCountLabel(0), equals('confirmed by 0 drivers'));
      expect(confirmedCountLabel(1), equals('confirmed by 1 driver'));
      expect(confirmedCountLabel(3), equals('confirmed by 3 drivers'));

      expect(notSeenCountLabel(0), equals('not seen by 0 drivers'));
      expect(notSeenCountLabel(1), equals('not seen by 1 driver'));
      expect(notSeenCountLabel(2), equals('not seen by 2 drivers'));
    });
  });

  group('Pass detection ("Still there?" trigger)', () {
    late RailNetwork net;

    setUpAll(() {
      net = _loadNetwork();
    });

    test('approaching within 100 m and moving past along the track triggers once', () {
      final r7 = net.routes['r7']!;
      // Pick a hazard point on r7
      final hPt = r7.points[535];
      final hazard = _hazard(
        id: 'h-r7',
        lat: hPt.lat,
        lon: hPt.lon,
        reportedBy: 'driver',
        unitId: 'unit-02',
      );

      // Find points along r7: ~250 m before, ~50 m before (within 100 m), and ~60 m past
      final beforeFar = r7.points.firstWhere((p) => (hPt.chainageM - p.chainageM) <= 260 && (hPt.chainageM - p.chainageM) >= 150);
      final within100 = r7.points.firstWhere((p) => (hPt.chainageM - p.chainageM) <= 90 && (hPt.chainageM - p.chainageM) >= 10);
      final past = r7.points.firstWhere((p) => (p.chainageM - hPt.chainageM) >= 25);

      final tracker = HazardPassTracker();

      // 1. Far ahead (> 100 m) -> no prompt
      expect(
        tracker.checkPassed(
          lat: beforeFar.lat,
          lon: beforeFar.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );

      // 2. Within 100 m, still ahead -> armed, not yet past -> no prompt
      expect(
        tracker.checkPassed(
          lat: within100.lat,
          lon: within100.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );

      // 3. Moved past along the track -> prompts!
      final passed = tracker.checkPassed(
        lat: past.lat,
        lon: past.lon,
        travelDirection: TravelDirection.increasing,
        hazards: [hazard],
        now: _t0,
        network: net,
        ownUid: 'uid-1',
        ownUnitId: 'unit-01',
      );
      expect(passed.map((h) => h.id), equals(['h-r7']));

      // 4. Subsequent fixes do not re-prompt the same hazard
      expect(
        tracker.checkPassed(
          lat: past.lat,
          lon: past.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );
    });

    test('reversing away before passing the hazard does not trigger prompt', () {
      final r7 = net.routes['r7']!;
      final hPt = r7.points[535];
      final hazard = _hazard(id: 'h-rev', lat: hPt.lat, lon: hPt.lon);

      final within100 = r7.points.firstWhere((p) => (hPt.chainageM - p.chainageM) <= 90 && (hPt.chainageM - p.chainageM) >= 10);
      final backFar = r7.points.firstWhere((p) => (hPt.chainageM - p.chainageM) >= 150 && (hPt.chainageM - p.chainageM) <= 300);

      final tracker = HazardPassTracker();

      // Approach within 100 m
      expect(
        tracker.checkPassed(
          lat: within100.lat,
          lon: within100.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );

      // Reverse back without ever crossing hazard chainage (hazard is still ahead in increasing dir)
      expect(
        tracker.checkPassed(
          lat: backFar.lat,
          lon: backFar.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );
    });

    test('hazard on a disjoint line never prompts', () {
      final r5 = net.routes['r5']!;
      final r76 = net.routes['r76']!;
      final pTrain = r5.points[245];
      final pOtherLine = r76.points.first;

      final hazard = _hazard(id: 'h-other', lat: pOtherLine.lat, lon: pOtherLine.lon);
      final tracker = HazardPassTracker();

      expect(
        tracker.checkPassed(
          lat: pTrain.lat,
          lon: pTrain.lon,
          travelDirection: TravelDirection.increasing,
          hazards: [hazard],
          now: _t0,
          network: net,
          ownUid: 'uid-1',
          ownUnitId: 'unit-01',
        ),
        isEmpty,
      );
    });
  });
}
