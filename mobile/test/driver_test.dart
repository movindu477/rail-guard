// Driver profile: storage round trip and form validation.
// No Flutter widgets, no Firebase: these run with `flutter test` offline.

import 'package:flutter_test/flutter_test.dart';
import 'package:railguard_app/driver.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sample = DriverProfile(
  unitId: 'unit-02',
  driverName: 'W. Perera',
  driverId: 'SLR-4417',
  trainNo: '1005',
  service: Service.down,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('storage', () {
    test('nothing stored reads as not registered', () async {
      expect(await loadDriver(), isNull);
    });

    test('saved profile comes back unchanged', () async {
      await saveDriver(_sample);
      final got = await loadDriver();
      expect(got, isNotNull);
      expect(got!.unitId, 'unit-02');
      expect(got.driverName, 'W. Perera');
      expect(got.driverId, 'SLR-4417');
      expect(got.trainNo, '1005');
      expect(got.service, Service.down);
    });

    test('signing out clears the phone', () async {
      await saveDriver(_sample);
      await clearDriver();
      expect(await loadDriver(), isNull);
    });

    test('corrupt stored value reads as not registered, not a crash', () async {
      SharedPreferences.setMockInitialValues({'railguard.driver.v1': 'not json'});
      expect(await loadDriver(), isNull);
    });
  });

  group('map round trip', () {
    test('toMap then fromMap keeps every field', () {
      final back = DriverProfile.fromMap(_sample.toMap());
      expect(back.unitId, _sample.unitId);
      expect(back.trainNo, _sample.trainNo);
      expect(back.service, _sample.service);
    });

    test('missing service falls back to up, missing unit to the build default', () {
      final p = DriverProfile.fromMap({'driver_name': 'X'});
      expect(p.service, Service.up);
      expect(p.unitId, defaultUnitId);
    });

    test('train label reads as it is spoken', () {
      expect(_sample.trainLabel, '1005 DOWN');
    });
  });

  group('validation', () {
    test('unit id accepts the ids the laptop uses', () {
      expect(validateUnitId('unit-01'), isNull);
      expect(validateUnitId('  unit-02  '), isNull);
    });

    test('unit id rejects what cannot be a document id', () {
      expect(validateUnitId(''), isNotNull);
      expect(validateUnitId('a'), isNotNull); // too short to retype safely
      expect(validateUnitId('Unit 01'), isNotNull); // space and capital
      expect(validateUnitId('-unit'), isNotNull); // leading dash
      expect(validateUnitId('unit/01'), isNotNull); // slash splits a path
    });

    test('name and staff number are required', () {
      expect(validateRequired('', 'Name'), isNotNull);
      expect(validateRequired('   ', 'Name'), isNotNull);
      expect(validateRequired('W. Perera', 'Name'), isNull);
    });

    test('train number is required and short', () {
      expect(validateTrainNo(''), isNotNull);
      expect(validateTrainNo('123456789'), isNotNull);
      expect(validateTrainNo('1005'), isNull);
      expect(validateTrainNo('8760A'), isNull);
    });
  });
}
