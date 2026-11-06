import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

class _NavigationHarness {
  final WidgetTester tester;
  final List<ScriptLine> lines;
  final key = GlobalKey<TeleprompterTextLayerState>();
  final controller = ScrollController();

  _NavigationHarness(this.tester, this.lines) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  TeleprompterTextLayerState get state => key.currentState!;

  Future<void> show({
    int index = 0,
    bool mirror = false,
    double scale = 1.1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 400,
            child: TeleprompterTextLayer(
              key: key,
              scrollController: controller,
              lines: lines,
              currentIndex: index,
              fontSize: 26,
              lineHeight: 1.5,
              mirrorMode: mirror,
              currentCharScale: scale,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<ReadingTextLayout> measureParagraphs() {
    final rendered = tester.widget<ReadingEmphasisLine>(
      find.byType(ReadingEmphasisLine).first,
    );
    final layouts = [
      for (final line in lines)
        if (line.characters.isNotEmpty)
          ReadingTextLayout(
            line: line,
            geometry: rendered.geometry,
            width: rendered.width,
            direction: rendered.direction,
          ),
    ];
    addTearDown(() {
      for (final layout in layouts) {
        layout.dispose();
      }
    });
    return layouts;
  }
}

typedef _VisualRow = ({ReadingTextLayout layout, ReadingVisualRow row});

List<_VisualRow> _rows(List<ReadingTextLayout> layouts) => [
  for (final layout in layouts)
    for (final row in layout.rows) (layout: layout, row: row),
];

int _rawAt(_VisualRow target, double x) =>
    target.layout.rawIndexForOffset(Offset(x, target.row.centerY))!;

List<ScriptLine> _mixedParagraphs() {
  final paragraphs = TextParser.parse(
    '<p>${List.filled(8, '中文提词稳定阅读。').join()}</p>'
    '<p><span style="font-size: 48px">'
    '${List.filled(8, '大字段落换行。').join()}</span></p>'
    '<p><span style="font-size: 16px">'
    '${List.filled(8, '小字段落稳定阅读。').join()}</span></p>',
  );
  return [
    const ScriptLine(characters: [], lineIndex: 0),
    paragraphs[0],
    const ScriptLine(characters: [], lineIndex: 2),
    const ScriptLine(characters: [], lineIndex: 3),
    paragraphs[1],
    const ScriptLine(characters: [], lineIndex: 5),
    paragraphs[2],
    const ScriptLine(characters: [], lineIndex: 7),
  ];
}

void main() {
  testWidgets('单段翻页保留完整步数并保持列位置', (tester) async {
    final harness = _NavigationHarness(
      tester,
      TextParser.parse('<p>${List.filled(120, '中文提词稳定阅读。').join()}</p>'),
    );
    await harness.show(index: 3);
    final layout = harness.measureParagraphs().single;
    final rows = _rows([layout]);
    expect(rows.length, greaterThan(13));
    final x = layout.placementForRawIndex(3)!.cell.center.dx;

    expect(harness.state.rawIndexForVisualLineMove(1), _rawAt(rows[1], x));
    expect(harness.state.rawIndexForVisualLineMove(5), _rawAt(rows[5], x));

    final middle = _rawAt(rows[8], x);
    await harness.show(index: middle);
    final middleX = layout.placementForRawIndex(middle)!.cell.center.dx;
    expect(
      harness.state.rawIndexForVisualLineMove(-5),
      _rawAt(rows[3], middleX),
    );
    expect(
      harness.state.rawIndexForVisualLineMove(5),
      _rawAt(rows[13], middleX),
    );
    expect(harness.state.rawIndexForVisualLineMove(0), isNull);
  });

  testWidgets('跨段翻页按真实可视行计数并跳过空段', (tester) async {
    final harness = _NavigationHarness(tester, _mixedParagraphs());
    await harness.show();
    final layouts = harness.measureParagraphs();
    final rows = _rows(layouts);
    expect(layouts.every((layout) => layout.rows.length > 1), isTrue);
    expect(
      rows.map((entry) => entry.row.height).toSet().length,
      greaterThan(1),
    );

    final startRow = layouts.first.rows.length - 1;
    final targetRow =
        rows.indexWhere((entry) => entry.layout == layouts.last) + 1;
    final start = _rawAt(rows[startRow], 90);
    await harness.show(index: start);
    final startX = rows[startRow].layout
        .placementForRawIndex(start)!
        .cell
        .center
        .dx;
    final target = _rawAt(rows[targetRow], startX);
    expect(
      harness.state.rawIndexForVisualLineMove(targetRow - startRow),
      target,
    );

    await harness.show(index: target);
    final targetX = rows[targetRow].layout
        .placementForRawIndex(target)!
        .cell
        .center
        .dx;
    expect(
      harness.state.rawIndexForVisualLineMove(startRow - targetRow),
      _rawAt(rows[startRow], targetX),
    );
  });

  testWidgets('越界翻页停在首末可读行且边界继续移动保持原位', (tester) async {
    final harness = _NavigationHarness(tester, _mixedParagraphs());
    await harness.show();
    final rows = _rows(harness.measureParagraphs());
    final middleRow = rows[rows.length ~/ 2];
    final middle = _rawAt(middleRow, 90);
    await harness.show(index: middle);
    final x = middleRow.layout.placementForRawIndex(middle)!.cell.center.dx;
    final first = _rawAt(rows.first, x);
    final last = _rawAt(rows.last, x);
    expect(harness.state.rawIndexForVisualLineMove(-10000), first);
    expect(harness.state.rawIndexForVisualLineMove(10000), last);

    await harness.show(index: last);
    expect(harness.state.rawIndexForVisualLineMove(1), last);
    expect(harness.state.rawIndexForVisualLineMove(5), last);
    await harness.show(index: first);
    expect(harness.state.rawIndexForVisualLineMove(-1), first);
    expect(harness.state.rawIndexForVisualLineMove(-5), first);
  });

  testWidgets('镜像和突出倍率不改变翻页目标或已有布局', (tester) async {
    final harness = _NavigationHarness(
      tester,
      TextParser.parse(List.filled(120, '中文提词稳定阅读。').join()),
    );
    await harness.show(index: 3);
    final lineState = tester.state<ReadingEmphasisLineState>(
      find.byType(ReadingEmphasisLine).first,
    );
    final layout = lineState.debugLayout;
    final target = harness.state.rawIndexForVisualLineMove(5);
    final extent = harness.controller.position.maxScrollExtent;
    final metricsBuildCount = harness.state.debugMetricsBuildCount;
    for (final mirror in [true, false]) {
      for (final scale in [1.0, 1.15]) {
        await harness.show(index: 3, mirror: mirror, scale: scale);
        expect(harness.state.rawIndexForVisualLineMove(5), target);
        expect(lineState.debugLayout, same(layout));
        expect(harness.state.debugMetricsBuildCount, metricsBuildCount);
        expect(harness.controller.position.maxScrollExtent, extent);
      }
    }
  });

  testWidgets('空稿和未开始状态保留原有导航行为', (tester) async {
    for (final lines in <List<ScriptLine>>[
      [],
      [const ScriptLine(characters: [], lineIndex: 0)],
      _mixedParagraphs(),
    ]) {
      final harness = _NavigationHarness(tester, lines);
      await harness.show(index: -1);
      final readable = lines.where((line) => line.characters.isNotEmpty);
      final expected = readable.isEmpty
          ? null
          : readable.first.characters.first.rawIndex;
      expect(harness.state.rawIndexForVisualLineMove(5), expected);
      expect(harness.state.rawIndexForVisualLineMove(-5), expected);
      expect(harness.state.rawIndexForVisualLineMove(0), isNull);
    }
  });
}
