// Map marker images drawn in code: round hazard pins (emoji in a coloured
// ring, with a point at the bottom) and the glowing green train dot.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'theme.dart';

Future<BitmapDescriptor> _draw(Size size, double dpr, void Function(Canvas) paint) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(dpr);
  paint(canvas);
  final img = await rec.endRecording().toImage((size.width * dpr).ceil(), (size.height * dpr).ceil());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.bytes(png!.buffer.asUint8List(), imagePixelRatio: dpr);
}

/// Hazard pin, 56 x 66 logical px; anchor it at (0.5, 1.0), the point.
Future<BitmapDescriptor> hazardPin(String emoji, Color ring, double dpr) =>
    _draw(const Size(56, 66), dpr, (c) {
      const r = 28.0, centre = Offset(28, 28);
      c.drawPath(
          Path()
            ..moveTo(19, 50)
            ..lineTo(28, 66)
            ..lineTo(37, 50)
            ..close(),
          Paint()..color = ring);
      c.drawCircle(centre, r, Paint()..color = ring);
      c.drawCircle(centre, r - 4, Paint()..color = RG.surface);
      final tp = TextPainter(
        text: TextSpan(text: emoji, style: const TextStyle(fontSize: 26)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
    });

/// Train position: green dot, white ring, soft glow. 36 x 36; anchor (0.5, 0.5).
Future<BitmapDescriptor> trainDot(double dpr) => _draw(const Size(36, 36), dpr, (c) {
      const centre = Offset(18, 18);
      c.drawCircle(centre, 18, Paint()..color = RG.accent.withValues(alpha: 0.30));
      c.drawCircle(centre, 10, Paint()..color = Colors.white);
      c.drawCircle(centre, 7, Paint()..color = RG.accent);
    });
