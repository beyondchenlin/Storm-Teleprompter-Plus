import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/script_character.dart';

/// Layout reserves the largest supported emphasis, even when emphasis is off.
/// Changing a cursor, a colour or a scale is consequently a paint-only change.
const double readingEmphasisMaximumScale = AppSettings.maxCurrentCharScale;

double clampReadingEmphasisScale(double value) => value.isFinite
    ? value
          .clamp(AppSettings.minCurrentCharScale, readingEmphasisMaximumScale)
          .toDouble()
    : AppSettings.defaultCurrentCharScale;

/// A complete grapheme and its mapping back to the parser's UTF-16 indices.
/// The parser can split a surrogate pair or a ZWJ emoji across ScriptCharacters;
/// neither painting nor hit testing may split that user-visible character.
@immutable
class ReadingGrapheme {
  final String text;
  final int start;
  final int end;
  final int rawStart;
  final int rawEnd;
  final ScriptCharacter format;
  final ScriptParagraph? paragraph;

  const ReadingGrapheme({
    required this.text,
    required this.start,
    required this.end,
    required this.rawStart,
    required this.rawEnd,
    required this.format,
    this.paragraph,
  });

  bool containsRawIndex(int index) => index >= rawStart && index <= rawEnd;
}

/// Only metrics-affecting settings belong here. Colours and reading state must
/// never become part of the geometry key.
@immutable
class ReadingTextGeometry {
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final String fontFamily;
  final bool defaultBold;

  /// A viewport fit only; saved font sizes and cursor emphasis stay unchanged.
  final double fontScale;

  const ReadingTextGeometry({
    required this.fontSize,
    required this.lineHeight,
    this.letterSpacing = 0,
    this.fontFamily = '',
    this.defaultBold = false,
    this.fontScale = 1,
  });

  // Independent emphasis needs independent Latin character cells. Disable
  // discretionary ligatures/kerning in BOTH the measuring and drawing fonts;
  // combining marks and emoji remain intact graphemes. This avoids measuring
  // an "fi" ligature and subsequently drawing two incompatible glyph widths.
  static const _cellFontFeatures = <ui.FontFeature>[
    ui.FontFeature.disable('kern'),
    ui.FontFeature.disable('liga'),
    ui.FontFeature.disable('clig'),
  ];

  FontWeight get normalWeight =>
      defaultBold ? FontWeight.w700 : FontWeight.w400;
  FontWeight get boldWeight => defaultBold ? FontWeight.w900 : FontWeight.w700;

  double fontSizeFor(ScriptCharacter char) =>
      (char.fontSizePx ?? fontSize * (char.fontSizeRatio ?? 1.0)) * fontScale;

  TextStyle styleFor(ScriptCharacter char, {bool reserve = false}) => TextStyle(
    fontSize: fontSizeFor(char) * (reserve ? readingEmphasisMaximumScale : 1),
    height: lineHeight,
    // Also reserve the optional current-character bold weight. Toggling that
    // effect or moving it to another character must not alter the layout.
    fontWeight: reserve || char.bold ? boldWeight : normalWeight,
    fontStyle: char.italic ? FontStyle.italic : FontStyle.normal,
    fontFamily: fontFamily.isEmpty ? null : fontFamily,
    fontFeatures: _cellFontFeatures,
    // Advance widths do not include italic side bearings. Keep fixed ink
    // breathing room as well as the 115% advance; negative legacy spacing may
    // not consume that reserve. These settings never depend on the cursor.
    letterSpacing: reserve
        ? math.max(0.0, letterSpacing) * fontScale +
              fontSizeFor(char) *
                  readingEmphasisMaximumScale *
                  (char.italic ? 0.20 : 0.04)
        : 0,
  );

  double get emptyHeight =>
      fontSize * fontScale * readingEmphasisMaximumScale * lineHeight;

  @override
  bool operator ==(Object other) =>
      other is ReadingTextGeometry &&
      fontSize == other.fontSize &&
      lineHeight == other.lineHeight &&
      letterSpacing == other.letterSpacing &&
      fontFamily == other.fontFamily &&
      defaultBold == other.defaultBold &&
      fontScale == other.fontScale;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    letterSpacing,
    fontFamily,
    defaultBold,
    fontScale,
  );
}

@immutable
class ReadingVisualRow {
  final int start;
  final int end;
  final double top;
  final double height;
  final double baseline;

  const ReadingVisualRow({
    required this.start,
    required this.end,
    required this.top,
    required this.height,
    required this.baseline,
  });

  double get bottom => top + height;
  double get centerY => top + height / 2;
}

@immutable
class ReadingGlyphPlacement {
  final ReadingGrapheme grapheme;
  final Rect cell;
  final ReadingVisualRow row;
  final double horizontalAnchorOffset;

  const ReadingGlyphPlacement(
    this.grapheme,
    this.cell,
    this.row, {
    this.horizontalAnchorOffset = 0,
  });

  double get paintAnchorX => cell.center.dx + horizontalAnchorOffset;
}

/// A synthetic italic shear changes ink bounds without changing advances.
/// Skia uses x' = x - 0.25 * y, relative to the alphabetic baseline. In
/// particular, Windows can expose an Oblique face separately from Italic and
/// apply this shear to an already slanted face. Reserve its union with the
/// unsheared face on BOTH platforms, rather than changing positions at paint
/// time or assuming advance widths enclose the ink.
///
/// Source, pinned to Flutter 3.44.1's Skia revision:
/// https://github.com/google/skia/blob/e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465/modules/skparagraph/src/OneLineShaper.cpp
@immutable
class _ItalicShearEnvelope {
  static const double _maximumShear = 0.25;
  final double left;
  final double right;

  const _ItalicShearEnvelope(this.left, this.right);

  double get spacing => left + right;
  double get anchorOffset => (left - right) / 2;

  static Map<TextStyle, _ItalicShearEnvelope> measure(
    List<ReadingGrapheme> graphemes,
    ReadingTextGeometry geometry,
    TextDirection direction,
  ) {
    // One native measurement per italic metric style, not per character. Use
    // the actual text so CJK/emoji fallback metrics are included. This pass is
    // only performed when fixed paragraph geometry is rebuilt.
    final texts = <TextStyle, StringBuffer>{};
    for (final glyph in graphemes) {
      if (!glyph.format.italic) continue;
      final style = geometry.styleFor(glyph.format, reserve: true);
      (texts[style] ??= StringBuffer()).write(glyph.text);
    }
    final result = <TextStyle, _ItalicShearEnvelope>{};
    for (final entry in texts.entries) {
      final painter = TextPainter(
        text: TextSpan(
          text: entry.value.toString(),
          // Font ascent/descent must not shrink with a user's line-height
          // setting: the shear acts on the full glyph, not the line box.
          style: entry.key.copyWith(
            height: ui.kTextHeightNone,
            letterSpacing: 0,
          ),
        ),
        textDirection: direction,
        textScaler: TextScaler.noScaling,
      )..layout();
      var ascent = 0.0;
      var descent = 0.0;
      for (final metrics in painter.computeLineMetrics()) {
        ascent = math.max(ascent, metrics.ascent);
        descent = math.max(descent, metrics.descent);
      }
      result[entry.key] = _ItalicShearEnvelope(
        descent * _maximumShear,
        ascent * _maximumShear,
      );
      painter.dispose();
    }
    return result;
  }
}

/// One paragraph's fixed wrapping, baselines and hit-test coordinates.
///
/// Flutter still performs word wrapping and punctuation/bidi positioning. This
/// class only draws smaller original glyphs inside those reserved positions.
/// Full layouts are owned by the visible paragraph widgets, not by every line
/// in a long script. The text layer keeps one additional layout for navigation.
class ReadingTextLayout {
  final ScriptLine line;
  final ReadingTextGeometry geometry;
  final double width;
  final TextDirection direction;
  final List<ReadingGrapheme> graphemes;
  final TextPainter _painter;
  final Map<TextStyle, _ItalicShearEnvelope> _italicEnvelopes;
  late final List<ReadingVisualRow> rows = _computeRows();
  final LinkedHashMap<int, ReadingGlyphPlacement> _placements = LinkedHashMap();
  static const int _placementCacheLimit = 2048;

  ReadingTextLayout._({
    required this.line,
    required this.geometry,
    required this.width,
    required this.direction,
    required this.graphemes,
    required TextPainter painter,
    required Map<TextStyle, _ItalicShearEnvelope> italicEnvelopes,
  }) : _painter = painter,
       _italicEnvelopes = italicEnvelopes;

  factory ReadingTextLayout({
    required ScriptLine line,
    required ReadingTextGeometry geometry,
    required double width,
    required TextDirection direction,
  }) {
    final graphemes = _splitGraphemes(line);
    final italicEnvelopes = _ItalicShearEnvelope.measure(
      graphemes,
      geometry,
      direction,
    );
    final spans = <TextSpan>[];
    TextStyle? previousStyle;
    var text = StringBuffer();
    // Coalesce equal metric runs; a long plain paragraph does not need a
    // TextSpan per UTF-16 code unit to be measured.
    for (final glyph in graphemes) {
      var style = geometry.styleFor(glyph.format, reserve: true);
      final italicEnvelope = italicEnvelopes[style];
      if (italicEnvelope != null) {
        style = style.copyWith(
          letterSpacing: style.letterSpacing! + italicEnvelope.spacing,
        );
      }
      if (previousStyle != null && style != previousStyle) {
        spans.add(TextSpan(text: text.toString(), style: previousStyle));
        text = StringBuffer();
      }
      previousStyle = style;
      text.write(glyph.text);
    }
    if (text.isNotEmpty) {
      spans.add(TextSpan(text: text.toString(), style: previousStyle));
    }
    final painter = TextPainter(
      text: TextSpan(children: spans),
      textDirection: direction,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: math.max(0.0, width));
    return ReadingTextLayout._(
      line: line,
      geometry: geometry,
      width: width,
      direction: direction,
      graphemes: graphemes,
      painter: painter,
      italicEnvelopes: italicEnvelopes,
    );
  }

  static List<ReadingGrapheme> _splitGraphemes(ScriptLine line) {
    if (line.characters.isEmpty) return const [];
    // Metadata is resolved once with geometry, never by scanning the script
    // while the reading cursor or microphone level changes. Legacy callers
    // that construct a ScriptLine directly still get whole-line colouring.
    final paragraph =
        line.paragraph ??
        ScriptParagraph(
          index: line.lineIndex,
          rawStart: line.characters.first.rawIndex,
          rawEnd:
              line.characters.last.rawIndex +
              line.characters.last.char.length -
              1,
        );
    final text = line.text;
    final result = <ReadingGrapheme>[];
    var sourceIndex = 0;
    var sourceOffset = 0;
    var offset = 0;
    for (final cluster in text.characters) {
      while (sourceIndex + 1 < line.characters.length &&
          sourceOffset + line.characters[sourceIndex].char.length <= offset) {
        sourceOffset += line.characters[sourceIndex].char.length;
        sourceIndex++;
      }
      final first = line.characters[sourceIndex];
      final rawStart = first.rawIndex + offset - sourceOffset;
      final end = offset + cluster.length;
      var lastIndex = sourceIndex;
      var lastOffset = sourceOffset;
      while (lastIndex + 1 < line.characters.length &&
          lastOffset + line.characters[lastIndex].char.length < end) {
        lastOffset += line.characters[lastIndex].char.length;
        lastIndex++;
      }
      result.add(
        ReadingGrapheme(
          text: cluster,
          start: offset,
          end: end,
          rawStart: rawStart,
          rawEnd: line.characters[lastIndex].rawIndex + end - lastOffset - 1,
          format: first,
          paragraph: paragraph,
        ),
      );
      offset = end;
    }
    return List.unmodifiable(result);
  }

  double get height =>
      graphemes.isEmpty ? geometry.emptyHeight : _painter.height;

  /// Width of this authored line without automatic wrapping. This shares the
  /// same reserved emphasis and italic ink envelopes as the visible layout.
  double get maxIntrinsicWidth => _painter.maxIntrinsicWidth;

  List<ReadingVisualRow> _computeRows() => _painter
      .computeLineMetrics()
      .map((m) {
        final top = m.baseline - m.ascent;
        final sample = _painter.getPositionForOffset(
          Offset(m.left + m.width / 2, top + m.height / 2),
        );
        final range = _painter.getLineBoundary(sample);
        return ReadingVisualRow(
          start: range.start,
          end: range.end,
          top: top,
          height: m.height,
          baseline: m.baseline,
        );
      })
      .toList(growable: false);

  int _indexForCodeUnit(int offset) {
    var low = 0;
    var high = graphemes.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final glyph = graphemes[middle];
      if (offset < glyph.start) {
        high = middle - 1;
      } else if (offset >= glyph.end) {
        low = middle + 1;
      } else {
        return middle;
      }
    }
    return low.clamp(0, graphemes.length - 1).toInt();
  }

  int indexForRawIndex(int rawIndex) {
    var low = 0;
    var high = graphemes.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final glyph = graphemes[middle];
      if (rawIndex < glyph.rawStart) {
        high = middle - 1;
      } else if (rawIndex > glyph.rawEnd) {
        low = middle + 1;
      } else {
        return middle;
      }
    }
    return low.clamp(0, graphemes.length - 1).toInt();
  }

  ReadingVisualRow _rowAtY(double y) {
    var low = 0;
    var high = rows.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final row = rows[middle];
      if (y < row.top) {
        high = middle - 1;
      } else if (y >= row.bottom) {
        low = middle + 1;
      } else {
        return row;
      }
    }
    return rows[low.clamp(0, rows.length - 1).toInt()];
  }

  ReadingGlyphPlacement placementAt(int index) {
    final cached = _placements.remove(index);
    if (cached != null) {
      _placements[index] = cached;
      return cached;
    }
    final glyph = graphemes[index];
    final boxes = _painter.getBoxesForSelection(
      TextSelection(baseOffset: glyph.start, extentOffset: glyph.end),
    );
    final caret = _painter.getOffsetForCaret(
      TextPosition(offset: glyph.start),
      Rect.zero,
    );
    final box = boxes.isNotEmpty ? boxes.first.toRect() : null;
    final row = _rowAtY(box?.center.dy ?? caret.dy);
    final placement = ReadingGlyphPlacement(
      glyph,
      Rect.fromLTRB(
        box?.left ?? caret.dx,
        row.top,
        box?.right ?? caret.dx,
        row.bottom,
      ),
      row,
      horizontalAnchorOffset:
          _italicEnvelopes[geometry.styleFor(glyph.format, reserve: true)]
              ?.anchorOffset ??
          0,
    );
    if (_placements.length >= _placementCacheLimit) {
      _placements.remove(_placements.keys.first);
    }
    _placements[index] = placement;
    return placement;
  }

  ReadingGlyphPlacement? placementForRawIndex(int rawIndex) =>
      graphemes.isEmpty ? null : placementAt(indexForRawIndex(rawIndex));

  int? rawIndexForOffset(Offset offset) {
    if (graphemes.isEmpty) return null;
    // A caret offset chooses the NEXT character in the right half of a glyph.
    // Closest glyph bounds instead give the actual clicked grapheme.
    final glyph = _painter.getClosestGlyphForOffset(offset);
    final codeUnit =
        glyph?.graphemeClusterCodeUnitRange.start ??
        _painter.getPositionForOffset(offset).offset;
    return graphemes[_indexForCodeUnit(codeUnit)].rawStart;
  }

  Iterable<ReadingGlyphPlacement> placementsIn(Rect clip) sync* {
    if (graphemes.isEmpty || rows.isEmpty || clip.isEmpty) return;
    final firstRow = _rowAtY(clip.top);
    final lastRow = _rowAtY(clip.bottom);
    final first = _indexForCodeUnit(firstRow.start);
    final last = _indexForCodeUnit(math.max(lastRow.start, lastRow.end - 1));
    for (var index = first; index <= last; index++) {
      final placement = placementAt(index);
      if (placement.cell.overlaps(clip)) yield placement;
    }
  }

  void dispose() => _painter.dispose();
}

@immutable
class ReadingGlyphAppearance {
  final TextStyle style;
  final double scale;
  final bool isCurrent;
  final bool isCurrentParagraph;
  final bool isRead;

  const ReadingGlyphAppearance({
    required this.style,
    required this.scale,
    required this.isCurrent,
    this.isCurrentParagraph = false,
    required this.isRead,
  });
}

/// Paint-only state shared by the real canvas renderer and inspection/tests.
@immutable
class ReadingTextPresentation {
  final int currentIndex;
  final bool continuous;
  final bool enabled;
  final bool grayReadChars;
  final bool highlightCurrentChar;
  final bool underlineCurrentChar;
  final int textColor;
  final int currentCharColor;
  final int readCharColor;
  final double currentCharScale;

  const ReadingTextPresentation({
    required this.currentIndex,
    this.continuous = false,
    this.enabled = true,
    this.grayReadChars = true,
    this.highlightCurrentChar = false,
    this.underlineCurrentChar = false,
    this.textColor = 0,
    this.currentCharColor = AppSettings.defaultCurrentCharColor,
    this.readCharColor = AppSettings.defaultReadCharColor,
    this.currentCharScale = AppSettings.defaultCurrentCharScale,
  });

  ReadingGlyphAppearance appearanceFor(
    ReadingGrapheme glyph,
    ReadingTextGeometry geometry,
  ) {
    final current = !continuous && glyph.containsRawIndex(currentIndex);
    final paragraph = glyph.paragraph;
    final currentParagraph =
        !continuous && (paragraph?.containsRawIndex(currentIndex) ?? current);
    final read =
        !continuous && (paragraph?.rawEnd ?? glyph.rawEnd) < currentIndex;
    final originalColor = Color(
      glyph.format.textColor ?? (textColor == 0 ? 0xFFFFFFFF : textColor),
    );
    final color = currentParagraph && enabled
        ? Color(currentCharColor)
        : read && grayReadChars
        ? Color(readCharColor)
        : originalColor;
    final decorations = <TextDecoration>[
      if (glyph.format.underline || (current && underlineCurrentChar))
        TextDecoration.underline,
      if (glyph.format.strikeThrough) TextDecoration.lineThrough,
    ];
    return ReadingGlyphAppearance(
      style: geometry
          .styleFor(glyph.format)
          .copyWith(
            color: color,
            decorationColor: color,
            decoration: decorations.isEmpty
                ? TextDecoration.none
                : TextDecoration.combine(decorations),
            fontWeight: current && highlightCurrentChar
                ? geometry.boldWeight
                : null,
          ),
      scale: current && enabled
          ? clampReadingEmphasisScale(currentCharScale)
          : 1,
      isCurrent: current,
      isCurrentParagraph: currentParagraph,
      isRead: read,
    );
  }

  Object paintKey(ReadingTextLayout layout) => (
    continuous || layout.graphemes.isEmpty
        ? -1
        : currentIndex.clamp(
            layout.graphemes.first.rawStart - 1,
            layout.graphemes.last.rawEnd + 1,
          ),
    // A paragraph can span several authored <br> lines. Its early line must
    // repaint when the cursor leaves the paragraph even though the clamped
    // per-line cursor was already past that line's last glyph.
    continuous || layout.graphemes.isEmpty
        ? false
        : layout.graphemes.first.paragraph!.containsRawIndex(currentIndex),
    continuous || layout.graphemes.isEmpty
        ? false
        : layout.graphemes.first.paragraph!.rawEnd < currentIndex,
    continuous,
    enabled,
    grayReadChars,
    highlightCurrentChar,
    underlineCurrentChar,
    textColor,
    currentCharColor,
    readCharColor,
    clampReadingEmphasisScale(currentCharScale),
  );
}

/// Native paragraphs are expensive objects. Reuse the individual glyph
/// painters across visible lines, with a hard cap independent of script length.
class ReadingGlyphPainterCache {
  final int capacity;
  final _painters =
      LinkedHashMap<(String, TextStyle, TextDirection), TextPainter>();

  ReadingGlyphPainterCache({this.capacity = 1024}) : assert(capacity > 0);

  TextPainter painterFor(
    String text,
    TextStyle style,
    TextDirection direction,
  ) {
    final key = (text, style, direction);
    final cached = _painters.remove(key);
    if (cached != null) {
      _painters[key] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: TextScaler.noScaling,
    )..layout();
    if (_painters.length >= capacity) {
      _painters.remove(_painters.keys.first)?.dispose();
    }
    _painters[key] = painter;
    return painter;
  }

  @visibleForTesting
  int get length => _painters.length;

  void dispose() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }
}

class ReadingTextPainter extends CustomPainter {
  final ReadingTextLayout layout;
  final ReadingTextPresentation presentation;
  final ReadingGlyphPainterCache glyphCache;
  final ScrollController? scrollController;
  final double contentTop;
  final double viewportHeight;

  @visibleForTesting
  int debugLastPaintedGlyphCount = 0;

  ReadingTextPainter({
    required this.layout,
    required this.presentation,
    required this.glyphCache,
    this.scrollController,
    this.contentTop = 0,
    this.viewportHeight = double.infinity,
  }) : super(
         // Ordinary short paragraphs keep their cached layer while scrolling.
         // A huge unbroken paragraph instead redraws only a bounded viewport
         // window, so it cannot repaint the entire manuscript for every word.
         repaint: layout.height > viewportHeight * 2 ? scrollController : null,
       );

  @override
  void paint(Canvas canvas, Size size) {
    var clip = canvas.getLocalClipBounds().intersect(Offset.zero & size);
    final controller = scrollController;
    if (layout.height > viewportHeight * 2 &&
        controller != null &&
        controller.hasClients) {
      final overscan = viewportHeight / 2;
      clip = clip.intersect(
        Rect.fromLTWH(
          0,
          controller.offset - contentTop - overscan,
          size.width,
          viewportHeight + overscan * 2,
        ),
      );
    }
    debugLastPaintedGlyphCount = 0;
    canvas.save();
    canvas.clipRect(clip);
    for (final placement in layout.placementsIn(clip)) {
      debugLastPaintedGlyphCount++;
      final glyph = placement.grapheme;
      if (glyph.format.backgroundColor case final int background) {
        canvas.drawRect(
          placement.cell,
          Paint()..color = Color(background).withValues(alpha: 0.3),
        );
      }
      final appearance = presentation.appearanceFor(glyph, layout.geometry);
      final painter = glyphCache.painterFor(
        glyph.text,
        appearance.style,
        layout.direction,
      );
      final scale = appearance.scale;
      final baseline = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      // There is exactly ONE glyph draw, not an enlarged copy over a normal
      // glyph. The fixed ink-envelope anchor and baseline remain unchanged at
      // every scale; advance-centering alone would push synthetic italics into
      // their right-hand neighbour.
      canvas.save();
      canvas.translate(
        placement.paintAnchorX - painter.width * scale / 2,
        placement.row.baseline - baseline * scale,
      );
      canvas.scale(scale);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ReadingTextPainter oldDelegate) =>
      !identical(layout, oldDelegate.layout) ||
      scrollController != oldDelegate.scrollController ||
      contentTop != oldDelegate.contentTop ||
      viewportHeight != oldDelegate.viewportHeight ||
      presentation.paintKey(layout) !=
          oldDelegate.presentation.paintKey(oldDelegate.layout);
}

/// One widget per logical paragraph, never one widget per character.
class ReadingEmphasisLine extends StatefulWidget {
  final ScriptLine line;
  final ReadingTextGeometry geometry;
  final ReadingTextPresentation presentation;
  final ReadingGlyphPainterCache glyphCache;
  final double width;
  final TextDirection direction;
  final ValueChanged<int>? onCharTap;
  final ScrollController? scrollController;
  final double contentTop;
  final double viewportHeight;

  const ReadingEmphasisLine({
    super.key,
    required this.line,
    required this.geometry,
    required this.presentation,
    required this.glyphCache,
    required this.width,
    required this.direction,
    this.onCharTap,
    this.scrollController,
    this.contentTop = 0,
    this.viewportHeight = double.infinity,
  });

  @override
  State<ReadingEmphasisLine> createState() => ReadingEmphasisLineState();
}

class ReadingEmphasisLineState extends State<ReadingEmphasisLine> {
  late ReadingTextLayout _layout;
  int _layoutBuildCount = 0;

  @visibleForTesting
  ReadingTextLayout get debugLayout => _layout;
  @visibleForTesting
  int get debugLayoutBuildCount => _layoutBuildCount;

  void _createLayout() {
    _layout = ReadingTextLayout(
      line: widget.line,
      geometry: widget.geometry,
      width: widget.width,
      direction: widget.direction,
    );
    _layoutBuildCount++;
  }

  @override
  void initState() {
    super.initState();
    _createLayout();
  }

  @override
  void didUpdateWidget(ReadingEmphasisLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.line, oldWidget.line) ||
        widget.geometry != oldWidget.geometry ||
        widget.width != oldWidget.width ||
        widget.direction != oldWidget.direction) {
      _layout.dispose();
      _createLayout();
    }
  }

  @override
  void dispose() {
    _layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        final rawIndex = _layout.rawIndexForOffset(details.localPosition);
        if (rawIndex != null) widget.onCharTap?.call(rawIndex);
      },
      child: Semantics(
        label: widget.line.text,
        textDirection: widget.direction,
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size(widget.width, _layout.height),
            painter: ReadingTextPainter(
              layout: _layout,
              presentation: widget.presentation,
              glyphCache: widget.glyphCache,
              scrollController: widget.scrollController,
              contentTop: widget.contentTop,
              viewportHeight: widget.viewportHeight,
            ),
          ),
        ),
      ),
    ),
  );
}
