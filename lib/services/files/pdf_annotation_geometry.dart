import 'dart:math' as math;

import '../../models/reading_annotation.dart';

/// Coordinates here are unrotated PDF user-space coordinates, never screen
/// coordinates. They are discarded after conversion to body-text offsets.
class PdfTextPoint {
  const PdfTextPoint(this.x, this.y);

  final double x;
  final double y;
}

class PdfTextBounds {
  const PdfTextBounds({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final double left;
  final double bottom;
  final double right;
  final double top;

  bool get isValid =>
      left.isFinite &&
      bottom.isFinite &&
      right.isFinite &&
      top.isFinite &&
      right > left &&
      top > bottom;

  PdfTextPoint get center =>
      PdfTextPoint((left + right) / 2, (bottom + top) / 2);
}

class PdfTextGlyph {
  const PdfTextGlyph({
    required this.start,
    required this.end,
    required this.bounds,
    this.isDecoded = true,
  });

  /// Half-open UTF-16 offsets in the concatenated, decoded HTML paragraphs.
  final int start;
  final int end;
  final PdfTextBounds? bounds;
  final bool isDecoded;
}

class PdfTextQuad {
  const PdfTextQuad(this.points);

  final List<PdfTextPoint> points;
}

class PdfAnnotationMatch {
  const PdfAnnotationMatch({this.ranges = const [], this.unresolvedReason});

  final List<AnnotationRange> ranges;
  final String? unresolvedReason;
}

/// Matches actual markup quadrilaterals to glyphs from the SAME extraction.
/// It deliberately does not search for quoted words or snap notes to nearby
/// text. Separate selections remain separate when there is unselected text.
PdfAnnotationMatch matchPdfAnnotationRanges({
  required String body,
  required List<PdfTextGlyph> glyphs,
  required List<PdfTextQuad> quads,
}) {
  if (quads.isEmpty) {
    return const PdfAnnotationMatch(
      unresolvedReason: '这条文字批注没有保存有效的选词范围，请重新选词定位。',
    );
  }

  final spans = <(int, int)>[];
  for (final quad in quads) {
    final hull = _convexHull(quad.points);
    if (hull.length < 3) {
      return const PdfAnnotationMatch(
        unresolvedReason: '这条批注的选词坐标不完整，请重新选词定位。',
      );
    }
    final selected = glyphs.where((glyph) {
      final box = glyph.bounds;
      return glyph.start >= 0 &&
          glyph.end > glyph.start &&
          glyph.end <= body.length &&
          box != null &&
          box.isValid &&
          _contains(hull, box.center);
    }).toList()..sort((a, b) => a.start.compareTo(b.start));

    if (selected.isEmpty ||
        !selected.any(
          (glyph) => body.substring(glyph.start, glyph.end).trim().isNotEmpty,
        )) {
      // Do not silently import only the successful part of a multi-quad note.
      return const PdfAnnotationMatch(
        unresolvedReason: '这条批注有选区无法对应到正文文字，请重新选词定位。',
      );
    }
    if (selected.any((glyph) => !glyph.isDecoded)) {
      return const PdfAnnotationMatch(
        unresolvedReason: '批注对应的原文字体无法完整解码，请核对正文后重新选词。',
      );
    }

    var start = selected.first.start;
    var end = selected.first.end;
    for (final glyph in selected.skip(1)) {
      final overlaps = glyph.start <= end;
      final onlyWhitespaceBetween = !overlaps &&
          body.substring(end, glyph.start).trim().isEmpty;
      if (overlaps || onlyWhitespaceBetween) {
        end = math.max(end, glyph.end);
      } else {
        spans.add(_wholeSurrogates(body, start, end));
        start = glyph.start;
        end = glyph.end;
      }
    }
    spans.add(_wholeSurrogates(body, start, end));
  }

  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final span in spans) {
    if (merged.isNotEmpty && span.$1 <= merged.last.$2) {
      final previous = merged.removeLast();
      merged.add((previous.$1, math.max(previous.$2, span.$2)));
    } else {
      merged.add(span);
    }
  }

  return PdfAnnotationMatch(
    ranges: List.unmodifiable([
      for (final span in merged)
        AnnotationRange(
          start: span.$1,
          end: span.$2,
          quote: body.substring(span.$1, span.$2),
        ),
    ]),
  );
}

(int, int) _wholeSurrogates(String body, int start, int end) {
  bool high(int value) => value >= 0xd800 && value <= 0xdbff;
  bool low(int value) => value >= 0xdc00 && value <= 0xdfff;
  if (start > 0 &&
      low(body.codeUnitAt(start)) &&
      high(body.codeUnitAt(start - 1))) {
    start--;
  }
  if (end < body.length &&
      high(body.codeUnitAt(end - 1)) &&
      low(body.codeUnitAt(end))) {
    end++;
  }
  return (start, end);
}

double _cross(PdfTextPoint a, PdfTextPoint b, PdfTextPoint c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

List<PdfTextPoint> _convexHull(List<PdfTextPoint> input) {
  if (input.length != 4 ||
      input.any((point) => !point.x.isFinite || !point.y.isFinite)) {
    return const [];
  }
  // Producers use different quad-point orders. A convex hull avoids assuming
  // either the specification's winding order or Acrobat's common Z order.
  final sorted = List<PdfTextPoint>.of(input)
    ..sort((a, b) {
      final byX = a.x.compareTo(b.x);
      return byX == 0 ? a.y.compareTo(b.y) : byX;
    });
  final points = <PdfTextPoint>[];
  for (final point in sorted) {
    if (points.isEmpty ||
        point.x != points.last.x ||
        point.y != points.last.y) {
      points.add(point);
    }
  }
  if (points.length < 3) return const [];

  List<PdfTextPoint> half(Iterable<PdfTextPoint> values) {
    final result = <PdfTextPoint>[];
    for (final point in values) {
      while (result.length >= 2 &&
          _cross(result[result.length - 2], result.last, point) <= 0) {
        result.removeLast();
      }
      result.add(point);
    }
    return result;
  }

  final lower = half(points)..removeLast();
  final upper = half(points.reversed)..removeLast();
  return [...lower, ...upper];
}

bool _contains(List<PdfTextPoint> hull, PdfTextPoint point) {
  const toleranceInPoints = 0.05;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i];
    final b = hull[(i + 1) % hull.length];
    final edgeLength = math.sqrt(
      (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y),
    );
    if (_cross(a, b, point) < -toleranceInPoints * edgeLength) return false;
  }
  return true;
}
