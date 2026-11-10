// The railway network drawn on the map: Sri Lanka's running lines from
// OpenStreetMap, built by tool/railway_from_osm.py. Drawn by the app rather
// than relying on Google's transit layer, which is patchy for Sri Lankan rail.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';

Future<List<List<LatLng>>> loadRailway() async {
  final data = jsonDecode(await rootBundle.loadString('assets/railway_line.json'));
  return [
    for (final line in data['lines'] as List)
      [for (final p in line as List) LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble())],
  ];
}
