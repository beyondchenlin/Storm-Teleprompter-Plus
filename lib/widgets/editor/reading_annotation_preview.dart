import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/reading_annotation.dart';
import '../../models/reading_annotation_style.dart';
import '../../models/script_character.dart';
import '../../services/text_parser.dart';
import '../teleprompter/reading_emphasis_text.dart';
import '../teleprompter/reading_annotation_layer.dart';

typedef ReadingAnnotationPreviewStatus = ReadingAnnotationDisplayStatus;

/// A live excerpt using the same body and annotation painters as playback.
/// Source indices and rich-text formatting survive excerpting, so a preview
/// click edits the same anchored note that will appear during a reading.
class ReadingAnnotationPreview extends StatefulWidget {
  final String content;
  final List<ReadingAnnotation> annotations;
  final int? focusRawIndex;
  final double height;
  final ValueChanged<ReadingAnnotation>? onNoteTap;

  /// The active manuscript's appearance, including its background and body
  /// geometry. Omitted only by legacy callers that request the compact sample.
  final AppSettings? settings;
  final ValueChanged<ReadingAnnotationPreviewStatus>? onLayoutStatus;

  const ReadingAnnotationPreview({
    super.key,
    required this.content,
    required this.annotations,
    this.focusRawIndex,
    this.height = 230,
    this.onNoteTap,
    this.settings,
    this.onLayoutStatus,
  });

  @override
  State<ReadingAnnotationPreview> createState() =>
      _ReadingAnnotationPreviewState();
}

class _ReadingAnnotationPreviewState extends State<ReadingAnnotationPreview> {
  static const double _legacyFontSize = 48;
  static const double _legacyTopSpace = 64;
  final _lineKey = GlobalKey<ReadingEmphasisLineState>();
  final _glyphCache = ReadingGlyphPainterCache(capacity: 256);
  final _scrollController = ScrollController();
  String? _parsedContent;
  List<ScriptLine> _lines = const [];
  (ScriptLine, int, int)? _excerptKey;
  ScriptLine? _excerpt;
  ScriptLine? _precedingLine;
  bool _precedingIsAuthoredLine = false;
  ReadingTextLayout? _precedingLayout;
  bool _statusScheduled = false;
  ReadingAnnotationPreviewStatus? _reportedStatus;

  AppSettings get _settings => widget.settings ?? const AppSettings(
    fontSize: _legacyFontSize,
    lineHeight: 1.8,
    teleprompterFontFamily: '',
    defaultBold: false,
    currentCharScale: 1,
    currentCharColor: 0xFFFFE36C,
    grayReadChars: false,
  );

  ReadingTextGeometry get _geometry => ReadingTextGeometry(
    fontSize: _settings.fontSize,
    lineHeight: math.max(1, _settings.lineHeight),
    letterSpacing: _settings.letterSpacing,
    fontFamily: _settings.teleprompterFontFamily,
    defaultBold: _settings.defaultBold,
  );

  @override
  void initState() {
    super.initState();
    _glyphCache.inkCache.addListener(_onInkChanged);
  }

  @override
  void didUpdateWidget(ReadingAnnotationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An inline callback acquires a new identity on every parent setState.
    // Reset only for new preview inputs, otherwise status -> rebuild -> status
    // would schedule an endless series of frames in the appearance dialog.
    if (widget.settings != oldWidget.settings ||
        widget.content != oldWidget.content ||
        widget.focusRawIndex != oldWidget.focusRawIndex ||
        (oldWidget.onLayoutStatus == null && widget.onLayoutStatus != null)) {
      _reportedStatus = null;
    }
  }

  void _onInkChanged() {
    if (!mounted) return;
    // A preceding authored line can donate newly measured trailing whitespace.
    // The excerpt's body geometry itself stays unchanged.
    if (widget.settings != null && _precedingLayout != null) setState(() {});
    _scheduleStatus();
  }

  void _scheduleStatus() {
    if (_statusScheduled || widget.onLayoutStatus == null) return;
    _statusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _statusScheduled = false;
      if (!mounted) return;
      final status = _lineKey.currentState?.annotationDisplayStatus() ??
          const ReadingAnnotationPreviewStatus();
      if (status == _reportedStatus) return;
      _reportedStatus = status;
      widget.onLayoutStatus?.call(status);
    });
  }
  Duration? _pointerStarted;
  Offset? _pointerStartPosition;
  int? _activePointer;
  bool _pointerMoved = false;
  bool _primaryPointer = false;
  bool _noteOpened = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _precedingLayout?.dispose();
    _glyphCache.inkCache.removeListener(_onInkChanged);
    _glyphCache.dispose();
    super.dispose();
  }

  int _focus() {
    if (widget.focusRawIndex case final value?) return value;
    for (final note in widget.annotations) {
      if (note.isAnchored) return note.ranges.first.start;
    }
    return _lines.isEmpty || _lines.first.characters.isEmpty
        ? 0
        : _lines.first.characters.first.rawIndex;
  }

  ScriptLine? _excerptFor(int focus, double width) {
    if (_lines.isEmpty) return null;
    ScriptLine? source;
    for (final line in _lines) {
      if (line.characters.isEmpty) continue;
      source = line;
      final last = line.characters.last;
      if (focus < last.rawIndex + last.char.length) break;
    }
    if (source == null) return null;
    final columns = (width / (_settings.fontSize * readingEmphasisMaximumScale * 1.08))
        .floor()
        .clamp(2, 28)
        .toInt();
    final key = (source, focus, columns);
    if (_excerptKey == key) return _excerpt;
    _excerptKey = key;

    var localFocus = 0;
    for (final char in source.characters) {
      if (focus < char.rawIndex + char.char.length) {
        localFocus += (focus - char.rawIndex)
            .clamp(0, char.char.length)
            .toInt();
        break;
      }
      localFocus += char.char.length;
    }
    final before = math.min(4, math.max(1, columns ~/ 3));
    final maximumClusters = math.min(40, columns * 2);
    final window = ListQueue<(int, int)>();
    var offset = 0;
    var found = false;
    for (final cluster in source.text.characters) {
      final end = offset + cluster.length;
      window.add((offset, end));
      if (!found && localFocus < end) found = true;
      if (!found && window.length > before) window.removeFirst();
      offset = end;
      if (found && window.length >= maximumClusters) break;
    }
    if (window.isEmpty) return null;
    final start = window.first.$1;
    final end = window.last.$2;
    _excerpt = _slice(source, start, end);
    _precedingLayout?.dispose();
    _precedingLayout = null;
    _precedingIsAuthoredLine = false;
    if (start > 0) {
      // A bounded prefix retains the real preceding characters and rich styles.
      // It supplies only trailing whitespace, never a synthetic tall note band.
      _precedingLine = _tail(source, before: start);
    } else {
      final sourceIndex = _lines.indexOf(source);
      _precedingIsAuthoredLine = sourceIndex > 0;
      _precedingLine = sourceIndex > 0 ? _tail(_lines[sourceIndex - 1]) : null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _scrollController.hasClients &&
          _scrollController.offset != 0) {
        _scrollController.jumpTo(0);
      }
    });
    return _excerpt;
  }

  ScriptLine _slice(ScriptLine source, int start, int end) {
    final characters = <ScriptCharacter>[];
    var offset = 0;
    for (final char in source.characters) {
      final next = offset + char.char.length;
      if (offset >= end) break;
      if (next > start) {
        final from = math.max(0, start - offset);
        final to = math.min(char.char.length, end - offset);
        characters.add(
          from == 0 && to == char.char.length
              ? char
              : ScriptCharacter(
                  char: char.char.substring(from, to),
                  rawIndex: char.rawIndex + from,
                  bold: char.bold,
                  italic: char.italic,
                  underline: char.underline,
                  strikeThrough: char.strikeThrough,
                  fontSizeRatio: char.fontSizeRatio,
                  fontSizePx: char.fontSizePx,
                  backgroundColor: char.backgroundColor,
                  textColor: char.textColor,
                ),
        );
      }
      offset = next;
    }
    return ScriptLine(
      characters: List.unmodifiable(characters),
      lineIndex: source.lineIndex,
      paragraph: source.paragraph,
    );
  }

  ScriptLine _tail(ScriptLine source, {int? before}) {
    final end = before ?? source.text.length;
    final clusters = source.text.substring(0, end).characters;
    final tail = clusters.skip(math.max(0, clusters.length - 80)).toString();
    return _slice(source, end - tail.length, end);
  }

  double _leadingSpace(double width) {
    if (widget.settings == null) return _legacyTopSpace - 4;
    final geometry = _geometry;
    final cap = geometry.fontSize * 1.2;
    final preceding = _precedingLine;
    if (preceding == null) {
      // The document's first line can borrow the playback viewport's existing
      // top padding. Preview it using this viewport's own reading-line padding.
      final ratio = _settings.readingLineOffset > 0
          ? _settings.readingLineOffset.clamp(0.0, 1.0)
          : .5;
      return math.min(cap, math.max(widget.height * .1, widget.height * ratio));
    }
    if (preceding.characters.isEmpty) return math.min(cap, geometry.emptyHeight + 4);
    if (_precedingLayout?.geometry != geometry ||
        _precedingLayout?.width != width ||
        !identical(_precedingLayout?.line, preceding)) {
      _precedingLayout?.dispose();
      _precedingLayout = ReadingTextLayout(
        line: preceding,
        geometry: geometry,
        width: width,
        direction: TextDirection.ltr,
      );
    }
    return math.min(
      cap,
      ReadingAnnotationLayout.trailingSpace(_precedingLayout!, _glyphCache) +
          (_precedingIsAuthoredLine ? 4 : 0),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointer != null) {
      _primaryPointer = false;
      return;
    }
    _activePointer = event.pointer;
    _pointerStarted = event.timeStamp;
    _pointerStartPosition = event.position;
    _pointerMoved = false;
    _primaryPointer = event.buttons == kPrimaryButton;
    _noteOpened = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _activePointer &&
        _pointerStartPosition != null &&
        (event.position - _pointerStartPosition!).distance > kTouchSlop) {
      _pointerMoved = true;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _primaryPointer = false;
    _pointerStarted = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    if (!_primaryPointer ||
        _pointerMoved ||
        _noteOpened ||
        _pointerStarted == null ||
        event.timeStamp - _pointerStarted! >= kLongPressTimeout)
      return;
    final state = _lineKey.currentState;
    final box = state?.context.findRenderObject();
    if (state != null && box is RenderBox) {
      _noteOpened = state.openAnnotationsAt(box.globalToLocal(event.position));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_parsedContent != widget.content) {
      _parsedContent = widget.content;
      _lines = TextParser.isHtml(widget.content)
          ? TextParser.parse(widget.content)
          : TextParser.parsePlainText(widget.content);
      _excerptKey = null;
    }
    _scheduleStatus();
    final settings = _settings;
    final focus = _focus();
    final focusedNotes = widget.annotations
        .where(
          (note) =>
              note.isAnchored &&
              note.ranges.any(
                (range) => range.start <= focus && focus < range.end,
              ),
        )
        .toList(growable: false);
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Color(settings.teleprompterBgColor),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerCancel: _onPointerCancel,
            onPointerUp: _onPointerUp,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = math.max(1.0, constraints.maxWidth - 32);
                final excerpt = _excerptFor(focus, width);
                if (excerpt == null || excerpt.characters.isEmpty) {
                  return const Center(
                    child: Text(
                      '选择正文中的字词后，在这里预览批注效果',
                      style: TextStyle(color: Color(0xFFA7B4B4), fontSize: 13),
                    ),
                  );
                }
                final leadingSpace = _leadingSpace(width);
                final topSpace = widget.settings == null
                    ? _legacyTopSpace
                    : math.max(12.0, leadingSpace + 4);
                return Semantics(
                  label: '批注效果局部预览，点击标记字词或备注编辑',
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(16, topSpace, 16, 20),
                    child: ReadingEmphasisLine(
                      key: _lineKey,
                      line: excerpt,
                      geometry: _geometry,
                      presentation: ReadingTextPresentation(
                        currentIndex: focusedNotes.isEmpty ? -1 : focus,
                        currentCharScale: settings.currentCharScale,
                        currentCharColor: settings.currentCharColor,
                        readCharColor: settings.readCharColor,
                        textColor: settings.textColor == 0
                            ? ThemeData.estimateBrightnessForColor(Color(settings.teleprompterBgColor)) == Brightness.dark
                                ? 0xFFFFFFFF
                                : 0xFF000000
                            : settings.textColor,
                        enabled: settings.readingEmphasisEnabled,
                        continuous: settings.isContinuousScroll,
                        highlightCurrentChar: settings.highlightCurrentChar,
                        underlineCurrentChar: settings.underlineCurrentChar,
                        grayReadChars: settings.grayReadChars,
                      ),
                      glyphCache: _glyphCache,
                      width: width,
                      direction: TextDirection.ltr,
                      annotations: focusedNotes,
                      annotationLeadingSpace: leadingSpace,
                      annotationStyle: ReadingAnnotationStyle.fromSettings(settings),
                      handleAnnotationLabelTaps: false,
                      onAnnotationsTap: widget.onNoteTap == null
                          ? null
                          : (notes) {
                              _noteOpened = true;
                              widget.onNoteTap!(notes.first);
                            },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
