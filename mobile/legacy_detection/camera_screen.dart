import 'dart:async';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart' show DeviceOrientation, rootBundle;
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'detector.dart';
import 'firebase_options.dart';
import 'warning.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  // Must run before any plugin call (Firebase, camera), or the app crashes on launch.
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  cameras = await availableCameras();
  runApp(const RailGuardApp());
}

class RailGuardApp extends StatelessWidget {
  const RailGuardApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RailGuard',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: const CameraScreen(),
      );
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _busy = false;
  String _status = 'Starting…';
  List<Detection> _dets = [];
  double _inferMs = 0;
  int _frames = 0;
  int _skip = 0;

  Position? _pos;                          // latest GPS fix, null until the first one
  StreamSubscription<Position>? _gpsSub;
  String? _gpsProblem = 'GPS: starting…';  // shown instead of the fix while not null

  List<Hazard> _hazards = [];              // active reports from Firestore
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _hazardSub;
  String? _hazardProblem;                  // Firestore read error, if any
  HazardWarning? _warning;                 // closest hazard ahead, null if none
  Timer? _recheck;                         // re-runs the check while standing still

  static const _orientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Clockwise rotation that turns a raw sensor frame upright on screen.
  /// Stream frames arrive in sensor orientation; the preview is rotated
  /// for display, so frames must be rotated the same way before inference.
  int _frameRotation() {
    final cam = _controller!.description;
    final device =
        _orientationDegrees[_controller!.value.deviceOrientation] ?? 0;
    return cam.lensDirection == CameraLensDirection.front
        ? (cam.sensorOrientation + device) % 360
        : (cam.sensorOrientation - device + 360) % 360;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

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

  Future<void> _startGps() async {
    try {
      if (!await _ensureLocationPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_gpsProblem!)));
        }
        return;
      }
      setState(() => _gpsProblem = 'GPS: waiting for first fix… (go outside)');
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5, // metres moved before the next update
        ),
      ).listen(
        (pos) {
          if (!mounted) return;
          setState(() { _pos = pos; _gpsProblem = null; });
          _updateWarning();
        },
        onError: (e) {
          if (mounted) setState(() => _gpsProblem = 'GPS error: $e');
        },
      );
    } catch (e) {
      if (mounted) setState(() => _gpsProblem = 'GPS error: $e');
    }
  }

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
        if (mounted) setState(() => _hazardProblem = 'Hazard feed error: $e');
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

  Widget _warningBanner() {
    final w = _warning;
    if (w == null && _hazardProblem == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: w != null ? Colors.red.shade700 : Colors.orange.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        w?.message ?? _hazardProblem!,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );
  }

  Future<void> _init() async {
    _startHazards();
    await Permission.camera.request();
    // After the camera dialog: two permission dialogs at once make the second fail.
    await _startGps();

    try {
      _interpreter =
          await Interpreter.fromAsset('assets/railguard_mobile_320_float32.tflite');
      final raw = await rootBundle.loadString('assets/labels.txt');
      _labels = raw.split('\n').where((e) => e.trim().isNotEmpty).toList();
      setState(() => _status = 'Model ready');
    } catch (e) {
      setState(() => _status = 'Model load FAILED: $e');
      return;
    }

    _controller = CameraController(
      cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    if (!mounted) return;
    setState(() {});
    _controller!.startImageStream(_onFrame);
  }

  Future<void> _onFrame(CameraImage cam) async {
    _skip++;
    if (_skip % 8 != 0) return;
    if (_busy || _interpreter == null) return;
    _busy = true;
    final sw = Stopwatch()..start();

    try {
      final rgb = Detector.yuv420ToImage(cam);
      final input = Detector.preprocess(rgb, rotation: _frameRotation());

      // Output buffer shaped like the model output: [1, 4 + classes, anchors]
      final shape = _interpreter!.getOutputTensor(0).shape;
      final output = List.generate(
        shape[0],
        (_) => List.generate(shape[1], (_) => List.filled(shape[2], 0.0)),
      );

      _interpreter!.run(input, output);
      final dets = Detector.parseOutput(output);

      sw.stop();
      if (mounted) {
        setState(() {
          _dets = dets;
          _inferMs = sw.elapsedMilliseconds.toDouble();
          _frames++;
        });
      }
    } catch (e) {
      debugPrint('inference error: $e');
    } finally {
      _busy = false;
    }
  }

  /// Manual hazard report: saves the current GPS position to `hazards`.
  Future<void> _reportHazard() async {
    final messenger = ScaffoldMessenger.of(context);
    final pos = _pos;
    if (pos == null) {
      messenger.showSnackBar(SnackBar(
          content: Text('No GPS fix yet, not sent. ${_gpsProblem ?? ''}')));
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance.collection('hazards').add({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'timestamp': Timestamp.now(),
        'object_type': 'manual',
        'distance_m': 0,
        'status': 'active',
      });
      messenger.showSnackBar(SnackBar(
          content: Text('Hazard saved: hazards/${doc.id}\n'
              '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)} '
              '(±${pos.accuracy.toStringAsFixed(0)} m)')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Firestore write FAILED: $e')));
    }
  }

  /// Four lines: latitude, longitude, accuracy, heading (or why there is no fix).
  List<Widget> _gpsLines() {
    const style = TextStyle(color: Colors.lightBlueAccent, fontSize: 12);
    final pos = _pos;
    if (pos == null) return [Text(_gpsProblem ?? 'GPS: no fix', style: style)];
    // Heading comes from movement: below ~1 m/s it is -1 or frozen.
    final h = usableHeading(pos.heading, pos.speed);
    final heading = h == null ? '— (only while moving)' : '${h.toStringAsFixed(0)}°';
    return [
      Text('lat ${pos.latitude.toStringAsFixed(6)}', style: style),
      Text('lon ${pos.longitude.toStringAsFixed(6)}', style: style),
      Text('accuracy ±${pos.accuracy.toStringAsFixed(1)} m', style: style),
      Text('heading $heading', style: style),
      if (_gpsProblem != null) Text(_gpsProblem!, style: style),
    ];
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _hazardSub?.cancel();
    _recheck?.cancel();
    _controller?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      // GPS shown here too, so it can be checked even if the model or camera fails.
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_status),
              const SizedBox(height: 12),
              ..._gpsLines(),
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.all(16), child: _warningBanner()),
            ],
          ),
        ),
      );
    }
    final mirror =
        _controller!.description.lensDirection == CameraLensDirection.front;
    return Scaffold(
      backgroundColor: Colors.black,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _reportHazard,
        icon: const Icon(Icons.report),
        label: const Text('Report hazard'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Center keeps the preview at its true aspect ratio; the painter is
          // the preview's child so boxes share exactly the same area.
          Center(
            child: CameraPreview(
              _controller!,
              child: CustomPaint(
                painter: BoxPainter(_dets, _labels, mirror: mirror),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('RAILGUARD',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  Text(
                    'detections: ${_dets.length} · '
                    '${_inferMs.toStringAsFixed(0)} ms · '
                    '${(_inferMs > 0 ? 1000 / _inferMs : 0).toStringAsFixed(1)} FPS',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text('frames processed: $_frames',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 6),
                  ..._gpsLines(),
                ],
              ),
            ),
          ),
          // Above the Report hazard button.
          Positioned(left: 16, right: 16, bottom: 96, child: _warningBanner()),
        ],
      ),
    );
  }
}

class BoxPainter extends CustomPainter {
  final List<Detection> dets;
  final List<String> labels;
  final bool mirror; // front camera preview is mirrored
  BoxPainter(this.dets, this.labels, {this.mirror = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.redAccent;

    for (final d in dets) {
      // Detections are normalised (0..1) to the upright frame.
      final x1 = mirror ? 1 - d.x2 : d.x1;
      final x2 = mirror ? 1 - d.x1 : d.x2;
      final rect = Rect.fromLTRB(
        x1 * size.width,
        d.y1 * size.height,
        x2 * size.width,
        d.y2 * size.height,
      );
      canvas.drawRect(rect, paint);

      final name = (d.classId >= 0 && d.classId < labels.length)
          ? labels[d.classId]
          : '?';
      final tp = TextPainter(
        text: TextSpan(
          text: '$name ${(d.score * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            backgroundColor: Colors.redAccent,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, rect.top - 16));
    }
  }

  @override
  bool shouldRepaint(covariant BoxPainter old) => true;
}
