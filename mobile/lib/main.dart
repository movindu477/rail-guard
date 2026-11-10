// RailGuard driver app: marks hazards with GPS and warns about hazards ahead.
// No camera here: detection runs on the train unit (see legacy_detection/README.md).
//
// Screen: full-screen dark railway map, a top bar (GPS status, follow toggle),
// and at the bottom the hazard status card and a large Report hazard button.
// Alerts for a following train, once each per hazard (warning.dart):
//   INFO 3 km grey card · CAUTION 1 km orange, beep, short vibration ·
//   STOP 400 m (1 km if the line is blocked) full screen, alarm until acknowledged.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'alarm.dart';
import 'firebase_options.dart';
import 'railway.dart';
import 'sim.dart';
import 'ui/markers.dart';
import 'ui/sheets.dart';
import 'ui/stop_alert.dart';
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

/// This phone's train unit. The laptop's hazard publisher reads
/// `train_position/{unitId}` to place automatic hazards, so both must match:
/// flutter run --dart-define=RAILGUARD_UNIT=unit-02 / publisher --unit unit-02.
const unitId = String.fromEnvironment('RAILGUARD_UNIT', defaultValue: 'unit-01');

/// How often the train position is sent to Firestore.
const positionUploadInterval = Duration(seconds: 5);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // GPS
  Position? _pos; // latest GPS fix, null until the first one
  double? _lastHeading; // last known heading: kept while standing
  StreamSubscription<Position>? _gpsSub;
  SimDrive? _sim; // demo build only: simulated GPS
  StreamSubscription<ServiceStatus>? _serviceSub;
  bool _gpsStarting = false;
  String? _gpsProblem = 'GPS starting…'; // why there is no usable fix, if any

  // Hazards and alerts
  List<Hazard> _hazards = []; // active reports from Firestore
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _hazardSub;
  String? _hazardProblem; // Firestore read error, if any
  List<HazardWarning> _ahead = []; // hazards ahead in range, most urgent first
  final _tracker = AlertTracker(); // which level has sounded for each hazard
  final _alarm = Alarm();
  final Set<String> _acknowledged = {}; // STOP alerts the driver has acknowledged
  Timer? _recheck; // re-runs the check while standing still
  Timer? _positionUpload; // train_position every 5 s
  bool _saving = false;

  // Map
  GoogleMapController? _map;
  String? _mapStyle;
  Set<Polyline> _rail = {};
  bool _follow = true; // keep the train in view
  bool _centred = false; // camera moved to the first fix yet
  final Map<String, BitmapDescriptor> _icons = {};
  BitmapDescriptor? _trainIcon;

  /// The most urgent hazard ahead, shown in the status card.
  HazardWarning? get _warning => _ahead.isEmpty ? null : _ahead.first;

  /// The STOP alert to show full screen: most urgent one not yet acknowledged.
  HazardWarning? get _stopAlert {
    for (final w in _ahead) {
      if (w.level == AlertLevel.stop && !_acknowledged.contains(w.hazard.id)) return w;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _alarm.init();
    _startHazards();
    _loadMap();
    if (simMode) {
      _startSim();
    } else {
      _startGps();
      // Location switched on (or off) from the quick settings: retry or report it.
      _serviceSub = Geolocator.getServiceStatusStream().listen((status) {
        if (status == ServiceStatus.enabled) {
          _startGps();
        } else if (mounted) {
          setState(() => _gpsProblem = 'Location is off. Turn on location in phone settings.');
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _makeIcons());
    _positionUpload = Timer.periodic(positionUploadInterval, (_) => _uploadPosition());
  }

  /// Back from Settings (permission or location changed there): retry.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !simMode) _startGps();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceSub?.cancel();
    _gpsSub?.cancel();
    _sim?.stop();
    _hazardSub?.cancel();
    _recheck?.cancel();
    _positionUpload?.cancel();
    _alarm.dispose();
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
      setState(
        () => _gpsProblem = permission == LocationPermission.deniedForever
            ? 'Location permission blocked. Allow it in Settings > Apps > RailGuard.'
            : 'Location permission denied. Restart the app and allow location.',
      );
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
      _gpsSub =
          Geolocator.getPositionStream(
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

  /// Demo build: positions from a simulated drive instead of the GPS. The
  /// simulated driver brakes while a STOP alert is on, and pulls away again
  /// once it is gone (hazard cleared or passed).
  Future<void> _startSim() async {
    final sim = await SimDrive.load(() => _ahead.any((w) => w.level == AlertLevel.stop));
    if (!mounted) return;
    _sim = sim;
    _gpsSub = sim.start().listen(_onPosition);
  }

  void _onPosition(Position pos) {
    if (!mounted) return;
    setState(() {
      _pos = pos;
      _gpsProblem = null;
      _lastHeading = usableHeading(pos.heading, pos.speed) ?? _lastHeading;
    });
    _updateWarning();
    if (_follow || !_centred) _moveTo(LatLng(pos.latitude, pos.longitude));
  }

  /// One document per unit, overwritten: where this train is now, for the
  /// laptop to place the hazards its camera finds. Not awaited: with no
  /// signal Firestore keeps the latest write and sends it when it can.
  void _uploadPosition() {
    final pos = _pos;
    if (pos == null) return; // no fix: send nothing rather than a stale or wrong position
    if (simMode) return; // never let the laptop place hazards from simulated positions
    FirebaseFirestore.instance
        .collection('train_position')
        .doc(unitId)
        .set({
          'unit_id': unitId,
          'latitude': pos.latitude,
          'longitude': pos.longitude,
          'heading': usableHeading(pos.heading, pos.speed), // null = unknown (standing / slow)
          'accuracy_m': pos.accuracy,
          // Server time, so the laptop can tell how old the position is without
          // depending on the phone's clock.
          'timestamp': FieldValue.serverTimestamp(),
        })
        .catchError((Object e) => debugPrint('train_position upload failed: $e'));
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
    final reportedBy = (d['reported_by'] as String?) ?? '';
    final dist = d['distance_m'], conf = d['confidence'];
    return Hazard(
      id: id,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      objectType: (d['object_type'] as String?) ?? 'unknown',
      // Timestamp from the app; ISO text from a hand-written test document.
      time: t is Timestamp ? t.toDate() : (t is String ? DateTime.tryParse(t) : null),
      severity: (d['severity'] as String?) ?? '',
      reportedBy: reportedBy,
      unitId: d['unit_id'] as String?,
      cameraDistanceM: reportedBy == 'auto' && dist is num ? dist.toDouble() : null,
      confidence: conf is num ? conf.toDouble() : null,
    );
  }

  /// Recomputes the alerts, and sounds each new level once.
  void _updateWarning() {
    final pos = _pos;
    // This train's own reports do not alert it: its driver (or its camera
    // unit) already knows. They still show on the map and in the list.
    final others = _hazards.where((h) => h.unitId != unitId);
    final ahead = pos == null
        ? <HazardWarning>[]
        : hazardsAhead(
            lat: pos.latitude,
            lon: pos.longitude,
            headingDeg: usableHeading(pos.heading, pos.speed),
            hazards: others,
            now: DateTime.now(),
          );
    _tracker.keepOnly(_hazards.map((h) => h.id).toSet());
    _acknowledged.retainWhere((id) => _hazards.any((h) => h.id == id));
    final raised = _tracker.raised(ahead);
    if (raised.any((w) => w.level == AlertLevel.caution) &&
        !raised.any((w) => w.level == AlertLevel.stop)) {
      _alarm.caution();
    }
    if (!mounted) return;
    setState(() => _ahead = ahead);
    // The alarm rings while an unacknowledged STOP is on screen; it stops by
    // itself if that hazard goes (passed, cleared, expired).
    if (_stopAlert != null) {
      _alarm.startStop();
    } else {
      _alarm.stopStop();
    }
  }

  void _acknowledge(HazardWarning w) {
    setState(() => _acknowledged.add(w.hazard.id));
    if (_stopAlert == null) _alarm.stopStop();
    // Recorded, to show the alert reached the driver. Does not clear the hazard.
    FirebaseFirestore.instance
        .collection('acknowledgements')
        .add({
          'hazard_id': w.hazard.id,
          'unit_id': unitId,
          'level': w.level.name,
          'distance_m': w.distanceM.round(),
          'timestamp': FieldValue.serverTimestamp(),
        })
        .then((_) {}, onError: (Object e) => debugPrint('acknowledgement upload failed: $e'));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No GPS fix yet, nothing sent. ${_gpsProblem ?? ''}')));
      return;
    }
    final choice = await showReportSheet(context, accuracyM: pos.accuracy);
    if (choice == null || !mounted) return; // closed without choosing
    final (type, severity) = choice;
    final label = typeInfo(type).label;
    await _write(
      FirebaseFirestore.instance.collection('hazards').add({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'timestamp': Timestamp.now(),
        'object_type': type,
        'severity': severity,
        'distance_m': 0,
        'status': 'active',
        'reported_by': 'driver',
        'unit_id': unitId,
      }),
      '$label reported (${severity == 'blocked' ? 'line blocked' : 'near the line'})',
      '$label saved on the phone; uploads when signal returns',
    );
  }

  Future<void> _showHazard(Hazard h) async {
    final clear = await showHazardDetail(context, row: _row(h));
    if (!clear || !mounted) return;
    await _write(
      FirebaseFirestore.instance.collection('hazards').doc(h.id).update({
        'status': 'cleared',
        'cleared_at': Timestamp.now(),
        'cleared_by': unitId,
      }),
      '${typeInfo(h.objectType).label} cleared',
      'Cleared on the phone; uploads when signal returns',
    );
  }

  Future<void> _showList() async {
    final rows = _fresh().map(_row).toList()
      ..sort((a, b) {
        if (a.level != b.level) return b.level.index.compareTo(a.level.index);
        if (a.distanceM != null && b.distanceM != null) return a.distanceM!.compareTo(b.distanceM!);
        return (b.hazard.time ?? DateTime(0)).compareTo(a.hazard.time ?? DateTime(0));
      });
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
            zIndex: 0,
          ),
          Polyline(
            polylineId: PolylineId('rail$i'),
            points: lines[i],
            color: RG.accent,
            width: 3,
            zIndex: 1,
          ),
        ],
      };
    });
  }

  Future<void> _makeIcons() async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final icons = <String, BitmapDescriptor>{};
    for (final emoji in {...hazardTypes.map((t) => t.emoji), '⚠️'}) {
      for (final level in AlertLevel.values) {
        icons['$emoji/${level.name}'] = await hazardPin(emoji, levelColour(level), dpr);
      }
    }
    final train = await BitmapDescriptor.asset(
      ImageConfiguration(devicePixelRatio: dpr),
      'assets/train_icon.png',
      width: 44,
    );
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
      _centred ? CameraUpdate.newLatLng(target) : CameraUpdate.newLatLngZoom(target, 15),
    );
    _centred = true;
  }

  Set<Marker> _markers() {
    final levels = {for (final w in _ahead) w.hazard.id: w.level};
    final markers = <Marker>{};
    for (final h in _fresh()) {
      final emoji = typeInfo(h.objectType).emoji;
      final level = levels[h.id] ?? AlertLevel.none;
      markers.add(
        Marker(
          // Level in the id: the map plugin does not always redraw a marker
          // whose icon alone changed, so a new id forces the swap.
          markerId: MarkerId('${h.id}/${level.name}'),
          position: LatLng(h.latitude, h.longitude),
          icon: _icons['$emoji/${level.name}'] ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 1.0),
          consumeTapEvents: true,
          onTap: () => _showHazard(h),
        ),
      );
    }
    final pos = _pos;
    if (pos != null && _trainIcon != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('train'),
          position: LatLng(pos.latitude, pos.longitude),
          icon: _trainIcon!,
          // Nose along the heading; while standing, keep the last one (not north).
          rotation: usableHeading(pos.heading, pos.speed) ?? _lastHeading ?? 0,
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 2,
          consumeTapEvents: true,
        ),
      );
    }
    return markers;
  }

  Set<Circle> _circles() {
    final pos = _pos;
    if (pos == null) return {};
    return {
      // GPS accuracy around the train, under the train icon.
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
  Widget build(BuildContext context) {
    final stop = _stopAlert;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // The map takes no touches under the STOP screen: acknowledging must
            // not pan it or switch Follow off.
            child: IgnorePointer(
              ignoring: stop != null,
              // Dragging the map stops following the train.
              child: Listener(
                onPointerMove: (e) {
                  if (_follow && e.delta.distance > 4) setState(() => _follow = false);
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
                  padding: const EdgeInsets.only(top: 100, bottom: 220),
                  onMapCreated: (c) {
                    _map = c;
                    final pos = _pos;
                    if (pos != null) _moveTo(LatLng(pos.latitude, pos.longitude));
                  },
                ),
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _topBar()),
          Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel()),
          // STOP: takes over the screen until acknowledged.
          if (stop != null)
            Positioned.fill(
              child: StopAlert(
                warning: stop,
                simulated: simMode,
                onAcknowledge: () => _acknowledge(stop),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final pos = _pos;
    final ok = pos != null && _gpsProblem == null;
    final heading = pos == null ? null : usableHeading(pos.heading, pos.speed);
    final motion = heading == null
        ? 'stationary'
        : '${(pos!.speed * 3.6).round()} km/h  ·  ${heading.toStringAsFixed(0)}°';
    final status = !ok
        ? 'No GPS fix  ·  $unitId'
        : simMode
        ? 'SIMULATED GPS  ·  $motion'
        : 'GPS ±${pos.accuracy.toStringAsFixed(0)} m  ·  $motion  ·  $unitId';
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
          padding: const EdgeInsets.fromLTRB(16, 6, 10, 24),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(color: RG.surfaceHigh, shape: BoxShape.circle),
                    child: const Icon(Icons.train_rounded, color: RG.accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('RailGuard', style: TS.title),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: ok && !simMode ? RG.accent : RG.warn,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(status, overflow: TextOverflow.ellipsis, style: TS.small),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: _follow,
                          onChanged: (v) {
                            setState(() => _follow = v);
                            final p = _pos;
                            if (v && p != null) _moveTo(LatLng(p.latitude, p.longitude));
                          },
                        ),
                      ),
                      const Text('Follow', style: TextStyle(fontSize: 11, color: RG.textDim)),
                    ],
                  ),
                ],
              ),
              // Why there is no fix, in full.
              if (_gpsProblem != null)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: RG.surfaceHigh.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_gpsProblem!, textAlign: TextAlign.center, style: TS.body),
                ),
            ],
          ),
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
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _statusCard(),
            const SizedBox(height: 10),
            // Large tap target: pressed in a moving cab.
            SizedBox(
              width: double.infinity,
              height: 58,
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
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 3, color: RG.onAccent),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_alert_rounded, size: 22),
                          SizedBox(width: 8),
                          Text('Report hazard', style: TS.button),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// Colour by tier: STOP red, CAUTION orange, INFO grey; orange also when
  /// hazards cannot be checked (no GPS, feed offline). Never "no hazards"
  /// unless that was checked.
  Widget _statusCard() {
    final w = _warning;
    final pos = _pos;
    final n = _fresh().length;
    Color colour = RG.surface;
    Color fg = RG.text;
    Widget lead;
    String title, subtitle;
    final time = pos == null ? null : hhmm(pos.timestamp);

    if (w != null) {
      final t = typeInfo(w.hazard.objectType);
      final s = severityInfo(w.hazard);
      lead = Text(t.emoji, style: const TextStyle(fontSize: 26));
      title = '${t.label}  ·  ${formatDistance(w.distanceM)}';
      subtitle = '${s.label}  ·  ${w.headingKnown ? 'ahead' : 'direction unknown'}';
      switch (w.level) {
        case AlertLevel.stop:
          colour = RG.danger;
          subtitle += '  ·  STOP';
        case AlertLevel.caution:
          colour = RG.warn;
          fg = RG.onAccent;
          subtitle += '  ·  CAUTION';
        default:
          subtitle += '  ·  INFO';
      }
    } else if (_hazardProblem != null || pos == null) {
      colour = RG.warn;
      fg = RG.onAccent;
      lead = Icon(
        _hazardProblem != null ? Icons.cloud_off_rounded : Icons.gps_off_rounded,
        color: RG.onAccent,
        size: 24,
      );
      title = 'Hazards not checked';
      subtitle = _hazardProblem ?? 'No GPS position';
    } else {
      lead = const Icon(Icons.check_circle_rounded, color: RG.accent, size: 26);
      title = 'No hazards ahead';
      subtitle = n == 0 ? 'Line clear within 3 km' : '$n active report${n == 1 ? '' : 's'} nearby';
    }
    final filled = colour != RG.surface;

    return Material(
      color: colour,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showList,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: filled ? null : Border.all(color: w != null ? RG.info : RG.border),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: filled ? Colors.white.withValues(alpha: 0.22) : RG.surfaceHigh,
                  shape: BoxShape.circle,
                ),
                child: lead,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: fg),
                    ),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ),
              if (time != null && !filled)
                Text(time, style: const TextStyle(fontSize: 13, color: RG.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
