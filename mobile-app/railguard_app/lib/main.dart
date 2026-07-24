import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
      final input = Detector.preprocess(rgb);

      // Output buffer shaped [1][11][2100]
      final output = List.generate(
        1,
        (_) => List.generate(11, (_) => List.filled(2100, 0.0)),
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
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          CustomPaint(
            painter: BoxPainter(_dets, _labels),
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
  BoxPainter(this.dets, this.labels);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.redAccent;

    for (final d in dets) {
      final rect = Rect.fromLTRB(
        d.x1 * size.width,
        d.y1 * size.height,
        d.x2 * size.width,
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
