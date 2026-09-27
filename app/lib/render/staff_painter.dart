/// 把排版指令画到 Canvas 上（Flutter 层）
library;

import 'package:flutter/material.dart';

import 'staff_layout.dart';

class StaffPainter extends CustomPainter {
  final StaffDocument doc;
  final Color color;
  final Color accent;

  StaffPainter(this.doc, {required this.color, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..isAntiAlias = true;
    final thickPaint = Paint()..color = color;

    for (final op in doc.ops) {
      switch (op) {
        case LineOp():
          linePaint.strokeWidth = op.width;
          canvas.drawLine(Offset(op.x1, op.y1), Offset(op.x2, op.y2), linePaint);
          break;
        case RectOp():
          canvas.drawRect(Rect.fromLTWH(op.x, op.y, op.w, op.h), thickPaint);
          break;
        case BeamOp():
          final path = Path()
            ..moveTo(op.x1, op.y1 - op.thickness / 2)
            ..lineTo(op.x2, op.y2 - op.thickness / 2)
            ..lineTo(op.x2, op.y2 + op.thickness / 2)
            ..lineTo(op.x1, op.y1 + op.thickness / 2)
            ..close();
          canvas.drawPath(path, thickPaint);
          break;
        case CurveOp():
          final path = Path()
            ..moveTo(op.x1, op.y1)
            ..quadraticBezierTo(op.cx, op.cy, op.x2, op.y2);
          canvas.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = op.width,
          );
          break;
        case GlyphOp():
          _drawGlyph(canvas, op, color);
          break;
        case TextOp():
          _drawText(canvas, op, color);
          break;
      }
    }
  }

  void _drawGlyph(Canvas canvas, GlyphOp op, Color c) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(op.codePoint),
        style: TextStyle(fontFamily: 'Bravura', fontSize: op.size, color: c, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    tp.paint(canvas, Offset(op.x, op.y - baseline));
  }

  void _drawText(Canvas canvas, TextOp op, Color c) {
    final tp = TextPainter(
      text: TextSpan(
        text: op.text,
        style: TextStyle(
          fontSize: op.size,
          color: c,
          fontWeight: op.bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = op.alignCenter ? op.x - tp.width / 2 : op.x;
    tp.paint(canvas, Offset(x, op.y - tp.height));
  }

  @override
  bool shouldRepaint(covariant StaffPainter oldDelegate) =>
      oldDelegate.doc != doc || oldDelegate.color != color;
}
