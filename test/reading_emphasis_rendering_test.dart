import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

const _sourceColor = Color(0xFF1976D2);
const _currentColor = Color(AppSettings.defaultCurrentCharColor);
const _readColor = Color(AppSettings.defaultReadCharColor);

Widget _lineHost({
  required GlobalKey<ReadingEmphasisLineState> key,
  required ScriptLine line,
  required ReadingGlyphPainterCache cache,
  required ReadingTextPresentation presentation,
  ReadingTextGeometry geometry = const ReadingTextGeometry(
    fontSize: 32,
    lineHeight: 1.5,
  ),
  double width = 360,
  bool mirror = false,
  ValueChanged<int>? onTap,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(mirror ? -1 : 1, 1, 1),
        child: ReadingEmphasisLine(
          key: key,
          line: line,
          geometry: geometry,
          presentation: presentation,
          glyphCache: cache,
          width: width,
          direction: TextDirection.ltr,
          onCharTap: onTap,
        ),
      ),
    ),
  ),
);

ReadingTextPresentation _presentation({
  int index = 1,
  double scale = 1,
  bool enabled = true,
  bool grayReadChars = true,
  bool continuous = false,
  bool bold = false,
  bool underline = false,
}) => ReadingTextPresentation(
  currentIndex: index,
  currentCharScale: scale,
  enabled: enabled,
  grayReadChars: grayReadChars,
  continuous: continuous,
  highlightCurrentChar: bold,
  underlineCurrentChar: underline,
  textColor: _sourceColor.toARGB32(),
);

class _Raster {
  final int width;
  final int height;
  final Uint8List bytes;
  const _Raster(this.width, this.height, this.bytes);

  Rect? colorBounds(Color color, {Rect? within}) {
    var left = width;
    var right = -1;
    var top = height;
    var bottom = -1;
    final argb = color.toARGB32();
    final r = (argb >> 16) & 255;
    final g = (argb >> 8) & 255;
    final b = argb & 255;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (within != null && !within.contains(Offset(x + .5, y + .5)))
          continue;
        final at = (y * width + x) * 4;
        if (bytes[at + 3] < 230 ||
            (bytes[at] - r).abs() > 2 ||
            (bytes[at + 1] - g).abs() > 2 ||
            (bytes[at + 2] - b).abs() > 2)
          continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    return right < 0
        ? null
        : Rect.fromLTRB(left.toDouble(), top.toDouble(), right + 1, bottom + 1);
  }

  /// Paragraphs now share one colour. Compare same-colour baseline pixels to
  /// isolate the enlarged glyph without clipping away an actual overflow.
  Rect? differenceBounds(_Raster baseline) {
    expect((width, height), (baseline.width, baseline.height));
    var left = width;
    var right = -1;
    var top = height;
    var bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = (y * width + x) * 4;
        var different = false;
        for (var channel = 0; channel < 4; channel++) {
          if (bytes[at + channel] != baseline.bytes[at + channel]) {
            different = true;
            break;
          }
        }
        if (!different) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    return right < 0
        ? null
        : Rect.fromLTRB(left.toDouble(), top.toDouble(), right + 1, bottom + 1);
  }
}

Future<_Raster> _capture(WidgetTester tester, Finder line) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(of: line, matching: find.byType(RepaintBoundary)).first,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final raster = _Raster(
      image.width,
      image.height,
      Uint8List.fromList(data!.buffer.asUint8List()),
    );
    image.dispose();
    return raster;
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('整段同色且原位放大保持几何；当前字只有一份，段落读完恢复原尺寸', (tester) async {
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    final line = TextParser.parse('甲乙丙').first;
    Future<void> show(ReadingTextPresentation state) async {
      await tester.pumpWidget(
        _lineHost(key: key, line: line, cache: cache, presentation: state),
      );
      await tester.pump();
    }

    await show(_presentation());
    final layout = key.currentState!.debugLayout;
    final cells = [
      for (var i = 0; i < layout.graphemes.length; i++)
        layout.placementAt(i).cell,
    ];
    final sizeBefore = tester.getSize(find.byKey(key));
    final initial = await _capture(tester, find.byKey(key));
    final initialCurrent = initial.colorBounds(
      _currentColor,
      within: cells[1],
    )!;
    for (final cell in cells) {
      expect(initial.colorBounds(_currentColor, within: cell), isNotNull);
    }
    expect(initial.colorBounds(_readColor), isNull);
    expect(initial.colorBounds(_sourceColor), isNull);

    await show(_presentation(scale: 1.15));
    final enlarged = await _capture(tester, find.byKey(key));
    final enlargedCurrent = enlarged.colorBounds(
      _currentColor,
      within: cells[1],
    )!;
    expect(enlargedCurrent.width, greaterThan(initialCurrent.width));
    expect(enlargedCurrent.height, greaterThan(initialCurrent.height));
    expect(enlargedCurrent.center.dx, closeTo(initialCurrent.center.dx, 1));
    expect(enlargedCurrent.bottom, closeTo(initialCurrent.bottom, 1));
    expect(
      enlarged.colorBounds(_sourceColor, within: cells[1]),
      isNull,
      reason: '当前字底下不能残留未读色的小字',
    );
    expect(
      enlarged.colorBounds(_readColor, within: cells[1]),
      isNull,
      reason: '当前字不能同时算已读',
    );
    expect(tester.getSize(find.byKey(key)), sizeBefore);
    expect(key.currentState!.debugLayout, same(layout));
    expect(key.currentState!.debugLayoutBuildCount, 1);

    await show(_presentation(index: 2, scale: 1.15));
    final advanced = await _capture(tester, find.byKey(key));
    final previousGlyph = advanced.colorBounds(
      _currentColor,
      within: cells[1],
    )!;
    expect(previousGlyph.width, closeTo(initialCurrent.width, 1));
    expect(previousGlyph.height, closeTo(initialCurrent.height, 1));
    expect(advanced.colorBounds(_currentColor, within: cells[2]), isNotNull);
    expect(advanced.colorBounds(_readColor), isNull);

    await show(_presentation(index: 3, scale: 1.15));
    final completed = await _capture(tester, find.byKey(key));
    expect(completed.colorBounds(_currentColor), isNull);
    for (final cell in cells) {
      expect(completed.colorBounds(_readColor, within: cell), isNotNull);
    }
    expect(
      completed.colorBounds(_readColor, within: cells[1])!.width,
      closeTo(initialCurrent.width, 1),
    );

    await show(_presentation(index: 1, enabled: false, scale: 1.15));
    final disabled = await _capture(tester, find.byKey(key));
    expect(disabled.colorBounds(_currentColor), isNull);
    expect(
      disabled.colorBounds(_sourceColor, within: cells[1])!.width,
      closeTo(initialCurrent.width, 1),
    );
    expect(disabled.colorBounds(_readColor), isNull);
    expect(key.currentState!.debugLayout, same(layout));

    await show(_presentation(index: 1, grayReadChars: false));
    final readOff = await _capture(tester, find.byKey(key));
    expect(readOff.colorBounds(_readColor), isNull);
    expect(readOff.colorBounds(_currentColor, within: cells[0]), isNotNull);
    expect(readOff.colorBounds(_currentColor, within: cells[1]), isNotNull);
    await show(_presentation(index: 3, grayReadChars: false));
    final completedReadOff = await _capture(tester, find.byKey(key));
    expect(completedReadOff.colorBounds(_readColor), isNull);
    expect(completedReadOff.colorBounds(_currentColor), isNull);
    for (final cell in cells) {
      expect(
        completedReadOff.colorBounds(_sourceColor, within: cell),
        isNotNull,
      );
    }
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('中文、中英数字标点、混合字号与字符簇始终使用固定字框和点击坐标', (tester) async {
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    final line = TextParser.parse(
      '<p>中文 AV fi 123，。<b>粗体</b><span style="font-size: 44px; color: #3366ff">标题</span>👩🏽‍💻e\u0301尾</p>',
    ).first;
    final tapped = <int>[];
    const geometry = ReadingTextGeometry(fontSize: 22, lineHeight: 1.4);
    Future<void> show({
      required int index,
      required double scale,
      bool mirror = false,
    }) async {
      await tester.pumpWidget(
        _lineHost(
          key: key,
          line: line,
          cache: cache,
          presentation: _presentation(
            index: index,
            scale: scale,
            bold: true,
            underline: true,
          ),
          geometry: geometry,
          width: 260,
          mirror: mirror,
          onTap: tapped.add,
        ),
      );
      await tester.pump();
    }

    await show(index: 0, scale: 1);
    final layout = key.currentState!.debugLayout;
    final positions = [
      for (var i = 0; i < layout.graphemes.length; i++)
        layout.placementAt(i).cell,
    ];
    final rows = [
      for (final row in layout.rows) (row.start, row.end, row.top, row.height),
    ];
    expect(rows.length, greaterThan(1));
    expect(
      layout.graphemes.map((g) => g.text),
      containsAll(['👩🏽‍💻', 'e\u0301']),
    );
    expect(layout.graphemes.map((g) => g.text).join(), line.text);

    for (final mirror in [false, true]) {
      for (final scale in [1.0, 1.15]) {
        for (var i = 0; i < layout.graphemes.length; i++) {
          final glyph = layout.graphemes[i];
          if (glyph.text.trim().isEmpty) continue;
          // Target the last UTF-16 unit too: emoji and combining marks must
          // still activate and hit-test as one complete displayed character.
          await show(index: glyph.rawEnd, scale: scale, mirror: mirror);
          expect(key.currentState!.debugLayout, same(layout));
          expect(layout.placementAt(i).cell, positions[i]);
          final appearance = _presentation(
            index: glyph.rawEnd,
            scale: scale,
          ).appearanceFor(glyph, geometry);
          expect(appearance.isCurrent, isTrue);
          expect(appearance.isRead, isFalse);
          final box = tester.renderObject<RenderBox>(find.byKey(key));
          await tester.tapAt(box.localToGlobal(positions[i].center));
          expect(tapped.last, glyph.rawStart);
        }
      }
    }
    expect([
      for (final row in layout.rows) (row.start, row.end, row.top, row.height),
    ], rows);
    expect(key.currentState!.debugLayoutBuildCount, 1);
    final heading = layout.graphemes.firstWhere((g) => g.text == '标');
    final headingAppearance = _presentation(
      index: -1,
    ).appearanceFor(heading, geometry);
    expect(headingAppearance.style.fontSize, 44);
    expect(headingAppearance.style.color, const Color(0xFF3366FF));
    final bold = layout.graphemes.firstWhere((g) => g.text == '粗');
    expect(
      _presentation(index: -1).appearanceFor(bold, geometry).style.fontWeight,
      FontWeight.w700,
    );
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('匀速模式实际像素与无阅读状态相同，当前色倍率及旧加粗下划线都不生效', (tester) async {
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    final line = TextParser.parse('甲乙 ABC123，末尾。').first;
    await tester.pumpWidget(
      _lineHost(
        key: key,
        line: line,
        cache: cache,
        presentation: _presentation(index: -1),
      ),
    );
    final normal = await _capture(tester, find.byKey(key));
    final layout = key.currentState!.debugLayout;
    await tester.pumpWidget(
      _lineHost(
        key: key,
        line: line,
        cache: cache,
        presentation: _presentation(
          index: 4,
          continuous: true,
          scale: 1.15,
          bold: true,
          underline: true,
        ),
      ),
    );
    final continuous = await _capture(tester, find.byKey(key));
    expect(continuous.bytes, orderedEquals(normal.bytes));
    expect(key.currentState!.debugLayout, same(layout));
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('长稿保持按段懒加载，改倍率颜色及阅读位置不重测全稿或改变滚动高度', (tester) async {
    final key = GlobalKey<TeleprompterTextLayerState>();
    final controller = ScrollController();
    final lines = TextParser.parse(
      List.filled(400, '<p>中文长稿 123，稳定阅读。</p>').join(),
    );
    Future<void> show({
      double scale = 1,
      bool enabled = true,
      int index = 50,
      bool playing = false,
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
                mirrorMode: false,
                readingEmphasisEnabled: enabled,
                currentCharScale: scale,
                currentCharColor: enabled ? 0xFFFFD54F : 0xFF66BB6A,
                isPlaying: playing,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    key.currentState!.scrollToCurrentChar(animate: false);
    await tester.pumpAndSettle();
    final extent = controller.position.maxScrollExtent;
    final offset = controller.offset;
    expect(find.byType(ReadingEmphasisLine).evaluate().length, lessThan(50));
    expect(key.currentState!.debugMetricsBuildCount, 1);
    for (final scale in [1.15, 1.0, 1.10]) {
      for (final enabled in [false, true]) {
        await show(scale: scale, enabled: enabled, playing: enabled);
        expect(controller.offset, closeTo(offset, 0.01));
        expect(controller.position.maxScrollExtent, closeTo(extent, 0.01));
        expect(key.currentState!.debugMetricsBuildCount, 1);
      }
    }
    await show(scale: 1.15, index: 3000);
    expect(controller.position.maxScrollExtent, closeTo(extent, 0.01));
    expect(key.currentState!.debugMetricsBuildCount, 1);
    expect(find.byType(ReadingEmphasisLine).evaluate().length, lessThan(50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('真实粗斜体在最大倍率下不侵入邻字；字形缓存保持有界', (tester) async {
    final loader = FontLoader('ReadingBearingFixture')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              'test/fixtures/reading_emphasis/DejaVuSansMono-BoldOblique.ttf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await loader.load();
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache(capacity: 12);
    final line = TextParser.parse(
      '<p><b><i>fjAVW(123),.;!?/</i></b></p>',
    ).first;
    const geometry = ReadingTextGeometry(
      fontSize: 42,
      lineHeight: 1.5,
      fontFamily: 'ReadingBearingFixture',
    );
    // Independent font-table bounds (units/em = 2048) from the unchanged
    // fixture. Their synthetic-shear envelopes make the Windows regression
    // reproducible even on engines that correctly choose its native italic.
    const outlines = <String, (double, double, double, double)>{
      'f': (231, 0, 1268, 1556),
      'j': (-63, -424, 1049, 1665),
      'W': (41, 0, 1370, 1493),
    };
    ReadingTextLayout? fixedLayout;
    List<Rect>? fixedCells;
    List<double>? fixedAnchors;
    for (var index = 0; index < line.characters.length; index++) {
      await tester.pumpWidget(
        _lineHost(
          key: key,
          line: line,
          cache: cache,
          geometry: geometry,
          width: 500,
          presentation: _presentation(index: index, scale: 1, bold: true),
        ),
      );
      final baselineRaster = await _capture(tester, find.byKey(key));
      await tester.pumpWidget(
        _lineHost(
          key: key,
          line: line,
          cache: cache,
          geometry: geometry,
          width: 500,
          presentation: _presentation(index: index, scale: 1.15, bold: true),
        ),
      );
      final layout = key.currentState!.debugLayout;
      final cell = layout.placementForRawIndex(index)!.cell;
      final raster = await _capture(tester, find.byKey(key));
      final ink = raster.differenceBounds(baselineRaster)!;
      final glyph = layout.graphemes[index];
      final appearance = _presentation(
        index: index,
        scale: 1.15,
        bold: true,
      ).appearanceFor(glyph, geometry);
      final drawnPainter = cache.painterFor(
        glyph.text,
        appearance.style,
        TextDirection.ltr,
      );
      expect(
        drawnPainter.width,
        closeTo(42 * 1233 / 2048, 0.01),
        reason: 'The real fixture must be loaded, not a square test fallback.',
      );
      final placement = layout.placementForRawIndex(index)!;
      final outline = outlines[glyph.text];
      if (outline != null) {
        final unitScale = 42 * 1.15 / 2048;
        final originX = placement.paintAnchorX - drawnPainter.width * 1.15 / 2;
        expect(
          originX + (outline.$1 + 0.25 * outline.$2) * unitScale,
          greaterThanOrEqualTo(cell.left),
          reason: 'Unclipped synthetic-italic outline left: ${glyph.text}',
        );
        expect(
          originX + (outline.$3 + 0.25 * outline.$4) * unitScale,
          lessThanOrEqualTo(cell.right),
          reason: 'Unclipped synthetic-italic outline right: ${glyph.text}',
        );
      }
      final cells = [
        for (var i = 0; i < layout.graphemes.length; i++)
          layout.placementAt(i).cell,
      ];
      final anchors = [
        for (var i = 0; i < layout.graphemes.length; i++)
          layout.placementAt(i).paintAnchorX,
      ];
      fixedLayout ??= layout;
      fixedCells ??= cells;
      fixedAnchors ??= anchors;
      expect(layout, same(fixedLayout));
      expect(cells, fixedCells);
      expect(anchors, fixedAnchors);
      final diagnostics =
          '${Platform.operatingSystem}: glyph=${glyph.text}, '
          'cell=$cell, ink=$ink, anchor=${placement.paintAnchorX}, '
          'drawnSize=${drawnPainter.size}, drawnStyle=${appearance.style}';
      expect(
        ink.left,
        greaterThanOrEqualTo(cell.left - 1),
        reason: 'left bearing: $diagnostics',
      );
      expect(
        ink.right,
        lessThanOrEqualTo(cell.right + 1),
        reason: 'right bearing: $diagnostics',
      );
      expect(ink.top, greaterThanOrEqualTo(cell.top - 1));
      expect(ink.bottom, lessThanOrEqualTo(cell.bottom + 1));
      expect(cache.length, lessThanOrEqualTo(12));
    }
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('负字距不吃掉安全字位，小绝对字号和行首尾最大倍率仍可准确点击', (tester) async {
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    final line = TextParser.parse(
      '<p>A1，。<span style="font-size: 8px">甲乙23，</span>中尾</p>',
    ).first;
    const geometry = ReadingTextGeometry(
      fontSize: 20,
      lineHeight: 1.5,
      letterSpacing: -2,
    );
    await tester.pumpWidget(
      _lineHost(
        key: key,
        line: line,
        cache: cache,
        geometry: geometry,
        width: 96,
        presentation: _presentation(index: 0, scale: 1.15),
      ),
    );
    final layout = key.currentState!.debugLayout;
    final originalCells = [
      for (var i = 0; i < layout.graphemes.length; i++)
        layout.placementAt(i).cell,
    ];
    final zeroSpacing = ReadingTextLayout(
      line: line,
      geometry: const ReadingTextGeometry(fontSize: 20, lineHeight: 1.5),
      width: 96,
      direction: TextDirection.ltr,
    );
    expect([
      for (var i = 0; i < layout.graphemes.length; i++)
        zeroSpacing.placementAt(i).cell,
    ], originalCells);
    zeroSpacing.dispose();
    final tapped = <int>[];
    for (var index = 0; index < layout.graphemes.length; index++) {
      final glyph = layout.graphemes[index];
      await tester.pumpWidget(
        _lineHost(
          key: key,
          line: line,
          cache: cache,
          geometry: geometry,
          width: 96,
          presentation: _presentation(index: glyph.rawStart, scale: 1),
          onTap: tapped.add,
        ),
      );
      final baselineRaster = await _capture(tester, find.byKey(key));
      await tester.pumpWidget(
        _lineHost(
          key: key,
          line: line,
          cache: cache,
          geometry: geometry,
          width: 96,
          presentation: _presentation(index: glyph.rawStart, scale: 1.15),
          onTap: tapped.add,
        ),
      );
      final raster = await _capture(tester, find.byKey(key));
      final ink = raster.differenceBounds(baselineRaster)!;
      final cell = originalCells[index];
      expect(ink.left, greaterThanOrEqualTo(cell.left - 1));
      expect(ink.right, lessThanOrEqualTo(cell.right + 1));
      expect(ink.top, greaterThanOrEqualTo(cell.top - 1));
      expect(ink.bottom, lessThanOrEqualTo(cell.bottom + 1));
      final box = tester.renderObject<RenderBox>(find.byKey(key));
      await tester.tapAt(box.localToGlobal(cell.center));
      expect(tapped.last, glyph.rawStart);
      expect(key.currentState!.debugLayout, same(layout));
    }
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('一整篇未分段长稿也只绘制可见窗口，滚动及更新游标不重排全稿', (tester) async {
    final key = GlobalKey<TeleprompterTextLayerState>();
    final controller = ScrollController();
    final lines = TextParser.parse(List.filled(800, '长段123，。').join());
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
              currentIndex: 0,
              fontSize: 22,
              lineHeight: 1.5,
              mirrorMode: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    ReadingTextPainter actualPainter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ReadingTextPainter>()
        .single;
    expect(actualPainter().layout.graphemes.length, greaterThan(5000));
    expect(
      actualPainter().debugLastPaintedGlyphCount,
      inExclusiveRange(0, 500),
    );
    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pump();
    expect(
      actualPainter().debugLastPaintedGlyphCount,
      inExclusiveRange(0, 500),
    );
    expect(key.currentState!.debugMetricsBuildCount, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
