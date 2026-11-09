/// 带格式信息的单个字符
///
/// 用于文本渲染层，每个字符携带独立的格式属性。
class ScriptCharacter {
  final String char;
  final int rawIndex;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikeThrough;
  final double? fontSizeRatio; // 相对基字号的倍数
  final double? fontSizePx; // 富文本指定的绝对字号
  final int? backgroundColor; // 背景色 ARGB hex
  final int? textColor;

  const ScriptCharacter({
    required this.char,
    required this.rawIndex,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeThrough = false,
    this.fontSizeRatio,
    this.fontSizePx,
    this.backgroundColor,
    this.textColor,
  });
}

/// 人工段落在语音对齐原文中的范围；自动折行不改变这个范围。
/// 同段落的多个人工行共享同一个实例。末尾空白归属前段，进入下一段的
/// 首字符时前段才整体变为已读。原始索引均保留解析器的 UTF-16 约定。
class ScriptParagraph {
  final int index;
  final int rawStart;
  final int rawEnd;

  const ScriptParagraph({
    required this.index,
    required this.rawStart,
    required this.rawEnd,
  });

  bool containsRawIndex(int index) => index >= rawStart && index <= rawEnd;
}

/// 人工文本行，包含一组字符；段内软换行可以产生多行。
class ScriptLine {
  final List<ScriptCharacter> characters;
  final int lineIndex;
  final ScriptParagraph? paragraph;

  const ScriptLine({
    required this.characters,
    required this.lineIndex,
    this.paragraph,
  });

  /// 获取行纯文本
  String get text => characters.map((c) => c.char).join();
}
