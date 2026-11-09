import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/reading_annotation.dart';
import '../../models/script_character.dart';
import '../../services/text_parser.dart';
import '../teleprompter/reading_emphasis_text.dart';

/// A live excerpt using the same body and annotation painters as playback.
/// Source indices and rich-text formatting survive excerpting, so a preview
/// click edits the same anchored note that will appear during a reading.
class ReadingAnnotationPreview extends StatefulWidget {
  final String content;
  final List<ReadingAnnotation> annotations;
  final int? focusRawIndex;
  final double height;
  final ValueChanged<ReadingAnnotation>? onNoteTap;

  const ReadingAnnotationPreview({
    super.key,
    required this.content,
    required this.annotations,
    this.focusRawIndex,
    this.height = 230,
    this.onNoteTap,
  });

  @override
  State<ReadingAnnotationPreview> createState() => _ReadingAnnotationPreviewState();
}

class _ReadingAnnotationPreviewState extends State<ReadingAnnotationPreview> {
  static const double _fontSize = 48;
  static const double _topSpace = 64;
  final _lineKey = GlobalKey<ReadingEmphasisLineState>();
  final _glyphCache = ReadingGlyphPainterCache(capacity: 256);
  final _scrollController = ScrollController();
  String? _parsedContent;
  List<ScriptLine> _lines = const [];
  (ScriptLine, int, int)? _excerptKey;
  ScriptLine? _excerpt;
  Duration? _pointerStarted;
  Offset? _pointerStartPosition;
  int? _activePointer;
  bool _pointerMoved = false;
  bool _primaryPointer = false;
  bool _noteOpened = false;

  @override
  void dispose() {
    _scrollController.dispose();
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
    final columns = (width / (_fontSize * readingEmphasisMaximumScale * 1.08))
        .floor().clamp(2, 28).toInt();
    final key = (source, focus, columns);
    if (_excerptKey == key) return _excerpt;
    _excerptKey = key;

    var localFocus = 0;
    for (final char in source.characters) {
      if (focus < char.rawIndex + char.char.length) {
        localFocus += (focus - char.rawIndex).clamp(0, char.char.length).toInt();
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
    final characters = <ScriptCharacter>[];
    offset = 0;
    for (final char in source.characters) {
      final next = offset + char.char.length;
      if (offset >= end) break;
      if (next > start) {
        // Parser characters are UTF-16 units. The fallback also preserves the
        // correct raw offset for legacy callers that provide a whole run.
        final from = math.max(0, start - offset);
        final to = math.min(char.char.length, end - offset);
        characters.add(from == 0 && to == char.char.length ? char : ScriptCharacter(
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
        ));
      }
      offset = next;
    }
    _excerpt = ScriptLine(
      characters: List.unmodifiable(characters),
      lineIndex: source.lineIndex,
      paragraph: source.paragraph,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients && _scrollController.offset != 0) {
        _scrollController.jumpTo(0);
      }
    });
    return _excerpt;
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
    if (event.pointer == _activePointer && _pointerStartPosition != null &&
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
    if (!_primaryPointer || _pointerMoved || _noteOpened || _pointerStarted == null ||
        event.timeStamp - _pointerStarted! >= kLongPressTimeout) return;
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
    final focus = _focus();
    final focusedNotes = widget.annotations.where((note) =>
        note.isAnchored && note.ranges.any((range) =>
          range.start <= focus && focus < range.end)).toList(growable: false);
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: const Color(0xFF080909),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerCancel: _onPointerCancel,
            onPointerUp: _onPointerUp,
            child: LayoutBuilder(builder: (context, constraints) {
              final width = math.max(1.0, constraints.maxWidth - 32);
              final excerpt = _excerptFor(focus, width);
              if (excerpt == null || excerpt.characters.isEmpty) {
                return const Center(child: Text(
                  '选择正文中的字词后，在这里预览批注效果',
                  style: TextStyle(color: Color(0xFFA7B4B4), fontSize: 13),
                ));
              }
              return Semantics(
                label: '批注效果局部预览，点击标记字词或备注编辑',
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, _topSpace, 16, 20),
                  child: ReadingEmphasisLine(
                    key: _lineKey,
                    line: excerpt,
                    geometry: const ReadingTextGeometry(fontSize: _fontSize, lineHeight: 1.8),
                    presentation: ReadingTextPresentation(
                      currentIndex: focusedNotes.isEmpty ? -1 : focus,
                      currentCharScale: 1,
                      currentCharColor: 0xFFFFE36C,
                      textColor: 0xFFFFFFFF,
                      grayReadChars: false,
                    ),
                    glyphCache: _glyphCache,
                    width: width,
                    direction: TextDirection.ltr,
                    annotations: focusedNotes,
                    annotationLeadingSpace: _topSpace - 4,
                    handleAnnotationLabelTaps: false,
                    onAnnotationsTap: widget.onNoteTap == null ? null : (notes) {
                      _noteOpened = true;
                      widget.onNoteTap!(notes.first);
                    },
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
