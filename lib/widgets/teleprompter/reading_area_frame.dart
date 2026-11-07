import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The reading guide sits in the side gutters. Its corner strokes never cross
/// the text column, even while a large mixed-size row is scrolling into place.
class ReadingAreaFrame extends StatelessWidget {
  final Rect row;
  final double borderWidth;

  const ReadingAreaFrame({
    super.key,
    required this.row,
    required this.borderWidth,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _ReadingAreaPainter(row, borderWidth),
      size: Size.infinite,
    ),
  );
}

class _ReadingAreaPainter extends CustomPainter {
  final Rect row;
  final double borderWidth;
  const _ReadingAreaPainter(this.row, this.borderWidth);

  @override
  void paint(Canvas canvas, Size size) {
    if (borderWidth <= 0) return;
    final width = borderWidth.clamp(0.0, 8.0).toDouble();
    final inset = width / 2;
    final left = math.max(inset, row.left - 9);
    final right = math.min(size.width - inset, row.right + 9);
    final top = row.top
        .clamp(inset, math.max(inset, size.height - inset))
        .toDouble();
    final bottom = row.bottom
        .clamp(inset, math.max(inset, size.height - inset))
        .toDouble();
    if (bottom <= top || right <= left) return;
    final paint = Paint()
      ..color = const Color(0xFFFDC800).withValues(alpha: 0.9)
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    final leftInner = math.max(left, row.left - inset - 1);
    final rightInner = math.min(right, row.right + inset + 1);
    canvas.drawPath(
      Path()
        ..moveTo(leftInner, top)
        ..lineTo(left, top)
        ..lineTo(left, bottom)
        ..lineTo(leftInner, bottom),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(rightInner, top)
        ..lineTo(right, top)
        ..lineTo(right, bottom)
        ..lineTo(rightInner, bottom),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ReadingAreaPainter oldDelegate) =>
      row != oldDelegate.row || borderWidth != oldDelegate.borderWidth;
}
