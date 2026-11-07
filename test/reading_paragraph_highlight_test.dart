import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';

const _active = Color(0xFFFFCC00);
const _read = Color(0xFF808080);
const _unread = Color(0xFF66AAFF);
const _geometry = ReadingTextGeometry(fontSize: 28, lineHeight: 1.5);

ReadingTextPresentation _presentation(
  int index, {
  bool enabled = true,
  bool continuous = false,
  bool grayReadChars = true,
  double scale = 1,
  bool bold = false,
  bool underline = false,
}) => ReadingTextPresentation(
  currentIndex: index,
  enabled: enabled,
  continuous: continuous,
  grayReadChars: grayReadChars,
  currentCharColor: _active.toARGB32(),
  readCharColor: _read.toARGB32(),
  textColor: _unread.toARGB32(),
  currentCharScale: scale,
  highlightCurrentChar: bold,
  underlineCurrentChar: underline,
);

List<ReadingTextLayout> _layouts(List<ScriptLine> lines, {double width = 150}) {
  final layouts = [
    for (final line in lines)
      ReadingTextLayout(
        line: line,
        geometry: _geometry,
        width: width,
        direction: TextDirection.ltr,
      ),
  ];
  addTearDown(() {
    for (final layout in layouts) {
      layout.dispose();
    }
  });
  return layouts;
}

List<ReadingGlyphAppearance> _appearances(
  ReadingTextLayout layout,
  ReadingTextPresentation presentation,
) => [
  for (final glyph in layout.graphemes)
    presentation.appearanceFor(glyph, layout.geometry),
];

Future<int> _colorPixelCount(
  WidgetTester tester,
  Finder line,
  Color color,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(of: line, matching: find.byType(RepaintBoundary)).first,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final argb = color.toARGB32();
    final red = (argb >> 16) & 255;
    final green = (argb >> 8) & 255;
    final blue = argb & 255;
    var count = 0;
    for (var i = 0; i < bytes.length; i += 4) {
      if (bytes[i + 3] > 230 &&
          (bytes[i] - red).abs() <= 2 &&
          (bytes[i + 1] - green).abs() <= 2 &&
          (bytes[i + 2] - blue).abs() <= 2) {
        count++;
      }
    }
    image.dispose();
    return count;
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('多句话人工段落跨所有自动折行和软换行整体高亮', () {
    final lines = TextParser.parse(
      '<p>第一句已经读了。第二句还没读！第三句也属于这段？'
      '<br>同段的第二个人工行也一起变色。</p><p>下一段。</p>',
    );
    final layouts = _layouts(lines);
    expect(layouts.first.rows.length, greaterThan(1));
    final paragraphGlyphs = [...layouts[0].graphemes, ...layouts[1].graphemes];
    for (final cursor in paragraphGlyphs) {
      final state = _presentation(cursor.rawEnd);
      final appearances = [
        ..._appearances(layouts[0], state),
        ..._appearances(layouts[1], state),
      ];
      expect(appearances.map((a) => a.style.color), everyElement(_active));
      expect(
        appearances.map((a) => a.isCurrentParagraph),
        everyElement(isTrue),
      );
      expect(appearances.map((a) => a.isRead), everyElement(isFalse));
      expect(appearances.where((a) => a.isCurrent), hasLength(1));
      expect(
        _appearances(layouts[2], state).map((a) => a.style.color),
        everyElement(_unread),
      );
    }
  });

  test('进入下一段才整段转已读，未来段落保留未读颜色', () {
    final layouts = _layouts(
      TextParser.parse('<p>上一段。两句话！<br>还是上一段。</p><p>当前段。继续读？</p><p>未来段。</p>'),
    );
    final state = _presentation(layouts[2].graphemes[2].rawStart);
    for (final layout in layouts.take(2)) {
      final appearances = _appearances(layout, state);
      expect(appearances.map((a) => a.style.color), everyElement(_read));
      expect(appearances.map((a) => a.isRead), everyElement(isTrue));
      expect(
        appearances.map((a) => a.isCurrentParagraph),
        everyElement(isFalse),
      );
    }
    expect(
      _appearances(layouts[2], state).map((a) => a.style.color),
      everyElement(_active),
    );
    expect(
      _appearances(layouts[3], state).map((a) => a.style.color),
      everyElement(_unread),
    );
  });

  test('纯文本换行空隙和回车换行空行不提前结束上一可见段落', () {
    for (final source in ['甲乙\n\n丙丁', '甲乙\r\n\r\n丙丁']) {
      final layouts = _layouts(TextParser.parsePlainText(source));
      final nextStart = source.indexOf('丙');
      for (var index = 0; index < nextStart; index++) {
        final state = _presentation(index);
        expect(
          _appearances(layouts.first, state).map((a) => a.style.color),
          everyElement(_active),
        );
        expect(
          _appearances(layouts.last, state).map((a) => a.style.color),
          everyElement(_unread),
        );
      }
      expect(
        _appearances(
          layouts.first,
          _presentation(nextStart),
        ).map((a) => a.style.color),
        everyElement(_read),
      );
      expect(
        _appearances(
          layouts.last,
          _presentation(nextStart),
        ).map((a) => a.style.color),
        everyElement(_active),
      );
    }
  });

  test('当前字倍率、加粗与下划线独立保留，不扩大为整段字形效果', () {
    final layout = _layouts(TextParser.parse('<p>甲。乙！丙？</p>')).single;
    final state = _presentation(2, scale: 1.15, bold: true, underline: true);
    final appearances = _appearances(layout, state);
    expect(appearances.map((a) => a.style.color), everyElement(_active));
    for (var i = 0; i < appearances.length; i++) {
      final current = i == 2;
      expect(appearances[i].scale, current ? 1.15 : 1);
      expect(appearances[i].isCurrent, current);
      expect(
        appearances[i].style.fontWeight,
        current ? _geometry.boldWeight : _geometry.normalWeight,
      );
      expect(
        appearances[i].style.decoration,
        current ? TextDecoration.underline : TextDecoration.none,
      );
    }
  });

  test('整段阅读色覆盖段内富文本前景色，未读时恢复各自原色与样式', () {
    final layouts = _layouts(
      TextParser.parse(
        '<p>甲<span style="color: #ff0088; font-size: 36px">乙</span><b>丙</b></p><p>丁</p>',
      ),
    );
    final current = _appearances(layouts.first, _presentation(0));
    expect(current.map((a) => a.style.color), everyElement(_active));
    expect(current[1].style.fontSize, 36);
    expect(current[2].style.fontWeight, FontWeight.w700);
    final unread = _appearances(layouts.first, _presentation(-1));
    expect(unread.map((a) => a.style.color), [
      _unread,
      const Color(0xFFFF0088),
      _unread,
    ]);
    final read = _appearances(layouts.first, _presentation(3));
    expect(read.map((a) => a.style.color), everyElement(_read));
    final readOff = _appearances(
      layouts.first,
      _presentation(3, grayReadChars: false),
    );
    expect(readOff.map((a) => a.style.color), [
      _unread,
      const Color(0xFFFF0088),
      _unread,
    ]);
  });

  test('关闭强调时整段不染当前色且段内已读字不提前灰化', () {
    final layouts = _layouts(TextParser.parse('<p>甲乙</p><p>丙丁戊</p>'));
    final state = _presentation(3, enabled: false, scale: 1.15);
    expect(
      _appearances(layouts.first, state).map((a) => a.style.color),
      everyElement(_read),
    );
    final active = _appearances(layouts.last, state);
    expect(active.map((a) => a.style.color), everyElement(_unread));
    expect(active.map((a) => a.scale), everyElement(1));
    expect(active.map((a) => a.isRead), everyElement(isFalse));
  });

  test('匀速滚动模式保持原色，不启用段落状态或逐字强调', () {
    final layout = _layouts(TextParser.parse('<p>甲乙丙丁</p>')).single;
    final state = _presentation(
      2,
      continuous: true,
      scale: 1.15,
      bold: true,
      underline: true,
    );
    final appearances = _appearances(layout, state);
    expect(appearances.map((a) => a.style.color), everyElement(_unread));
    expect(appearances.map((a) => a.scale), everyElement(1));
    expect(appearances.map((a) => a.isCurrentParagraph), everyElement(isFalse));
    expect(appearances.map((a) => a.isRead), everyElement(isFalse));
    expect(
      appearances.map((a) => a.style.decoration),
      everyElement(TextDecoration.none),
    );
  });

  test('字符簇继续按原始索引命中一个当前字，整段所有字同色', () {
    final layout = _layouts(TextParser.parse('<p>甲👩🏽‍💻e\u0301乙</p>')).single;
    final emoji = layout.graphemes.firstWhere((g) => g.text == '👩🏽‍💻');
    for (var index = emoji.rawStart; index <= emoji.rawEnd; index++) {
      final appearances = _appearances(
        layout,
        _presentation(index, scale: 1.15),
      );
      expect(appearances.map((a) => a.style.color), everyElement(_active));
      expect(appearances.where((a) => a.isCurrent), hasLength(1));
      expect(appearances.where((a) => a.scale > 1), hasLength(1));
      expect(layout.placementForRawIndex(index)!.grapheme, same(emoji));
    }
  });

  test('旧文本行构造仍默认整个人工行着色，空行无虚构字形', () {
    const line = ScriptLine(
      characters: [
        ScriptCharacter(char: '甲', rawIndex: 20),
        ScriptCharacter(char: '乙', rawIndex: 21),
      ],
      lineIndex: 7,
    );
    final layouts = _layouts([
      line,
      const ScriptLine(characters: [], lineIndex: 8),
    ]);
    expect(
      _appearances(layouts.first, _presentation(20)).map((a) => a.style.color),
      everyElement(_active),
    );
    expect(layouts.last.graphemes, isEmpty);
    expect(() => _presentation(20).paintKey(layouts.last), returnsNormally);
  });

  test('同段后行游标移动不重绘前行，离开整段时必须使前行重绘键失效', () {
    final layouts = _layouts(TextParser.parse('<p>甲乙<br>丙丁戊</p><p>己庚</p>'));
    final first = layouts.first;
    final inLaterLine = _presentation(2);
    final stillSameParagraph = _presentation(4);
    final nextParagraph = _presentation(5);
    expect(inLaterLine.paintKey(first), stillSameParagraph.paintKey(first));
    expect(
      stillSameParagraph.paintKey(first),
      isNot(nextParagraph.paintKey(first)),
    );
    final cache = ReadingGlyphPainterCache();
    addTearDown(cache.dispose);
    final before = ReadingTextPainter(
      layout: first,
      presentation: inLaterLine,
      glyphCache: cache,
    );
    final within = ReadingTextPainter(
      layout: first,
      presentation: stillSameParagraph,
      glyphCache: cache,
    );
    final after = ReadingTextPainter(
      layout: first,
      presentation: nextParagraph,
      glyphCache: cache,
    );
    expect(within.shouldRepaint(before), isFalse);
    expect(after.shouldRepaint(within), isTrue);
  });

  testWidgets('跨软换行的前行真实像素随整段变色，游标更新不重建布局', (tester) async {
    final lines = TextParser.parse('<p>甲乙<br>丙丁戊</p><p>己庚</p>');
    final key = GlobalKey<ReadingEmphasisLineState>();
    final cache = ReadingGlyphPainterCache();
    Future<void> show(int index) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ReadingEmphasisLine(
                key: key,
                line: lines.first,
                geometry: _geometry,
                presentation: _presentation(index),
                glyphCache: cache,
                width: 200,
                direction: TextDirection.ltr,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(0);
    final layout = key.currentState!.debugLayout;
    final cells = [
      for (var i = 0; i < layout.graphemes.length; i++)
        layout.placementAt(i).cell,
    ];
    final activePixels = await _colorPixelCount(
      tester,
      find.byKey(key),
      _active,
    );
    expect(activePixels, greaterThan(0));
    expect(await _colorPixelCount(tester, find.byKey(key), _read), 0);
    await show(4);
    expect(
      await _colorPixelCount(tester, find.byKey(key), _active),
      activePixels,
    );
    await show(5);
    expect(await _colorPixelCount(tester, find.byKey(key), _active), 0);
    expect(
      await _colorPixelCount(tester, find.byKey(key), _read),
      greaterThan(0),
    );
    expect(key.currentState!.debugLayout, same(layout));
    expect(key.currentState!.debugLayoutBuildCount, 1);
    expect([
      for (var i = 0; i < layout.graphemes.length; i++)
        layout.placementAt(i).cell,
    ], cells);
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });
}
