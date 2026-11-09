import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/reading_annotation.dart';
import 'reading_emphasis_text.dart';

const Color readingAnnotationColor = Color(0xFF8BD1D0);
const double readingAnnotationLeaderAngle = 17.5;

/// A selected range fragment on one visual row. Different logical ranges and
/// bidi runs never acquire a box around the intervening, unselected text.
@immutable
class ReadingAnnotationAnchor {
  final Rect frame;
  final List<ReadingAnnotation> notes;
  final double bodyFontSize;

  const ReadingAnnotationAnchor({
    required this.frame,
    required this.notes,
    required this.bodyFontSize,
  });
}

/// Label geometry is independent of the reading cursor and visibility switch.
/// The arrow starts at the bottom centre of the whole multiline label, and
/// ends at the top centre of the selected range's frame.
class ReadingAnnotationLabel {
  final ReadingAnnotationAnchor anchor;
  final Rect rect;
  final TextPainter painter;
  final bool mirrored;
  final bool isTruncated;

  ReadingAnnotationLabel({
    required this.anchor,
    required this.rect,
    required this.painter,
    required this.mirrored,
    required this.isTruncated,
  });

  Offset get tail => rect.bottomCenter;
  Offset get tip => anchor.frame.topCenter;
  Rect get occupiedBounds => rect.expandToInclude(Rect.fromPoints(tail, tip));

  Path get leader {
    final delta = tip - tail;
    return Path()
      ..moveTo(tail.dx, tail.dy)
      ..cubicTo(
        tail.dx + delta.dx * .33,
        tail.dy + delta.dy * .28,
        tail.dx + delta.dx * .76,
        tail.dy + delta.dy * .76,
        tip.dx,
        tip.dy,
      );
  }

  /// Two short strokes, with no filled triangle or dot that could be mistaken
  /// for punctuation in a manuscript.
  Path get arrowHead {
    final vector = tail - tip;
    final distance = vector.distance;
    if (distance == 0) return Path();
    final unit = vector / distance;
    final normal = Offset(-unit.dy, unit.dx);
    final length = math.min(5.0, math.max(2.8, rect.height * .14));
    final back = tip + unit * length;
    final first = back + normal * length * .42;
    final second = back - normal * length * .42;
    return Path()
      ..moveTo(first.dx, first.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(second.dx, second.dy);
  }

  void dispose() => painter.dispose();
}

class ReadingAnnotationRow {
  final int index;
  final Rect safeBand;
  final List<Rect> bodyBounds;
  final List<ReadingAnnotationAnchor> anchors;
  final List<ReadingAnnotationLabel> labels;

  const ReadingAnnotationRow({
    required this.index,
    required this.safeBand,
    required this.bodyBounds,
    required this.anchors,
    required this.labels,
  });

  void dispose() {
    for (final label in labels) {
      label.dispose();
    }
  }
}

class _RangeEntry {
  final ReadingAnnotation note;
  final AnnotationRange range;

  const _RangeEntry(this.note, this.range);
}

class _RowEnvelope {
  final List<ReadingGlyphPlacement> placements;
  final List<Rect> bounds;
  final double top;
  final double bottom;

  const _RowEnvelope(this.placements, this.bounds, this.top, this.bottom);
}

/// A bounded, lazily measured annotation foreground. It never changes or
/// rebuilds [textLayout]. Only visible rows acquire native label paragraphs.
/// Long notes, dense lines and colliding notes retain their exact range frames;
/// the line widget makes their complete original text available on long press
/// or secondary click. Preview truncation never changes the stored note.
class ReadingAnnotationLayout {
  static const int maximumCachedRows = 64;
  static const int maximumLabelsPerRow = 6;
  static const int maximumPreviewGraphemes = 180;
  static const double _clearance = 1.5;

  final ReadingTextLayout textLayout;
  final ReadingGlyphPainterCache glyphCache;
  final double leadingSpace;
  final List<_RangeEntry> _entries = [];
  final List<int> _prefixEnds = [];
  final LinkedHashMap<int, ReadingAnnotationRow> _rows = LinkedHashMap();
  final LinkedHashMap<int, _RowEnvelope> _envelopes = LinkedHashMap();

  ReadingAnnotationLayout({
    required this.textLayout,
    required List<ReadingAnnotation> annotations,
    required this.glyphCache,
    double leadingSpace = 0,
  }) : leadingSpace = leadingSpace.isFinite ? math.max(0, leadingSpace) : 0 {
    if (textLayout.graphemes.isEmpty) return;
    final first = textLayout.graphemes.first.rawStart;
    final last = textLayout.graphemes.last.rawEnd + 1;
    for (final note in annotations) {
      if (!note.isAnchored || note.text.trim().isEmpty) continue;
      for (final range in note.ranges) {
        if (range.start < range.end &&
            range.start < last &&
            range.end > first) {
          _entries.add(_RangeEntry(note, range));
        }
      }
    }
    _entries.sort((a, b) => a.range.start.compareTo(b.range.start));
    var end = -1;
    for (final entry in _entries) {
      end = math.max(end, entry.range.end);
      _prefixEnds.add(end);
    }
  }

  @visibleForTesting
  int get debugCachedRowCount => _rows.length;

  bool get isEmpty => _entries.isEmpty;

  /// Leading is shared across authored lines without moving either body. The
  /// caller may borrow only the previous line's actual unused trailing space.
  static double trailingSpace(
    ReadingTextLayout layout,
    ReadingGlyphPainterCache cache,
  ) {
    if (layout.rows.isEmpty) return layout.height;
    final row = layout.rows.last;
    var bottom = row.top;
    for (final placement in layout.placementsIn(
      Rect.fromLTWH(0, row.top, layout.width, row.height),
    )) {
      bottom = math.max(
        bottom,
        layout.maximumGlyphBounds(placement, cache).bottom,
      );
    }
    return math.max(0, layout.height - bottom - _clearance);
  }

  _RowEnvelope _envelope(int index) {
    final cached = _envelopes.remove(index);
    if (cached != null) {
      _envelopes[index] = cached;
      return cached;
    }
    final row = textLayout.rows[index];
    final placements = textLayout
        .placementsIn(Rect.fromLTWH(0, row.top, textLayout.width, row.height))
        .toList(growable: false);
    final bounds = [
      for (final placement in placements)
        textLayout.maximumGlyphBounds(placement, glyphCache),
    ];
    var top = row.bottom;
    var bottom = row.top;
    for (final rect in bounds) {
      top = math.min(top, rect.top);
      bottom = math.max(bottom, rect.bottom);
    }
    final result = _RowEnvelope(placements, bounds, top, bottom);
    if (_envelopes.length >= maximumCachedRows + 2) {
      _envelopes.remove(_envelopes.keys.first);
    }
    _envelopes[index] = result;
    return result;
  }

  Iterable<_RangeEntry> _intersecting(int start, int end) sync* {
    var low = 0;
    var high = _entries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_entries[middle].range.start < end) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (
      var index = low - 1;
      index >= 0 && _prefixEnds[index] > start;
      index--
    ) {
      if (_entries[index].range.end > start) yield _entries[index];
    }
  }

  ReadingAnnotationRow rowAt(int index) {
    final cached = _rows.remove(index);
    if (cached != null) {
      _rows[index] = cached;
      return cached;
    }
    final envelope = _envelope(index);
    final previousBottom = index == 0
        ? -leadingSpace
        : _envelope(index - 1).bottom + _clearance;
    final bandBottom = envelope.top - _clearance * 2;
    final safeBand = Rect.fromLTRB(
      _clearance,
      previousBottom,
      math.max(_clearance, textLayout.width - _clearance),
      math.max(previousBottom, bandBottom),
    );
    final anchors = <ReadingAnnotationAnchor>[];
    if (envelope.placements.isNotEmpty) {
      final selectedByNote = <ReadingAnnotation, Set<int>>{};
      for (final entry in _intersecting(
        envelope.placements.first.grapheme.rawStart,
        envelope.placements.last.grapheme.rawEnd + 1,
      )) {
        final selected = selectedByNote.putIfAbsent(entry.note, () => <int>{});
        for (var i = 0; i < envelope.placements.length; i++) {
          final glyph = envelope.placements[i].grapheme;
          if (glyph.rawStart < entry.range.end &&
              glyph.rawEnd >= entry.range.start) {
            selected.add(i);
          }
        }
      }
      final notesByFrame = <Rect, List<ReadingAnnotation>>{};
      final fontByFrame = <Rect, double>{};
      for (final entry in selectedByNote.entries) {
        final selected = entry.value.toList()
          ..sort(
            (a, b) =>
                envelope.bounds[a].left.compareTo(envelope.bounds[b].left),
          );
        Rect? segment;
        var fontSize = 0.0;
        void finish() {
          if (segment == null) return;
          final frame = Rect.fromLTRB(
            math.max(.75, segment.left + .4),
            math.max(-leadingSpace + .75, segment.top - _clearance),
            math.min(textLayout.width - .75, segment.right - .4),
            math.min(textLayout.height - .75, segment.bottom + _clearance),
          );
          if (frame.isEmpty) return;
          (notesByFrame[frame] ??= []).add(entry.key);
          fontByFrame[frame] = math.max(fontByFrame[frame] ?? 0, fontSize);
        }

        for (final i in selected) {
          final bounds = envelope.bounds[i];
          if (segment != null && bounds.left > segment.right + .5) {
            finish();
            segment = null;
            fontSize = 0;
          }
          segment = segment?.expandToInclude(bounds) ?? bounds;
          fontSize = math.max(
            fontSize,
            textLayout.geometry.fontSizeFor(
              envelope.placements[i].grapheme.format,
            ),
          );
        }
        finish();
      }
      for (final entry in notesByFrame.entries) {
        anchors.add(
          ReadingAnnotationAnchor(
            frame: entry.key,
            notes: List.unmodifiable(entry.value),
            bodyFontSize: fontByFrame[entry.key]!,
          ),
        );
      }
      anchors.sort((a, b) => a.frame.left.compareTo(b.frame.left));
    }

    final labels = <ReadingAnnotationLabel>[];
    final occupied = <Rect>[];
    for (final anchor in anchors) {
      if (labels.length >= maximumLabelsPerRow) break;
      final label = _placeLabel(anchor, safeBand, envelope.bounds, occupied);
      if (label != null) {
        labels.add(label);
        occupied.add(label.occupiedBounds.inflate(_clearance));
      }
    }
    final result = ReadingAnnotationRow(
      index: index,
      safeBand: safeBand,
      bodyBounds: List.unmodifiable(envelope.bounds),
      anchors: List.unmodifiable(anchors),
      labels: List.unmodifiable(labels),
    );
    if (_rows.length >= maximumCachedRows) {
      _rows.remove(_rows.keys.first)?.dispose();
    }
    _rows[index] = result;
    return result;
  }

  ReadingAnnotationLabel? _placeLabel(
    ReadingAnnotationAnchor anchor,
    Rect band,
    List<Rect> bodyBounds,
    List<Rect> occupied,
  ) {
    // Keep the approved small-note proportion. Do not enlarge tiny notes into
    // the manuscript or reduce them into unreadable dots to force a fit.
    final fontSize = anchor.bodyFontSize * .22;
    if (fontSize < 8 || band.isEmpty) return null;
    final style = TextStyle(
      fontSize: fontSize,
      height: ui.kTextHeightNone,
      color: readingAnnotationColor,
      fontWeight: FontWeight.w400,
      fontFamily: textLayout.geometry.fontFamily.isEmpty
          ? null
          : textLayout.geometry.fontFamily,
    );
    final lineHeight = glyphCache
        .painterFor('国', style, TextDirection.ltr)
        .height;
    final maxLines = math.min(3, ((band.height - 2.5) / lineHeight).floor());
    if (maxLines < 1) return null;
    final source = anchor.notes.first.text.trim().replaceAll('\r\n', '\n');
    final characters = source.characters;
    final shortened = characters.take(maximumPreviewGraphemes).toString();
    final sourceClipped = shortened.length < source.length;
    final preview =
        '$shortened${sourceClipped ? '…' : ''}'
        '${anchor.notes.length > 1 ? ' · +${anchor.notes.length - 1}' : ''}';
    final preferredWidth = math.min(textLayout.width * .55, fontSize * 14);
    final tip = anchor.frame.topCenter;
    for (final factor in const [1.0, .72, .5]) {
      final width = preferredWidth * factor;
      if (width < fontSize * 2) continue;
      final painter = TextPainter(
        text: TextSpan(text: preview, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        textScaler: TextScaler.noScaling,
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: width);
      final minimumRise = math.max(2.5, tip.dy - band.bottom);
      final availableRise = tip.dy - band.top - painter.height;
      if (availableRise < minimumRise) {
        painter.dispose();
        continue;
      }
      final rise = math.min(
        availableRise,
        math.max(minimumRise, fontSize * .75),
      );
      final run = rise / math.tan(readingAnnotationLeaderAngle * math.pi / 180);
      // Only the right boundary mirrors a leader. A collision does not send
      // the reader hunting for a note on an unrelated side of the word.
      final mirrored = tip.dx + run + painter.width / 2 > band.right;
      final centerX = tip.dx + (mirrored ? -run : run);
      final rect = Rect.fromLTWH(
        centerX - painter.width / 2,
        tip.dy - rise - painter.height,
        painter.width,
        painter.height,
      );
      final leaderBounds = Rect.fromPoints(rect.bottomCenter, tip).inflate(.75);
      final occupiedBounds = rect
          .expandToInclude(leaderBounds)
          .inflate(_clearance);
      if (rect.left < band.left ||
          rect.right > band.right ||
          rect.top < band.top - .01 ||
          rect.bottom > band.bottom + .01 ||
          occupied.any((other) => other.overlaps(occupiedBounds)) ||
          bodyBounds.any((body) => body.overlaps(leaderBounds))) {
        painter.dispose();
        continue;
      }
      return ReadingAnnotationLabel(
        anchor: anchor,
        rect: rect,
        painter: painter,
        mirrored: mirrored,
        isTruncated: sourceClipped || painter.didExceedMaxLines,
      );
    }
    return null;
  }

  int _rowIndex(double y) {
    var low = 0;
    var high = textLayout.rows.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (textLayout.rows[middle].bottom <= y) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  Iterable<ReadingAnnotationRow> rowsIn(Rect clip) sync* {
    if (isEmpty || textLayout.rows.isEmpty || clip.isEmpty) return;
    final first = _rowIndex(clip.top);
    // The next row can place a note in this row's unused trailing whitespace.
    final last = math.min(
      textLayout.rows.length - 1,
      _rowIndex(clip.bottom) + 1,
    );
    for (var index = first; index <= last; index++) {
      yield rowAt(index);
    }
  }

  List<ReadingAnnotation> notesAt(Offset position, {bool labelsOnly = false}) {
    if (isEmpty || textLayout.rows.isEmpty) return const [];
    final result = <ReadingAnnotation>{};
    final index = _rowIndex(position.dy);
    final first = math.max(0, index - 1);
    final last = math.min(textLayout.rows.length - 1, index + 1);
    for (var i = first; i <= last; i++) {
      final row = rowAt(i);
      for (final label in row.labels) {
        if (label.rect.contains(position)) result.addAll(label.anchor.notes);
      }
      if (!labelsOnly) {
        for (final anchor in row.anchors) {
          if (anchor.frame.contains(position)) result.addAll(anchor.notes);
        }
      }
    }
    return result.toList(growable: false);
  }

  void dispose() {
    for (final row in _rows.values) {
      row.dispose();
    }
    _rows.clear();
    _envelopes.clear();
  }
}

class ReadingAnnotationPainter extends CustomPainter {
  final ReadingAnnotationLayout layout;
  final ScrollController? scrollController;
  final double contentTop;
  final double viewportHeight;

  @visibleForTesting
  int debugLastPaintedRows = 0;

  ReadingAnnotationPainter({
    required this.layout,
    this.scrollController,
    this.contentTop = 0,
    this.viewportHeight = double.infinity,
  }) : super(
         repaint: layout.textLayout.height > viewportHeight * 2
             ? scrollController
             : null,
       );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, layout.leadingSpace);
    var clip = canvas.getLocalClipBounds().intersect(
      Rect.fromLTRB(
        0,
        -layout.leadingSpace,
        size.width,
        layout.textLayout.height,
      ),
    );
    final controller = scrollController;
    if (layout.textLayout.height > viewportHeight * 2 &&
        controller != null &&
        controller.hasClients) {
      clip = clip.intersect(
        Rect.fromLTWH(
          0,
          controller.offset - contentTop - viewportHeight / 2,
          size.width,
          viewportHeight * 2,
        ),
      );
    }
    canvas.clipRect(clip);
    final paint = Paint()
      ..color = readingAnnotationColor.withValues(alpha: .9)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    debugLastPaintedRows = 0;
    for (final row in layout.rowsIn(clip)) {
      debugLastPaintedRows++;
      for (final anchor in row.anchors) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            anchor.frame,
            Radius.circular(math.min(7, anchor.frame.width / 5)),
          ),
          paint,
        );
      }
      for (final label in row.labels) {
        canvas.drawPath(label.leader, paint);
        canvas.drawPath(label.arrowHead, paint);
        label.painter.paint(canvas, label.rect.topLeft);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ReadingAnnotationPainter oldDelegate) =>
      layout != oldDelegate.layout ||
      scrollController != oldDelegate.scrollController ||
      contentTop != oldDelegate.contentTop ||
      viewportHeight != oldDelegate.viewportHeight;
}
