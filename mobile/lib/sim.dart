// Simulated GPS for demonstrations without going outside. Demo build only:
//
//   flutter run --dart-define=RAILGUARD_SIM=true
//
// Drives along assets/demo_route.json (Coastal Line, southbound) at line speed
// and brakes like a driver while a STOP alert is on. Everything after the GPS
// is the real app: real Firestore hazards, real alert tiers, sound, vibration.
// The screen says "SIMULATED GPS" throughout, and train_position is not
// uploaded in this mode (the laptop must never place hazards from it).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';

import 'warning.dart';

const simMode = bool.fromEnvironment('RAILGUARD_SIM');

class SimDrive {
  static const cruiseMps = 20.0; // 72 km/h
  static const brakeMps2 = 0.8; // service braking
  static const accelMps2 = 0.4;

  final List<(double, double)> route;
  final double stepM;
  final bool Function() shouldBrake;
  double _s = 0, _v = cruiseMps;
  Timer? _timer;
  final _out = StreamController<Position>();

  SimDrive(this.route, this.stepM, this.shouldBrake);

  static Future<SimDrive> load(bool Function() shouldBrake) async {
    final d = jsonDecode(await rootBundle.loadString('assets/demo_route.json'));
    return SimDrive(
      [for (final p in d['route'] as List) ((p[0] as num).toDouble(), (p[1] as num).toDouble())],
      (d['step_m'] as num).toDouble(),
      shouldBrake,
    );
  }

  double get lengthM => (route.length - 1) * stepM;

  (double, double) _at(double s) {
    final x = (s / stepM).clamp(0, route.length - 1.0001);
    final i = x.floor();
    final t = x - i;
    final a = route[i], b = route[i + 1];
    return (a.$1 + t * (b.$1 - a.$1), a.$2 + t * (b.$2 - a.$2));
  }

  /// One position per second until the end of the route.
  Stream<Position> start() {
    _emit();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (shouldBrake()) {
        _v = (_v - brakeMps2).clamp(0, cruiseMps);
      } else if (_v < cruiseMps) {
        _v = (_v + accelMps2).clamp(0, cruiseMps);
      }
      _s = (_s + _v).clamp(0, lengthM);
      if (_s >= lengthM) _v = 0;
      _emit();
    });
    return _out.stream;
  }

  void _emit() {
    final (lat, lon) = _at(_s);
    final (lat2, lon2) = _at(_s + 10);
    _out.add(
      Position(
        latitude: lat,
        longitude: lon,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: bearingDeg(lat, lon, lat2, lon2),
        headingAccuracy: 1,
        speed: _v,
        speedAccuracy: 0.5,
        isMocked: true,
      ),
    );
  }

  void stop() {
    _timer?.cancel();
    _out.close();
  }
}
