// RailGuard driver app: marks hazards with GPS and warns about hazards ahead.
// No camera here: detection runs on the train unit (see legacy_detection/README.md).
//
// Screen: full-screen dark railway map, a top bar (GPS status, follow toggle),
// and at the bottom the hazard status card and a large Report hazard button.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'firebase_options.dart';
import 'railway.dart';
import 'ui/markers.dart';
import 'ui/sheets.dart';
import 'ui/theme.dart';
import 'warning.dart';

Future<void> main() async {
  // Must run before any plugin call, or the app crashes on launch.
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const RailGuardApp());
}

class RailGuardApp extends StatelessWidget {
  const RailGuardApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RailGuard',
        debugShowCheckedModeBanner: false,
        theme: railGuardTheme(),
        home: const HomeScreen(),
      );
}

const _colombo = LatLng(6.9271, 79.8612);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // GPS
  Position? _pos;                          // latest GPS fix, null until the first one
  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<ServiceStatus>? _serviceSub;
  bool _gpsStarting = false;
  String? _gpsProblem = 'GPS starting…';   // why there is no usable fix, if any

  // Hazards
  List<Hazard> _hazards = [];              // active reports from Firestore
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _hazardSub;
  String? _hazardProblem;                  // Firestore read error, if any
  HazardWarning? _warning;                 // closest hazard ahead, null if none
  Timer? _recheck;                         // re-runs the check while standing still
  bool _saving = false;

  // Map
  GoogleMapController? _map;
  String? _mapStyle;
  Set<Polyline> _rail = {};
  bool _follow = true;                     // keep the train in view
  bool _centred = false;                   // camera moved to the first fix yet
  final Map<String, BitmapDescriptor> _icons = {};
  BitmapDescriptor? _trainIcon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startHazards();
    _startGps();
    _loadMap();
    // Location switched on (or off) from the quick settings: retry or report it.
    _serviceSub = Geolocator.getServiceStatusStream().listen((status) {
      if (status == ServiceStatus.enabled) {
        _startGps();
      } else if (mounted) {
        setState(() => _gpsProblem = 'Location is off. Turn on location in phone settings.');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _makeIcons());
  }

  /// Back from Settings (permission or location changed there): retry.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _startGps();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceSub?.cancel();
    _gpsSub?.cancel();
    _hazardSub?.cancel();
    _recheck?.cancel();
    _map?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- GPS

  /// True only if location services are on and the app may use location.
  /// Asks for permission if it has not been decided yet.
  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _gpsProblem = 'Location is off. Turn on location in phone settings.');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      setState(() => _gpsProblem = permission == LocationPermission.deniedForever
          ? 'Location permission blocked. Allow it in Settings > Apps > RailGuard.'
          : 'Location permission denied. Restart the app and allow location.');
      return false;
    }
    return true;
  }

  /// Starts the position stream; safe to call again (does nothing if running).
  Future<void> _startGps() async {
    if (_gpsSub != null || _gpsStarting) return;
    _gpsStarting = true;
    try {
      if (!await _ensureLocationPermission()) return;
      setState(() => _gpsProblem = 'Waiting for GPS fix… (go outside)');
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5, // metres moved before the next update
        ),
      ).listen(
        _onPosition,
        onError: (e) {
          // e.g. location switched off: drop the stream so _startGps can restart it.
          _gpsSub?.cancel();
          _gpsSub = null;
          if (mounted) setState(() => _gpsProblem = 'GPS error: $e');
        },
      );
    } catch (e) {
      if (mounted) setState(() => _gpsProblem = 'GPS error: $e');
    } finally {
      _gpsStarting = false;
    }
  }

  void _onPosition(Position pos) {
    if (!mounted) return;
    setState(() {
      _pos = pos;
      _gpsProblem = null;
    });
    _updateWarning();
    if (_follow || !_centred) _moveTo(LatLng(pos.latitude, pos.longitude));
  }

  // ------------------------------------------------------------ hazards

  /// Keeps [_hazards] in step with the active reports in Firestore.
  void _startHazards() {
    _hazardSub = FirebaseFirestore.instance
        .collection('hazards')
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen(
      (snap) {
        _hazards = [for (final doc in snap.docs) ?_parseHazard(doc.id, doc.data())];
        _hazardProblem = null;
        _updateWarning();
      },
      onError: (e) {
        if (mounted) setState(() => _hazardProblem = 'Hazard feed offline');
      },
    );
    // The GPS stream is silent while standing still (5 m filter), so re-check
    // regularly: reports still expire and new ones still show.
    _recheck = Timer.periodic(const Duration(seconds: 15), (_) => _updateWarning());
  }

  /// A Firestore document as a Hazard, or null if it has no usable position.
  static Hazard? _parseHazard(String id, Map<String, dynamic> d) {
    final lat = d['latitude'], lon = d['longitude'];
    if (lat is! num || lon is! num) return null;
    final t = d['timestamp'];
    return Hazard(
      id: id,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      objectType: (d['object_type'] as String?) ?? 'unknown',
      // Timestamp from the app; ISO text from a hand-written test document.
      time: t is Timestamp ? t.toDate() : (t is String ? DateTime.tryParse(t) : null),
    );
  }

  void _updateWarning() {
    final pos = _pos;
    final w = pos == null
        ? null
        : closestHazardAhead(
            lat: pos.latitude,
            lon: pos.longitude,
            headingDeg: usableHeading(pos.heading, pos.speed),
            hazards: _hazards,
            now: DateTime.now(),
          );
    if (mounted) setState(() => _warning = w);
  }

  /// Active reports not yet expired (what the map and the list show).
  List<Hazard> _fresh() {
    final now = DateTime.now();
    return _hazards
        .where((h) => h.time == null || now.difference(h.time!) <= hazardMaxAge)
        .toList();
  }

  HazardRow _row(Hazard h) {
    final pos = _pos;
    if (pos == null) return HazardRow(h, null, null);
    final heading = usableHeading(pos.heading, pos.speed);
    return HazardRow(
      h,
      distanceM(pos.latitude, pos.longitude, h.latitude, h.longitude),
      heading == null
          ? null
          : isAhead(bearingDeg(pos.latitude, pos.longitude, h.latitude, h.longitude), heading),
    );
  }

  /// Writes to Firestore without leaving the driver waiting: with no signal the
  /// change is kept on the phone and uploaded later.
  Future<void> _write(Future<void> write, String done, String queued) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await write.timeout(const Duration(seconds: 8));
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on TimeoutException {
      messenger.showSnackBar(SnackBar(content: Text(queued)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('FAILED: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _report() async {
    final pos = _pos;
    if (pos == null) {
      // Refuse rather than save a wrong location.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No GPS fix yet, nothing sent. ${_gpsProblem ?? ''}')));
      return;
    }
    final type = await showReportSheet(context, accuracyM: pos.accuracy);
    if (type == null || !mounted) return; // closed without choosing
    final label = typeInfo(type).label;
    await _write(
      FirebaseFirestore.instance.collection('hazards').add({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'timestamp': Timestamp.now(),
        'object_type': type,
        'distance_m': 0,
        'status': 'active',
      }),
      '$label reported at ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
      '$label saved on the phone; uploads when signal returns',
    );
  }

  Future<void> _showHazard(Hazard h) async {
    final clear = await showHazardDetail(context, row: _row(h));
    if (!clear || !mounted) return;
    await _write(
      FirebaseFirestore.instance
          .collection('hazards')
          .doc(h.id)
          .update({'status': 'cleared', 'cleared_at': Timestamp.now()}),
      '${typeInfo(h.objectType).label} cleared',
      'Cleared on the phone; uploads when signal returns',
    );
  }

  Future<void> _showList() async {
    final rows = _fresh().map(_row).toList()
      ..sort((a, b) => a.distanceM != null && b.distanceM != null
          ? a.distanceM!.compareTo(b.distanceM!)
          : (b.hazard.time ?? DateTime(0)).compareTo(a.hazard.time ?? DateTime(0)));
    final h = await showHazardList(context, rows: rows);
    if (h == null || !mounted) return;
    setState(() => _follow = false);
    _moveTo(LatLng(h.latitude, h.longitude));
    await _showHazard(h);
  }

  // ---------------------------------------------------------------- map

  Future<void> _loadMap() async {
    final style = await rootBundle.loadString('assets/map_style.json');
    final lines = await loadRailway();
    if (!mounted) return;
    setState(() {
      _mapStyle = style;
      _rail = {
        for (var i = 0; i < lines.length; i++) ...[
          // Soft glow under a thin bright line.
          Polyline(
              polylineId: PolylineId('glow$i'),
              points: lines[i],
              color: RG.accent.withValues(alpha: 0.22),
              width: 10,
              zIndex: 0),
          Polyline(
              polylineId: PolylineId('rail$i'),
              points: lines[i],
              color: RG.accent,
              width: 3,
              zIndex: 1),
        ],
      };
    });
  }

  Future<void> _makeIcons() async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final icons = <String, BitmapDescriptor>{};
    for (final emoji in {...hazardTypes.map((t) => t.emoji), '⚠️'}) {
      icons['$emoji/ahead'] = await hazardPin(emoji, RG.danger, dpr);
      icons['$emoji/other'] = await hazardPin(emoji, RG.warn, dpr);
    }
    final train = await trainDot(dpr);
    if (!mounted) return;
    setState(() {
      _icons
        ..clear()
        ..addAll(icons);
      _trainIcon = train;
    });
  }

  void _moveTo(LatLng target) {
    final map = _map;
    if (map == null) return;
    map.animateCamera(
        _centred ? CameraUpdate.newLatLng(target) : CameraUpdate.newLatLngZoom(target, 15));
    _centred = true;
  }

  Set<Marker> _markers() {
    final markers = <Marker>{};
    for (final h in _fresh()) {
      final emoji = typeInfo(h.objectType).emoji;
      final ahead = _warning?.hazard.id == h.id; // the one being warned about
      markers.add(Marker(
        // State in the id: the map plugin does not always redraw a marker
        // whose icon alone changed, so a new id forces the swap.
        markerId: MarkerId('${h.id}/${ahead ? 'ahead' : 'other'}'),
        position: LatLng(h.latitude, h.longitude),
        icon: _icons['$emoji/${ahead ? 'ahead' : 'other'}'] ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 1.0),
        consumeTapEvents: true,
        onTap: () => _showHazard(h),
      ));
    }
    final pos = _pos;
    if (pos != null && _trainIcon != null) {
      markers.add(Marker(
        markerId: const MarkerId('train'),
        position: LatLng(pos.latitude, pos.longitude),
        icon: _trainIcon!,
        anchor: const Offset(0.5, 0.5),
        consumeTapEvents: true,
      ));
    }
    return markers;
  }

  Set<Circle> _circles() {
    final pos = _pos;
    if (pos == null) return {};
    return {
      // GPS accuracy around the train.
      Circle(
        circleId: const CircleId('accuracy'),
        center: LatLng(pos.latitude, pos.longitude),
        radius: pos.accuracy,
        fillColor: RG.accent.withValues(alpha: 0.12),
        strokeColor: RG.accent.withValues(alpha: 0.45),
        strokeWidth: 1,
      ),
    };
  }

  // ------------------------------------------------------------- screen

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          Positioned.fill(
            // Dragging the map stops following the train.
            child: Listener(
              onPointerMove: (e) {
                if (_follow && e.delta.distance > 2) setState(() => _follow = false);
              },
              child: GoogleMap(
                initialCameraPosition: const CameraPosition(target: _colombo, zoom: 13),
                style: _mapStyle,
                polylines: _rail,
                markers: _markers(),
                circles: _circles(),
                myLocationEnabled: false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                compassEnabled: false,
                // Keep the Google logo and centre clear of the overlays.
                padding: const EdgeInsets.only(top: 110, bottom: 250),
                onMapCreated: (c) {
                  _map = c;
                  final pos = _pos;
                  if (pos != null) _moveTo(LatLng(pos.latitude, pos.longitude));
                },
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _topBar()),
          Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel()),
        ]),
      );

  Widget _topBar() {
    final pos = _pos;
    final ok = pos != null && _gpsProblem == null;
    final heading = pos == null ? null : usableHeading(pos.heading, pos.speed);
    final status = ok
        ? 'GPS ±${pos.accuracy.toStringAsFixed(0)} m  ·  '
            '${heading == null ? 'stationary' : 'heading ${heading.toStringAsFixed(0)}°'}'
        : 'No GPS fix';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [RG.bg, RG.bg.withValues(alpha: 0.85), RG.bg.withValues(alpha: 0)],
          stops: const [0, 0.6, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 28),
          child: Column(children: [
            Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(color: RG.surfaceHigh, shape: BoxShape.circle),
                child: const Icon(Icons.train_rounded, color: RG.accent, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('RailGuard',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: RG.text)),
                  Row(children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                          color: ok ? RG.accent : RG.warn, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(status,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, color: RG.textDim)),
                    ),
                  ]),
                ]),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: _follow,
                  onChanged: (v) {
                    setState(() => _follow = v);
                    final p = _pos;
                    if (v && p != null) _moveTo(LatLng(p.latitude, p.longitude));
                  },
                ),
                const Text('Follow', style: TextStyle(fontSize: 12, color: RG.textDim)),
              ]),
            ]),
            // Why there is no fix, in full.
            if (_gpsProblem != null)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: RG.surfaceHigh.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(_gpsProblem!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: RG.text)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _bottomPanel() => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [RG.bg, RG.bg.withValues(alpha: 0.9), RG.bg.withValues(alpha: 0)],
            stops: const [0, 0.7, 1],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 32, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _statusCard(),
              const SizedBox(height: 12),
              // Large: pressed in a moving cab.
              SizedBox(
                width: double.infinity,
                height: 68,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: RG.accent,
                    foregroundColor: RG.onAccent,
                    disabledBackgroundColor: RG.accent.withValues(alpha: 0.5),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _saving ? null : _report,
                  child: _saving
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 3, color: RG.onAccent))
                      : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.add_alert_rounded, size: 28),
                          SizedBox(width: 10),
                          Text('Report hazard',
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                        ]),
                ),
              ),
            ]),
          ),
        ),
      );

  /// Red when a hazard is ahead; orange when hazards cannot be checked (no
  /// GPS, feed offline) - never "no hazards" unless that was checked.
  Widget _statusCard() {
    final w = _warning;
    final pos = _pos;
    final n = _fresh().length;
    final Color colour;
    final Widget lead;
    final String title, subtitle;
    String? time = pos == null ? null : hhmm(pos.timestamp);

    if (w != null) {
      final t = typeInfo(w.hazard.objectType);
      colour = RG.danger;
      lead = Text(t.emoji, style: const TextStyle(fontSize: 34));
      title = '${t.label.toUpperCase()}  ${formatDistance(w.distanceM)}';
      subtitle = w.headingKnown ? 'Ahead on your route' : 'Direction unknown (not moving)';
    } else if (_hazardProblem != null) {
      colour = RG.warn;
      lead = const Icon(Icons.cloud_off_rounded, color: RG.onAccent, size: 30);
      title = 'Hazards not checked';
      subtitle = _hazardProblem!;
    } else if (pos == null) {
      colour = RG.warn;
      lead = const Icon(Icons.gps_off_rounded, color: RG.onAccent, size: 30);
      title = 'Hazards not checked';
      subtitle = 'No GPS position';
    } else {
      colour = RG.surface;
      lead = const Icon(Icons.check_circle_rounded, color: RG.accent, size: 32);
      title = 'No hazards ahead';
      subtitle = n == 0 ? 'Line clear within 3 km' : '$n active report${n == 1 ? '' : 's'} nearby';
    }
    final alert = colour != RG.surface;
    final fg = colour == RG.warn ? RG.onAccent : RG.text;

    return Material(
      color: colour,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _showList,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: alert ? null : Border.all(color: RG.border),
          ),
          child: Row(children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: alert ? Colors.white.withValues(alpha: 0.22) : RG.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: lead,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: w != null ? 28 : 22, fontWeight: FontWeight.w800, color: fg)),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: fg.withValues(alpha: 0.85))),
              ]),
            ),
            if (time != null && !alert)
              Text(time,
                  style: const TextStyle(
                      fontSize: 15, color: RG.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}
