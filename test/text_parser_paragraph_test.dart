import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/script_character.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';

List<ScriptCharacter> _characters(List<ScriptLine> lines) => [
  for (final line in lines) ...line.characters,
];

void _expectContinuousIndices(List<ScriptLine> lines, String expected) {
  final characters = _characters(lines);
  expect(characters.map((char) => char.char).join(), expected);
  expect(
    characters.map((char) => char.rawIndex),
    List.generate(expected.length, (i) => i),
  );
}

void main() {
  test('纯文本人工换行切段，段内多句话不切分，空行及原始索引保留', () {
    const source = '一句。两句！三句？\n第二段\n\n尾段🙂';
    final lines = TextParser.parsePlainText(source);
    expect(lines.map((line) => line.text), ['一句。两句！三句？', '第二段', '', '尾段🙂']);
    expect(lines.map((line) => line.lineIndex), [0, 1, 2, 3]);
    expect(lines.map((line) => line.paragraph).toSet(), hasLength(4));
    for (final char in _characters(lines)) {
      expect(char.char, source[char.rawIndex]);
    }
    expect(lines[0].paragraph!.rawStart, 0);
    expect(lines[0].paragraph!.rawEnd, source.indexOf('第二段') - 1);
    expect(lines[1].paragraph!.rawEnd, source.indexOf('尾段') - 1);
    expect(
      lines[1].paragraph!.containsRawIndex(source.indexOf('\n\n') + 1),
      isTrue,
    );
    expect(lines[2].paragraph!.containsRawIndex(source.indexOf('尾段')), isFalse);
    expect(lines[3].paragraph!.rawEnd, source.length - 1);
  });

  test('回车换行和制表符保持现有原始字符位置，不挪动语音对齐', () {
    const source = '甲。乙！\r\n\t丙\r\n\r\n丁';
    final lines = TextParser.parsePlainText(source);
    expect(lines.map((line) => line.text), ['甲。乙！\r', '\t丙\r', '\r', '丁']);
    for (final char in _characters(lines)) {
      expect(char.char, source[char.rawIndex]);
    }
    expect(lines[1].characters.first.rawIndex, source.indexOf('\t'));
    expect(lines.last.characters.first.rawIndex, source.indexOf('丁'));
    expect(lines[0].paragraph!.rawEnd, source.indexOf('\t') - 1);
    expect(lines[1].paragraph!.rawEnd, source.indexOf('丁') - 1);
    expect(
      lines[2].paragraph!.containsRawIndex(source.indexOf('\r\n\r') + 2),
      isFalse,
    );
  });

  test('富文本块标签切段，各种软换行仅切人工行，标点不切段', () {
    final lines = TextParser.parse(
      '<p>甲。乙！<br>丙？丁。<br/>戊<br />己<BR>庚</p><div>辛。壬！</div>',
    );
    expect(lines.map((line) => line.text), [
      '甲。乙！',
      '丙？丁。',
      '戊',
      '己',
      '庚',
      '辛。壬！',
    ]);
    final paragraph = lines.first.paragraph!;
    for (final line in lines.take(5)) {
      expect(line.paragraph, same(paragraph));
    }
    expect(lines.last.paragraph, isNot(same(paragraph)));
    expect(paragraph.rawEnd, lines.last.characters.first.rawIndex - 1);
    _expectContinuousIndices(lines, '甲。乙！丙？丁。戊己庚辛。壬！');
  });

  test('嵌套容器内每个人工段落、标题及列表项分别着色', () {
    final lines = TextParser.parse(
      '<div><p>甲。乙！</p><p>丙？</p></div>'
      '<h2>丁</h2><ul><li>戊</li><li>己</li></ul><blockquote>庚</blockquote>',
    );
    expect(lines.map((line) => line.text), ['甲。乙！', '丙？', '丁', '戊', '己', '庚']);
    expect(lines.map((line) => line.paragraph).toSet(), hasLength(6));
    _expectContinuousIndices(lines, '甲。乙！丙？丁戊己庚');
  });

  test('编辑器空段落保留一行间隔，不合并前后两个段落', () {
    final lines = TextParser.parse('<p>甲</p><p><br></p><p>乙</p>');
    expect(lines.map((line) => line.text), ['甲', '', '乙']);
    expect(lines.map((line) => line.paragraph).toSet(), hasLength(3));
    expect(lines[1].paragraph!.containsRawIndex(0), isFalse);
    expect(lines[1].paragraph!.containsRawIndex(1), isFalse);
    _expectContinuousIndices(lines, '甲乙');
  });

  test('同段连续软换行保留空行，并仍与前后人工行共用段落范围', () {
    final lines = TextParser.parse('<p>甲<br><br>乙</p><p>丙</p>');
    expect(lines.map((line) => line.text), ['甲', '', '乙', '丙']);
    for (final line in lines.take(3)) {
      expect(line.paragraph, same(lines.first.paragraph));
    }
    expect(lines.last.paragraph, isNot(same(lines.first.paragraph)));
    _expectContinuousIndices(lines, '甲乙丙');
  });

  test('块内源文本换行只换人工行，块外纯文本换行切段', () {
    final html = TextParser.parse('<p>甲\n乙</p><p>丙</p>');
    expect(html.map((line) => line.text), ['甲', '乙', '丙']);
    expect(html[0].paragraph, same(html[1].paragraph));
    expect(html[1].paragraph, isNot(same(html[2].paragraph)));
    _expectContinuousIndices(html, '甲乙丙');
    final plain = TextParser.parse('甲\n乙\n\n丙');
    expect(plain.map((line) => line.text), ['甲', '乙', '', '丙']);
    expect(plain.map((line) => line.paragraph).toSet(), hasLength(4));
    _expectContinuousIndices(plain, '甲乙丙');
  });

  test('闭合块标签后的游离文本不并入上一段，文字索引保持连续', () {
    final lines = TextParser.parse('<p>甲</p>乙<div>丙</div>丁');
    expect(lines.map((line) => line.text), ['甲', '乙', '丙', '丁']);
    expect(lines.map((line) => line.paragraph).toSet(), hasLength(4));
    _expectContinuousIndices(lines, '甲乙丙丁');
  });

  test('行内混合样式不切段也不丢失格式', () {
    final lines = TextParser.parse(
      '<p><b>甲</b><i>乙</i>'
      '<span style="font-size: 42px; color: #3366ff; background-color: #ff0000">丙</span>'
      '<u>丁</u><s>戊</s><br>己</p><p>庚</p>',
    );
    final chars = _characters(lines);
    expect(lines[0].paragraph, same(lines[1].paragraph));
    expect(chars[0].bold, isTrue);
    expect(chars[1].italic, isTrue);
    expect(chars[2].fontSizePx, 42);
    expect(chars[2].textColor, 0xFF3366FF);
    expect(chars[2].backgroundColor, 0xFFFF0000);
    expect(chars[3].underline, isTrue);
    expect(chars[4].strikeThrough, isTrue);
    _expectContinuousIndices(lines, '甲乙丙丁戊己庚');
  });

  test('字符簇和现有实体文本的原始码元序列保持不变', () {
    const expected = '甲👩🏽‍💻e\u0301&amp;乙';
    final lines = TextParser.parse('<p>甲👩🏽‍💻e\u0301&amp;</p><p>乙</p>');
    _expectContinuousIndices(lines, expected);
    expect(lines.first.paragraph!.rawEnd, expected.indexOf('乙') - 1);
  });

  test('空稿无虚构字符，旧文本行构造保持兼容', () {
    expect(TextParser.parse('   '), isEmpty);
    expect(TextParser.parsePlainText('\n\n'), isEmpty);
    final empty = TextParser.parse('<p></p>').single;
    expect(empty.characters, isEmpty);
    expect(empty.paragraph!.containsRawIndex(0), isFalse);
    const legacy = ScriptLine(
      characters: [ScriptCharacter(char: '甲', rawIndex: 12)],
      lineIndex: 4,
    );
    expect(legacy.text, '甲');
    expect(legacy.paragraph, isNull);
  });
}
