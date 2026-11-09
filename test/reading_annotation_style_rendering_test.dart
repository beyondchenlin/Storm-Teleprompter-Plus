import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation_style.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/editor/reading_annotation_preview.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_annotation_layer.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_glyph_ink_cache.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

import 'support/reading_ink_test_utils.dart';

class _PendingInkCache extends ReadingGlyphInkCache {
  @override
  Rect? boundsFor(
    String text,
    TextStyle style,
    TextDirection direction,
    TextPainter painter,
  ) => null;
}

const _note = ReadingAnnotation(
  id: 'appearance',
  text: '重读',
  ranges: [AnnotationRange(start: 2, end: 3, quote: 'C')],
);

({ReadingTextLayout body, ReadingAnnotationLayout notes}) _layout({
  required ReadingAnnotationStyle style,
  double bodySize = 64,
  double? bandHeight,
  ReadingAnnotation note = _note,
}) {
  final cache = ReadingGlyphPainterCache(inkCache: _PendingInkCache());
  final body = ReadingTextLayout(
    line: TextParser.parsePlainText('ABCDEFGH').single,
    geometry: ReadingTextGeometry(fontSize: bodySize, lineHeight: 1.5),
    width: 1100,
    direction: TextDirection.ltr,
  );
  final top = body.maximumGlyphBounds(
    body.placementAt(0),
    cache,
    resolveInk: false,
  ).top;
  final notes = ReadingAnnotationLayout(
    textLayout: body,
    annotations: [note],
    glyphCache: cache,
    style: style,
    leadingSpace: bandHeight == null ? 100 : bandHeight - top + 3,
  );
  addTearDown(() {
    notes.dispose();
    body.dispose();
    cache.dispose();
  });
  return (body: body, notes: notes);
}

Future<List<int>> _bodyPixels(WidgetTester tester, Finder line) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(of: line, matching: find.byType(RepaintBoundary)).first,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = bytes!.buffer.asUint8List().toList(growable: false);
    image.dispose();
    return result;
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自动字号保持原行为，独立字号和字体颜色传到真实标签', () {
    final automatic = _layout(style: const ReadingAnnotationStyle());
    expect(
      automatic.notes.rowAt(0).labels.single.painter.text!.style!.fontSize,
      closeTo(64 * .22, .001),
    );
    const style = ReadingAnnotationStyle(
      fontSize: 24,
      fontFamily: 'Ahem',
      color: 0xFFFF80AB,
    );
    final custom = _layout(style: style);
    final label = custom.notes.rowAt(0).labels.single;
    expect(label.painter.text!.style!.fontSize, 24);
    expect(label.painter.text!.style!.fontFamily, 'Ahem');
    expect(label.painter.text!.style!.color, const Color(0xFFFF80AB));
    expect(custom.notes.style.paintColor, const Color(0xFFFF80AB));
    expect(custom.notes.notesAt(label.rect.center), [_note]);
  });

  test('固定小字号正文仍能使用独立批注字号，自动模式保持兼容', () {
    final automatic = _layout(
      style: const ReadingAnnotationStyle(),
      bodySize: 24,
    );
    expect(automatic.notes.rowAt(0).labels, isEmpty);
    final custom = _layout(
      style: const ReadingAnnotationStyle(fontSize: 12),
      bodySize: 24,
    );
    expect(custom.notes.rowAt(0).labels, hasLength(1));
    expect(custom.notes.displayStatus().largestFontSize, 12);
    expect(custom.notes.displayStatus().hiddenLabelCount, 0);
  });

  test('放大批注字体不会连带拉长引线，整块备注与词框仍以中心相连', () {
    final automatic = _layout(style: const ReadingAnnotationStyle());
    final large = _layout(style: const ReadingAnnotationStyle(fontSize: 36));
    final original = automatic.notes.rowAt(0).labels.single;
    final enlarged = large.notes.rowAt(0).labels.single;
    expect(enlarged.painter.text!.style!.fontSize, 36);
    expect(enlarged.tail, enlarged.rect.bottomCenter);
    expect(enlarged.tip, enlarged.anchor.frame.topCenter);
    expect(
      (enlarged.tip - enlarged.tail).distance,
      closeTo((original.tip - original.tail).distance, .001),
    );
  });

  test('大字号在固定留白内收敛，报告实际字号并保留完整原文与备注', () {
    const note = ReadingAnnotation(
      id: 'two-lines',
      text: '放慢语速\n把意思讲清楚',
      ranges: [AnnotationRange(start: 2, end: 3, quote: 'C')],
    );
    final value = _layout(
      style: const ReadingAnnotationStyle(fontSize: 36),
      bandHeight: 26,
      note: note,
    );
    final row = value.notes.rowAt(0);
    final label = row.labels.single;
    final status = value.notes.displayStatus();
    expect(status.reducedLabelCount, 1);
    expect(status.largestFontSize, inInclusiveRange(8, 35));
    expect(status.message, contains('按行间留白缩至'));
    expect(label.rect.top, greaterThanOrEqualTo(row.safeBand.top - .01));
    expect(label.rect.bottom, lessThanOrEqualTo(row.safeBand.bottom + .01));
    expect(row.bodyBounds.any((rect) => rect.overlaps(label.occupiedBounds)), isFalse);
    expect(value.notes.notesAt(label.rect.center).single.text, note.text);
    expect(value.body.line.text, 'ABCDEFGH');
  });

  testWidgets('字体字号颜色更新仅重绘批注，正文测量与正文像素逐项不变', (tester) async {
    final lineKey = GlobalKey<ReadingEmphasisLineState>();
    final line = TextParser.parsePlainText('ABCDEFGH').single;
    final cache = ReadingGlyphPainterCache();
    const notes = [_note];
    Future<void> show(ReadingAnnotationStyle style) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Padding(
        padding: const EdgeInsets.only(top: 110),
        child: ReadingEmphasisLine(
          key: lineKey,
          line: line,
          geometry: const ReadingTextGeometry(fontSize: 64, lineHeight: 1.5),
          presentation: const ReadingTextPresentation(currentIndex: 2),
          glyphCache: cache,
          width: 750,
          direction: TextDirection.ltr,
          annotations: notes,
          annotationStyle: style,
          annotationLeadingSpace: 100,
        ),
      ))));
      await settleReadingInk(tester, cache.inkCache);
    }
    await show(const ReadingAnnotationStyle(fontSize: 12));
    final state = lineKey.currentState!;
    final body = state.debugLayout;
    final builds = state.debugLayoutBuildCount;
    final pixels = await _bodyPixels(tester, find.byKey(lineKey));
    await show(const ReadingAnnotationStyle(
      fontFamily: 'FontMissingForFallbackTest',
      fontSize: 28,
      color: 0xFFFF80AB,
    ));
    expect(identical(state.debugLayout, body), isTrue);
    expect(state.debugLayoutBuildCount, builds);
    expect(await _bodyPixels(tester, find.byKey(lineKey)), pixels);
    final label = state.debugAnnotationLayout!.rowAt(0).labels.single;
    expect(label.painter.text!.style!.fontFamily, 'FontMissingForFallbackTest');
    expect(label.painter.text!.style!.fontSize, 28);
    expect(label.painter.text!.style!.color, const Color(0xFFFF80AB));
    expect(state.annotationsAt(label.rect.center), notes);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('预览采用实际稿件外观并使用前一行留白，闭包状态回调不会无限重建', (tester) async {
    const body = '前一行正文\n目标词继续讲清楚';
    const note = ReadingAnnotation(
      id: 'actual-settings',
      text: '放慢语速\n语气自然',
      ranges: [AnnotationRange(start: 6, end: 9, quote: '目标词')],
    );
    const settings = AppSettings(
      fontSize: 64,
      lineHeight: 1.5,
      teleprompterFontFamily: 'Ahem',
      annotationFontFamily: 'Ahem',
      annotationFontSize: 36,
      annotationColor: 0xFFFF80AB,
      teleprompterBgColor: 0xFF123456,
    );
    var reports = 0;
    ReadingAnnotationPreviewStatus? status;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) => ReadingAnnotationPreview(
        content: body,
        annotations: const [note],
        // Common parent getters create a fresh snapshot on every rebuild.
        // Equal values and a new callback identity must still settle.
        settings: settings.copyWith(),
        focusRawIndex: 6,
        onLayoutStatus: (next) => setState(() {
          reports++;
          status = next;
        }),
      ),
    ))));
    final line = tester.widget<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine));
    await settleReadingInk(tester, line.glyphCache.inkCache);
    for (var index = 0; index < 5; index++) {
      await tester.pump();
    }
    final stableCount = reports;
    for (var index = 0; index < 5; index++) {
      await tester.pump();
    }
    expect(reports, stableCount);
    expect(status, isNotNull);
    expect(status!.hasAnnotations, isTrue);
    expect(status!.hasAdaptation, isTrue);
    final updatedLine = tester.widget<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine));
    expect(updatedLine.geometry.fontSize, 64);
    expect(updatedLine.geometry.lineHeight, 1.5);
    expect(updatedLine.geometry.fontFamily, 'Ahem');
    expect(updatedLine.annotationStyle.fontSize, 36);
    expect(updatedLine.annotationStyle.color, 0xFFFF80AB);
    expect(updatedLine.annotationLeadingSpace, lessThan(60));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放中修改批注外观不改变滚动偏移或全文高度', (tester) async {
    final lines = TextParser.parsePlainText(List.filled(40, 'ABCDEFGH').join('\n'));
    final controller = ScrollController();
    final layerKey = GlobalKey<TeleprompterTextLayerState>();
    Future<void> show(ReadingAnnotationStyle style) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TeleprompterTextLayer(
        key: layerKey,
        scrollController: controller,
        lines: lines,
        currentIndex: 0,
        fontSize: 64,
        lineHeight: 1.5,
        mirrorMode: false,
        annotations: const [_note],
        annotationStyle: style,
      ))));
      await tester.pump();
    }
    await show(const ReadingAnnotationStyle());
    controller.jumpTo(340);
    await tester.pump();
    final offset = controller.offset;
    final extent = controller.position.maxScrollExtent;
    await show(const ReadingAnnotationStyle(fontSize: 36, fontFamily: 'Ahem', color: 0xFFFFFF00));
    expect(controller.offset, offset);
    expect(controller.position.maxScrollExtent, extent);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('匀速预览首行只使用实际视口顶部留白，不借用阅读线位置', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: ReadingAnnotationPreview(
        content: 'ABCDEFGH',
        annotations: [_note],
        height: 190,
        settings: AppSettings(
          fontSize: 64,
          autoScrollMode: AutoScrollMode.continuous,
          readingLineOffset: .9,
          annotationFontSize: 36,
        ),
      ),
    )));
    final line = tester.widget<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine));
    expect(line.annotationLeadingSpace, closeTo(190 * .3 + 2, .001));
    expect(line.presentation.continuous, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
