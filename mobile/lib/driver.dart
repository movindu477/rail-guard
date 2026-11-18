/// The driver signed in on this phone, and the train they are working.
///
/// Kept on the device (shared_preferences) as an offline cache so the app opens
/// straight into the map without network. Firestore `drivers/{uid}` is the
/// authoritative record, keyed by the Firebase Auth user id.
/// Nothing here touches Flutter widgets, so it is unit tested in
/// test/driver_test.dart.
library;

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _storeKey = 'railguard.driver.v1';

/// Unit id suggested on the registration form. Overridable at build time for
/// the two-phone demo: flutter run --dart-define=RAILGUARD_UNIT=unit-02
const defaultUnitId = String.fromEnvironment(
  'RAILGUARD_UNIT',
  defaultValue: 'unit-01',
);

/// Which way along the line the train is working. Sri Lankan practice: an UP
/// train runs towards Colombo Fort, a DOWN train runs away from it. Trains
/// only warn trains working the same way (see Step 4).
enum Service { up, down }

extension ServiceText on Service {
  String get id => name; // 'up' | 'down'
  String get short => this == Service.up ? 'UP' : 'DOWN';
  String get label =>
      this == Service.up ? 'Up — towards Colombo' : 'Down — away from Colombo';
}

/// Anything not 'down' reads as 'up': a missing value must still give a train.
Service serviceFrom(Object? v) => v == 'down' ? Service.down : Service.up;

class DriverProfile {
  /// This phone's train unit, e.g. "unit-01". The laptop's hazard publisher
  /// writes to `train_position/{unitId}`, so the two must match.
  final String unitId;
  final String driverName;

  /// Railway staff number, so a report can be traced to a person.
  final String driverId;
  final String trainNo;
  final Service service;
  final String email;

  const DriverProfile({
    required this.unitId,
    required this.driverName,
    required this.driverId,
    required this.trainNo,
    this.service = Service.up,
    this.email = '',
  });

  /// "1005 UP · unit-01" for the top bar.
  String get trainLabel => '$trainNo ${service.short}';

  Map<String, dynamic> toMap() => {
    'unit_id': unitId,
    'driver_name': driverName,
    'driver_id': driverId,
    'train_no': trainNo,
    'service': service.id,
    'email': email,
  };

  factory DriverProfile.fromMap(Map<String, dynamic> m) => DriverProfile(
    unitId: (m['unit_id'] as String?)?.trim().isNotEmpty == true
        ? (m['unit_id'] as String).trim()
        : defaultUnitId,
    driverName: (m['driver_name'] as String?) ?? '',
    driverId: (m['driver_id'] as String?) ?? '',
    trainNo: (m['train_no'] as String?) ?? '',
    service: serviceFrom(m['service']),
    email: (m['email'] as String?) ?? '',
  );

  DriverProfile copyWith({
    String? unitId,
    String? driverName,
    String? driverId,
    String? trainNo,
    Service? service,
    String? email,
  }) => DriverProfile(
    unitId: unitId ?? this.unitId,
    driverName: driverName ?? this.driverName,
    driverId: driverId ?? this.driverId,
    trainNo: trainNo ?? this.trainNo,
    service: service ?? this.service,
    email: email ?? this.email,
  );
}

// ------------------------------------------------------------ persistence

/// The registered driver cached on this phone, or null if never saved.
/// A stored value that cannot be read is treated as "never registered"
/// rather than crashing the app on launch.
Future<DriverProfile?> loadDriver() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_storeKey);
    if (raw == null || raw.isEmpty) return null;
    final m = jsonDecode(raw);
    if (m is! Map) return null;
    return DriverProfile.fromMap(Map<String, dynamic>.from(m));
  } catch (_) {
    return null;
  }
}

Future<void> saveDriver(DriverProfile p) async =>
    (await SharedPreferences.getInstance()).setString(
      _storeKey,
      jsonEncode(p.toMap()),
    );

/// Signs the driver out of this phone's local cache.
Future<void> clearDriver() async =>
    (await SharedPreferences.getInstance()).remove(_storeKey);

// ------------------------------------------------------------ Firestore

/// Writes the driver profile to Firestore `drivers/{uid}`. Throws on error so
/// callers can show actionable errors or retry.
Future<void> saveDriverToFirestore(String uid, DriverProfile p) async {
  await FirebaseFirestore.instance.collection('drivers').doc(uid).set({
    ...p.toMap(),
    'updated_at': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

/// Reads the authoritative profile from Firestore `drivers/{uid}`.
/// Returns null if the document does not exist or network fails.
Future<DriverProfile?> fetchDriverFromFirestore(String uid) async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('drivers')
        .doc(uid)
        .get();
    if (!doc.exists || doc.data() == null) return null;
    return DriverProfile.fromMap(doc.data()!);
  } catch (e) {
    debugPrint('fetchDriverFromFirestore error: $e');
    return null;
  }
}

// ------------------------------------------------------------ validation

/// Lower-case letters, digits and dashes: it becomes a Firestore document id
/// and is typed on the laptop as --unit, so it must be simple to retype.
final _unitPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,23}$');

String? validateUnitId(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Required';
  if (!_unitPattern.hasMatch(s)) return 'Lower-case letters, digits and - only';
  return null;
}

String? validateRequired(String? v, String field) =>
    (v ?? '').trim().isEmpty ? '$field is required' : null;

/// Train numbers on Sri Lankan services are short and may carry a letter.
String? validateTrainNo(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Required';
  if (s.length > 8) return 'Too long';
  return null;
}
