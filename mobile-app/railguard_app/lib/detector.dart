import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class Detection {
  final double x1, y1, x2, y2, score;
  final int classId;
  Detection(this.x1, this.y1, this.x2, this.y2, this.score, this.classId);
}

class Detector {
  static const int inputSize = 320;
  static const int numClasses = 7;
  static const double confThreshold = 0.35;
  static const double iouThreshold = 0.45;

  /// Convert a YUV420 camera frame to an RGB image.
  static img.Image yuv420ToImage(CameraImage cam) {
    final w = cam.width, h = cam.height;
    final out = img.Image(width: w, height: h);
    final yPlane = cam.planes[0];
    final uPlane = cam.planes[1];
    final vPlane = cam.planes[2];
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final uvIndex =
            uvPixelStride * (x >> 1) + uvRowStride * (y >> 1);
        final yIndex = y * yPlane.bytesPerRow + x;
        final yy = yPlane.bytes[yIndex];
        final uu = uPlane.bytes[uvIndex];
        final vv = vPlane.bytes[uvIndex];

        int r = (yy + 1.370705 * (vv - 128)).round();
        int g = (yy - 0.337633 * (uu - 128) - 0.698001 * (vv - 128)).round();
        int b = (yy + 1.732446 * (uu - 128)).round();
        out.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
      }
    }
    return out;
  }

  /// Build the [1, inputSize, inputSize, 3] float input tensor.
  ///
  /// [rotation] is the clockwise angle (0/90/180/270) that turns the raw
  /// sensor frame upright, so the model sees the scene as the user does and
  /// output boxes line up with the on-screen preview.
  static List<List<List<List<double>>>> preprocess(img.Image src,
      {int rotation = 0}) {
    var resized = img.copyResize(src, width: inputSize, height: inputSize);
    if (rotation % 360 != 0) {
      resized = img.copyRotate(resized, angle: rotation);
    }
    return List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ),
    );
  }

  /// Parse raw output [1, 4 + numClasses, N] into detections.
  ///
  /// The model emits cx, cy, w, h in input pixels (0..inputSize); they are
  /// normalised here so returned boxes are in 0..1 of the (rotated) frame.
  static List<Detection> parseOutput(List output) {
    final raw = output[0] as List; // [4 + numClasses][N]
    final n = (raw[0] as List).length;
    final dets = <Detection>[];

    for (int i = 0; i < n; i++) {
      double best = 0;
      int bestId = -1;
      for (int c = 0; c < numClasses; c++) {
        final s = (raw[4 + c][i] as num).toDouble();
        if (s > best) {
          best = s;
          bestId = c;
        }
      }
      if (best < confThreshold) continue;

      final cx = (raw[0][i] as num).toDouble() / inputSize;
      final cy = (raw[1][i] as num).toDouble() / inputSize;
      final w = (raw[2][i] as num).toDouble() / inputSize;
      final h = (raw[3][i] as num).toDouble() / inputSize;

      dets.add(Detection(
        (cx - w / 2).clamp(0.0, 1.0),
        (cy - h / 2).clamp(0.0, 1.0),
        (cx + w / 2).clamp(0.0, 1.0),
        (cy + h / 2).clamp(0.0, 1.0),
        best,
        bestId,
      ));
    }
    return _nms(dets);
  }

  /// Non-max suppression: drop overlapping duplicate boxes.
  /// Runs on the normalised boxes from [parseOutput].
  static List<Detection> _nms(List<Detection> dets) {
    dets.sort((a, b) => b.score.compareTo(a.score));
    final keep = <Detection>[];
    for (final d in dets) {
      bool overlaps = false;
      for (final k in keep) {
        if (k.classId != d.classId) continue;
        final ix1 = math.max(d.x1, k.x1), iy1 = math.max(d.y1, k.y1);
        final ix2 = math.min(d.x2, k.x2), iy2 = math.min(d.y2, k.y2);
        final iw = math.max(0.0, ix2 - ix1), ih = math.max(0.0, iy2 - iy1);
        final inter = iw * ih;
        final union = (d.x2 - d.x1) * (d.y2 - d.y1) +
            (k.x2 - k.x1) * (k.y2 - k.y1) - inter;
        if (union > 0 && inter / union > iouThreshold) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) keep.add(d);
      if (keep.length >= 20) break;
    }
    return keep;
  }
}
