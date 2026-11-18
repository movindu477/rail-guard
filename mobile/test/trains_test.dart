// Live train presence: freshness rules, own-unit filtering, distance sorting,
// and m/s -> km/h conversion. Pure Dart, runs offline with `flutter test`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/driver.dart';
import 'package:railguard_app/trains.dart';
import 'package:railguard_app/warning.dart';

final _t0 = DateTime.utc(2026, 11, 17, 10, 0, 0);

// Colombo Fort (reference train)
const _fortLat = 6.9344, _fortLon = 79.8428;
// Maradana (~1.8 km away)
const _maradanaLat = 6.9291, _maradanaLon = 79.8606;
// Ragama (~15 km away)
const _ragamaLat = 7.0267, _ragamaLon = 79.9219;

OtherTrain _train({
  String unitId = 'unit-02',
  String trainNo = '1005',
  String driverName = 'K. Silva',
  Service service = Service.up,
  double lat = _maradanaLat,
  double lon = _maradanaLon,
  double? heading = 180,
  double? speedMps = 12.5,
  DateTime? lastSeen,
}) => OtherTrain(
  unitId: unitId,
  trainNo: trainNo,
  driverName: driverName,
  service: service,
  lat: lat,
  lon: lon,
  heading: heading,
  speedMps: speedMps,
  lastSeen: lastSeen,
);

RailNetwork _loadNetwork() {
  var path = 'assets/railway_routes.json';
  if (!File(path).existsSync()) {
    path = 'mobile/assets/railway_routes.json';
  }
  return RailNetwork.fromJson(File(path).readAsStringSync());
}

void main() {
  group('freshness', () {
    test('30 s-old train is live', () {
      final t = _train(lastSeen: _t0.subtract(const Duration(seconds: 30)));
      expect(t.freshness(_t0), TrainFreshness.live);
      expect(t.isLive(_t0), isTrue);
    });

    test('3 min-old train is stale', () {
      final t = _train(lastSeen: _t0.subtract(const Duration(minutes: 3)));
      expect(t.freshness(_t0), TrainFreshness.stale);
      expect(t.isLive(_t0), isFalse);
    });

    test('6 min-old train is dropped', () {
      final t = _train(lastSeen: _t0.subtract(const Duration(minutes: 6)));
      expect(t.freshness(_t0), TrainFreshness.dropped);
    });

    test('missing timestamp is stale, not live', () {
      final t = _train(lastSeen: null);
      expect(t.freshness(_t0), TrainFreshness.stale);
      expect(t.isLive(_t0), isFalse);
    });
  });

  group('trainsToShow', () {
    test('own unit is excluded', () {
      final list = [
        _train(unitId: 'unit-01', lastSeen: _t0.subtract(const Duration(seconds: 10))),
        _train(unitId: 'unit-02', lastSeen: _t0.subtract(const Duration(seconds: 10))),
      ];
      final shown = trainsToShow(
        trains: list,
        ownUnitId: 'unit-01',
        now: _t0,
        lat: _fortLat,
        lon: _fortLon,
      );
      expect(shown.map((t) => t.unitId), ['unit-02']);
    });

    test('6 min-old train is dropped while live, 3 min-old and null-timestamp are kept', () {
      final list = [
        _train(unitId: 'live-unit', lastSeen: _t0.subtract(const Duration(seconds: 30))),
        _train(unitId: 'stale-unit', lastSeen: _t0.subtract(const Duration(minutes: 3))),
        _train(unitId: 'no-ts-unit', lastSeen: null),
        _train(unitId: 'old-unit', lastSeen: _t0.subtract(const Duration(minutes: 6))),
      ];
      final shown = trainsToShow(
        trains: list,
        ownUnitId: 'unit-01',
        now: _t0,
        lat: _fortLat,
        lon: _fortLon,
      );
      expect(shown.map((t) => t.unitId), ['live-unit', 'stale-unit', 'no-ts-unit']);
    });

    test('sorting is nearest-first', () {
      final far = _train(
        unitId: 'unit-far',
        lat: _ragamaLat,
        lon: _ragamaLon,
        lastSeen: _t0.subtract(const Duration(seconds: 15)),
      );
      final near = _train(
        unitId: 'unit-near',
        lat: _maradanaLat,
        lon: _maradanaLon,
        lastSeen: _t0.subtract(const Duration(seconds: 15)),
      );
      final shown = trainsToShow(
        trains: [far, near],
        ownUnitId: 'unit-01',
        now: _t0,
        lat: _fortLat,
        lon: _fortLon,
      );
      expect(shown.map((t) => t.unitId), ['unit-near', 'unit-far']);
    });
  });

  group('speed conversion', () {
    test('speed_mps converts correctly to km/h', () {
      expect(speedMpsToKmh(0), 0);
      expect(speedMpsToKmh(10), 36);
      expect(speedMpsToKmh(12.5), 45);
      expect(speedMpsToKmh(22.22), 80);
      expect(speedMpsToKmh(null), isNull);
      expect(speedMpsToKmh(-1), isNull);
      expect(_train(speedMps: 15.0).speedKmh, 54);
    });
  });

  group('Train Conflict Awareness (Step 4 - Part 2)', () {
    late RailNetwork net;

    setUpAll(() {
      net = _loadNetwork();
    });

    test('opposite measured directions on a shared line -> approaching', () {
      final r7 = net.routes['r7']!;
      final pOwn = r7.points[10];
      final pOther = r7.points[30];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final other = _train(
        unitId: 'unit-02',
        trainNo: '1006',
        lat: pOther.lat,
        lon: pOther.lon,
        speedMps: 15.0,
      );

      final conflict = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.increasing,
        ownService: Service.down,
        ownSpeedMps: 10.0,
        otherTrain: other,
        otherMeasuredDir: TravelDirection.decreasing,
      );

      expect(conflict.conflict, equals(TrainConflict.approaching));
      expect(conflict.closingSpeedKmh, equals(90)); // (10 + 15) * 3.6 = 90 km/h
      expect(conflict.alongTrackGapM, closeTo(pOther.chainageM - pOwn.chainageM, 1.0));
      expect(conflict.timeToMeet, isNotNull);
    });

    test('same direction -> not approaching (ahead or behind)', () {
      final r7 = net.routes['r7']!;
      final pOwn = r7.points[10];
      final pOther = r7.points[30];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final otherAhead = _train(
        unitId: 'unit-02',
        lat: pOther.lat,
        lon: pOther.lon,
        speedMps: 15.0,
      );

      final conflictAhead = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.increasing,
        ownService: Service.down,
        ownSpeedMps: 10.0,
        otherTrain: otherAhead,
        otherMeasuredDir: TravelDirection.increasing,
      );

      expect(conflictAhead.conflict, equals(TrainConflict.ahead));
      expect(conflictAhead.conflict, isNot(equals(TrainConflict.approaching)));

      // If other train is behind us
      final pBehind = r7.points[5];
      final otherBehind = _train(
        unitId: 'unit-03',
        lat: pBehind.lat,
        lon: pBehind.lon,
        speedMps: 12.0,
      );
      final conflictBehind = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.increasing,
        ownService: Service.down,
        ownSpeedMps: 10.0,
        otherTrain: otherBehind,
        otherMeasuredDir: TravelDirection.increasing,
      );

      expect(conflictBehind.conflict, equals(TrainConflict.behind));
      expect(conflictBehind.conflict, isNot(equals(TrainConflict.approaching)));
    });

    test('disjoint candidate sets -> never approaching (otherLine)', () {
      final r7 = net.routes['r7']!;
      final r0 = net.routes['r0']!;
      final pOwn = r7.points[10];
      final pOther = r0.points[80];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final other = _train(
        unitId: 'unit-02',
        lat: pOther.lat,
        lon: pOther.lon,
        speedMps: 15.0,
      );

      final conflict = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.increasing,
        ownService: Service.down,
        ownSpeedMps: 10.0,
        otherTrain: other,
        otherMeasuredDir: TravelDirection.decreasing,
      );

      expect(conflict.conflict, equals(TrainConflict.otherLine));
      expect(conflict.conflict, isNot(equals(TrainConflict.approaching)));
    });

    test('unknown direction -> approaching (fail-safe, labeled direction unknown)', () {
      final r7 = net.routes['r7']!;
      final pOwn = r7.points[10];
      final pOther = r7.points[30];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final other = _train(
        unitId: 'unit-02',
        lat: pOther.lat,
        lon: pOther.lon,
        speedMps: 10.0,
        heading: null,
      );

      final conflict = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.unknown,
        ownService: Service.down,
        ownSpeedMps: 0.0,
        otherTrain: other,
        otherMeasuredDir: TravelDirection.unknown,
      );

      expect(conflict.conflict, equals(TrainConflict.approaching));
      expect(conflict.isDirectionUnknown, isTrue);
    });

    test('standing train falls back to registered UP/DOWN service', () {
      final r7 = net.routes['r7']!;
      final pOwn = r7.points[10];
      final pOther = r7.points[30];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final other = _train(
        unitId: 'unit-02',
        lat: pOther.lat,
        lon: pOther.lon,
        service: Service.up,
        speedMps: 0.0,
      );

      final conflict = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.unknown,
        ownService: Service.down,
        ownSpeedMps: 0.0,
        otherTrain: other,
      );

      expect(conflict.conflict, equals(TrainConflict.approaching));
      expect(conflict.isDirectionUnknown, isFalse);
    });

    test('time-to-meet arithmetic: zero combined speed yields unknown and no division by zero', () {
      final r7 = net.routes['r7']!;
      final pOwn = r7.points[10];
      final pOther = r7.points[30];

      final ownPos = net.snap(pOwn.lat, pOwn.lon)!;
      final other = _train(
        unitId: 'unit-02',
        lat: pOther.lat,
        lon: pOther.lon,
        service: Service.up,
        speedMps: 0.0,
      );

      final conflict = classifyTrainConflict(
        network: net,
        ownTrackPos: ownPos,
        ownMeasuredDir: TravelDirection.unknown,
        ownService: Service.down,
        ownSpeedMps: 0.0,
        otherTrain: other,
      );

      expect(conflict.closingSpeedMps, equals(0.0));
      expect(conflict.timeToMeet, isNull);
      expect(conflict.timeToMeetText, equals('unknown'));
    });

    test('time-to-meet arithmetic: calculates accurate duration and formatting', () {
      const info1 = TrainConflictInfo(
        conflict: TrainConflict.approaching,
        alongTrackGapM: 1500,
        closingSpeedMps: 25.0, // 90 km/h
        timeToMeet: Duration(seconds: 60),
      );
      expect(info1.closingSpeedKmh, equals(90));
      expect(info1.timeToMeetText, equals('1 min'));

      const info2 = TrainConflictInfo(
        conflict: TrainConflict.approaching,
        alongTrackGapM: 450,
        closingSpeedMps: 10.0, // 36 km/h
        timeToMeet: Duration(seconds: 45),
      );
      expect(info2.closingSpeedKmh, equals(36));
      expect(info2.timeToMeetText, equals('45 s'));

      const info3 = TrainConflictInfo(
        conflict: TrainConflict.approaching,
        alongTrackGapM: 2500,
        closingSpeedMps: 20.0,
        timeToMeet: Duration(seconds: 125), // 2 min 5 s
      );
      expect(info3.timeToMeetText, equals('2 min 5 s'));
    });
  });
}
