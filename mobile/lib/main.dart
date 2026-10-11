import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, rootBundle;
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'detector.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  Future<void> _init() async {
    await Permission.camera.request();
    await Permission.location.request();

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

  @override
  void dispose() {
    _controller?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(body: Center(child: Text(_status)));
    }
    final mirror =
        _controller!.description.lensDirection == CameraLensDirection.front;
    return Scaffold(
      backgroundColor: Colors.black,
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
                ],
              ),
            ),
          ),
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
