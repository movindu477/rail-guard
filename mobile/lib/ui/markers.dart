// Hazard pins drawn in code, after the design reference: a coloured circle
// with a white border and a white icon, and a point at the bottom.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Future<BitmapDescriptor> _draw(Size size, double dpr, void Function(Canvas) paint) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(dpr);
  paint(canvas);
  final img = await rec.endRecording().toImage(
    (size.width * dpr).ceil(),
    (size.height * dpr).ceil(),
  );
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.bytes(png!.buffer.asUint8List(), imagePixelRatio: dpr);
}

/// Hazard pin, 48 x 60 logical px; anchor it at (0.5, 1.0), the point.
Future<BitmapDescriptor> hazardPin(IconData icon, Color colour, double dpr) =>
    _draw(const Size(48, 60), dpr, (c) {
      const centre = Offset(24, 24);
      // Shadow, point, white ring, coloured disc.
      c.drawCircle(
        centre.translate(0, 2),
        23,
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      c.drawPath(
        Path()
          ..moveTo(15, 42)
          ..lineTo(24, 59)
          ..lineTo(33, 42)
          ..close(),
        Paint()..color = Colors.white,
      );
      c.drawCircle(centre, 23, Paint()..color = Colors.white);
      c.drawCircle(centre, 19.5, Paint()..color = colour);
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: 22,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
    });
