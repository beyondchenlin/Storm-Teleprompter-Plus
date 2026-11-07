import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../models/app_settings.dart';
import '../../models/script_character.dart';
import '../../theme/app_colors.dart';
import '../../utils/constants.dart';
import 'continuous_scroll_driver.dart';
import 'measured_line_delegate.dart';
import 'reading_emphasis_text.dart';
import 'reading_area_frame.dart';

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
  ReadingTextLayout? _navigationLayout;
  int _metricsBuildCount = 0;
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

  double _horizontalPadding(double viewportWidth) {
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

  double _textWidthForViewport(double viewportWidth) {
    final horizontalPadding = _horizontalPadding(viewportWidth);
    return (viewportWidth - horizontalPadding * 2)
        .clamp(0.0, viewportWidth)
        .toDouble();
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
        final horizontalPadding = _horizontalPadding(viewportWidth);
        final textWidth = _textWidthForViewport(viewportWidth);
        final size = Size(viewportWidth, viewportHeight);
        final viewportChanged =
            size != _lastViewportSize ||
            widget.readingLineY != _lastRequestedReadingLineY;
        final anchor = widget.continuous && viewportChanged && !_metricsDirty
            ? _captureViewportAnchor()
            : null;
        final nextScale = _fitFontScale(textWidth, viewportHeight);
        if (_lastFitScale != nextScale ||
            size != _lastViewportSize ||
            _metricsDirty) {
          if (_fontScale != nextScale) {
            _fontScale = nextScale;
            _metricsDirty = true;
          }
          _lastFitScale = nextScale;
        }
        _ensureLineMetrics(textWidth, Directionality.of(context));
        // Include real fallback-font metrics, not just a nominal font-size
        // estimate, when a very short window cannot contain one expanded row.
        final availableRowHeight = math.max(1.0, viewportHeight - 8);
        if (_maximumRowHeight > availableRowHeight) {
          _fontScale *= availableRowHeight / _maximumRowHeight * 0.98;
          _metricsDirty = true;
          _ensureLineMetrics(textWidth, Directionality.of(context));
        }
        _lastViewportSize = size;
        _lastRequestedReadingLineY = widget.readingLineY;
        _lastReadingLineY = _readingLineY(viewportHeight, viewportWidth);
        _lastTopPadding = _topPad(viewportHeight);
        if (viewportChanged) _scheduleViewportRealignment(anchor);

        return ClipRect(
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
        line: line,
        geometry: _textGeometry,
        presentation: _textPresentation,
        glyphCache: _glyphCache,
        width: textWidth,
        direction: Directionality.of(context),
        onCharTap: widget.onCharTap,
        scrollController: widget.scrollController,
        contentTop:
            _topPad(viewportHeight) + _lineTops[index] + _lineVerticalPadding,
        viewportHeight: viewportHeight,
      ),
    );
  }
}
