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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'account.dart';
import 'alarm.dart';
import 'driver.dart';
import 'duty.dart';
import 'l10n/app_localizations.dart';
import 'lifecycle.dart';
import 'locale_store.dart';
import 'offline.dart';
import 'railway.dart';
import 'sim.dart';
import 'trains.dart';
import 'ui/login.dart';
import 'ui/markers.dart';
import 'ui/register.dart';
import 'ui/sheets.dart';
import 'ui/splash.dart';
import 'ui/stop_alert.dart';
import 'ui/theme.dart';
import 'warning.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RailGuardApp());
}

class RailGuardApp extends StatefulWidget {
  const RailGuardApp({super.key});
  @override
  State<RailGuardApp> createState() => _RailGuardAppState();
}

class _RailGuardAppState extends State<RailGuardApp> {
  SplashRoute? _route;

  void _onSignOut() {
    setState(() {
      _signedIn = null;
      _route = SplashRoute.login;
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
    valueListenable: appLocaleNotifier,
    builder: (context, locale, _) => MaterialApp(
      title: 'RailGuard',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeResolutionCallback: (device, _) => resolveAppLocale(device),
      theme: railGuardTheme(locale: locale),
      home: switch (_route) {
        null => SplashScreen(
            onReady: (route, p) => setState(() {
              _signedIn = p;
              _route = route;
            }),
          ),
        SplashRoute.login => LoginScreen(
            onLoggedIn: (p) => setState(() {
              _signedIn = p;
              _route = SplashRoute.map;
            }),
            onGoToRegister: () => setState(() => _route = SplashRoute.register),
          ),
        SplashRoute.register => RegisterScreen(
            existing: _signedIn,
            onDone: (p) => setState(() {
              _signedIn = p;
              _route = SplashRoute.map;
            }),
            onBackToLogin: () => setState(() => _route = SplashRoute.login),
          ),
        SplashRoute.map => HomeScreen(
            key: ValueKey(_signedIn?.unitId ?? defaultUnitId),
            onSignOut: _onSignOut,
          ),
      },
    ),
  );
}

const _colombo = LatLng(6.9271, 79.8612);

/// The driver signed on to this phone, set in main() before the app starts
/// and replaced when the driver re-registers. Null only before registration,
/// which is the one screen that runs without it.
DriverProfile? _signedIn;

/// The signed-on driver. Falls back to an unnamed profile on the build-time
/// unit id so nothing can crash if a widget outlives registration.
DriverProfile get driver =>
    _signedIn ??
    const DriverProfile(unitId: defaultUnitId, driverName: '', driverId: '', trainNo: '');

/// This phone's train unit. The laptop's hazard publisher reads
/// `train_position/{unitId}` to place automatic hazards, so both must match:
/// the unit id typed at registration / publisher --unit unit-02.
String get unitId => driver.unitId;

/// How often the train position is sent to Firestore.
const positionUploadInterval = Duration(seconds: 5);

class HomeScreen extends StatefulWidget {
  final VoidCallback? onSignOut;
  const HomeScreen({super.key, this.onSignOut});
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
  DutyState _duty = DutyState.onDuty; // position is shared only while on duty
  bool _backgroundAllowed = false;    // "Allow all the time" granted?

  // Hazards and alerts
  List<Hazard> _hazards = []; // active reports from Firestore
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _hazardSub;
  String? _hazardProblem; // Firestore read error, if any
  List<HazardWarning> _ahead = []; // hazards ahead in range, most urgent first
  final _tracker = AlertTracker(); // which level has sounded for each hazard
  final _passTracker = HazardPassTracker(); // detects passing within 100 m then past a hazard
  final List<Hazard> _pendingPassPrompts = []; // queued "Still there?" prompts
  bool _passPromptOpen = false;
  final _uploadGate = PositionUploadGate(); // quota discipline: > 10 m or 30 s
  late final FeedFreshnessTracker _freshness = FeedFreshnessTracker(startedAt: DateTime.now());
  final _pendingReports = PendingReportTracker(); // queued reports awaiting server confirmation
  final _alarm = Alarm();
  final Set<String> _acknowledged = {}; // STOP alerts the driver has acknowledged
  Timer? _recheck; // re-runs the check while standing still
  Timer? _positionUpload; // 5 s moving cadence, gated by _uploadGate
  Timer? _freshnessProbe; // periodic server check when feeds are quiet
  Timer? _clock; // refreshes "updated ... ago" and stale age once a second
  bool _saving = false;

  // Other trains on the line (map presence only; never feeds into alerting)
  List<OtherTrain> _trains = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _trainSub;
  String? _trainProblem; // Firestore read error on train_position, if any

  // Map
  GoogleMapController? _map;
  String? _mapStyle;
  Set<Polyline> _rail = {};
  RailNetwork? _railNetwork;
  TrackPosition? _prevTrackPos;
  TravelDirection _travelDir = TravelDirection.unknown;
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
    _startTrains();
    _loadMap();
    if (simMode) {
      _startSim();
    } else {
      _restoreDutyThenStartGps();
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
    _freshnessProbe = Timer.periodic(const Duration(seconds: 25), (_) => _probeServerFreshness());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          (_pos != null || _freshness.isStale(DateTime.now()) || _pendingReports.hasPending)) {
        setState(() {});
      }
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
    _trainSub?.cancel();
    _recheck?.cancel();
    _positionUpload?.cancel();
    _freshnessProbe?.cancel();
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
      // On duty this carries a foreground-service notification, so the stream
      // survives the driver leaving the app. See duty.dart.
      _gpsSub =
          Geolocator.getPositionStream(
            locationSettings: dutyLocationSettings(
              duty: _duty,
              trainLabel: driver.trainNo.isEmpty ? unitId : driver.trainLabel,
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
    final firstFix = _uploadGate.lastUploadedAt == null;
    setState(() {
      _pos = pos;
      _gpsProblem = null;
      _lastHeading = usableHeading(pos.heading, pos.speed) ?? _lastHeading;
    });
    if (firstFix) _uploadPosition();
    _updateWarning();
    if (_follow || !_centred) _moveTo(LatLng(pos.latitude, pos.longitude));
  }

  /// One document per unit, overwritten: where this train is now, for the
  /// laptop to place the hazards its camera finds and for other trains to see
  /// on the map. Gated by [_uploadGate] (> 10 m moved or 30 s elapsed) on a
  /// 5-second moving cadence so standing trains do not exhaust the Firestore
  /// write quota.
  void _uploadPosition() {
    final pos = _pos;
    if (pos == null) return; // no fix: send nothing rather than a stale or wrong position
    if (simMode) return; // never let the laptop place hazards from simulated positions
    final now = DateTime.now();
    if (!_uploadGate.tryUpload(lat: pos.latitude, lon: pos.longitude, now: now)) return;
    FirebaseFirestore.instance
        .collection('train_position')
        .doc(unitId)
        .set({
          'unit_id': unitId,
          'train_no': driver.trainNo,
          'driver_name': driver.driverName,
          'service': driver.service.id,
          'latitude': pos.latitude,
          'longitude': pos.longitude,
          'heading': usableHeading(pos.heading, pos.speed), // null = unknown (standing / slow)
          'speed_mps': pos.speed >= 0 ? pos.speed : 0.0,
          'accuracy_m': pos.accuracy,
          // Server time, so the laptop can tell how old the position is without
          // depending on the phone's clock.
          'timestamp': FieldValue.serverTimestamp(),
        })
        .catchError((Object e) => debugPrint('train_position upload failed: $e'));
  }

  /// Lightweight server freshness probe run every 25 s when a feed has been
  /// quiet, so an online phone with no recent changes never shows a false
  /// "No signal" banner, while an offline phone stops refreshing and shows
  /// stale age past 60 s.
  Future<void> _probeServerFreshness() async {
    final now = DateTime.now();
    if (_freshness.hazardAge(now) >= const Duration(seconds: 25)) {
      try {
        await FirebaseFirestore.instance
            .collection('hazards')
            .where('status', isEqualTo: 'active')
            .limit(1)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 5));
        _freshness.recordHazardServerUpdate(DateTime.now());
        if (mounted) setState(() {});
      } catch (_) {
        // Offline or unreachable: leave lastHazardServerUpdate unchanged.
      }
    }
    if (_freshness.trainAge(now) >= const Duration(seconds: 25)) {
      try {
        await FirebaseFirestore.instance
            .collection('train_position')
            .limit(1)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 5));
        _freshness.recordTrainServerUpdate(DateTime.now());
        if (mounted) setState(() {});
      } catch (_) {
        // Offline or unreachable: leave lastTrainServerUpdate unchanged.
      }
    }
  }

  // ------------------------------------------------------------ trains

  /// Keeps [_trains] in step with the `train_position` collection in Firestore.
  void _startTrains() {
    _trainSub = FirebaseFirestore.instance
        .collection('train_position')
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snap) {
            if (!mounted) return;
            if (!snap.metadata.isFromCache) {
              _freshness.recordTrainServerUpdate(DateTime.now());
            }
            setState(() {
              _trains = [for (final doc in snap.docs) ?_parseTrain(doc.id, doc.data())];
              _trainProblem = null;
            });
          },
          onError: (Object e) {
            if (mounted) setState(() => _trainProblem = 'Train feed offline');
          },
        );
  }

  static OtherTrain? _parseTrain(String id, Map<String, dynamic> d) {
    final t = d['timestamp'];
    final lastSeen = t is Timestamp ? t.toDate() : (t is String ? DateTime.tryParse(t) : null);
    return OtherTrain.fromMap(id, d, lastSeen: lastSeen);
  }

  List<OtherTrain> _visibleTrains() {
    final pos = _pos;
    return trainsToShow(
      trains: _trains,
      ownUnitId: unitId,
      now: DateTime.now(),
      lat: pos?.latitude,
      lon: pos?.longitude,
    );
  }

  TrainConflictInfo? _conflictForTrain(OtherTrain t) {
    final net = _railNetwork;
    final pos = _pos;
    if (net == null || pos == null) return null;
    final pTrain = net.snap(pos.latitude, pos.longitude, gpsAccuracyM: pos.accuracy);
    if (pTrain == null) return null;
    return classifyTrainConflict(
      network: net,
      ownTrackPos: pTrain,
      ownMeasuredDir: _travelDir,
      ownService: driver.service,
      ownSpeedMps: pos.speed >= 0 ? pos.speed : null,
      otherTrain: t,
    );
  }

  OtherTrain? get _mostUrgentApproachingTrain {
    final net = _railNetwork;
    final pos = _pos;
    if (net == null || pos == null) return null;
    final pTrain = net.snap(pos.latitude, pos.longitude, gpsAccuracyM: pos.accuracy);
    if (pTrain == null) return null;

    OtherTrain? bestTrain;
    double minGap = double.infinity;

    for (final t in _visibleTrains()) {
      final c = classifyTrainConflict(
        network: net,
        ownTrackPos: pTrain,
        ownMeasuredDir: _travelDir,
        ownService: driver.service,
        ownSpeedMps: pos.speed >= 0 ? pos.speed : null,
        otherTrain: t,
      );
      if (c.conflict == TrainConflict.approaching) {
        final gap = c.alongTrackGapM ?? double.infinity;
        if (gap < minGap) {
          minGap = gap;
          bestTrain = t;
        }
      }
    }
    return bestTrain;
  }

  Future<void> _showTrain(OtherTrain t) async {
    final pos = _pos;
    final straightD = t.distanceFrom(pos?.latitude, pos?.longitude);
    double? alongD;
    final net = _railNetwork;
    TrainConflictInfo? conflict;
    if (net != null && pos != null) {
      final pTrain = net.snap(pos.latitude, pos.longitude, gpsAccuracyM: pos.accuracy);
      final pOther = net.snap(t.lat, t.lon);
      if (pTrain != null && pOther != null) {
        final d = net.alongTrack(pTrain, pOther);
        if (d != null) alongD = d.abs();
      }
      if (pTrain != null) {
        conflict = classifyTrainConflict(
          network: net,
          ownTrackPos: pTrain,
          ownMeasuredDir: _travelDir,
          ownService: driver.service,
          ownSpeedMps: pos.speed >= 0 ? pos.speed : null,
          otherTrain: t,
        );
      }
    }
    await showTrainDetail(
      context,
      train: t,
      distanceM: straightD,
      alongTrackM: alongD,
      conflictInfo: conflict,
    );
  }

  Future<void> _showTrainList() async {
    final pos = _pos;
    final net = _railNetwork;
    Map<String, double>? alongDistances;
    Map<String, TrainConflictInfo>? conflicts;
    if (net != null && pos != null) {
      final pTrain = net.snap(pos.latitude, pos.longitude, gpsAccuracyM: pos.accuracy);
      if (pTrain != null) {
        alongDistances = {};
        conflicts = {};
        for (final t in _visibleTrains()) {
          final pOther = net.snap(t.lat, t.lon);
          if (pOther != null) {
            final d = net.alongTrack(pTrain, pOther);
            if (d != null) alongDistances[t.unitId] = d.abs();
          }
          conflicts[t.unitId] = classifyTrainConflict(
            network: net,
            ownTrackPos: pTrain,
            ownMeasuredDir: _travelDir,
            ownService: driver.service,
            ownSpeedMps: pos.speed >= 0 ? pos.speed : null,
            otherTrain: t,
          );
        }
      }
    }
    final picked = await showTrainList(
      context,
      trains: _visibleTrains(),
      fromLat: pos?.latitude,
      fromLon: pos?.longitude,
      alongTrackDistances: alongDistances,
      conflicts: conflicts,
    );
    if (picked == null || !mounted) return;
    setState(() => _follow = false);
    _moveTo(LatLng(picked.lat, picked.lon));
    await _showTrain(picked);
  }

  // ------------------------------------------------------------ hazards

  /// Keeps [_hazards] in step with the active reports in Firestore.
  void _startHazards() {
    _hazardSub = FirebaseFirestore.instance
        .collection('hazards')
        .where('status', isEqualTo: 'active')
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snap) {
            final now = DateTime.now();
            if (!snap.metadata.isFromCache) {
              _freshness.recordHazardServerUpdate(now);
            }
            final parsed = <Hazard>[];
            for (final doc in snap.docs) {
              final data = doc.data();
              final isOwnDriverReport =
                  data['reported_by'] == 'driver' && data['unit_id'] == unitId;
              if (doc.metadata.hasPendingWrites && isOwnDriverReport) {
                final t = data['timestamp'];
                final queuedAt = t is Timestamp ? t.toDate() : now;
                _pendingReports.markPending(doc.id, queuedAt);
              } else if (!doc.metadata.hasPendingWrites && !snap.metadata.isFromCache) {
                _pendingReports.confirmSent(doc.id);
              }
              final pending = doc.metadata.hasPendingWrites || _pendingReports.isPending(doc.id);
              final h = _parseHazard(doc.id, data, pendingSend: pending);
              if (h != null) parsed.add(h);
            }
            _hazards = parsed;
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

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return [for (final v in raw) if (v is String && v.isNotEmpty) v];
  }

  /// A Firestore document as a Hazard, or null if it has no usable position.
  static Hazard? _parseHazard(String id, Map<String, dynamic> d, {bool pendingSend = false}) {
    final lat = d['latitude'], lon = d['longitude'];
    if (lat is! num || lon is! num) return null;
    final t = d['timestamp'];
    final clearedT = d['cleared_at'];
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
      status: (d['status'] as String?) ?? 'active',
      reportedByUid: d['reported_by_uid'] as String?,
      confirmedByUids: _stringList(d['confirmed_by_uids']),
      notSeenByUids: _stringList(d['not_seen_by_uids']),
      clearedByUids: _stringList(d['cleared_by_uids']),
      clearedBy: d['cleared_by'] as String?,
      clearedByUid: d['cleared_by_uid'] as String?,
      clearedAt: clearedT is Timestamp
          ? clearedT.toDate()
          : (clearedT is String ? DateTime.tryParse(clearedT) : null),
      pendingSend: pendingSend,
    );
  }

  /// Recomputes the alerts, and sounds each new level once.
  void _updateWarning() {
    final pos = _pos;
    final now = DateTime.now();

    // Track position and travel direction along the route
    final net = _railNetwork;
    if (net != null && pos != null) {
      final curPos = net.snap(pos.latitude, pos.longitude, gpsAccuracyM: pos.accuracy);
      if (curPos != null) {
        if (_prevTrackPos != null && _prevTrackPos!.routeId == curPos.routeId) {
          final diff = curPos.chainageM - _prevTrackPos!.chainageM;
          if (diff.abs() >= 1.5) {
            _travelDir = diff > 0 ? TravelDirection.increasing : TravelDirection.decreasing;
            _prevTrackPos = curPos;
          }
        } else {
          _prevTrackPos = curPos;
          final usable = usableHeading(pos.heading, pos.speed);
          if (usable != null) {
            _travelDir = net.travelDirectionFromHeading(
              position: curPos,
              headingDeg: usable,
            );
          } else {
            _travelDir = TravelDirection.unknown;
          }
        }
      }
    }

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
            now: now,
            network: _railNetwork,
            travelDirection: _travelDir,
            gpsAccuracyM: pos.accuracy,
          );
    _tracker.keepOnly(_hazards.map((h) => h.id).toSet());
    _acknowledged.retainWhere((id) => _hazards.any((h) => h.id == id));
    final raised = _tracker.raised(ahead);
    if (raised.any((w) => w.level == AlertLevel.caution) &&
        !raised.any((w) => w.level == AlertLevel.stop)) {
      _alarm.caution();
    }

    // Detect hazards passed within 100 m and now behind us along the track.
    if (pos != null) {
      final passed = _passTracker.checkPassed(
        lat: pos.latitude,
        lon: pos.longitude,
        travelDirection: _travelDir,
        hazards: _hazards,
        now: now,
        network: _railNetwork,
        gpsAccuracyM: pos.accuracy,
        ownUid: currentUid,
        ownUnitId: unitId,
      );
      for (final h in passed) {
        if (!_pendingPassPrompts.any((p) => p.id == h.id)) {
          _pendingPassPrompts.add(h);
        }
      }
    }

    if (!mounted) return;
    setState(() => _ahead = ahead);
    // The alarm rings while an unacknowledged STOP is on screen; it stops by
    // itself if that hazard goes (passed, cleared, expired).
    if (_stopAlert != null) {
      _alarm.startStop();
    } else {
      _alarm.stopStop();
      _drainPassPrompts();
    }
  }

  void _acknowledge(HazardWarning w) {
    setState(() => _acknowledged.add(w.hazard.id));
    if (_stopAlert == null) {
      _alarm.stopStop();
      _drainPassPrompts();
    }
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

    final net = _railNetwork;
    if (net != null) {
      final tPos = net.snap(pos.latitude, pos.longitude);
      final hPos = net.snap(h.latitude, h.longitude);
      if (tPos != null && hPos != null && tPos.offsetM <= 15.0 && hPos.offsetM <= 15.0 && tPos.routeId == hPos.routeId) {
        final diff = hPos.chainageM - tPos.chainageM;
        final bool? isAhead;
        if (_travelDir == TravelDirection.increasing) {
          isAhead = diff > 0;
        } else if (_travelDir == TravelDirection.decreasing) {
          isAhead = diff < 0;
        } else {
          isAhead = null;
        }
        return HazardRow(
          h,
          diff.abs(),
          isAhead,
          alongTrack: true,
        );
      }
    }

    final heading = usableHeading(pos.heading, pos.speed);
    return HazardRow(
      h,
      distanceM(pos.latitude, pos.longitude, h.latitude, h.longitude),
      heading == null
          ? null
          : isAhead(bearingDeg(pos.latitude, pos.longitude, h.latitude, h.longitude), heading),
      alongTrack: false,
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
    final now = DateTime.now();
    final docRef = FirebaseFirestore.instance.collection('hazards').doc();
    setState(() => _pendingReports.markPending(docRef.id, now));
    final writeFuture = docRef.set({
      'latitude': pos.latitude,
      'longitude': pos.longitude,
      'timestamp': Timestamp.fromDate(now),
      'object_type': objectType,
      'severity': severity,
      'distance_m': 0,
      'status': 'active',
      'reported_by': 'driver',
      'reported_by_uid': currentUid ?? unitId,
      'unit_id': unitId,
      'confirmed_by_uids': const <String>[],
      'not_seen_by_uids': const <String>[],
      'cleared_by_uids': const <String>[],
    }).then((_) {
      _pendingReports.confirmSent(docRef.id);
      if (mounted) setState(() {});
    });
    await _write(
      writeFuture,
      '$label reported (${severity == 'blocked' ? 'line blocked' : 'near the line'})',
      '$label saved on the phone — not yet sent; uploads when signal returns',
    );
  }

  /// Applies a driver's Cleared / Still there / Did not see answer via Firestore
  /// `.update(...)`. Never deletes a hazard document.
  Future<void> _submitHazardAnswer(Hazard h, HazardPassAnswer answer) async {
    _passTracker.markPrompted(h.id);
    // Use the freshest snapshot of this hazard if still in the active feed.
    final latest = _hazards.cast<Hazard?>().firstWhere(
          (item) => item?.id == h.id,
          orElse: () => h,
        ) ??
        h;
    final now = DateTime.now();
    final result = applyHazardAnswer(
      hazard: latest,
      answer: answer,
      driverUid: currentUid ?? unitId,
      unitId: unitId,
      now: now,
      firestoreTimestamp: Timestamp.fromDate(now),
    );
    await _write(
      FirebaseFirestore.instance.collection('hazards').doc(latest.id).update(result.firestoreUpdate),
      result.feedbackMessage,
      'Saved on the phone; uploads when signal returns',
    );
  }

  /// Displays queued "Still there?" prompts one at a time when no STOP alert is active.
  void _drainPassPrompts() {
    if (_passPromptOpen || _stopAlert != null || _pendingPassPrompts.isEmpty || !mounted) return;
    _passPromptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        while (mounted && _stopAlert == null && _pendingPassPrompts.isNotEmpty) {
          final next = _pendingPassPrompts.removeAt(0);
          final latest = _hazards.cast<Hazard?>().firstWhere(
                (item) => item?.id == next.id,
                orElse: () => null,
              );
          if (latest == null || !isHazardActiveOnMap(latest, DateTime.now())) continue;
          if (!mounted) return;
          final answer = await showStillTherePrompt(context, hazard: latest);
          if (answer != null && mounted) {
            await _submitHazardAnswer(latest, answer);
          }
        }
      } finally {
        _passPromptOpen = false;
      }
    });
  }

  Future<void> _showHazard(Hazard h) async {
    final clear = await showHazardDetail(context, row: _row(h));
    if (!clear || !mounted) return;
    await _submitHazardAnswer(h, HazardPassAnswer.cleared);
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
    final network = await loadRailNetwork();
    if (!mounted) return;
    setState(() {
      _mapStyle = style;
      _railNetwork = network;
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
    // Also pre-render a "not yet sent" badged pin for offline queued reports.
    for (final t in [...hazardTypes, typeInfo('other')]) {
      for (final level in AlertLevel.values) {
        final colour = level == AlertLevel.none ? t.colour : levelColour(level);
        icons['${t.id}/${level.name}'] = await hazardPin(t.icon, colour, dpr);
        icons['${t.id}/${level.name}/pending'] = await pendingHazardPin(t.icon, colour, dpr);
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
      final suffix = h.pendingSend ? '/pending' : '';
      markers.add(
        Marker(
          // Level & pending state in the id: forces Google Maps to redraw when icon swaps.
          markerId: MarkerId('${h.id}/${level.name}$suffix'),
          position: LatLng(h.latitude, h.longitude),
          icon: _icons['$key/${level.name}$suffix'] ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 1.0),
          zIndexInt: h.pendingSend ? 3 : 0,
          consumeTapEvents: true,
          onTap: () => _showHazard(h),
        ),
      );
    }
    final pos = _pos;
    final now = DateTime.now();
    if (_trainIcon != null) {
      for (final t in _visibleTrains()) {
        final live = t.isLive(now);
        markers.add(
          Marker(
            markerId: MarkerId('train/${t.unitId}/${live ? 'live' : 'stale'}'),
            position: LatLng(t.lat, t.lon),
            icon: _trainIcon!,
            rotation: t.heading ?? 0,
            flat: true,
            alpha: live ? 1.0 : 0.45,
            anchor: const Offset(0.5, 0.5),
            zIndexInt: 1,
            infoWindow: InfoWindow(title: t.markerLabel),
            consumeTapEvents: true,
            onTap: () => _showTrain(t),
          ),
        );
      }
    }
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
                  _staleOfflineBanner(),
                  _pendingOverdueBanner(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 4),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _trainsChip(),
                          _pendingReportsChip(),
                        ],
                      ),
                    ),
                  ),
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

  /// Opens the registration form again, so the train can be handed over.
  /// Changing the unit id restarts the screen (HomeScreen is keyed on it),
  /// which re-subscribes the feeds under the new unit.
  Future<void> _editDriver() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RegisterScreen(
          existing: driver,
          onDone: (p) {
            _signedIn = p;
            Navigator.of(context).pop();
            setState(() {});
          },
          onSignOut: () {
            Navigator.of(context).pop();
            widget.onSignOut?.call();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Reads the saved duty state first, so the position stream is created with
  /// the right settings rather than started plain and restarted a moment later.
  Future<void> _restoreDutyThenStartGps() async {
    final saved = await loadDuty();
    final granted = await Geolocator.checkPermission() == LocationPermission.always;
    if (!mounted) return;
    setState(() {
      _duty = saved;
      _backgroundAllowed = granted;
    });
    await _startGps();
  }

  /// Restarts the position stream so new duty settings take effect: a running
  /// stream keeps the settings it was created with.
  Future<void> _restartGps() async {
    await _gpsSub?.cancel();
    _gpsSub = null;
    await _startGps();
  }

  /// Switches duty. Going on duty asks for background location, because
  /// without it the position stops the moment the driver leaves the app and
  /// the train disappears from every other map.
  Future<void> _setDuty(DutyState next) async {
    if (next.isOn) {
      final granted = await ensureBackgroundLocation();
      if (!mounted) return;
      setState(() => _backgroundAllowed = granted);
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 6),
            content: Text(
              'Location is only allowed while the app is open. Your train will '
              'disappear from other drivers when you switch away. Set location '
              'to "Allow all the time" in Settings to stay visible.',
            ),
          ),
        );
      }
    }
    setState(() => _duty = next);
    await saveDuty(next);
    await _restartGps();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next.isOn
            ? 'On duty — your position is shared with other drivers'
            : 'Off duty — your position is no longer shared'),
      ),
    );
  }

  /// On duty / off duty, stated plainly. A driver must be able to see whether
  /// they are being tracked without opening a menu.
  Widget _dutyChip() {
    final on = _duty.isOn;
    // On duty without background permission is the misleading state: the
    // driver believes they are visible and they are not, so it is marked.
    final warn = on && !_backgroundAllowed;
    return GestureDetector(
      onTap: () => _setDuty(on ? DutyState.offDuty : DutyState.onDuty),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: on ? (warn ? const Color(0xFFB45309) : const Color(0xFF15803D)) : Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: cardShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? (warn ? Icons.warning_amber_rounded : Icons.podcasts_rounded)
                 : Icons.pause_circle_outline_rounded,
              size: 18,
              color: on ? Colors.white : Colors.black54,
            ),
            const SizedBox(width: 6),
            Text(
              warn ? 'App only' : _duty.label,
              style: TS.small.copyWith(
                color: on ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final pos = _pos;
    final train = driver.trainNo.isEmpty ? unitId : '${driver.trainLabel}  ·  $unitId';
    final subtitle = simMode
        ? 'Simulated GPS'
        : pos == null || _gpsProblem != null
        ? '$train  ·  no GPS fix'
        : '$train  ·  GPS ±${pos.accuracy.toStringAsFixed(0)} m';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          // Tap the name plate to change driver or train: a unit is handed
          // over between drivers without reinstalling the app.
          GestureDetector(
            onTap: _editDriver,
            child: Container(
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
                      Text(
                        driver.driverName.isEmpty ? 'RailGuard' : driver.driverName,
                        style: TS.title,
                      ),
                      Text(subtitle, style: TS.small),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _dutyChip(),
          const SizedBox(width: 8),
          _roundButton(Icons.notifications_none_rounded, _showList, badge: _fresh().length),
        ],
      ),
    );
  }

  /// Persistent offline banner shown whenever either feed is more than 60 s stale.
  /// Always names the age and sits at the top of the overlay stack so it never
  /// disappears behind other UI.
  Widget _staleOfflineBanner() {
    final now = DateTime.now();
    if (!_freshness.isStale(now)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final text = l10n.bannerNoSignal(staleAgeText(_freshness.oldestFeedAge(now)));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFB45309),
        borderRadius: BorderRadius.circular(14),
        boxShadow: cardShadow,
      ),
      child: Row(
        children: [
          const Icon(Icons.signal_wifi_off_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                fontFamilyFallback: scriptFontFallbacks,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Plain warning banner when a locally queued report has still not gone out
  /// after 5 minutes — prevents the driver from believing trains behind were warned.
  Widget _pendingOverdueBanner() {
    final text = _pendingReports.overdueWarningText(DateTime.now());
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: RG.brand,
        borderRadius: BorderRadius.circular(14),
        boxShadow: cardShadow,
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Top-bar area chip showing how many driver reports are waiting to send.
  Widget _pendingReportsChip() {
    if (!_pendingReports.hasPending) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final label = _pendingReports.count == 1
        ? l10n.pendingWaitingSingle
        : l10n.pendingWaitingPlural(_pendingReports.count);
    return Material(
      color: const Color(0xFFFEF3C7),
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showList,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFD97706), width: 1.2),
            boxShadow: cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_upload_outlined, size: 16, color: Color(0xFF92400E)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TS.label.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF92400E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Small chip below the top bar showing how many other trains are on the line
  /// (or "Train feed offline" in amber if the Firestore stream fails).
  Widget _trainsChip() {
    if (_trainProblem != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: RG.warn,
          borderRadius: BorderRadius.circular(20),
          boxShadow: cardShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              _trainProblem!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );
    }
    final trains = _visibleTrains();
    if (trains.isEmpty) return const SizedBox.shrink();

    final urgentTrain = _mostUrgentApproachingTrain;
    final isConflict = urgentTrain != null;
    final count = trains.length;
    final label = isConflict
        ? 'Approaching: ${urgentTrain.trainNo.isEmpty ? urgentTrain.unitId : urgentTrain.trainNo}'
        : (count == 1 ? '1 train on the line' : '$count trains on the line');
    final chipColor = isConflict ? const Color(0xFF5E35B1) : RG.blue;
    final chipBg = isConflict ? const Color(0xFFEDE7F6) : Colors.white;

    return Material(
      color: chipBg,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showTrainList,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: cardShadow,
            border: isConflict ? Border.all(color: const Color(0xFF7E57C2), width: 1.2) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.train_rounded, size: 16, color: chipColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TS.label.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isConflict ? const Color(0xFF311B92) : RG.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Quick report: one tap on a type goes straight to the severity choice.
  Widget _quickReportRail() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: 74,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: cardShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                l10n.btnReport,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 9,
                  letterSpacing: 0.6,
                  color: RG.textDim,
                  fontFamilyFallback: scriptFontFallbacks,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          for (final t in hazardTypes)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _saving ? null : () => _report(type: t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
                child: Column(
                  children: [
                    iconCircle(t.icon, t.colour, size: 40),
                    const SizedBox(height: 4),
                    Text(
                      localizedHazardType(l10n, t.id),
                      style: TS.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _approachingTrainBanner(OtherTrain t, TrainConflictInfo c) {
    return InkWell(
      onTap: () => _showTrain(t),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFEDE7F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF7E57C2), width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFF512DA8), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          AppLocalizations.of(context)!.advisoryTrainConflict,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF311B92),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            fontFamilyFallback: scriptFontFallbacks,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        t.trainNo.isEmpty ? t.unitId : 'Train ${t.trainNo}',
                        style: const TextStyle(
                          color: Color(0xFF4527A0),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (c.isDirectionUnknown) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF512DA8).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'dir unknown',
                            style: TextStyle(
                              color: Color(0xFF311B92),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatDistance(c.alongTrackGapM ?? 0)} along line  ·  closing ${c.closingSpeedKmh ?? 0} km/h  ·  meet in ${c.timeToMeetText}',
                    style: const TextStyle(
                      color: Color(0xFF311B92),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF512DA8), size: 20),
          ],
        ),
      ),
    );
  }

  /// Dark live-status pill on top of the status card, in one white panel.
  Widget _statusPanel() {
    final urgentTrain = _mostUrgentApproachingTrain;
    TrainConflictInfo? conflict;
    if (urgentTrain != null) {
      conflict = _conflictForTrain(urgentTrain);
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: cardShadow,
      ),
      child: Column(
        children: [
          _livePill(),
          if (urgentTrain != null && conflict != null) ...[
            const SizedBox(height: 6),
            _approachingTrainBanner(urgentTrain, conflict),
          ],
          const SizedBox(height: 6),
          _statusCard(),
        ],
      ),
    );
  }

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

    final l10n = AppLocalizations.of(context)!;
    if (w != null) {
      final t = typeInfo(w.hazard.objectType);
      final typeLabel = localizedHazardType(l10n, w.hazard.objectType);
      final sevLabel = localizedSeverity(l10n, w.hazard);
      icon = t.icon;
      iconColour = levelColour(w.level);
      if (w.onAnotherLine) {
        title = '$typeLabel  ·  ${formatDistance(w.distanceM)}';
        subtitle = '$sevLabel  ·  on another line';
      } else if (w.alongTrack) {
        title = '$typeLabel  ·  ${formatDistance(w.distanceM)} along the line';
        subtitle = '$sevLabel  ·  ${w.headingKnown ? l10n.stopAhead : l10n.stopDirectionUnknown}';
      } else {
        title = '$typeLabel  ·  ${formatDistance(w.distanceM)}';
        subtitle = '$sevLabel  ·  ${w.headingKnown ? l10n.stopAhead : l10n.stopDirectionUnknown}';
      }
      tag = localizedAlertLevel(l10n, w.level);
      if (w.level == AlertLevel.stop || w.level == AlertLevel.caution) {
        bg = iconColour;
        fg = Colors.white;
        dim = Colors.white.withValues(alpha: 0.85);
      }
    } else {
      final now = DateTime.now();
      final stale = _freshness.isStale(now);
      final staleAge = stale ? _freshness.oldestFeedAge(now) : null;
      final status = resolveNoHazardStatus(
        feedIsStale: stale,
        staleAge: staleAge,
        hazardProblem: _hazardProblem,
        hasGps: pos != null,
        gpsProblem: _gpsProblem,
        nearbyCount: n,
      );
      if (stale) {
        title = l10n.statusCannotCheckNoSignal;
        subtitle = staleAge != null
            ? l10n.statusCachedDataOnly(staleAgeText(staleAge))
            : status.subtitle;
        tag = '';
      } else if (!status.isAmberWarning) {
        title = l10n.statusNoHazardsAhead;
        subtitle = n == 0 ? l10n.statusLineClear3km : status.subtitle;
        tag = l10n.statusClearTag;
      } else {
        title = status.title;
        subtitle = status.subtitle;
        tag = status.tag;
      }
      if (status.isAmberWarning) {
        icon = stale
            ? Icons.signal_wifi_off_rounded
            : (_hazardProblem != null ? Icons.cloud_off_rounded : Icons.gps_off_rounded);
        iconColour = RG.warn;
        bg = RG.warn;
        fg = Colors.white;
        dim = Colors.white.withValues(alpha: 0.9);
      } else {
        icon = Icons.verified_user_rounded;
        iconColour = RG.blue;
      }
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
                          maxLines: 2,
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
    final l10n = AppLocalizations.of(context)!;
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
                    l10n.btnFollow,
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
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.campaign_rounded, color: Colors.white, size: 28),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.btnReport,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  fontFamilyFallback: scriptFontFallbacks,
                                ),
                              ),
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
