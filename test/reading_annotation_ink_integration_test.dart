import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_annotation_layer.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_glyph_ink_cache.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

class _ControlledInkCache extends ReadingGlyphInkCache {
  final readyWeights = <FontWeight>{};
  final requested = <({String text, TextStyle style})>[];
  bool emptyInk = false;
  int _generation = 0;

  @override
  int get revision => _generation;

  @override
  Future<void> get settled async {}

  void complete(FontWeight weight) {
    readyWeights.add(weight);
    _generation++;
    notifyListeners();
  }

  @override
  Rect? boundsFor(
    String text,
    TextStyle style,
    TextDirection direction,
    TextPainter painter,
  ) {
    requested.add((text: text, style: style));
    if (!readyWeights.contains(style.fontWeight)) return null;
    if (emptyInk) return Rect.zero;
    final baseline = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    // Deliberately asymmetric styles: neither weight contains the other.
    return style.fontWeight == FontWeight.w400
        ? Rect.fromLTRB(-7, baseline - 9, painter.width + 2, baseline + 4)
        : Rect.fromLTRB(1, baseline - 12, painter.width + 8, baseline + 2);
  }
}

ReadingAnnotation _note(int start, String quote) => ReadingAnnotation(
  id: 'note-$start',
  text: '重读',
  ranges: [AnnotationRange(start: start, end: start + quote.length, quote: quote)],
);

Future<void> _settleInk(WidgetTester tester, ReadingGlyphPainterCache cache) async {
  for (var pass = 0; pass < 8; pass++) {
    await tester.runAsync(() => cache.inkCache.settled);
    await tester.pump();
    if (cache.inkCache.debugPendingCount == 0) {
      await tester.pump();
      if (cache.inkCache.debugPendingCount == 0) return;
    }
  }
  fail('可见字形墨迹测量未在有界轮次内完成');
}

Future<List<int>> _bodyPixels(
  WidgetTester tester,
  ReadingEmphasisLineState state,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byWidget(state.widget),
      matching: find.byType(RepaintBoundary),
    ).first,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = bytes!.buffer.asUint8List().toList(growable: false);
    image.dispose();
    return pixels;
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('候选墨迹全部就绪前不缩小包络，完成后按原基线与实际画布缩放并集', () {
    final ink = _ControlledInkCache();
    final cache = ReadingGlyphPainterCache(inkCache: ink);
    final body = ReadingTextLayout(
      line: TextParser.parse('<p><i>f</i></p>').single,
      geometry: const ReadingTextGeometry(fontSize: 64, lineHeight: 1.5),
      width: 500,
      direction: TextDirection.ltr,
    );
    addTearDown(body.dispose);
    addTearDown(cache.dispose);
    final placement = body.placementAt(0);
    final fallback = body.maximumGlyphBounds(placement, cache, resolveInk: false);
    expect(ink.requested, isEmpty);
    expect(body.maximumGlyphBounds(placement, cache), fallback);
    ink.complete(FontWeight.w400);
    expect(body.maximumGlyphBounds(placement, cache), fallback);
    ink.complete(FontWeight.w700);
    final actual = body.maximumGlyphBounds(placement, cache);
    expect(actual.top, closeTo(placement.row.baseline - 12 * 1.15, .0001));
    expect(actual.bottom, closeTo(placement.row.baseline + 4 * 1.15, .0001));
    expect(actual.left, lessThanOrEqualTo(placement.cell.left));
    expect(actual.right, greaterThanOrEqualTo(placement.cell.right));
    for (final request in ink.requested) {
      expect(request.style.fontSize, 64);
      expect(request.style.height, ui.kTextHeightNone);
      expect(request.style.fontStyle, FontStyle.italic);
      expect(request.style.color, Colors.white);
      expect(request.style.backgroundColor, isNull);
      expect(request.style.background, isNull);
      expect(request.style.decoration!.contains(TextDecoration.underline), isTrue);
      expect(request.style.decoration!.contains(TextDecoration.lineThrough), isTrue);
      final painter = cache.painterFor(request.text, request.style, TextDirection.ltr);
      final leftInk = request.style.fontWeight == FontWeight.w400 ? -7 : 1;
      final rightInk = request.style.fontWeight == FontWeight.w400 ? 2 : 8;
      for (final scale in [1.0, 1.15]) {
        final originX = placement.paintAnchorX - painter.width * scale / 2;
        expect(actual.left, lessThanOrEqualTo(originX + leftInk * scale + .0001));
        expect(actual.right, greaterThanOrEqualTo(originX + (painter.width + rightInk) * scale - .0001));
      }
    }
    final queries = ink.requested.length;
    // Simulate native-cache eviction. Completed layout rectangles must survive
    // annotation refreshes without scheduling those glyphs all over again.
    ink.readyWeights.clear();
    expect(body.maximumGlyphBounds(placement, cache), actual);
    expect(ink.requested.length, queries);
  });

  test('墨迹完成会使批注行和包络两层失效，确实空墨迹不重新占用字体高度', () {
    final ink = _ControlledInkCache()..emptyInk = true;
    final cache = ReadingGlyphPainterCache(inkCache: ink);
    const text = 'abcdefghijklmnopqrstuvwxyz';
    final body = ReadingTextLayout(
      line: TextParser.parsePlainText(text).single,
      geometry: const ReadingTextGeometry(fontSize: 40, lineHeight: 1.5),
      width: 190,
      direction: TextDirection.ltr,
    );
    final start = body.rows[2].start;
    final notes = ReadingAnnotationLayout(
      textLayout: body,
      annotations: [_note(start, text.substring(start, start + 1))],
      glyphCache: cache,
    );
    addTearDown(notes.dispose);
    addTearDown(body.dispose);
    addTearDown(cache.dispose);
    final before = notes.rowAt(2);
    expect(before.bodyBounds.every((rect) => !rect.isEmpty), isTrue);
    ink.complete(FontWeight.w400);
    final partial = notes.rowAt(2);
    expect(partial, isNot(same(before)));
    expect(partial.bodyBounds, before.bodyBounds);
    ink.complete(FontWeight.w700);
    final after = notes.rowAt(2);
    expect(after.bodyBounds.every((rect) => rect.isEmpty), isTrue);
    expect(after.safeBand.height, greaterThan(body.rows[2].height / 2));
    expect(after.safeBand.top, greaterThan(0));
    expect(
      ReadingAnnotationLayout.trailingSpace(body, cache),
      closeTo(body.height - body.rows.last.top - 1.5, .001),
    );
  });

  test('无批注可见行与不可读小字号不发起像素探针，范围框仍保留', () {
    final ink = _ControlledInkCache();
    final cache = ReadingGlyphPainterCache(inkCache: ink);
    final text = List.generate(80, (index) => String.fromCharCode(0x4e00 + index)).join();
    final body = ReadingTextLayout(
      line: TextParser.parsePlainText(text).single,
      geometry: const ReadingTextGeometry(fontSize: 40, lineHeight: 1.5),
      width: 190,
      direction: TextDirection.ltr,
    );
    final start = body.rows.last.start;
    final notes = ReadingAnnotationLayout(
      textLayout: body,
      annotations: [_note(start, text.substring(start, start + 1))],
      glyphCache: cache,
    );
    addTearDown(notes.dispose);
    addTearDown(body.dispose);
    addTearDown(cache.dispose);
    expect(notes.rowsIn(Rect.fromLTWH(0, 0, 190, body.rows[1].bottom)).toList(), isEmpty);
    expect(notes.notesAt(const Offset(30, 30)), isEmpty);
    expect(ink.requested, isEmpty);
    expect(notes.rowAt(body.rows.length - 1).anchors, isNotEmpty);
    final allowed = text.substring(body.rows[body.rows.length - 2].start).characters.toSet();
    expect(ink.requested.every((request) => allowed.contains(request.text)), isTrue);

    final smallInk = _ControlledInkCache();
    final smallCache = ReadingGlyphPainterCache(inkCache: smallInk);
    final smallBody = ReadingTextLayout(
      line: TextParser.parsePlainText('小字范围').single,
      geometry: const ReadingTextGeometry(fontSize: 18, lineHeight: 1.5),
      width: 190,
      direction: TextDirection.ltr,
    );
    final smallNotes = ReadingAnnotationLayout(
      textLayout: smallBody,
      annotations: [_note(0, '小字')],
      glyphCache: smallCache,
    );
    addTearDown(smallNotes.dispose);
    addTearDown(smallBody.dispose);
    addTearDown(smallCache.dispose);
    expect(smallNotes.rowAt(0).anchors, isNotEmpty);
    expect(smallNotes.rowAt(0).labels, isEmpty);
    expect(smallInk.requested, isEmpty);
  });

  test('超过原生缓存容量的已完成字形在批注重建后不再次请求测量', () {
    final ink = _ControlledInkCache()
      ..complete(FontWeight.w400)
      ..complete(FontWeight.w700);
    final cache = ReadingGlyphPainterCache(inkCache: ink);
    final text = List.generate(270, (index) => String.fromCharCode(0x4e00 + index)).join();
    final body = ReadingTextLayout(
      line: TextParser.parsePlainText(text).single,
      geometry: const ReadingTextGeometry(fontSize: 40, lineHeight: 1.5),
      width: 350,
      direction: TextDirection.ltr,
    );
    ReadingAnnotationLayout makeNotes() => ReadingAnnotationLayout(
      textLayout: body,
      annotations: [_note(0, text)],
      glyphCache: cache,
    );
    final before = makeNotes();
    for (var index = 0; index < body.rows.length; index++) {
      before.rowAt(index);
    }
    final requests = ink.requested.length;
    expect(requests, greaterThan(ReadingGlyphInkCache.maximumCachedEntries));
    ink.readyWeights.clear();
    ink.complete(FontWeight.w900);
    final after = makeNotes();
    for (var index = 0; index < body.rows.length; index++) {
      after.rowAt(index);
    }
    expect(ink.requested.length, requests);
    before.dispose();
    after.dispose();
    body.dispose();
    cache.dispose();
  });

  testWidgets('墨迹分批完成只替换批注布局，不重建正文布局或改变视觉行', (tester) async {
    final ink = _ControlledInkCache();
    final cache = ReadingGlyphPainterCache(inkCache: ink);
    final key = GlobalKey<ReadingEmphasisLineState>();
    final line = TextParser.parsePlainText('abcdefghij').single;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 60),
          child: ReadingEmphasisLine(
            key: key,
            line: line,
            geometry: const ReadingTextGeometry(fontSize: 48, lineHeight: 1.5),
            presentation: const ReadingTextPresentation(currentIndex: 0),
            glyphCache: cache,
            width: 320,
            direction: TextDirection.ltr,
            annotations: [_note(0, 'a')],
            annotationLeadingSpace: 60,
          ),
        ),
      ),
    ));
    final state = key.currentState!;
    final body = state.debugLayout;
    final rowMetrics = body.rows.map((row) => (row.start, row.end, row.height, row.baseline)).toList();
    final size = tester.getSize(find.byKey(key));
    var annotations = state.debugAnnotationLayout;
    for (final weight in [FontWeight.w400, FontWeight.w700]) {
      ink.complete(weight);
      await tester.pump();
      expect(state.debugAnnotationLayout, isNot(same(annotations)));
      annotations = state.debugAnnotationLayout;
      expect(state.debugLayout, same(body));
      expect(state.debugLayoutBuildCount, 1);
      expect(tester.getSize(find.byKey(key)), size);
      expect(body.rows.map((row) => (row.start, row.end, row.height, row.baseline)).toList(), rowMetrics);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    ink.complete(FontWeight.w400);
    expect(tester.takeException(), isNull);
    cache.dispose();
  });

  testWidgets('真实墨迹完成只刷新批注，正文像素、布局次数、换行、基线和滚动都不动', (tester) async {
    const lineText = 'Agjf 知识讲述与节奏';
    final lines = TextParser.parsePlainText(List.filled(80, lineText).join('\n'));
    final notes = [for (final line in lines) _note(line.characters.first.rawIndex, 'A')];
    final controller = ScrollController();
    final key = GlobalKey<TeleprompterTextLayerState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TeleprompterTextLayer(
          key: key,
          scrollController: controller,
          lines: lines,
          currentIndex: 0,
          fontSize: 48,
          lineHeight: 1.5,
          mirrorMode: false,
          continuous: true,
          annotations: notes,
        ),
      ),
    ));
    controller.jumpTo(900);
    await tester.pump();
    final viewport = tester.getRect(find.byKey(key));
    final states = tester.stateList<ReadingEmphasisLineState>(find.byType(ReadingEmphasisLine)).where((state) {
      final box = state.context.findRenderObject()! as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      return top >= viewport.top && top + box.size.height <= viewport.bottom;
    }).toList();
    expect(states, isNotEmpty);
    final layouts = {for (final state in states) state: state.debugLayout};
    final annotationLayouts = {for (final state in states) state: state.debugAnnotationLayout};
    final counts = {for (final state in states) state: state.debugLayoutBuildCount};
    final rows = {for (final state in states) state: state.debugLayout.rows.map((row) => (row.start, row.end, row.top, row.height, row.baseline)).toList()};
    final sizes = {for (final state in states) state: (state.context.findRenderObject()! as RenderBox).size};
    final offset = controller.offset;
    final extent = controller.position.maxScrollExtent;
    final metrics = key.currentState!.debugMetricsBuildCount;
    final intrinsic = key.currentState!.debugIntrinsicWidthBuildCount;
    final rawIndex = key.currentState!.rawIndexAtViewport();
    final bodyPixels = await _bodyPixels(tester, states.first);
    final cache = states.first.widget.glyphCache;
    // Force a genuinely new native completion even on platforms that finished
    // all visible requests during the first frame, avoiding a timing-only test.
    const probeStyle = TextStyle(fontSize: 21.25, color: Colors.white);
    final revision = cache.inkCache.revision;
    cache.inkCache.boundsFor(
      '刷新证明', probeStyle, TextDirection.ltr,
      cache.painterFor('刷新证明', probeStyle, TextDirection.ltr),
    );
    await _settleInk(tester, cache);
    expect(cache.inkCache.revision, greaterThan(revision));
    expect(states.any((state) => !identical(state.debugAnnotationLayout, annotationLayouts[state])), isTrue);
    for (final state in states) {
      expect(state.mounted, isTrue);
      expect(state.debugLayout, same(layouts[state]));
      expect(state.debugLayoutBuildCount, counts[state]);
      expect(state.debugLayout.rows.map((row) => (row.start, row.end, row.top, row.height, row.baseline)).toList(), rows[state]);
      expect((state.context.findRenderObject()! as RenderBox).size, sizes[state]);
    }
    expect(await _bodyPixels(tester, states.first), bodyPixels);
    expect(controller.offset, closeTo(offset, .001));
    expect(controller.position.maxScrollExtent, closeTo(extent, .001));
    expect(key.currentState!.debugMetricsBuildCount, metrics);
    expect(key.currentState!.debugIntrinsicWidthBuildCount, intrinsic);
    expect(key.currentState!.rawIndexAtViewport(), rawIndex);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(() => cache.inkCache.settled);
  });

  testWidgets('真实正文画布在普通、粗体、装饰和中间缩放比例下均位于最终墨迹包络内', (tester) async {
    final cache = ReadingGlyphPainterCache();
    final body = ReadingTextLayout(
      line: ScriptLine(
        lineIndex: 0,
        characters: const [ScriptCharacter(char: 'f', rawIndex: 0, italic: true, strikeThrough: true)],
      ),
      geometry: const ReadingTextGeometry(fontSize: 64, lineHeight: 1.5),
      width: 250,
      direction: TextDirection.ltr,
    );
    final placement = body.placementAt(0);
    body.maximumGlyphBounds(placement, cache);
    await _settleInk(tester, cache);
    final envelope = body.maximumGlyphBounds(placement, cache);
    const ratio = 1.25;
    for (final bold in [false, true]) {
      for (final scale in [1.0, 1.075, 1.15]) {
        final outside = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(ratio);
          ReadingTextPainter(
            layout: body,
            presentation: ReadingTextPresentation(
              currentIndex: 0,
              highlightCurrentChar: bold,
              underlineCurrentChar: true,
              currentCharScale: scale,
            ),
            glyphCache: cache,
          ).paint(canvas, Size(body.width, body.height));
          final picture = recorder.endRecording();
          final image = await picture.toImage((body.width * ratio).ceil(), (body.height * ratio).ceil());
          final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          var count = 0;
          var painted = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              if (bytes[(y * image.width + x) * 4 + 3] == 0) continue;
              painted++;
              if (!envelope.contains(Offset((x + .5) / ratio, (y + .5) / ratio))) count++;
            }
          }
          expect(painted, greaterThan(0));
          image.dispose();
          picture.dispose();
          return count;
        });
        expect(outside, 0, reason: '粗体=$bold，画布比例=$scale');
      }
    }
    body.dispose();
    cache.dispose();
    await tester.runAsync(() => cache.inkCache.settled);
  });
}
