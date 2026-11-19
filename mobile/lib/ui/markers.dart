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

/// Hazard pin with an amber "not yet sent" badge drawn directly above it;
/// 96 x 84 logical px; anchor at (0.5, 1.0), the bottom point.
Future<BitmapDescriptor> pendingHazardPin(IconData icon, Color colour, double dpr) =>
    _draw(const Size(96, 84), dpr, (c) {
      const centre = Offset(48, 48);
      // Pin shadow, point, white ring, coloured disc.
      c.drawCircle(
        centre.translate(0, 2),
        23,
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      c.drawPath(
        Path()
          ..moveTo(39, 66)
          ..lineTo(48, 83)
          ..lineTo(57, 66)
          ..close(),
        Paint()..color = Colors.white,
      );
      c.drawCircle(centre, 23, Paint()..color = Colors.white);
      c.drawCircle(centre, 19.5, Paint()..color = colour);
      final iconTp = TextPainter(
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
      iconTp.paint(c, centre - Offset(iconTp.width / 2, iconTp.height / 2));

      // Amber "not yet sent" badge pill at top.
      final badgeRect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(4, 2, 88, 22),
        const Radius.circular(11),
      );
      c.drawRRect(
        badgeRect.shift(const Offset(0, 1)),
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      c.drawRRect(badgeRect, Paint()..color = const Color(0xFFD97706));
      c.drawRRect(
        badgeRect,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
      final labelTp = TextPainter(
        text: const TextSpan(
          text: 'not yet sent',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelTp.paint(
        c,
        Offset(48 - labelTp.width / 2, 13 - labelTp.height / 2),
      );
    });
