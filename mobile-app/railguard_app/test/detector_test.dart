import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:railguard_app/detector.dart';

const _anchors = 2100;

/// Build a fake model output [1][4 + classes][anchors] with the given boxes.
/// Each box is (cx, cy, w, h) in input pixels, plus class id and score.
List _output(List<(double, double, double, double, int, double)> boxes) {
  final raw = List.generate(
    4 + Detector.numClasses,
    (_) => List.filled(_anchors, 0.0),
  );
  for (var i = 0; i < boxes.length; i++) {
    final (cx, cy, w, h, cls, score) = boxes[i];
    raw[0][i] = cx;
    raw[1][i] = cy;
    raw[2][i] = w;
    raw[3][i] = h;
    raw[4 + cls][i] = score;
  }
  return [raw];
}

void main() {
  group('Detector.parseOutput', () {
    test('normalises pixel coordinates to 0..1', () {
      // Person centred at (160, 160), 32 px wide, 64 px tall in a 320 input.
      final dets = Detector.parseOutput(_output([(160, 160, 32, 64, 0, 0.9)]));

      expect(dets, hasLength(1));
      final d = dets.single;
      expect(d.classId, 0);
      expect(d.score, closeTo(0.9, 1e-9));
      expect(d.x1, closeTo(0.45, 1e-9));
      expect(d.y1, closeTo(0.40, 1e-9));
      expect(d.x2, closeTo(0.55, 1e-9));
      expect(d.y2, closeTo(0.60, 1e-9));
    });

    test('clamps boxes that extend past the frame edge', () {
      final dets = Detector.parseOutput(_output([(10, 310, 40, 40, 1, 0.8)]));

      final d = dets.single;
      expect(d.x1, 0.0);
      expect(d.y2, 1.0);
    });

    test('drops detections below the confidence threshold', () {
      final dets = Detector.parseOutput(
          _output([(160, 160, 32, 64, 0, Detector.confThreshold - 0.01)]));

      expect(dets, isEmpty);
    });

    test('NMS keeps the best of overlapping same-class boxes', () {
      final dets = Detector.parseOutput(_output([
        (160, 160, 40, 80, 0, 0.7),
        (162, 161, 40, 80, 0, 0.9), // near-duplicate, higher score
        (60, 60, 20, 20, 0, 0.6), // separate person
        (161, 160, 40, 80, 1, 0.5), // same place, different class
      ]));

      expect(dets, hasLength(3));
      expect(dets.where((d) => d.classId == 0).map((d) => d.score),
          containsAll([0.9, 0.6]));
      expect(dets.where((d) => d.classId == 1), hasLength(1));
    });
  });

  group('Detector.preprocess', () {
    test('produces a [1, inputSize, inputSize, 3] tensor in 0..1', () {
      final src = img.Image(width: 64, height: 48)
        ..clear(img.ColorRgb8(255, 0, 0));
      final t = Detector.preprocess(src);

      expect(t, hasLength(1));
      expect(t[0], hasLength(Detector.inputSize));
      expect(t[0][0], hasLength(Detector.inputSize));
      expect(t[0][0][0], [1.0, 0.0, 0.0]);
    });

    test('rotation turns a sideways sensor frame upright (clockwise)', () {
      // Landscape frame: left half white, right half black.
      final src = img.Image(width: 64, height: 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 64; x++) {
          final v = x < 32 ? 255 : 0;
          src.setPixelRgb(x, y, v, v, v);
        }
      }
      final t = Detector.preprocess(src, rotation: 90);
      const n = Detector.inputSize;

      // After a 90° clockwise turn the white (left) half is on top.
      expect(t[0][n ~/ 4][n ~/ 2][0], 1.0);
      expect(t[0][3 * n ~/ 4][n ~/ 2][0], 0.0);
    });
  });
}
