// Offline visibility & Firestore write-quota tests: upload gating (> 10 m or
// 30 s heartbeat), 59 s vs 61 s stale feed banner, "Cannot check — no signal"
// status card rule, and pending report badge / 5-minute unsent warning.
// Pure Dart, runs offline with `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/offline.dart';
import 'package:railguard_app/warning.dart';

final _t0 = DateTime.utc(2026, 11, 18, 12, 0, 0);

// Reference coordinate on route r7
const _lat0 = 6.95653;
const _lon0 = 80.65955;

/// Shifts latitude north by [metres] (1 deg lat ≈ 111,195 m).
double _latPlusM(double lat, double metres) => lat + (metres / 111195.0);

void main() {
  group('PositionUploadGate — quota discipline (Step 6 Part 1)', () {
    test('upload is skipped when moved under 10 m and 30 s have not passed', () {
      final gate = PositionUploadGate();

      // First fix always uploads
      expect(gate.tryUpload(lat: _lat0, lon: _lon0, now: _t0), isTrue);

      // Moved 5 m after 5 s -> skipped
      expect(
        gate.tryUpload(
          lat: _latPlusM(_lat0, 5.0),
          lon: _lon0,
          now: _t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );

      // Moved 9.5 m after 29 s -> still skipped
      expect(
        gate.tryUpload(
          lat: _latPlusM(_lat0, 9.5),
          lon: _lon0,
          now: _t0.add(const Duration(seconds: 29)),
        ),
        isFalse,
      );

      expect(gate.uploadCount, equals(1));
    });

    test('upload fires at 30 s regardless of movement', () {
      final gate = PositionUploadGate();
      expect(gate.tryUpload(lat: _lat0, lon: _lon0, now: _t0), isTrue);

      // Standing completely still: skipped at 25 s, fires at 30 s
      expect(
        gate.tryUpload(lat: _lat0, lon: _lon0, now: _t0.add(const Duration(seconds: 25))),
        isFalse,
      );
      expect(
        gate.tryUpload(lat: _lat0, lon: _lon0, now: _t0.add(const Duration(seconds: 30))),
        isTrue,
      );
      expect(gate.uploadCount, equals(2));
    });

    test('upload fires immediately past 10 m', () {
      final gate = PositionUploadGate();
      expect(gate.tryUpload(lat: _lat0, lon: _lon0, now: _t0), isTrue);

      // Only 2 s later, moved 12 m (> 10 m) -> fires immediately
      final latMoved = _latPlusM(_lat0, 12.0);
      expect(distanceM(_lat0, _lon0, latMoved, _lon0), greaterThan(10.0));
      expect(
        gate.tryUpload(
          lat: latMoved,
          lon: _lon0,
          now: _t0.add(const Duration(seconds: 2)),
        ),
        isTrue,
      );
      expect(gate.uploadCount, equals(2));
    });

    test('measured hourly write rate: standing = 120/hr, moving (5 s cadence) = 720/hr', () {
      // Simulate 1 full hour of 5-second timer ticks (720 ticks: t = 0..3595 s)
      final standingGate = PositionUploadGate();
      final movingGate = PositionUploadGate();

      var curLat = _lat0;
      for (var sec = 0; sec < 3600; sec += 5) {
        final now = _t0.add(Duration(seconds: sec));
        // Standing train: tiny 1 m GPS jitter
        final jitterLat = _latPlusM(_lat0, (sec % 10 == 0) ? 0.5 : -0.5);
        standingGate.tryUpload(lat: jitterLat, lon: _lon0, now: now);

        // Moving train (~50 km/h ≈ 13.9 m/s -> ~69.5 m every 5 s)
        curLat = _latPlusM(curLat, 69.5);
        movingGate.tryUpload(lat: curLat, lon: _lon0, now: now);
      }

      expect(standingGate.uploadCount, equals(120));
      expect(movingGate.uploadCount, equals(720));
    });
  });

  group('FeedFreshnessTracker — stale banner & status card (Step 6 Part 2)', () {
    test('feed stale by 59 s shows no banner; 61 s shows banner with correct age text', () {
      final tracker = FeedFreshnessTracker(startedAt: _t0);
      tracker.recordHazardServerUpdate(_t0);
      tracker.recordTrainServerUpdate(_t0);

      // 59 s -> fresh, no banner
      final t59 = _t0.add(const Duration(seconds: 59));
      expect(tracker.isStale(t59), isFalse);
      expect(tracker.staleBannerText(t59), isNull);

      // 60 s -> boundary, not yet strictly > 60 s
      final t60 = _t0.add(const Duration(seconds: 60));
      expect(tracker.isStale(t60), isFalse);
      expect(tracker.staleBannerText(t60), isNull);

      // 61 s -> stale, shows banner naming the age
      final t61 = _t0.add(const Duration(seconds: 61));
      expect(tracker.isStale(t61), isTrue);
      expect(
        tracker.staleBannerText(t61),
        equals('No signal — hazards shown were last updated 1 minute ago.'),
      );

      // 4 minutes -> names "4 minutes ago"
      final t4m = _t0.add(const Duration(minutes: 4, seconds: 10));
      expect(
        tracker.staleBannerText(t4m),
        equals('No signal — hazards shown were last updated 4 minutes ago.'),
      );

      // Even if train feed updates, hazard feed still 4 min old keeps banner up
      tracker.recordTrainServerUpdate(t4m);
      expect(tracker.isStale(t4m), isTrue);
      expect(
        tracker.staleBannerText(t4m),
        equals('No signal — hazards shown were last updated 4 minutes ago.'),
      );

      // Once hazard feed also gets a server update, banner clears
      tracker.recordHazardServerUpdate(t4m);
      expect(tracker.isStale(t4m), isFalse);
      expect(tracker.staleBannerText(t4m), isNull);
    });

    test('while stale, status card never returns "No hazards ahead"', () {
      final status = resolveNoHazardStatus(
        feedIsStale: true,
        staleAge: const Duration(minutes: 4),
        hazardProblem: null,
        hasGps: true,
        gpsProblem: null,
        nearbyCount: 0,
      );

      expect(status.title, equals('Cannot check — no signal'));
      expect(status.title, isNot(equals('No hazards ahead')));
      expect(status.isAmberWarning, isTrue);
      expect(status.subtitle, contains('4 minutes ago'));

      // When fresh with GPS and no hazards -> returns "No hazards ahead"
      final fresh = resolveNoHazardStatus(
        feedIsStale: false,
        staleAge: null,
        hazardProblem: null,
        hasGps: true,
        gpsProblem: null,
        nearbyCount: 0,
      );
      expect(fresh.title, equals('No hazards ahead'));
      expect(fresh.isAmberWarning, isFalse);
    });
  });

  group('PendingReportTracker — unsent reports & 5-min warning (Step 6 Part 3)', () {
    test('pending report carries badge and top-bar count, and loses both on confirmation', () {
      final pending = PendingReportTracker();
      expect(pending.hasPending, isFalse);
      expect(pending.topBarLabel, isNull);

      // Report created offline -> marked pending
      pending.markPending('h-offline-1', _t0);
      expect(pending.isPending('h-offline-1'), isTrue);
      expect(pending.count, equals(1));
      expect(pending.topBarLabel, equals('1 report waiting to send'));

      final pendingHazard = Hazard(
        id: 'h-offline-1',
        latitude: _lat0,
        longitude: _lon0,
        objectType: 'obstruction',
        severity: 'blocked',
        reportedBy: 'driver',
        unitId: 'unit-01',
        time: _t0,
        pendingSend: pending.isPending('h-offline-1'),
      );
      expect(pendingHazard.pendingSend, isTrue);

      // Server confirms write -> badge and top-bar count clear
      pending.confirmSent('h-offline-1');
      expect(pending.isPending('h-offline-1'), isFalse);
      expect(pending.count, equals(0));
      expect(pending.topBarLabel, isNull);

      final confirmedHazard = pendingHazard.copyWith(
        pendingSend: pending.isPending('h-offline-1'),
      );
      expect(confirmedHazard.pendingSend, isFalse);
    });

    test('report still unsent after 5 minutes triggers plain warning to driver', () {
      final pending = PendingReportTracker();
      pending.markPending('h-offline-1', _t0);

      // At 4 min 59 s -> no overdue warning yet
      expect(
        pending.overdueWarningText(_t0.add(const Duration(minutes: 4, seconds: 59))),
        isNull,
      );

      // At 5 min -> plain warning telling driver trains behind have NOT been warned
      final warn = pending.overdueWarningText(_t0.add(const Duration(minutes: 5)));
      expect(warn, isNotNull);
      expect(warn, contains('5 minutes'));
      expect(warn, contains('NOT been warned'));

      // Confirming clears the overdue warning
      pending.confirmSent('h-offline-1');
      expect(pending.overdueWarningText(_t0.add(const Duration(minutes: 6))), isNull);
    });
  });
}
