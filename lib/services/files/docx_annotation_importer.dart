import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/reading_annotation.dart';
import 'import_batch.dart';

/// Imports body text and comment anchors in the same document-order pass.
/// Offsets count decoded UTF-16 body text, never XML/HTML or paragraph breaks.
Future<ImportedArticleDraft> importDocx(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final name = file.path.split(RegExp(r'[\\/]')).last;
  return _DocxImporter(archive).read(
    name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim(),
  );
}

class _DocxImporter {
  _DocxImporter(this.archive);

  static const _documentPath = 'word/document.xml';
  static const _commentsRelationshipTypes = {
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments',
    'http://purl.oclc.org/ooxml/officeDocument/relationships/comments',
  };
  static const _maxXmlBytes = 32 * 1024 * 1024;

  final Archive archive;
  final _html = StringBuffer();
  final _body = StringBuffer();
  final _locations = <String, _CommentLocation>{};
  final _warnings = <String>{};
  int _rawIndex = 0;
  int _missingMarkerId = 0;
  String? _commentsFailure;

  ImportedArticleDraft read(String title) {
    final document = _readXml(_documentPath);
    if (document == null) {
      throw const FormatException('文档缺少正文部件 word/document.xml');
    }
    final body = document.descendants
        .whereType<XmlElement>()
        .where((node) => node.name.local == 'body')
        .firstOrNull;
    if (body == null) throw const FormatException('文档缺少正文');
    _visit(body);

    final comments = _readComments();
    final plainBody = _body.toString();
    final ids = <String, int>{};
    for (final comment in comments) {
      if (comment.id != null) {
        ids.update(comment.id!, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final annotations = <ReadingAnnotation>[];
    for (var index = 0; index < comments.length; index++) {
      final comment = comments[index];
      final id = comment.id;
      final duplicate = id != null && ids[id]! > 1;
      annotations.add(
        _annotation(
          id: id == null
              ? 'docx:missing-id:$index'
              : duplicate
              ? 'docx:$id:duplicate:$index'
              : 'docx:$id',
          text: comment.text,
          location: id == null ? null : _locations[id],
          body: plainBody,
          problem: id == null
              ? '批注缺少编号，无法对应正文'
              : duplicate
              ? '文档存在重复批注编号，无法确定对应关系'
              : !_isNumericId(id)
              ? '批注编号无效，需手动定位'
              : null,
        ),
      );
    }
    // Body markers without a comment body must also survive import. A missing
    // comments part is not evidence that a file contains no coaching notes.
    for (final entry in _locations.entries) {
      if (ids.containsKey(entry.key)) continue;
      annotations.add(
        _annotation(
          id: 'docx:${entry.key}',
          text: '',
          location: entry.value,
          body: plainBody,
          problem: _commentsFailure ?? '正文有批注标记，但没有对应的批注内容',
        ),
      );
    }
    final unresolved = annotations.where((note) => !note.isAnchored).length;
    if (unresolved > 0) {
      _warnings.add('有 $unresolved 条批注未自动定位，已保留供手动确认。');
    }
    return ImportedArticleDraft(
      title: title,
      content: _html.toString().trimRight(),
      annotations: List.unmodifiable(annotations),
      warnings: List.unmodifiable(_warnings),
    );
  }

  XmlDocument? _readXml(String part) {
    final file = archive.findFile(part);
    if (file == null || !file.isFile) return null;
    if (file.size > _maxXmlBytes) {
      throw const FormatException('文档文字部件过大，无法安全读取');
    }
    return XmlDocument.parse(utf8.decode(file.content));
  }

  List<_CommentEntry> _readComments() {
    try {
      final relationships = _readXml('word/_rels/document.xml.rels');
      final matches = relationships?.descendants
          .whereType<XmlElement>()
          .where(
            (node) =>
                node.name.local == 'Relationship' &&
                _commentsRelationshipTypes.contains(node.getAttribute('Type')),
          )
          .toList();
      String? commentsPath;
      if (matches != null && matches.isNotEmpty) {
        if (matches.length != 1) {
          throw const FormatException('正文存在多个批注部件关系，无法确定来源');
        }
        final relation = matches.single;
        if (relation.getAttribute('TargetMode')?.toLowerCase() == 'external') {
          throw const FormatException('批注部件指向外部位置，未读取外部内容');
        }
        commentsPath = _resolvePartTarget(relation.getAttribute('Target'));
        if (commentsPath == null) {
          throw const FormatException('批注部件关系的目标路径无效');
        }
      } else if (archive.findFile('word/comments.xml') != null) {
        commentsPath = 'word/comments.xml';
        _warnings.add('文档缺少批注部件关系，已从标准位置读取批注。');
      }
      if (commentsPath == null) return const [];
      final comments = _readXml(commentsPath);
      if (comments == null) {
        throw const FormatException('批注部件关系指向的文件不存在');
      }
      final root = comments.rootElement;
      if (root.name.local != 'comments') {
        throw const FormatException('批注部件不是有效的批注列表');
      }
      return root.children.whereType<XmlElement>().where(
        (node) => node.name.local == 'comment',
      ).map((node) {
        final buffer = StringBuffer();
        _appendCommentText(node, buffer);
        final text = buffer.toString().replaceFirst(RegExp(r'\n$'), '');
        return _CommentEntry(_commentId(node), text);
      }).toList();
    } on Exception catch (error) {
      _commentsFailure = error is FormatException
          ? error.message.toString()
          : '批注部件损坏，无法读取批注内容';
      _warnings.add(_commentsFailure!);
      return const [];
    }
  }

  /// Relationship targets are package URIs, not host filesystem paths.
  String? _resolvePartTarget(String? target) {
    if (target == null || target.isEmpty || target.contains('\\')) return null;
    final uri = Uri.tryParse(target);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final decoded = Uri.decodeComponent(uri.path);
    final path = p.posix.normalize(
      decoded.startsWith('/') ? decoded.substring(1) : p.posix.join('word', decoded),
    );
    if (path == '.' || path == '..' || path.startsWith('../')) return null;
    return path;
  }

  void _visit(XmlNode node, [_RunStyle style = const _RunStyle()]) {
    if (node is! XmlElement) return;
    switch (node.name.local) {
      case 'p':
        _html.write('<p>');
        for (final child in node.children) {
          _visit(child, style);
        }
        _html.write('</p>\n');
        return;
      case 'r':
        final runStyle = _RunStyle.fromRun(node);
        for (final child in node.children) {
          _visit(child, runStyle);
        }
        return;
      case 't':
        _writeText(node.innerText, style);
        return;
      case 'tab':
        _writeText('\t', style);
        return;
      case 'br':
      case 'cr':
        _html.write('<br>');
        return;
      case 'noBreakHyphen':
        _writeText('\u2011', style);
        return;
      case 'softHyphen':
        _writeText('\u00AD', style);
        return;
      case 'commentRangeStart':
        _location(node).startAt(_rawIndex);
        return;
      case 'commentRangeEnd':
        _location(node).endAt(_rawIndex);
        return;
      case 'commentReference':
        _location(node).references++;
        return;
      case 'tbl':
        _warnings.add('表格正文已按单元格阅读顺序转换为段落，批注保留对应文字。');
        break;
      case 'del':
      case 'moveFrom':
        _warnings.add('文档含修订，已按最终正文读取并忽略删除的文字。');
        return;
      case 'drawing':
      case 'pict':
      case 'object':
      case 'altChunk':
        _warnings.add('文档含非正文对象，仅导入可读取的正文文字。');
        return;
      case 'rPr':
      case 'pPr':
      case 'tblPr':
      case 'trPr':
      case 'tcPr':
      case 'sectPr':
      case 'instrText':
      case 'delText':
        return;
    }
    for (final child in node.children) {
      _visit(child, style);
    }
  }

  void _writeText(String text, _RunStyle style) {
    final parts = text.split(RegExp(r'\r\n?|\n'));
    for (var index = 0; index < parts.length; index++) {
      if (index > 0) _html.write('<br>');
      final part = parts[index];
      _body.write(part);
      _rawIndex += part.length;
      _html.write(style.wrap(part));
    }
  }

  _CommentLocation _location(XmlElement marker) {
    final externalId = _commentId(marker);
    final id = externalId ?? 'invalid-marker:${_missingMarkerId++}';
    final location = _locations.putIfAbsent(id, _CommentLocation.new);
    if (externalId == null || !_isNumericId(id)) {
      location.problems.add('批注标记缺少有效编号');
    }
    return location;
  }

  ReadingAnnotation _annotation({
    required String id,
    required String text,
    required _CommentLocation? location,
    required String body,
    String? problem,
  }) {
    final problems = <String>{
      if (problem != null) problem,
      if (text.trim().isEmpty) '批注内容为空',
      if (location == null) '未找到该批注对应的正文范围',
      ...?location?.problems,
    };
    if (location != null) {
      if (location.start == null && location.end == null) {
        problems.add('批注只有定位点，没有选中的正文范围');
      } else if (location.start == null || location.end == null) {
        problems.add('批注的正文起止标记不完整');
      } else if (location.end! <= location.start!) {
        problems.add('批注范围为空或起止顺序无效');
      }
      if (location.references == 0) problems.add('缺少正文批注引用标记');
    }
    final ranges = <AnnotationRange>[];
    if (problems.isEmpty) {
      final start = location!.start!;
      final end = location.end!;
      ranges.add(AnnotationRange(start: start, end: end, quote: body.substring(start, end)));
    }
    return ReadingAnnotation(
      id: id,
      text: text,
      ranges: List.unmodifiable(ranges),
      source: 'docx',
      unresolvedReason: problems.isEmpty ? null : problems.join('；'),
    );
  }
}

class _CommentEntry {
  const _CommentEntry(this.id, this.text);
  final String? id;
  final String text;
}

class _CommentLocation {
  int? start;
  int? end;
  int references = 0;
  final problems = <String>{};

  void startAt(int offset) {
    if (start != null) problems.add('批注有重复的开始标记');
    if (end != null) problems.add('批注结束标记出现在开始标记之前');
    start ??= offset;
  }

  void endAt(int offset) {
    if (end != null) problems.add('批注有重复的结束标记');
    if (start == null) problems.add('批注结束标记出现在开始标记之前');
    end ??= offset;
  }
}

String? _attribute(XmlElement? node, String local) => node?.attributes
    .where((attribute) => attribute.name.local == local)
    .firstOrNull
    ?.value;

XmlElement? _child(XmlElement node, String local) => node.children
    .whereType<XmlElement>()
    .where((child) => child.name.local == local)
    .firstOrNull;

String? _commentId(XmlElement node) {
  final raw = _attribute(node, 'id')?.trim();
  if (raw == null || raw.isEmpty) return null;
  return BigInt.tryParse(raw)?.toString() ?? raw;
}

bool _isNumericId(String id) => RegExp(r'^-?\d+$').hasMatch(id);

void _appendCommentText(XmlNode node, StringBuffer buffer) {
  if (node is! XmlElement) return;
  switch (node.name.local) {
    case 't':
      buffer.write(node.innerText);
      return;
    case 'tab':
      buffer.write('\t');
      return;
    case 'br':
    case 'cr':
      buffer.write('\n');
      return;
    case 'del':
    case 'moveFrom':
    case 'rPr':
    case 'pPr':
    case 'instrText':
      return;
  }
  for (final child in node.children) {
    _appendCommentText(child, buffer);
  }
  if (node.name.local == 'p') buffer.write('\n');
}

class _RunStyle {
  const _RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSizePx,
    this.backgroundHex,
    this.textHex,
  });

  factory _RunStyle.fromRun(XmlElement run) {
    final properties = _child(run, 'rPr');
    if (properties == null) return const _RunStyle();
    bool enabled(String name) {
      final property = _child(properties, name);
      if (property == null) return false;
      final value = _attribute(property, 'val')?.toLowerCase();
      return !const {'0', 'false', 'off', 'none'}.contains(value);
    }

    final halfPoints = int.tryParse(_attribute(_child(properties, 'sz'), 'val') ?? '');
    final fill = _validColor(_attribute(_child(properties, 'shd'), 'fill'));
    final highlight = _attribute(_child(properties, 'highlight'), 'val')?.toLowerCase();
    return _RunStyle(
      bold: enabled('b'),
      italic: enabled('i'),
      underline: enabled('u'),
      strike: enabled('strike') || enabled('dstrike'),
      fontSizePx: halfPoints == null ? null : ((halfPoints / 2) * 96 / 72).round().clamp(8, 96),
      backgroundHex: fill ?? _highlightColors[highlight],
      textHex: _validColor(_attribute(_child(properties, 'color'), 'val')),
    );
  }

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int? fontSizePx;
  final String? backgroundHex;
  final String? textHex;

  String wrap(String text) {
    if (text.isEmpty) return '';
    var html = const HtmlEscape(HtmlEscapeMode.element).convert(text);
    if (bold) html = '<b>$html</b>';
    if (italic) html = '<i>$html</i>';
    if (underline) html = '<u>$html</u>';
    if (strike) html = '<s>$html</s>';
    final styles = [
      if (fontSizePx != null) 'font-size: ${fontSizePx}px',
      if (backgroundHex != null) 'background-color: #$backgroundHex',
      if (textHex != null) 'color: #$textHex',
    ];
    if (styles.isNotEmpty) html = '<span style="${styles.join('; ')}">$html</span>';
    return html;
  }

  static String? _validColor(String? value) =>
      value != null && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)
      ? value.toUpperCase()
      : null;

  static const _highlightColors = {
    'yellow': 'FFF59D', 'green': 'A5D6A7', 'cyan': '80DEEA',
    'magenta': 'F48FB1', 'blue': '90CAF9', 'red': 'EF9A9A',
    'darkyellow': 'FBC02D', 'darkgreen': '388E3C', 'darkcyan': '0097A7',
    'darkmagenta': 'C2185B', 'darkblue': '1976D2', 'darkred': 'D32F2F',
  };
}
