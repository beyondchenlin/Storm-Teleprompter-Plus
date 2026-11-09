import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/editor/reading_annotation_preview.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_annotation_layer.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

ReadingAnnotation _note(
  String body,
  int start,
  int end,
  String text, {
  String? id,
}) => ReadingAnnotation(
  id: id ?? '$start-$end-$text',
  text: text,
  ranges: [
    AnnotationRange(start: start, end: end, quote: body.substring(start, end)),
  ],
);

({
  ReadingTextLayout body,
  ReadingAnnotationLayout notes,
  ReadingGlyphPainterCache cache,
})
_layout(
  String text,
  List<ReadingAnnotation> annotations, {
  double width = 700,
  double fontSize = 64,
  double lineHeight = 1.5,
  double leadingSpace = 0,
}) {
  final cache = ReadingGlyphPainterCache();
  final body = ReadingTextLayout(
    line: TextParser.parsePlainText(text).single,
    geometry: ReadingTextGeometry(fontSize: fontSize, lineHeight: lineHeight),
    width: width,
    direction: TextDirection.ltr,
  );
  final notes = ReadingAnnotationLayout(
    textLayout: body,
    annotations: annotations,
    glyphCache: cache,
    leadingSpace: leadingSpace,
  );
  addTearDown(() {
    notes.dispose();
    body.dispose();
    cache.dispose();
  });
  return (body: body, notes: notes, cache: cache);
}

Widget _lineHost({
  required GlobalKey<ReadingEmphasisLineState> lineKey,
  required ScriptLine line,
  required ReadingGlyphPainterCache cache,
  required List<ReadingAnnotation> annotations,
  required bool show,
  double lineHeight = 1.5,
  bool mirror = false,
  ValueChanged<int>? onTap,
}) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Padding(
      padding: const EdgeInsets.only(top: 100),
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(mirror ? -1 : 1, 1, 1),
          child: ReadingEmphasisLine(
            key: lineKey,
            line: line,
            geometry: ReadingTextGeometry(fontSize: 48, lineHeight: lineHeight),
            presentation: const ReadingTextPresentation(
              currentIndex: 2,
              currentCharScale: 1.15,
              highlightCurrentChar: true,
              underlineCurrentChar: true,
            ),
            glyphCache: cache,
            width: 650,
            direction: TextDirection.ltr,
            annotations: annotations,
            showAnnotations: show,
            annotationLeadingSpace: lineHeight > 1 ? 80 : 0,
            onCharTap: onTap,
          ),
        ),
      ),
    ),
  ),
);

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

  test('半开原文范围跨自动折行拆框，未选字不进入框内', () {
    const text = 'abcdefghijklmnopqrstuvwx';
    final value = _layout(
      text,
      [_note(text, 2, 16, '放慢语速')],
      width: 235,
      fontSize: 40,
    );
    final body = value.body;
    var markedRows = 0;
    for (var i = 0; i < body.rows.length; i++) {
      final row = value.notes.rowAt(i);
      if (row.anchors.isNotEmpty) markedRows++;
      for (final placement in body.placementsIn(
        Rect.fromLTWH(0, body.rows[i].top, body.width, body.rows[i].height),
      )) {
        final selected =
            placement.grapheme.rawStart >= 2 &&
            placement.grapheme.rawStart < 16;
        final marked = row.anchors.any(
          (anchor) =>
              placement.cell.center.dx > anchor.frame.left &&
              placement.cell.center.dx < anchor.frame.right,
        );
        expect(marked, selected, reason: '原文位置 ${placement.grapheme.rawStart}');
      }
    }
    expect(markedRows, greaterThan(1));
  });

  test('完整字素不会被拆框，互不相连的范围不覆盖中间正文', () {
    const text = 'A👩🏽‍💻BéCDE';
    final emojiEnd = text.indexOf('B');
    final note = ReadingAnnotation(
      id: 'graphemes',
      text: '语气上扬',
      ranges: [
        AnnotationRange(
          start: 2,
          end: emojiEnd - 1,
          quote: text.substring(2, emojiEnd - 1),
        ),
        AnnotationRange(start: text.length - 1, end: text.length, quote: 'E'),
      ],
    );
    final value = _layout(text, [note], width: 1400, leadingSpace: 100);
    final row = value.notes.rowAt(0);
    expect(row.anchors, hasLength(2));
    final emoji = value.body.placementForRawIndex(2)!;
    expect(row.anchors.first.frame.left, closeTo(emoji.cell.left + .4, 1));
    expect(row.anchors.first.frame.right, closeTo(emoji.cell.right - .4, 1));
    final middle = value.body.placementForRawIndex(emojiEnd)!;
    expect(
      row.anchors.any((anchor) => anchor.frame.contains(middle.cell.center)),
      isFalse,
    );
  });

  test('引线连接整块备注底部中心和范围框顶部中心，右边界镜像且为开放箭头', () {
    const text = 'abcdefgh';
    final measured = _layout(text, const [], width: 2000);
    final value = _layout(
      text,
      [_note(text, 1, 2, '重读'), _note(text, 7, 8, '停顿')],
      width: measured.body.maxIntrinsicWidth + .1,
      leadingSpace: 100,
    );
    final row = value.notes.rowAt(0);
    expect(row.labels, hasLength(2));
    expect(row.labels.first.mirrored, isFalse);
    expect(row.labels.last.mirrored, isTrue);
    for (final label in row.labels) {
      expect(label.tail, label.rect.bottomCenter);
      expect(label.tip, label.anchor.frame.topCenter);
      expect(label.tip.dy, greaterThan(label.tail.dy));
      final delta = label.tip - label.tail;
      final angle = math.atan2(delta.dy.abs(), delta.dx.abs()) * 180 / math.pi;
      expect(angle, closeTo(17.5, .001));
      expect(label.arrowHead.computeMetrics().single.isClosed, isFalse);
      expect(label.leader.computeMetrics().single.isClosed, isFalse);
      expect(row.bodyBounds.any((body) => body.overlaps(label.rect)), isFalse);
      expect(label.rect.top, greaterThanOrEqualTo(row.safeBand.top));
    }
  });

  test('长备注多行有界省略，保留完整文字且文字引线不压正文', () {
    const text = 'abcdefghijkl';
    final full = '放慢语速\n把意思讲清楚\n${List.filled(100, '这一句停顿后再继续').join()}';
    final note = _note(text, 3, 6, full);
    final value = _layout(text, [note], width: 1100, leadingSpace: 100);
    final row = value.notes.rowAt(0);
    expect(row.labels, hasLength(1));
    final label = row.labels.single;
    expect(label.painter.computeLineMetrics().length, inInclusiveRange(2, 3));
    expect(label.painter.text!.style!.fontSize, closeTo(14.08, .01));
    expect(label.isTruncated, isTrue);
    expect(
      row.bodyBounds.any((body) => body.overlaps(label.occupiedBounds)),
      isFalse,
    );
    expect(value.notes.notesAt(label.rect.center).single.text, full);
    expect(
      value.notes.notesAt(row.anchors.single.frame.center).single.text,
      full,
    );
  });

  test('相邻密集批注保持所有精确范围，文字和引线互不覆盖，同行段落数量有界', () {
    const text = 'abcdefghijkl';
    final notes = [
      for (var i = 0; i < text.length; i++)
        _note(text, i, i + 1, '这里需要放慢语速并讲清楚每个词的含义', id: 'note-$i'),
    ];
    final value = _layout(text, notes, width: 1200, leadingSpace: 100);
    final row = value.notes.rowAt(0);
    expect(row.anchors, hasLength(notes.length));
    expect(
      row.labels.length,
      lessThanOrEqualTo(ReadingAnnotationLayout.maximumLabelsPerRow),
    );
    expect(row.labels.length, lessThan(row.anchors.length));
    for (var i = 0; i < row.labels.length; i++) {
      for (var j = i + 1; j < row.labels.length; j++) {
        expect(
          row.labels[i].occupiedBounds.overlaps(row.labels[j].occupiedBounds),
          isFalse,
        );
      }
    }
    for (final anchor in row.anchors) {
      expect(
        value.notes.notesAt(anchor.frame.center),
        contains(anchor.notes.single),
      );
    }
  });

  test('同一原文范围的多条批注合并显示，密行距保留框与完整内容入口', () {
    const text = 'abcdef';
    final notes = [_note(text, 2, 3, '重读'), _note(text, 2, 3, '停顿后继续')];
    final value = _layout(text, notes, lineHeight: 1);
    final row = value.notes.rowAt(0);
    expect(row.anchors, hasLength(1));
    expect(row.anchors.single.notes, containsAll(notes));
    expect(row.labels, isEmpty);
    expect(
      value.notes.notesAt(row.anchors.single.frame.center),
      containsAll(notes),
    );
  });

  testWidgets('显隐只增减前景，正文像素、尺寸、换行、基线与点击索引保持不变', (tester) async {
    const text = 'abcdefghij';
    final line = TextParser.parsePlainText(text).single;
    final annotations = [_note(text, 2, 5, '放慢语速\n把意思讲清楚')];
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    int? tapped;
    Future<void> show(bool visible) async {
      await tester.pumpWidget(
        _lineHost(
          lineKey: key,
          line: line,
          cache: cache,
          annotations: annotations,
          show: visible,
          onTap: (value) => tapped = value,
        ),
      );
      await tester.pump();
    }

    await show(false);
    final body = key.currentState!.debugLayout;
    final annotationGeometry = key.currentState!.debugAnnotationLayout;
    final size = tester.getSize(find.byKey(key));
    final cells = [
      for (var i = 0; i < body.graphemes.length; i++) body.placementAt(i).cell,
    ];
    final baselines = body.rows.map((row) => row.baseline).toList();
    final pixels = await _bodyPixels(tester, find.byKey(key));
    for (final visible in [true, false, true]) {
      await show(visible);
      expect(key.currentState!.debugLayout, same(body));
      expect(key.currentState!.debugAnnotationLayout, same(annotationGeometry));
      expect(key.currentState!.debugLayoutBuildCount, 1);
      expect(tester.getSize(find.byKey(key)), size);
      expect(body.rows.map((row) => row.baseline), baselines);
      expect([
        for (var i = 0; i < body.graphemes.length; i++)
          body.placementAt(i).cell,
      ], cells);
      expect(await _bodyPixels(tester, find.byKey(key)), orderedEquals(pixels));
      final box = tester.renderObject<RenderBox>(find.byKey(key));
      await tester.tapAt(box.localToGlobal(cells[2].center));
      expect(tapped, 2);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('密行距和镜像下长按范围框可读取完整长备注', (tester) async {
    const text = 'abcdef';
    final line = TextParser.parsePlainText(text).single;
    final full = List.filled(60, '停顿以后再继续，不要漏掉这段解释。').join();
    final annotations = [_note(text, 2, 4, full)];
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    var seeks = 0;
    await tester.pumpWidget(
      _lineHost(
        lineKey: key,
        line: line,
        cache: cache,
        annotations: annotations,
        show: true,
        lineHeight: 1,
        mirror: true,
        onTap: (_) => seeks++,
      ),
    );
    final row = key.currentState!.debugAnnotationLayout!.rowAt(0);
    expect(row.labels, isEmpty);
    final box = tester.renderObject<RenderBox>(find.byKey(key));
    await tester.longPressAt(
      box.localToGlobal(row.anchors.single.frame.center),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      full,
    );
    expect(seeks, 0, reason: '长按查看不能先跳到被按住的词');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('首行与上一人工行留白中的备注可直接点击，镜像后也不触发正文跳读', (tester) async {
    const text = 'abcdefgh\nijklmnop';
    final lines = TextParser.parsePlainText(text);
    final annotations = [
      _note(text, 2, 3, '重读\n放慢语速\n讲清楚'),
      _note(text, 11, 12, '停顿\n吸气\n再继续'),
    ];
    final controller = ScrollController();
    var seeks = 0;
    for (final mirror in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeleprompterTextLayer(
              scrollController: controller,
              lines: lines,
              currentIndex: 0,
              fontSize: 64,
              lineHeight: 1.5,
              mirrorMode: mirror,
              continuous: true,
              annotations: annotations,
              onCharTap: (_) => seeks++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final states = tester
          .stateList<ReadingEmphasisLineState>(find.byType(ReadingEmphasisLine))
          .toList();
      expect(states, hasLength(2));
      for (final state in states) {
        final label = state.debugAnnotationLayout!.rowAt(0).labels.single;
        // Use the actually painted part above the body box. A multiline label
        // can straddle y=0 while its overall centre remains inside the body.
        final borrowedPart = Rect.fromLTRB(
          label.rect.left,
          label.rect.top,
          label.rect.right,
          math.min(0, label.rect.bottom),
        );
        expect(borrowedPart.isEmpty, isFalse);
        final target = borrowedPart.center;
        expect(target.dy, lessThan(0), reason: '必须实际点击正文盒以外的借位备注');
        expect(label.rect.contains(target), isTrue);
        final box = state.context.findRenderObject()! as RenderBox;
        await tester.tapAt(box.localToGlobal(target));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(seeks, 0);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('实时预览截取远处完整字素并保留原索引，点击词框或上方备注只回调目标批注', (tester) async {
    final text = '${List.filled(1000, '原文内容').join()}👩🏽‍💻重点知识和后面的解释';
    final focus = text.indexOf('重点');
    final target = _note(text, focus, focus + 2, '重读', id: 'target');
    final unrelated = _note(text, 0, 2, '先停顿', id: 'unrelated');
    final tapped = <ReadingAnnotation>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 650,
            child: ReadingAnnotationPreview(
              content: text,
              annotations: [unrelated, target],
              focusRawIndex: focus,
              onNoteTap: tapped.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final line = tester.widget<ReadingEmphasisLine>(
      find.byType(ReadingEmphasisLine),
    );
    expect(line.line.characters.first.rawIndex, greaterThan(focus - 30));
    expect(line.line.text, contains('👩🏽‍💻'));
    expect(line.line.text, contains('重点'));
    expect(line.annotations, [target]);
    final state = tester.state<ReadingEmphasisLineState>(
      find.byType(ReadingEmphasisLine),
    );
    final row = state.debugAnnotationLayout!.rowAt(0);
    final box = state.context.findRenderObject()! as RenderBox;
    final drag = await tester.startGesture(
      box.localToGlobal(row.anchors.single.frame.center),
    );
    await drag.moveBy(const Offset(25, 0));
    await drag.moveBy(const Offset(-25, 0));
    await drag.up();
    await tester.pump();
    expect(tapped, isEmpty, reason: '短距离拖动后回到批注框也不能误打开编辑');
    await tester.tapAt(box.localToGlobal(row.anchors.single.frame.center));
    await tester.pump();
    expect(tapped, [target]);
    await tester.tapAt(box.localToGlobal(row.labels.single.rect.center));
    await tester.pump();
    expect(tapped, [target, target]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('批注显隐和增删均不重建正文测量或改变滚动位置与范围', (tester) async {
    final text = List.filled(80, 'abcdefghijklmnop').join('\n');
    final lines = TextParser.parsePlainText(text);
    final note = _note(text, 2, 5, '重读');
    final annotations = [note];
    final controller = ScrollController();
    final key = GlobalKey<TeleprompterTextLayerState>();
    Future<void> show(bool visible, List<ReadingAnnotation> values) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeleprompterTextLayer(
              key: key,
              scrollController: controller,
              lines: lines,
              currentIndex: 0,
              fontSize: 40,
              lineHeight: 1.5,
              mirrorMode: false,
              continuous: true,
              annotations: values,
              showAnnotations: visible,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(false, const []);
    controller.jumpTo(1200);
    await tester.pump();
    final metrics = key.currentState!.debugMetricsBuildCount;
    final intrinsic = key.currentState!.debugIntrinsicWidthBuildCount;
    final extent = controller.position.maxScrollExtent;
    final offset = controller.offset;
    final rawIndex = key.currentState!.rawIndexAtViewport();
    for (final visible in [true, false, true]) {
      await show(visible, annotations);
      expect(controller.offset, closeTo(offset, .001));
      expect(controller.position.maxScrollExtent, closeTo(extent, .001));
      expect(key.currentState!.rawIndexAtViewport(), rawIndex);
      expect(key.currentState!.debugMetricsBuildCount, metrics);
      expect(key.currentState!.debugIntrinsicWidthBuildCount, intrinsic);
    }
    await show(true, const []);
    expect(controller.position.maxScrollExtent, closeTo(extent, .001));
    expect(controller.offset, closeTo(offset, .001));
    expect(key.currentState!.debugMetricsBuildCount, metrics);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('长段落的批注只测量访问行，原生备注排版缓存有固定上限', () {
    final text = List.filled(240, 'abcdef').join();
    final value = _layout(
      text,
      [_note(text, 0, text.length, '放慢语速')],
      width: 300,
      fontSize: 40,
    );
    expect(
      value.body.rows.length,
      greaterThan(ReadingAnnotationLayout.maximumCachedRows),
    );
    expect(value.notes.debugCachedRowCount, 0);
    for (var i = 0; i < value.body.rows.length; i++) {
      value.notes.rowAt(i);
      expect(
        value.notes.debugCachedRowCount,
        lessThanOrEqualTo(ReadingAnnotationLayout.maximumCachedRows),
      );
    }
    final visible = value.notes.rowsIn(const Rect.fromLTWH(0, 1000, 300, 400));
    expect(visible.length, lessThan(12));
  });
}
