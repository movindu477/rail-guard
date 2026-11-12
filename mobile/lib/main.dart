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
  Timer? _clock; // refreshes "updated ... ago" once a second
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
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _pos != null) setState(() {});
    });
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
    _clock?.cancel();
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

  /// Report button (pick type, then severity) or a quick-report button
  /// ([type] given: straight to severity).
  Future<void> _report({HazardType? type}) async {
    final pos = _pos;
    if (pos == null) {
      // Refuse rather than save a wrong location.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No GPS fix yet, nothing sent. ${_gpsProblem ?? ''}')));
      return;
    }
    final choice = await showReportSheet(context, accuracyM: pos.accuracy, type: type);
    if (choice == null || !mounted) return; // closed without choosing
    final (objectType, severity) = choice;
    final label = typeInfo(objectType).label;
    await _write(
      FirebaseFirestore.instance.collection('hazards').add({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'timestamp': Timestamp.now(),
        'object_type': objectType,
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
            color: RG.blue.withValues(alpha: 0.18),
            width: 9,
            zIndex: 0,
          ),
          Polyline(
            polylineId: PolylineId('rail$i'),
            points: lines[i],
            color: RG.blue,
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
    // One pin per hazard type and alert level; 'other' covers unknown types.
    for (final t in [...hazardTypes, typeInfo('other')]) {
      for (final level in AlertLevel.values) {
        final colour = level == AlertLevel.none ? t.colour : levelColour(level);
        icons['${t.id}/${level.name}'] = await hazardPin(t.icon, colour, dpr);
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
      final known = hazardTypes.any((t) => t.id == h.objectType);
      final key = known ? h.objectType : 'other';
      final level = levels[h.id] ?? AlertLevel.none;
      markers.add(
        Marker(
          // Level in the id: the map plugin does not always redraw a marker
          // whose icon alone changed, so a new id forces the swap.
          markerId: MarkerId('${h.id}/${level.name}'),
          position: LatLng(h.latitude, h.longitude),
          icon: _icons['$key/${level.name}'] ?? BitmapDescriptor.defaultMarker,
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
        fillColor: RG.blue.withValues(alpha: 0.14),
        strokeColor: RG.blue.withValues(alpha: 0.45),
        strokeWidth: 1,
      ),
    };
  }

  // ------------------------------------------------------------- screen
  //
  // After the design reference: full-screen light map; a profile-style pill
  // (logo, name, unit) and a bell (active hazards) at the top; a quick-report
  // rail on the left; at the bottom a dark live-status pill and a white
  // status card, then a bar with Follow, the red REPORT button and Speed.

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
                  // Keep the Google logo and the train clear of the overlays.
                  padding: const EdgeInsets.only(top: 90, bottom: 300),
                  onMapCreated: (c) {
                    _map = c;
                    final pos = _pos;
                    if (pos != null) _moveTo(LatLng(pos.latitude, pos.longitude));
                  },
                ),
              ),
            ),
          ),
          // Overlays. Empty space between them passes touches to the map.
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: Align(
                      alignment: const Alignment(-1, -0.55),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: _quickReportRail(),
                      ),
                    ),
                  ),
                  _statusPanel(),
                  _bottomBar(),
                ],
              ),
            ),
          ),
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

  /// The RailGuard logo, centred in a white circle.
  Widget _logo(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: RG.border),
    ),
    child: ClipOval(child: Image.asset('assets/images/logo_mark.png', fit: BoxFit.cover)),
  );

  /// White round button with an optional red count badge.
  Widget _roundButton(IconData icon, VoidCallback onTap, {int badge = 0}) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: cardShadow),
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 48, height: 48, child: Icon(icon, color: RG.text, size: 24)),
          ),
        ),
      ),
      if (badge > 0)
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: RG.brand,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Text(
              '$badge',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
    ],
  );

  Widget _topBar() {
    final pos = _pos;
    final subtitle = simMode
        ? 'Simulated GPS'
        : pos == null || _gpsProblem != null
        ? '$unitId  ·  no GPS fix'
        : '$unitId  ·  GPS ±${pos.accuracy.toStringAsFixed(0)} m';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(5, 5, 18, 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(32),
              boxShadow: cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _logo(42),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('RailGuard', style: TS.title),
                    Text(subtitle, style: TS.small),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          _roundButton(Icons.notifications_none_rounded, _showList, badge: _fresh().length),
        ],
      ),
    );
  }

  /// Quick report: one tap on a type goes straight to the severity choice.
  Widget _quickReportRail() => Container(
    width: 70,
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      boxShadow: cardShadow,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('REPORT', style: TextStyle(fontSize: 9, letterSpacing: 1, color: RG.textDim)),
        const SizedBox(height: 4),
        for (final t in hazardTypes)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _saving ? null : () => _report(type: t),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                children: [
                  iconCircle(t.icon, t.colour, size: 40),
                  const SizedBox(height: 4),
                  Text(t.label, style: TS.label, maxLines: 1, overflow: TextOverflow.fade),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  /// Dark live-status pill on top of the status card, in one white panel.
  Widget _statusPanel() => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      boxShadow: cardShadow,
    ),
    child: Column(children: [_livePill(), const SizedBox(height: 6), _statusCard()]),
  );

  Widget _livePill() {
    final pos = _pos;
    final ok = pos != null && _gpsProblem == null;
    final (dot, label) = simMode
        ? (RG.blue, 'Simulated GPS')
        : ok
        ? (RG.live, 'GPS live')
        : (RG.warn, 'No GPS fix');
    var detail = '';
    if (ok) {
      final secs = DateTime.now().difference(pos.timestamp).inSeconds.clamp(0, 99999);
      detail =
          '±${pos.accuracy.toStringAsFixed(0)} m  ·  updated '
          '${secs < 60 ? '$secs sec' : '${secs ~/ 60} min'} ago';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: RG.pill, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: dot.withValues(alpha: 0.6), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              detail,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Hazard status. Red at STOP, amber at CAUTION and when hazards cannot be
  /// checked (no GPS, feed offline); white otherwise. Never "no hazards"
  /// unless that was checked. Tap: the active-hazards list.
  Widget _statusCard() {
    final w = _warning;
    final pos = _pos;
    final n = _fresh().length;
    var bg = Colors.white;
    var fg = RG.text;
    var dim = RG.textDim;
    IconData icon;
    Color iconColour;
    String title, subtitle;
    var tag = '';

    if (w != null) {
      final t = typeInfo(w.hazard.objectType);
      final s = severityInfo(w.hazard);
      icon = t.icon;
      iconColour = levelColour(w.level);
      title = '${t.label}  ·  ${formatDistance(w.distanceM)}';
      subtitle = '${s.label}  ·  ${w.headingKnown ? 'ahead' : 'direction unknown'}';
      tag = levelName(w.level);
      if (w.level == AlertLevel.stop || w.level == AlertLevel.caution) {
        bg = iconColour;
        fg = Colors.white;
        dim = Colors.white.withValues(alpha: 0.85);
      }
    } else if (_hazardProblem != null || pos == null) {
      icon = _hazardProblem != null ? Icons.cloud_off_rounded : Icons.gps_off_rounded;
      iconColour = RG.warn;
      title = 'Hazards not checked';
      subtitle = _hazardProblem ?? _gpsProblem ?? 'No GPS position';
      bg = RG.warn;
      fg = Colors.white;
      dim = Colors.white.withValues(alpha: 0.9);
    } else {
      icon = Icons.verified_user_rounded;
      iconColour = RG.blue;
      title = 'No hazards ahead';
      subtitle = n == 0 ? 'Line clear within 3 km' : '$n active report${n == 1 ? '' : 's'} nearby';
      tag = 'CLEAR';
    }
    final filled = bg != Colors.white;
    final now = DateTime.now();
    final infoColour = filled ? Colors.white : RG.blue;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _showList,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  filled
                      ? Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, color: Colors.white, size: 22),
                        )
                      : iconCircle(icon, iconColour, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: fg),
                        ),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: dim),
                        ),
                      ],
                    ),
                  ),
                  if (tag.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: filled
                            ? Colors.white.withValues(alpha: 0.22)
                            : iconColour.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: filled ? Colors.white : iconColour,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.calendar_today_rounded, size: 13, color: dim),
                        const SizedBox(width: 5),
                        Text(dayLabel(now), style: TextStyle(fontSize: 12, color: dim)),
                        const SizedBox(width: 14),
                        Icon(Icons.schedule_rounded, size: 14, color: dim),
                        const SizedBox(width: 5),
                        Text(hhmm(now), style: TextStyle(fontSize: 12, color: dim)),
                      ],
                    ),
                    if (pos != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined, size: 14, color: infoColour),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Coordinates: ${pos.latitude.toStringAsFixed(5)} N, '
                              '${pos.longitude.toStringAsFixed(5)} E',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: infoColour),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, {VoidCallback? onTap, bool active = false}) =>
      InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          width: 86,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: active ? RG.blue : RG.surfaceHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 21, color: active ? Colors.white : RG.text),
              ),
              const SizedBox(height: 4),
              Text(label, style: TS.label),
            ],
          ),
        ),
      );

  /// Follow, the red REPORT button raised in the middle, and Speed.
  Widget _bottomBar() {
    final pos = _pos;
    final speed = pos == null || pos.speed < 0 ? 'Speed' : '${(pos.speed * 3.6).round()} km/h';
    return SizedBox(
      height: 96,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Positioned.fill(
            top: 18,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: cardShadow,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  _navItem(
                    Icons.navigation_rounded,
                    'Follow',
                    active: _follow,
                    onTap: () {
                      setState(() => _follow = !_follow);
                      final p = _pos;
                      if (_follow && p != null) _moveTo(LatLng(p.latitude, p.longitude));
                    },
                  ),
                  const Spacer(),
                  _navItem(Icons.speed_rounded, speed),
                ],
              ),
            ),
          ),
          // Large: pressed in a moving cab.
          Positioned(
            top: 0,
            child: GestureDetector(
              onTap: _saving ? null : () => _report(),
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: RG.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 5),
                  boxShadow: [
                    BoxShadow(
                      color: RG.brand.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: _saving
                    ? const Padding(
                        padding: EdgeInsets.all(26),
                        child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.campaign_rounded, color: Colors.white, size: 28),
                          Text(
                            'REPORT',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
