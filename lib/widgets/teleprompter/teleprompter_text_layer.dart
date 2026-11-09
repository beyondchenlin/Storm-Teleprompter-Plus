import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import '../../models/app_settings.dart';
import '../../models/reading_annotation.dart';
import '../../models/reading_annotation_style.dart';
import '../../models/script_character.dart';
import '../../theme/app_colors.dart';
import '../../utils/constants.dart';
import 'continuous_scroll_driver.dart';
import 'measured_line_delegate.dart';
import 'reading_emphasis_text.dart';
import 'reading_annotation_layer.dart';
import 'reading_area_frame.dart';

/// A line identity is local to its viewport, even when two previews share the
/// same parsed source. New key objects can resolve a mounted line without an
/// unbounded registry of keys for every line in a long manuscript.
class _ReadingLineKey extends GlobalObjectKey<ReadingEmphasisLineState> {
  final Object viewport;

  const _ReadingLineKey(super.value, this.viewport);

  @override
  bool operator ==(Object other) =>
      other is _ReadingLineKey &&
      identical(value, other.value) &&
      identical(viewport, other.viewport);

  @override
  int get hashCode =>
      Object.hash(identityHashCode(value), identityHashCode(viewport));
}

/// 提词器文本渲染层（懒加载 + 实际行高定位）。
///
/// - [SliverVariedExtentList] 只构建可见正文段落，控制大型稿件的控件数量。
/// - 按固定的最大突出空间缓存每个逻辑行的实际高度；当前字只影响绘制。
/// - 当前字滚动定位使用累计实际高度，避免长行换行、富文本字号、空行导致
///   当前字偏离阅读区域框中心行。
class TeleprompterTextLayer extends StatefulWidget {
  final ScrollController scrollController;
  final List<ScriptLine> lines;
  final int currentIndex;
  final double fontSize;
  final double lineHeight;
  final bool mirrorMode;
  final double paddingX;
  final double readingLineOffset;
  final double? readingLineY;
  final bool showReadingFrame;
  final double readingAreaBorderWidth;
  final bool autoFollow;
  final bool continuous;
  final bool isPlaying;
  final double pixelsPerSecond;
  final double? remoteProgress;
  final int seekRevision;
  final double seekProgress;
  final void Function(bool atStart)? onScrollBoundary;
  final ScrollPhysics? physics;
  final void Function(int rawIndex)? onCharTap;
  final void Function(int rawIndex)? onReadingLineChanged;

  final String teleprompterFontFamily;
  final bool grayReadChars;
  final int textColor;
  final double letterSpacing;
  final bool highlightCurrentChar;
  final bool defaultBold;
  final bool underlineCurrentChar;
  final bool readingEmphasisEnabled;
  final int currentCharColor;
  final int readCharColor;
  final double currentCharScale;
  final List<ReadingAnnotation> annotations;
  final bool showAnnotations;
  final ReadingAnnotationStyle annotationStyle;

  const TeleprompterTextLayer({
    super.key,
    required this.scrollController,
    required this.lines,
    required this.currentIndex,
    required this.fontSize,
    required this.lineHeight,
    required this.mirrorMode,
    this.autoFollow = false,
    this.continuous = false,
    this.isPlaying = false,
    this.pixelsPerSecond = 0,
    this.remoteProgress,
    this.seekRevision = 0,
    this.seekProgress = 0,
    this.onScrollBoundary,
    this.paddingX = 5.0,
    this.readingLineOffset = 0.5,
    this.readingLineY,
    this.showReadingFrame = false,
    this.readingAreaBorderWidth = 3,
    this.physics,
    this.onCharTap,
    this.onReadingLineChanged,
    this.teleprompterFontFamily = '',
    this.grayReadChars = true,
    this.textColor = 0,
    this.letterSpacing = 0.0,
    this.highlightCurrentChar = false,
    this.defaultBold = false,
    this.underlineCurrentChar = false,
    this.readingEmphasisEnabled = true,
    this.currentCharColor = AppSettings.defaultCurrentCharColor,
    this.readCharColor = AppSettings.defaultReadCharColor,
    this.currentCharScale = AppSettings.defaultCurrentCharScale,
    this.annotations = const [],
    this.showAnnotations = true,
    this.annotationStyle = const ReadingAnnotationStyle(),
  });

  @override
  State<TeleprompterTextLayer> createState() => TeleprompterTextLayerState();
}

/// 管理正文测量、按行定位和独立的匀速视口驱动。
class TeleprompterTextLayerState extends State<TeleprompterTextLayer>
    with SingleTickerProviderStateMixin {
  late final ContinuousScrollDriver _continuousDriver;

  @override
  void initState() {
    super.initState();
    _glyphCache.inkCache.addListener(_handleAnnotationInkChanged);
    _continuousDriver = ContinuousScrollDriver(
      vsync: this,
      controller: widget.scrollController,
      onBoundary: (atStart) => widget.onScrollBoundary?.call(atStart),
    );
    _updateContinuousDriver();
    _syncRemoteViewport();
  }

  /// 首帧和重连时均应用远程位置，布局完成后才读取滚动范围。
  void _syncRemoteViewport() {
    if (!widget.continuous || widget.remoteProgress == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scrollController.hasClients) {
        _jumpToOffset(
          widget.remoteProgress! *
              widget.scrollController.position.maxScrollExtent,
        );
      }
    });
  }

  /// 远程端由服务端同步视口，不独立积分以免逐渐漂移。
  void _updateContinuousDriver() {
    _continuousDriver.update(
      playing:
          widget.continuous &&
          widget.isPlaying &&
          widget.remoteProgress == null,
      speed: widget.pixelsPerSecond,
    );
  }

  @override
  void dispose() {
    _continuousDriver.dispose();
    _navigationLayout?.dispose();
    _glyphCache.inkCache.removeListener(_handleAnnotationInkChanged);
    _glyphCache.dispose();
    super.dispose();
  }

  static const double _lineVerticalPadding = 2.0;

  int _lastScrolledToIndex = -2;
  int _lastReportedReadingLine = -2;
  int _scrollRequestId = 0;
  bool _isProgrammaticScroll = false;

  bool _metricsDirty = true;
  double? _lastTextWidth;
  TextDirection? _lastTextDirection;
  final List<double> _lineHeights = <double>[];
  final List<double> _lineTops = <double>[];
  double _contentHeight = 0;
  final ReadingGlyphPainterCache _glyphCache = ReadingGlyphPainterCache();
  List<ScriptLine>? _indexedAnnotationLines;
  List<ReadingAnnotation>? _indexedAnnotations;
  List<List<ReadingAnnotation>> _lineAnnotations = const [];
  final Map<int, double> _annotationLeadingSpaces = {};
  bool _annotationTapHandled = false;
  ({
    ReadingEmphasisLineState state,
    Offset position,
    Duration time,
    int pointer,
  })?
  _annotationTapCandidate;
  bool _annotationPointerMoved = false;
  ReadingTextLayout? _navigationLayout;
  int _metricsBuildCount = 0;
  List<ScriptLine>? _intrinsicWidthLines;
  ReadingTextGeometry? _intrinsicWidthGeometry;
  TextDirection? _intrinsicWidthDirection;
  double _contentIntrinsicWidth = 0;
  int _intrinsicWidthBuildCount = 0;
  double _fontScale = 1;
  double? _lastFitScale;
  double _maximumRowHeight = 0;
  List<ScriptLine>? _profiledLines;
  double? _profiledFontSize;
  double _largestFontSize = 0;
  bool _hasItalicText = false;
  Size? _lastViewportSize;
  double? _lastRequestedReadingLineY;
  double _lastReadingLineY = 0;
  double _lastTopPadding = 0;
  bool _viewportRealignmentScheduled = false;
  ({int rawIndex, double fraction})? _pendingViewportAnchor;

  @visibleForTesting
  int get debugMetricsBuildCount => _metricsBuildCount;

  @visibleForTesting
  int get debugIntrinsicWidthBuildCount => _intrinsicWidthBuildCount;

  void _handleAnnotationInkChanged() {
    if (!mounted) return;
    // Neighbouring authored lines share existing trailing whitespace. Refresh
    // only this annotation borrowing cache: metrics, widths and scroll anchors
    // remain valid and must never be dirtied by asynchronous ink measurements.
    _annotationLeadingSpaces.clear();
    if (widget.annotations.isNotEmpty) setState(() {});
  }

  ReadingTextGeometry get _textGeometry => ReadingTextGeometry(
    fontSize: widget.fontSize,
    lineHeight: math.max(1.0, widget.lineHeight),
    letterSpacing: widget.letterSpacing,
    fontFamily: widget.teleprompterFontFamily,
    defaultBold: widget.defaultBold,
    fontScale: _fontScale,
  );

  ReadingTextPresentation get _textPresentation => ReadingTextPresentation(
    currentIndex: widget.currentIndex,
    continuous: widget.continuous,
    enabled: widget.readingEmphasisEnabled,
    grayReadChars: widget.grayReadChars,
    highlightCurrentChar: widget.highlightCurrentChar,
    underlineCurrentChar: widget.underlineCurrentChar,
    textColor: widget.textColor,
    currentCharColor: widget.currentCharColor,
    readCharColor: widget.readCharColor,
    currentCharScale: widget.currentCharScale,
  );

  @override
  void didUpdateWidget(TeleprompterTextLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.continuous && widget.seekRevision != oldWidget.seekRevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.scrollController.hasClients) {
          _jumpToOffset(
            widget.seekProgress *
                widget.scrollController.position.maxScrollExtent,
          );
        }
      });
    }
    _updateContinuousDriver();
    if (widget.remoteProgress != oldWidget.remoteProgress ||
        widget.continuous != oldWidget.continuous) {
      _syncRemoteViewport();
    }
    if (widget.continuous &&
        !oldWidget.continuous &&
        widget.remoteProgress == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.scrollController.hasClients)
          _jumpToOffset(widget.scrollController.offset);
      });
    }

    final metricsChanged =
        widget.lines != oldWidget.lines ||
        widget.fontSize != oldWidget.fontSize ||
        widget.lineHeight != oldWidget.lineHeight ||
        widget.letterSpacing != oldWidget.letterSpacing ||
        widget.paddingX != oldWidget.paddingX ||
        widget.defaultBold != oldWidget.defaultBold ||
        widget.teleprompterFontFamily != oldWidget.teleprompterFontFamily;

    if (metricsChanged) {
      _metricsDirty = true;
      _lastScrolledToIndex = -2;
      _lastReportedReadingLine = -2;
    }

    final indexChanged = widget.currentIndex != oldWidget.currentIndex;
    final offsetChanged =
        widget.readingLineOffset != oldWidget.readingLineOffset;

    if (!widget.continuous &&
        (indexChanged ||
            offsetChanged ||
            metricsChanged ||
            oldWidget.continuous)) {
      if (widget.currentIndex != _lastScrolledToIndex ||
          offsetChanged ||
          metricsChanged) {
        _lastScrolledToIndex = widget.currentIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToCurrentChar(animate: true);
            if (metricsChanged) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scrollToCurrentChar(animate: true);
              });
            }
          }
        });
      }
    }
  }

  double _minimumHorizontalPadding(double viewportWidth) {
    final isMobile = viewportWidth < LayoutConstants.compactBreakpoint;
    final basePadding = isMobile
        ? TeleprompterConstants.mobileHorizontalPadding
        : TeleprompterConstants.desktopHorizontalPadding;
    final extraPadding = viewportWidth * widget.paddingX / 100;
    // A saved wide-screen margin may not consume a narrow window's text area.
    final minimumTextWidth = math.min(
      math.max(0.0, viewportWidth - 24),
      math.max(96.0, widget.fontSize * readingEmphasisMaximumScale * 2),
    );
    return (basePadding + extraPadding)
        .clamp(0.0, math.max(0.0, (viewportWidth - minimumTextWidth) / 2))
        .toDouble();
  }

  double _maximumTextWidthForViewport(double viewportWidth) {
    final horizontalPadding = _minimumHorizontalPadding(viewportWidth);
    return (viewportWidth - horizontalPadding * 2)
        .clamp(0.0, viewportWidth)
        .toDouble();
  }

  double _textWidthForViewport(double viewportWidth) {
    final maximum = _maximumTextWidthForViewport(viewportWidth);
    if (_contentIntrinsicWidth <= 0) return maximum;
    // A small rounding allowance prevents a native paragraph from wrapping
    // its last glyph at its own fractional intrinsic width. The side guide
    // supplies the remaining breathing room outside the text column.
    return math.min(maximum, _contentIntrinsicWidth.ceilToDouble() + 2);
  }

  double _horizontalPadding(double viewportWidth) =>
      math.max(0.0, (viewportWidth - _textWidthForViewport(viewportWidth)) / 2);

  /// Share one content-derived column across the entire manuscript. A manual
  /// line is measured without wrapping, not joined with the other manual
  /// lines in its paragraph. Current glyph, reading colour and microphone
  /// events never invalidate this cache; ordinary window-width changes only
  /// clamp its result and do not remeasure the unwrapped manuscript.
  void _ensureIntrinsicWidth(TextDirection textDirection) {
    final geometry = _textGeometry;
    if (identical(_intrinsicWidthLines, widget.lines) &&
        _intrinsicWidthGeometry == geometry &&
        _intrinsicWidthDirection == textDirection) {
      return;
    }

    var widest = 0.0;
    for (final line in widget.lines) {
      if (line.characters.isEmpty || line.text.trim().isEmpty) continue;
      final layout = ReadingTextLayout(
        line: line,
        geometry: geometry,
        width: double.infinity,
        direction: textDirection,
      );
      // Reuse precisely the mixed-style, italic-safe and maximum-emphasis
      // cells that are used for painting and hit testing, not character count
      // times nominal font size. Each temporary native layout is released.
      widest = math.max(widest, layout.maxIntrinsicWidth);
      layout.dispose();
    }
    _contentIntrinsicWidth = widest;
    _intrinsicWidthLines = widget.lines;
    _intrinsicWidthGeometry = geometry;
    _intrinsicWidthDirection = textDirection;
    _intrinsicWidthBuildCount++;
  }

  double _effectiveReadingLineRatio(double viewportWidth) {
    if (widget.readingLineOffset > 0) {
      return widget.readingLineOffset.clamp(0.0, 1.0).toDouble();
    }
    return viewportWidth < LayoutConstants.compactBreakpoint
        ? TeleprompterConstants.readingLineRatioMobile
        : TeleprompterConstants.readingLineRatioDesktop;
  }

  double _topPad(double viewportHeight) => widget.continuous
      ? viewportHeight * (TeleprompterConstants.topPaddingVh / 100)
      : math.max(
          viewportHeight * (TeleprompterConstants.topPaddingVh / 100),
          _readingLineY(viewportHeight, _lastViewportSize?.width ?? 0),
        );

  double _bottomPad(double viewportHeight) => widget.continuous
      ? viewportHeight * (TeleprompterConstants.bottomPaddingVh / 100)
      : math.max(
          viewportHeight * (TeleprompterConstants.bottomPaddingVh / 100),
          viewportHeight -
              _readingLineY(viewportHeight, _lastViewportSize?.width ?? 0),
        );

  double _readingLineY(double viewportHeight, double viewportWidth) {
    final requested =
        widget.readingLineY ??
        viewportHeight * _effectiveReadingLineRatio(viewportWidth);
    final inset = math.min(viewportHeight / 2, _maximumRowHeight / 2 + 4);
    return requested
        .clamp(inset, math.max(inset, viewportHeight - inset))
        .toDouble();
  }

  /// Actual padding for the page's progress calculation after a viewport resize.
  double get topPadding => _topPad(_lastViewportSize?.height ?? 0);
  double get bottomPadding => _bottomPad(_lastViewportSize?.height ?? 0);

  double _fitFontScale(double textWidth, double viewportHeight) {
    if (!identical(_profiledLines, widget.lines) ||
        _profiledFontSize != widget.fontSize) {
      _largestFontSize = widget.fontSize;
      _hasItalicText = false;
      for (final line in widget.lines) {
        for (final char in line.characters) {
          _largestFontSize = math.max(
            _largestFontSize,
            char.fontSizePx ?? widget.fontSize * (char.fontSizeRatio ?? 1),
          );
          _hasItalicText = _hasItalicText || char.italic;
        }
      }
      _profiledLines = widget.lines;
      _profiledFontSize = widget.fontSize;
    }
    final reservedFont =
        math.max(1.0, _largestFontSize) * readingEmphasisMaximumScale;
    final heightScale =
        math.max(1.0, viewportHeight - 12) /
        (reservedFont * math.max(1.2, widget.lineHeight) + 4);
    final widthScale =
        math.max(1.0, textWidth) /
        (reservedFont * (_hasItalicText ? 1.8 : 1.35) +
            math.max(0.0, widget.letterSpacing));
    return math.min(1.0, math.min(heightScale, widthScale));
  }

  Rect? _rowRectForRawIndex(int rawIndex) {
    if (widget.lines.isEmpty || _lastTextWidth == null) return null;
    final lineIndex = _findLineForRawIndex(rawIndex);
    final line = widget.lines[lineIndex];
    if (line.characters.isEmpty) return null;
    final row = _layoutForLine(
      line,
      _lastTextWidth!,
      _lastTextDirection!,
    ).placementForRawIndex(rawIndex)!.row;
    return Rect.fromLTWH(
      0,
      _lineTops[lineIndex] + _lineVerticalPadding + row.top,
      _lastTextWidth!,
      row.height,
    );
  }

  @visibleForTesting
  Rect? get debugCurrentRowRect {
    final row = _rowRectForRawIndex(widget.currentIndex);
    if (row == null || !widget.scrollController.hasClients) return null;
    return row.shift(
      Offset(
        _horizontalPadding(_lastViewportSize!.width),
        topPadding - widget.scrollController.offset,
      ),
    );
  }

  ({int rawIndex, double fraction})? _captureViewportAnchor() {
    if (_lastViewportSize == null ||
        !widget.scrollController.hasClients ||
        _lastTextWidth == null ||
        _lineTops.isEmpty)
      return null;
    final contentY =
        widget.scrollController.offset + _lastReadingLineY - _lastTopPadding;
    final rawIndex = _rawIndexForContentOffset(
      contentY,
      _lastTextWidth!,
      _lastTextDirection!,
      0,
    );
    if (rawIndex == null) return null;
    final row = _rowRectForRawIndex(rawIndex)!;
    return (
      rawIndex: rawIndex,
      fraction: ((contentY - row.top) / row.height).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _scheduleViewportRealignment(({int rawIndex, double fraction})? anchor) {
    _pendingViewportAnchor = anchor ?? _pendingViewportAnchor;
    if (_viewportRealignmentScheduled) return;
    _viewportRealignmentScheduled = true;
    _isProgrammaticScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportRealignmentScheduled = false;
      if (!mounted || !widget.scrollController.hasClients) return;
      final anchor = _pendingViewportAnchor;
      _pendingViewportAnchor = null;
      if (!widget.continuous) {
        _scrollToCurrentChar(animate: false);
      } else if (widget.remoteProgress != null) {
        _jumpToOffset(
          widget.remoteProgress! *
              widget.scrollController.position.maxScrollExtent,
        );
      } else if (anchor != null) {
        final row = _rowRectForRawIndex(anchor.rawIndex);
        if (row != null) {
          _jumpToOffset(
            (topPadding +
                    row.top +
                    row.height * anchor.fraction -
                    _lastReadingLineY)
                .clamp(0.0, widget.scrollController.position.maxScrollExtent)
                .toDouble(),
          );
        }
      }
      _isProgrammaticScroll = false;
    });
  }

  int _findLineForRawIndex(int rawIndex) {
    if (rawIndex < 0 || widget.lines.isEmpty) return 0;

    var lastNonEmpty = 0;
    for (var i = 0; i < widget.lines.length; i++) {
      final chars = widget.lines[i].characters;
      if (chars.isEmpty) continue;

      lastNonEmpty = i;
      if (rawIndex <= chars.last.rawIndex) return i;
    }
    return lastNonEmpty;
  }

  ReadingTextLayout _layoutForLine(
    ScriptLine line,
    double textWidth,
    TextDirection textDirection,
  ) {
    final existing = _navigationLayout;
    final geometry = _textGeometry;
    if (existing != null &&
        identical(existing.line, line) &&
        existing.width == textWidth &&
        existing.direction == textDirection &&
        existing.geometry == geometry) {
      return existing;
    }
    existing?.dispose();
    return _navigationLayout = ReadingTextLayout(
      line: line,
      geometry: geometry,
      width: textWidth,
      direction: textDirection,
    );
  }

  double _visualRowCenterForRawIndex(
    int lineIndex,
    int rawIndex,
    double textWidth,
    TextDirection textDirection,
  ) {
    final line = widget.lines[lineIndex];
    if (line.characters.isEmpty) return _lineHeights[lineIndex] / 2;
    final layout = _layoutForLine(line, textWidth, textDirection);
    return (layout.placementForRawIndex(rawIndex)!.row.centerY +
            _lineVerticalPadding)
        .clamp(0.0, _lineHeights[lineIndex])
        .toDouble();
  }

  /// The measured current visual row, including the paragraph's small padding.
  /// Mixed-size manuscript text can be taller than the ordinary-body estimate.
  double get currentVisualRowHeight {
    if (widget.lines.isEmpty || _lastTextWidth == null) {
      return _textGeometry.emptyHeight + _lineVerticalPadding * 2;
    }
    final line = widget.lines[_findLineForRawIndex(widget.currentIndex)];
    if (line.characters.isEmpty) {
      return _textGeometry.emptyHeight + _lineVerticalPadding * 2;
    }
    return _layoutForLine(
          line,
          _lastTextWidth!,
          _lastTextDirection!,
        ).placementForRawIndex(widget.currentIndex)!.row.height +
        _lineVerticalPadding * 2;
  }

  void _ensureLineMetrics(double textWidth, TextDirection textDirection) {
    final widthChanged =
        _lastTextWidth == null || (_lastTextWidth! - textWidth).abs() > 0.5;
    final directionChanged = _lastTextDirection != textDirection;

    if (!_metricsDirty &&
        !widthChanged &&
        !directionChanged &&
        _lineHeights.length == widget.lines.length) {
      return;
    }

    _navigationLayout?.dispose();
    _navigationLayout = null;
    _metricsBuildCount++;
    _lineHeights.clear();
    _lineTops.clear();
    _annotationLeadingSpaces.clear();
    _maximumRowHeight = 0;

    var cursor = 0.0;
    for (final line in widget.lines) {
      _lineTops.add(cursor);
      final height = _measureLineHeight(line, textWidth, textDirection);
      _lineHeights.add(height);
      cursor += height;
    }

    _contentHeight = cursor;
    _lastTextWidth = textWidth;
    _lastTextDirection = textDirection;
    _metricsDirty = false;
  }

  double _measureLineHeight(
    ScriptLine line,
    double textWidth,
    TextDirection textDirection,
  ) {
    if (line.characters.isEmpty) {
      final height = _textGeometry.emptyHeight + _lineVerticalPadding * 2;
      _maximumRowHeight = math.max(_maximumRowHeight, height);
      return height;
    }
    final layout = ReadingTextLayout(
      line: line,
      geometry: _textGeometry,
      width: textWidth,
      direction: textDirection,
    );
    final height = layout.height + _lineVerticalPadding * 2;
    for (final row in layout.rows) {
      _maximumRowHeight = math.max(
        _maximumRowHeight,
        row.height + _lineVerticalPadding * 2,
      );
    }
    layout.dispose();
    return height;
  }

  int _findLineForContentOffset(double contentOffset) {
    if (_lineTops.isEmpty) return 0;

    final target = contentOffset
        .clamp(0.0, _contentHeight <= 0 ? 0.0 : _contentHeight)
        .toDouble();
    var low = 0;
    var high = _lineTops.length - 1;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final top = _lineTops[mid];
      final bottom = top + _lineHeights[mid];

      if (target < top) {
        high = mid - 1;
      } else if (target >= bottom) {
        low = mid + 1;
      } else {
        return mid;
      }
    }

    return low.clamp(0, _lineTops.length - 1).toInt();
  }

  int? _rawIndexForContentOffset(
    double contentOffset,
    double textWidth,
    TextDirection textDirection,
    double x,
  ) {
    if (widget.lines.isEmpty || _lineTops.isEmpty) return null;

    final lineIndex = _findLineForContentOffset(contentOffset);
    final line = widget.lines[lineIndex];
    if (line.characters.isEmpty) return null;

    final layout = _layoutForLine(line, textWidth, textDirection);
    final localY = (contentOffset - _lineTops[lineIndex] - _lineVerticalPadding)
        .clamp(0.0, layout.height)
        .toDouble();
    return layout.rawIndexForOffset(
      Offset(x.clamp(0.0, textWidth).toDouble(), localY),
    );
  }

  /// 把匀速模式当前视口中心映射为按行模式的恢复锚点。
  int? rawIndexAtViewport() {
    if (!widget.scrollController.hasClients) return null;
    final position = widget.scrollController.position;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    return _rawIndexForContentOffset(
      position.pixels +
          _readingLineY(position.viewportDimension, width) -
          _topPad(position.viewportDimension),
      _textWidthForViewport(width),
      Directionality.of(context),
      0,
    );
  }

  int? rawIndexForVisualLineMove(int direction) {
    if (direction == 0 || widget.lines.isEmpty) return null;

    final viewportWidth =
        context.size?.width ?? MediaQuery.of(context).size.width;
    final textWidth = _textWidthForViewport(viewportWidth);
    final textDirection = Directionality.of(context);
    _ensureLineMetrics(textWidth, textDirection);
    if (_lineHeights.isEmpty) return null;

    if (widget.currentIndex < 0) {
      for (final line in widget.lines) {
        if (line.characters.isNotEmpty) return line.characters.first.rawIndex;
      }
      return null;
    }

    final currentLine = _findLineForRawIndex(widget.currentIndex);
    final safeLine = currentLine.clamp(0, _lineHeights.length - 1).toInt();
    final line = widget.lines[safeLine];
    if (line.characters.isEmpty) return null;

    var layout = _layoutForLine(line, textWidth, textDirection);
    final placement = layout.placementForRawIndex(widget.currentIndex)!;
    final currentX = placement.cell.center.dx;
    var targetRow = layout.rows.indexOf(placement.row) + direction;
    var targetLine = safeLine;
    final step = direction.sign;

    // 按实际可视行累计完整步数，字号和段落行高不影响行数。
    // 空段没有可定位的字符；到达稿件边界时停在首末可读行。
    while (targetRow < 0 || targetRow >= layout.rows.length) {
      var nextLine = targetLine + step;
      while (nextLine >= 0 &&
          nextLine < widget.lines.length &&
          widget.lines[nextLine].characters.isEmpty) {
        nextLine += step;
      }
      if (nextLine < 0 || nextLine >= widget.lines.length) {
        targetRow = targetRow.clamp(0, layout.rows.length - 1).toInt();
        break;
      }

      if (step > 0) targetRow -= layout.rows.length;
      targetLine = nextLine;
      layout = _layoutForLine(
        widget.lines[targetLine],
        textWidth,
        textDirection,
      );
      if (step < 0) targetRow += layout.rows.length;
    }
    return layout.rawIndexForOffset(
      Offset(currentX, layout.rows[targetRow].centerY),
    );
  }

  void scrollToCurrentChar({bool animate = true}) {
    _scrollToCurrentChar(animate: animate);
  }

  void _animateToOffset(double targetOffset, Duration duration) {
    if (!widget.scrollController.hasClients) return;

    final requestId = ++_scrollRequestId;
    _isProgrammaticScroll = true;

    unawaited(
      widget.scrollController
          .animateTo(
            targetOffset,
            duration: duration,
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted || requestId != _scrollRequestId) return;
            _isProgrammaticScroll = false;
          }),
    );
  }

  void _jumpToOffset(double targetOffset) {
    if (!widget.scrollController.hasClients) return;

    _scrollRequestId++;
    _isProgrammaticScroll = true;
    widget.scrollController.jumpTo(targetOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _isProgrammaticScroll = false;
    });
  }

  void _scrollToCurrentChar({bool animate = true}) {
    if (widget.continuous) return;
    if (!widget.scrollController.hasClients) return;

    final pos = widget.scrollController.position;
    final viewportHeight = pos.viewportDimension;
    final viewportWidth =
        context.size?.width ?? MediaQuery.of(context).size.width;
    final maxScroll = pos.maxScrollExtent;

    if (widget.currentIndex < 0 || widget.lines.isEmpty) {
      if (animate) {
        _animateToOffset(0, const Duration(milliseconds: 200));
      } else {
        _jumpToOffset(0);
      }
      return;
    }

    final textWidth = _textWidthForViewport(viewportWidth);
    final textDirection = Directionality.of(context);
    _ensureLineMetrics(textWidth, textDirection);
    if (_lineHeights.isEmpty) return;

    final targetLine = _findLineForRawIndex(widget.currentIndex);
    final safeLine = targetLine.clamp(0, _lineHeights.length - 1).toInt();
    final rowCenter =
        _topPad(viewportHeight) +
        _lineTops[safeLine] +
        _visualRowCenterForRawIndex(
          safeLine,
          widget.currentIndex,
          textWidth,
          textDirection,
        );
    final targetOffset =
        (rowCenter - _readingLineY(viewportHeight, viewportWidth))
            .clamp(0.0, maxScroll)
            .toDouble();

    final currentOffset = pos.pixels;
    final offsetDelta = (targetOffset - currentOffset).abs();
    if (offsetDelta <= 0.5) return;

    final shouldAnimate = animate;

    if (shouldAnimate) {
      _animateToOffset(
        targetOffset,
        Duration(milliseconds: widget.autoFollow ? 150 : 190),
      );
    } else {
      _jumpToOffset(targetOffset);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (widget.continuous ||
        _isProgrammaticScroll ||
        widget.onReadingLineChanged == null) {
      return false;
    }
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification &&
        notification is! UserScrollNotification) {
      return false;
    }

    final viewportHeight = notification.metrics.viewportDimension;
    final viewportWidth =
        context.size?.width ?? MediaQuery.of(context).size.width;
    final contentY =
        notification.metrics.pixels +
        _readingLineY(viewportHeight, viewportWidth) -
        _topPad(viewportHeight);
    final textWidth = _textWidthForViewport(viewportWidth);
    final lineIndex = _findLineForContentOffset(contentY);
    final rawIndex = _rawIndexForContentOffset(
      contentY,
      textWidth,
      Directionality.of(context),
      0,
    );

    final isScrollEnd =
        notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle);
    if (rawIndex == null) return false;

    if (lineIndex == _lastReportedReadingLine &&
        rawIndex == widget.currentIndex &&
        !isScrollEnd) {
      return false;
    }

    if (rawIndex == widget.currentIndex) {
      if (isScrollEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToCurrentChar();
        });
      }
      return false;
    }

    _lastReportedReadingLine = lineIndex;
    _lastScrolledToIndex = isScrollEnd ? -2 : rawIndex;
    _scrollRequestId++;
    _isProgrammaticScroll = false;
    widget.onReadingLineChanged?.call(rawIndex);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    _ensureAnnotationIndex();
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screenWidth;
        final viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : screenHeight;
        final maximumTextWidth = _maximumTextWidthForViewport(viewportWidth);
        final textDirection = Directionality.of(context);
        final size = Size(viewportWidth, viewportHeight);
        final viewportChanged =
            size != _lastViewportSize ||
            widget.readingLineY != _lastRequestedReadingLineY;
        final anchor = widget.continuous && viewportChanged && !_metricsDirty
            ? _captureViewportAnchor()
            : null;
        // Fit only against the actual window limit, never the content-derived
        // column: a short line must not shrink its own saved font size.
        final nextScale = _fitFontScale(maximumTextWidth, viewportHeight);
        if (_lastFitScale != nextScale ||
            size != _lastViewportSize ||
            _metricsDirty) {
          if (_fontScale != nextScale) {
            _fontScale = nextScale;
            _metricsDirty = true;
          }
          _lastFitScale = nextScale;
        }
        _ensureIntrinsicWidth(textDirection);
        var textWidth = _textWidthForViewport(viewportWidth);
        _ensureLineMetrics(textWidth, textDirection);
        // Include real fallback-font metrics, not just a nominal font-size
        // estimate, when a very short window cannot contain one expanded row.
        final availableRowHeight = math.max(1.0, viewportHeight - 8);
        if (_maximumRowHeight > availableRowHeight) {
          _fontScale *= availableRowHeight / _maximumRowHeight * 0.98;
          _metricsDirty = true;
          _ensureIntrinsicWidth(textDirection);
          textWidth = _textWidthForViewport(viewportWidth);
          _ensureLineMetrics(textWidth, textDirection);
        }
        final horizontalPadding = _horizontalPadding(viewportWidth);
        _lastViewportSize = size;
        _lastRequestedReadingLineY = widget.readingLineY;
        _lastReadingLineY = _readingLineY(viewportHeight, viewportWidth);
        _lastTopPadding = _topPad(viewportHeight);
        if (viewportChanged) _scheduleViewportRealignment(anchor);

        return Listener(
          onPointerDown: _handleAnnotationPointerDown,
          onPointerMove: _handleAnnotationPointerMove,
          onPointerUp: _handleAnnotationPointerUp,
          onPointerCancel: (_) {
            _annotationTapCandidate = null;
            _annotationTapHandled = false;
          },
          child: ClipRect(
            child: Transform(
              alignment: Alignment.center,
              transform: widget.mirrorMode
                  ? (Matrix4.identity()..setEntry(0, 0, -1.0))
                  : Matrix4.identity(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleScrollNotification,
                      child: CustomScrollView(
                        controller: widget.scrollController,
                        // 播放中的滚动模式始终由速度控制，零速不能通过拖动改变位置。
                        physics: widget.continuous && widget.isPlaying
                            ? const NeverScrollableScrollPhysics()
                            : widget.physics ?? const ClampingScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: SizedBox(height: _topPad(viewportHeight)),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(
                              horizontal: horizontalPadding,
                            ),
                            sliver: widget.lines.isEmpty
                                ? SliverToBoxAdapter(
                                    child: Center(
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          top: viewportHeight * 0.2,
                                        ),
                                        child: const Text(
                                          '暂无内容',
                                          style: TextStyle(
                                            color: AppColors.textDisabled,
                                            fontSize: 18,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : SliverVariedExtentList(
                                    itemExtentBuilder: (index, dimensions) =>
                                        _lineHeights[index],
                                    delegate: MeasuredLineDelegate(
                                      (context, index) => _buildLine(
                                        index,
                                        textWidth,
                                        viewportHeight,
                                      ),
                                      count: widget.lines.length,
                                      contentHeight: _contentHeight,
                                    ),
                                  ),
                          ),
                          SliverToBoxAdapter(
                            child: SizedBox(height: _bottomPad(viewportHeight)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.showReadingFrame && !widget.continuous)
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: widget.scrollController,
                        builder: (context, _) {
                          final row = debugCurrentRowRect;
                          return row == null
                              ? const SizedBox.shrink()
                              : ReadingAreaFrame(
                                  key: const ValueKey('reading-area-frame'),
                                  row: row,
                                  borderWidth: widget.readingAreaBorderWidth,
                                );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLine(int index, double textWidth, double viewportHeight) {
    final line = widget.lines[index];
    if (line.characters.isEmpty) {
      return SizedBox(
        height: _textGeometry.emptyHeight + _lineVerticalPadding * 2,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _lineVerticalPadding),
      child: ReadingEmphasisLine(
        key: _ReadingLineKey(line, this),
        line: line,
        geometry: _textGeometry,
        presentation: _textPresentation,
        glyphCache: _glyphCache,
        width: textWidth,
        direction: Directionality.of(context),
        onCharTap: (rawIndex) {
          if (!_annotationTapHandled) widget.onCharTap?.call(rawIndex);
        },
        scrollController: widget.scrollController,
        contentTop:
            _topPad(viewportHeight) + _lineTops[index] + _lineVerticalPadding,
        viewportHeight: viewportHeight,
        annotations: _lineAnnotations[index],
        showAnnotations: widget.showAnnotations,
        annotationStyle: widget.annotationStyle,
        annotationLeadingSpace:
            !widget.showAnnotations || _lineAnnotations[index].isEmpty
            ? 0
            : _annotationLeadingSpace(index, textWidth, viewportHeight),
        handleAnnotationLabelTaps: false,
      ),
    );
  }

  void _handleAnnotationPointerDown(PointerDownEvent event) {
    _annotationTapHandled = false;
    _annotationTapCandidate = null;
    _annotationPointerMoved = false;
    if (!widget.showAnnotations ||
        widget.annotations.isEmpty ||
        event.buttons != kPrimaryButton ||
        !widget.scrollController.hasClients ||
        _lineTops.isEmpty)
      return;
    final render = context.findRenderObject();
    if (render is! RenderBox) return;
    final local = render.globalToLocal(event.position);
    final contentY =
        local.dy + widget.scrollController.offset - _lastTopPadding;
    final current = _findLineForContentOffset(contentY);
    // A following line borrows only its immediate predecessor's empty space.
    for (
      var index = current;
      index <= current + 1 && index < widget.lines.length;
      index++
    ) {
      final state = _ReadingLineKey(widget.lines[index], this).currentState;
      final box = state?.context.findRenderObject();
      if (state != null &&
          box is RenderBox &&
          state
              .annotationsAt(
                box.globalToLocal(event.position),
                labelsOnly: true,
              )
              .isNotEmpty) {
        _annotationTapHandled = true;
        _annotationTapCandidate = (
          state: state,
          position: event.position,
          time: event.timeStamp,
          pointer: event.pointer,
        );
        return;
      }
    }
  }

  void _handleAnnotationPointerMove(PointerMoveEvent event) {
    final candidate = _annotationTapCandidate;
    if (candidate != null &&
        candidate.pointer == event.pointer &&
        (event.position - candidate.position).distance > kTouchSlop) {
      _annotationPointerMoved = true;
    }
  }

  void _handleAnnotationPointerUp(PointerUpEvent event) {
    final candidate = _annotationTapCandidate;
    if (candidate == null || candidate.pointer != event.pointer) return;
    _annotationTapCandidate = null;
    if (_annotationPointerMoved ||
        !candidate.state.mounted ||
        event.timeStamp - candidate.time >= kLongPressTimeout)
      return;
    final box = candidate.state.context.findRenderObject();
    if (box is RenderBox) {
      candidate.state.openAnnotationLabelAt(box.globalToLocal(event.position));
    }
  }

  /// Resolve note intervals to authored lines once. A cursor or visibility
  /// update must not scan all notes for every visible line, or dirty metrics.
  void _ensureAnnotationIndex() {
    if (identical(_indexedAnnotationLines, widget.lines) &&
        identical(_indexedAnnotations, widget.annotations))
      return;
    _indexedAnnotationLines = widget.lines;
    _indexedAnnotations = widget.annotations;
    final nonEmpty = <int>[
      for (var i = 0; i < widget.lines.length; i++)
        if (widget.lines[i].characters.isNotEmpty) i,
    ];
    final notes = List.generate(
      widget.lines.length,
      (_) => <ReadingAnnotation>{},
    );
    for (final note in widget.annotations) {
      if (!note.isAnchored) continue;
      for (final range in note.ranges) {
        if (range.start >= range.end) continue;
        var low = 0;
        var high = nonEmpty.length;
        while (low < high) {
          final middle = (low + high) >> 1;
          final last = widget.lines[nonEmpty[middle]].characters.last;
          if (last.rawIndex + last.char.length <= range.start) {
            low = middle + 1;
          } else {
            high = middle;
          }
        }
        for (var i = low; i < nonEmpty.length; i++) {
          final index = nonEmpty[i];
          if (widget.lines[index].characters.first.rawIndex >= range.end) break;
          notes[index].add(note);
        }
      }
    }
    _lineAnnotations = [
      for (final lineNotes in notes)
        lineNotes.isEmpty
            ? const <ReadingAnnotation>[]
            : List<ReadingAnnotation>.unmodifiable(lineNotes),
    ];
  }

  double _annotationLeadingSpace(
    int index,
    double textWidth,
    double viewportHeight,
  ) {
    if (widget.annotationStyle.preferredFontSizeFor(
          _largestFontSize * _fontScale,
        ) <
        ReadingAnnotationStyle.minimumFontSize)
      return 0;
    // The first line borrows from the existing scroll padding. Recompute it
    // after viewport/reading-line changes; no new padding is ever introduced.
    final cap = _textGeometry.fontSize * _textGeometry.fontScale * 1.2;
    if (index == 0) {
      return math.min(
        cap,
        math.max(0, _topPad(viewportHeight) + _lineVerticalPadding),
      );
    }
    return _annotationLeadingSpaces.putIfAbsent(index, () {
      final previous = widget.lines[index - 1];
      final direction = Directionality.of(context);
      final blank = previous.characters.isEmpty
          ? _textGeometry.emptyHeight
          : _ReadingLineKey(
                  previous,
                  this,
                ).currentState?.annotationTrailingSpaceFor(
                  geometry: _textGeometry,
                  width: textWidth,
                  direction: direction,
                ) ??
                ReadingAnnotationLayout.trailingSpace(
                  _layoutForLine(previous, textWidth, direction),
                  _glyphCache,
                );
      return math.min(cap, blank + _lineVerticalPadding * 2);
    });
  }
}
