import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_area_frame.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

class _WidthHarness {
  final WidgetTester tester;
  final controller = ScrollController();
  final key = GlobalKey<TeleprompterTextLayerState>();
  List<ScriptLine> lines;
  int currentIndex = 0;
  double fontSize = 32;
  double letterSpacing = 0;
  double paddingX = 0;
  double currentCharScale = 1;
  int currentCharColor = 0xFFFFC800;
  bool mirror = false;
  bool continuous = false;
  TextDirection direction = TextDirection.ltr;

  _WidthHarness(this.tester, String source) : lines = TextParser.parse(source) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> show(
    Size size, {
    double systemTextScale = 1,
    double dpr = 1,
  }) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(systemTextScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Directionality(
            textDirection: direction,
            child: TeleprompterTextLayer(
              key: key,
              scrollController: controller,
              lines: lines,
              currentIndex: currentIndex,
              fontSize: fontSize,
              lineHeight: 1.5,
              letterSpacing: letterSpacing,
              paddingX: paddingX,
              mirrorMode: mirror,
              currentCharScale: currentCharScale,
              currentCharColor: currentCharColor,
              continuous: continuous,
              showReadingFrame: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TeleprompterTextLayerState get state => key.currentState!;
  Rect get row => state.debugCurrentRowRect!;

  Iterable<ReadingEmphasisLine> get visibleLines =>
      tester.widgetList<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine));

  ReadingTextGeometry get geometry => visibleLines.first.geometry;

  double intrinsicWidth(ScriptLine line) {
    final layout = ReadingTextLayout(
      line: line,
      geometry: geometry,
      width: double.infinity,
      direction: direction,
    );
    final width = layout.maxIntrinsicWidth;
    layout.dispose();
    return width;
  }

  double get widestManualLine =>
      lines.fold(0, (widest, line) => math.max(widest, intrinsicWidth(line)));

  void expectUnwrappedVisibleLines() {
    for (final lineState in tester.stateList<ReadingEmphasisLineState>(
      find.byType(ReadingEmphasisLine),
    )) {
      expect(lineState.debugLayout.rows, hasLength(1));
    }
  }
}

void main() {
  testWidgets('最长人工行决定统一正文宽度，短行和换段不会拉宽阅读括线', (tester) async {
    final harness = _WidthHarness(
      tester,
      '<p>甲乙丙丁戊己庚辛壬癸子丑寅卯辰</p><p>短句</p><p>中等长度文字</p>',
    );
    const size = Size(1800, 700);
    await harness.show(size);
    final width = harness.row.width;
    expect(width, harness.widestManualLine.ceilToDouble() + 2);
    expect(width, lessThan(size.width / 2));
    expect(harness.row.center.dx, closeTo(size.width / 2, 0.01));
    expect(harness.geometry.fontSize, 32);
    expect(harness.geometry.fontScale, 1);
    expect(harness.geometry.letterSpacing, 0);
    for (final line in harness.visibleLines) {
      expect(line.width, width);
    }
    harness.expectUnwrappedVisibleLines();
    final metrics = harness.state.debugMetricsBuildCount;
    final measurements = harness.state.debugIntrinsicWidthBuildCount;

    harness.currentIndex = harness.lines.last.characters.first.rawIndex;
    await harness.show(size);
    expect(harness.row.width, width);
    expect(harness.row.center.dx, closeTo(size.width / 2, 0.01));
    expect(harness.row.center.dy, closeTo(size.height / 2, 0.5));
    expect(harness.state.debugIntrinsicWidthBuildCount, measurements);
    expect(harness.state.debugMetricsBuildCount, metrics);
    final frame = tester.widget<ReadingAreaFrame>(
      find.byType(ReadingAreaFrame),
    );
    expect(frame.row, harness.row);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一段中的人工软换行独立测宽，不把多句拼成一条超长行', (tester) async {
    final harness = _WidthHarness(
      tester,
      '<p>第一句，先讲清楚。<br>第二句话，按照节奏。<br>第三句。</p>',
    );
    await harness.show(const Size(1600, 700));
    final widths = harness.lines
        .where((line) => line.characters.isNotEmpty)
        .map(harness.intrinsicWidth)
        .toList();
    expect(widths, hasLength(3));
    expect(harness.row.width, widths.reduce(math.max).ceilToDouble() + 2);
    expect(harness.row.width, lessThan(widths.reduce((a, b) => a + b)));
    harness.expectUnwrappedVisibleLines();
    expect(tester.takeException(), isNull);
  });

  testWidgets('未进入视口的最长人工行同样决定全稿宽度', (tester) async {
    final harness = _WidthHarness(
      tester,
      List.filled(90, '<p>短句</p>').join() + '<p>最后这一人工行才是整份稿件最宽的一行。</p>',
    );
    const size = Size(2000, 700);
    await harness.show(size);
    final lastLine = harness.lines.last;
    expect(
      harness.visibleLines.every((line) => !identical(line.line, lastLine)),
      isTrue,
    );
    final width = harness.row.width;
    expect(width, harness.intrinsicWidth(lastLine).ceilToDouble() + 2);
    expect(width, greaterThan(harness.intrinsicWidth(harness.lines.first)));
    final measured = harness.state.debugIntrinsicWidthBuildCount;
    harness.currentIndex = lastLine.characters.first.rawIndex;
    await harness.show(size);
    expect(
      harness.visibleLines.any((line) => identical(line.line, lastLine)),
      isTrue,
    );
    expect(harness.row.width, width);
    expect(harness.state.debugIntrinsicWidthBuildCount, measured);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按混合字号和中英文标点真实占位测量，不用字数乘默认字号', (tester) async {
    final harness = _WidthHarness(
      tester,
      '<p><span style="font-size: 12px">中文字符数量更多但是小字</span></p>'
      '<p><span style="font-size: 90px"><i>WWW!</i></span></p>'
      '<p>句末标点，“中文” Latin fi!</p>',
    );
    harness.letterSpacing = 2;
    await harness.show(const Size(2600, 900), dpr: 1.5);
    final content = harness.lines
        .where((line) => line.characters.isNotEmpty)
        .toList();
    expect(
      content[0].characters.length,
      greaterThan(content[1].characters.length),
    );
    expect(
      harness.intrinsicWidth(content[1]),
      greaterThan(harness.intrinsicWidth(content[0])),
    );
    expect(harness.row.width, harness.widestManualLine.ceilToDouble() + 2);
    expect(harness.geometry.fontSize, 32);
    expect(harness.geometry.fontScale, 1);
    expect(harness.geometry.letterSpacing, 2);
    harness.expectUnwrappedVisibleLines();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗限制正文宽度并折行，恢复宽窗保持原字号和当前阅读位置', (tester) async {
    final harness = _WidthHarness(
      tester,
      '<p>按人工断句保留这一行完整文字宽度。</p><p>第二段按自己的节奏讲述。</p>',
    );
    harness.currentIndex = 10;
    await harness.show(const Size(1800, 700));
    final width = harness.row.width;
    final intrinsicBuilds = harness.state.debugIntrinsicWidthBuildCount;
    final geometry = harness.geometry;
    await harness.show(const Size(280, 700));
    expect(harness.row.width, lessThan(width));
    expect(harness.row.left, greaterThanOrEqualTo(0));
    expect(harness.row.right, lessThanOrEqualTo(280));
    expect(harness.row.center.dx, closeTo(140, 0.01));
    expect(harness.row.center.dy, closeTo(350, 0.5));
    expect(harness.geometry, geometry);
    expect(harness.state.debugIntrinsicWidthBuildCount, intrinsicBuilds);
    expect(
      tester
          .state<ReadingEmphasisLineState>(
            find.byType(ReadingEmphasisLine).first,
          )
          .debugLayout
          .rows
          .length,
      greaterThan(1),
    );
    await harness.show(const Size(1800, 700));
    expect(harness.row.width, width);
    expect(harness.row.center.dy, closeTo(350, 0.5));
    expect(harness.currentIndex, 10);
    expect(harness.geometry, geometry);
    expect(harness.state.debugIntrinsicWidthBuildCount, intrinsicBuilds);
    harness.expectUnwrappedVisibleLines();
    expect(tester.takeException(), isNull);
  });

  testWidgets('一次测宽缓存覆盖整稿，游标、颜色及当前字缩放不重新测量', (tester) async {
    final harness = _WidthHarness(
      tester,
      List.filled(400, '<p>这一段需要保留稳定阅读宽度。</p>').join(),
    );
    const size = Size(1600, 700);
    await harness.show(size);
    final width = harness.row.width;
    final intrinsicBuilds = harness.state.debugIntrinsicWidthBuildCount;
    final metricsBuilds = harness.state.debugMetricsBuildCount;
    expect(intrinsicBuilds, 1);
    for (var i = 1; i <= 30; i++) {
      harness.currentIndex = i;
      harness.currentCharScale = i.isEven ? 1 : 1.15;
      harness.currentCharColor = i.isEven ? 0xFFFFC800 : 0xFF00FF00;
      await harness.show(size);
      expect(harness.row.width, width);
      expect(harness.state.debugIntrinsicWidthBuildCount, intrinsicBuilds);
      expect(harness.state.debugMetricsBuildCount, metricsBuilds);
    }
    harness.mirror = true;
    await harness.show(size, systemTextScale: 2, dpr: 1.5);
    expect(harness.row.width, width);
    expect(harness.state.debugIntrinsicWidthBuildCount, intrinsicBuilds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本和排版设置变更失效测宽缓存，普通边距调整只限制最大宽度', (tester) async {
    final harness = _WidthHarness(tester, '<p>短句</p>');
    const size = Size(1800, 700);
    await harness.show(size);
    final initial = harness.row.width;
    var builds = harness.state.debugIntrinsicWidthBuildCount;
    harness.paddingX = 35;
    await harness.show(size);
    expect(harness.row.width, initial);
    expect(harness.state.debugIntrinsicWidthBuildCount, builds);

    harness.lines = TextParser.parse('<p>这次更换更长的一份新稿件</p>');
    await harness.show(size);
    expect(harness.row.width, greaterThan(initial));
    expect(harness.state.debugIntrinsicWidthBuildCount, ++builds);
    final beforeSpacing = harness.intrinsicWidth(harness.lines.first);
    harness.letterSpacing = 3;
    await harness.show(size);
    expect(
      harness.intrinsicWidth(harness.lines.first),
      greaterThan(beforeSpacing),
    );
    expect(harness.state.debugIntrinsicWidthBuildCount, ++builds);
    harness.fontSize = 40;
    await harness.show(size);
    expect(harness.state.debugIntrinsicWidthBuildCount, ++builds);
    harness.direction = TextDirection.rtl;
    await harness.show(size);
    expect(harness.state.debugIntrinsicWidthBuildCount, ++builds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单字短行不因内在列宽再次缩小字号，空白稿件安全显示', (tester) async {
    final harness = _WidthHarness(tester, '<p>字</p>');
    await harness.show(const Size(1600, 700));
    expect(harness.geometry.fontScale, 1);
    expect(harness.row.width, harness.widestManualLine.ceilToDouble() + 2);
    expect(harness.row.width, lessThan(100));
    harness.lines = TextParser.parse('');
    await harness.show(const Size(280, 120));
    expect(find.text('暂无内容'), findsOneWidget);
    expect(harness.state.debugCurrentRowRect, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短窗临时适配后测宽和行高缓存仍稳定，不取消纵向视觉居中', (tester) async {
    final harness = _WidthHarness(
      tester,
      '<p><span style="font-size: 128px">大字重点</span></p>'
      '<p>普通文字说明。</p>',
    );
    const size = Size(800, 120);
    await harness.show(size, systemTextScale: 2, dpr: 1.5);
    final geometry = harness.geometry;
    final width = harness.row.width;
    final intrinsicBuilds = harness.state.debugIntrinsicWidthBuildCount;
    final metricsBuilds = harness.state.debugMetricsBuildCount;
    expect(geometry.fontScale, lessThan(1));
    expect(width, harness.widestManualLine.ceilToDouble() + 2);
    expect(harness.row.center.dy, closeTo(60, 0.5));
    expect(harness.row.top, greaterThanOrEqualTo(0));
    expect(harness.row.bottom, lessThanOrEqualTo(120));
    for (var i = 1; i < 4; i++) {
      harness.currentIndex = i;
      await harness.show(size, systemTextScale: 2, dpr: 1.5);
      expect(harness.row.width, width);
      expect(harness.geometry, geometry);
      expect(harness.state.debugIntrinsicWidthBuildCount, intrinsicBuilds);
      expect(harness.state.debugMetricsBuildCount, metricsBuilds);
    }
    expect(tester.takeException(), isNull);
  });
}
