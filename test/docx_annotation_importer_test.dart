import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';
import 'package:storm_teleprompter_plus/services/files/docx_annotation_importer.dart';
import 'package:storm_teleprompter_plus/services/files/import_service_io.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';

const _wordNamespace =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _relationshipNamespace =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _officeRelationship =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

void main() {
  test('imports exact single-word, repeated-word, cross-paragraph and table ranges', () async {
    final fixture = File('test/fixtures/annotations/docx_word_ranges.docx');
    final result = await ImportService().importFile(fixture.path);

    expect(result, isNotNull);
    expect(result!.title, 'docx_word_ranges');
    expect(
      AnnotationAnchors.bodyText(result.content),
      '学习，不是记住更多。重复词：理解，再理解。先想清楚。再讲明白。'
      '表内重点实体 & <br> 😀：A&😀\t结束',
    );
    expect(result.annotations, hasLength(5));
    final notes = {for (final note in result.annotations) note.id: note};
    _expectRange(notes['docx:0']!, 3, 4, '不');
    // The second occurrence is selected by markers, never by a text search.
    _expectRange(notes['docx:1']!, 18, 20, '理解');
    _expectRange(notes['docx:2']!, 21, 31, '先想清楚。再讲明白。');
    _expectRange(notes['docx:3']!, 31, 35, '表内重点');
    // XML entities and surrogate pairs use decoded UTF-16 body positions.
    _expectRange(notes['docx:4']!, 48, 52, 'A&😀');
    expect(notes['docx:1']!.text, '放慢语速\n把意思讲清楚');
    expect(notes['docx:2']!.text, '先停一秒\n然后继续');
    expect(
      AnnotationAnchors.validate(result.content, result.annotations)
          .every((note) => note.isAnchored),
      isTrue,
    );
    expect(result.warnings, contains(contains('表格正文')));
    expect(AnnotationAnchors.bodyText(result.content), isNot(contains('重读')));
  });

  test('preserves run formatting and literal text that looks like an HTML tag', () async {
    final result = await importDocx(
      File('test/fixtures/annotations/docx_word_ranges.docx'),
    );
    final characters = TextParser.parse(result.content)
        .expand((line) => line.characters)
        .toList();
    final emphasized = characters.singleWhere((character) => character.rawIndex == 3);
    expect(emphasized.bold, isTrue);
    expect(emphasized.textColor, 0xFF148A9C);
    final firstRun = characters.singleWhere((character) => character.rawIndex == 18);
    expect(firstRun.italic, isTrue);
    expect(firstRun.fontSizePx, 24);
    final secondRun = characters.singleWhere((character) => character.rawIndex == 19);
    expect(secondRun.underline, isTrue);
    expect(secondRun.backgroundColor, 0xFFFFF59D);
    expect(result.content, contains('&lt;br&gt;'));
    expect(result.content, contains('先想<br>清楚。'));
  });

  test('reads the related comments part instead of an unrelated standard-name part', () async {
    final file = await _document(
      body: _range('0', '准确'),
      comments: _comment('0', '来自关系指定部件'),
      commentPart: 'word/review/notes.xml',
      relationshipTarget: 'review/notes.xml',
      extraParts: {
        'word/comments.xml': _comments(_comment('0', '不能读取这个旧批注')),
      },
    );

    final result = await importDocx(file);

    expect(result.annotations.single.text, '来自关系指定部件');
    _expectRange(result.annotations.single, 0, 2, '准确');
    expect(result.warnings, isEmpty);
  });

  test('reports the standard-path fallback when a comments relationship is absent', () async {
    final file = await _document(
      body: _range('0', '原文'),
      comments: _comment('0', '回退仍需说明'),
      includeRelationship: false,
    );

    final result = await importDocx(file);

    _expectRange(result.annotations.single, 0, 2, '原文');
    expect(result.warnings, contains(contains('标准位置')));
  });

  test('does not follow external relationships or silently use stale fallback comments', () async {
    final file = await _document(
      body: _range('0', '原文'),
      comments: _comment('0', '不应读取'),
      relationshipTarget: 'https://example.invalid/comments.xml',
      relationshipMode: 'External',
    );

    final result = await importDocx(file);

    expect(result.annotations.single.text, isEmpty);
    expect(result.annotations.single.isAnchored, isFalse);
    expect(result.annotations.single.unresolvedReason, contains('外部'));
    expect(result.annotations.single.ranges, isEmpty);
  });

  for (final target in ['missing.xml', '../../outside.xml']) {
    test('keeps unresolved markers when a declared comments target is invalid: $target', () async {
      final file = await _document(
        body: _range('0', '保留正文'),
        comments: _comment('0', '不可用作替代'),
        relationshipTarget: target,
      );

      final result = await importDocx(file);

      expect(AnnotationAnchors.bodyText(result.content), '保留正文');
      expect(result.annotations.single.text, isEmpty);
      expect(result.annotations.single.isAnchored, isFalse);
      expect(result.warnings, isNotEmpty);
    });
  }

  test('preserves orphan, point, incomplete, reversed, duplicate and empty ranges for repair', () async {
    final file = await _document(
      body: '''
        <w:p><w:r><w:t>正文。</w:t><w:commentReference w:id="1"/></w:r>
        <w:commentRangeStart w:id="2"/><w:r><w:t>未结束。</w:t><w:commentReference w:id="2"/></w:r>
        <w:commentRangeEnd w:id="3"/><w:commentRangeStart w:id="3"/><w:r><w:t>倒序。</w:t><w:commentReference w:id="3"/></w:r>
        <w:commentRangeStart w:id="4"/><w:commentRangeStart w:id="4"/><w:r><w:t>重复。</w:t></w:r><w:commentRangeEnd w:id="4"/><w:r><w:commentReference w:id="4"/></w:r>
        <w:commentRangeStart w:id="5"/><w:r><w:t>无引用。</w:t></w:r><w:commentRangeEnd w:id="5"/>
        <w:commentRangeStart w:id="6"/><w:commentRangeEnd w:id="6"/><w:r><w:commentReference w:id="6"/></w:r>
        </w:p>${_range('7', '没有批注内容。')}
      ''',
      comments: [for (var id = 0; id < 7; id++) _comment('$id', '保留备注$id')].join(),
    );

    final result = await importDocx(file);

    expect(result.annotations, hasLength(8));
    expect(result.annotations.every((note) => !note.isAnchored), isTrue);
    expect(result.annotations.every((note) => note.ranges.isEmpty), isTrue);
    final notes = {for (final note in result.annotations) note.id: note};
    for (var id = 0; id < 7; id++) {
      expect(notes['docx:$id']!.text, '保留备注$id');
    }
    expect(notes['docx:0']!.unresolvedReason, contains('未找到'));
    expect(notes['docx:1']!.unresolvedReason, contains('定位点'));
    expect(notes['docx:2']!.unresolvedReason, contains('不完整'));
    expect(notes['docx:3']!.unresolvedReason, contains('顺序'));
    expect(notes['docx:4']!.unresolvedReason, contains('重复'));
    expect(notes['docx:5']!.unresolvedReason, contains('引用'));
    expect(notes['docx:6']!.unresolvedReason, contains('范围为空'));
    expect(notes['docx:7']!.text, isEmpty);
    expect(notes['docx:7']!.unresolvedReason, contains('没有对应'));
    expect(result.warnings, contains(contains('8 条批注')));
  });

  test('does not overwrite duplicate comment IDs or guess which text owns the range', () async {
    final file = await _document(
      body: _range('0', '同一范围'),
      comments: '${_comment('0', '第一条')}${_comment('0', '第二条')}',
    );

    final result = await importDocx(file);

    expect(result.annotations.map((note) => note.text), ['第一条', '第二条']);
    expect(result.annotations.map((note) => note.id).toSet(), hasLength(2));
    expect(result.annotations.every((note) => !note.isAnchored), isTrue);
    expect(result.annotations.every((note) => note.unresolvedReason!.contains('重复批注编号')), isTrue);
  });

  test('preserves comments with a missing ID and comments with empty text', () async {
    final file = await _document(
      body: _range('0', '原文'),
      comments: '<w:comment><w:p><w:r><w:t>无编号也要保留</w:t></w:r></w:p></w:comment>'
          '${_comment('0', '')}',
    );

    final result = await importDocx(file);

    expect(result.annotations, hasLength(2));
    expect(result.annotations.first.text, '无编号也要保留');
    expect(result.annotations.first.unresolvedReason, contains('缺少编号'));
    expect(result.annotations.last.text, isEmpty);
    expect(result.annotations.last.unresolvedReason, contains('内容为空'));
  });

  test('normalizes numeric IDs without assuming an XML namespace prefix', () async {
    final file = await _document(
      body: '<w:p><w:commentRangeStart w:id="0001"/><w:r><w:t>正文</w:t></w:r>'
          '<w:commentRangeEnd w:id="1"/><w:r><w:commentReference w:id="+1"/></w:r></w:p>',
      commentsXml: '<c:comments xmlns:c="$_wordNamespace">'
          '<c:comment c:id="1"><c:p><c:r><c:t>别依赖前缀</c:t></c:r></c:p></c:comment>'
          '</c:comments>',
    );

    final result = await importDocx(file);

    expect(result.annotations.single.id, 'docx:1');
    _expectRange(result.annotations.single, 0, 2, '正文');
    expect(result.annotations.single.text, '别依赖前缀');
  });

  test('reads final revision text and respects explicitly disabled formatting', () async {
    final file = await _document(
      body: '<w:p><w:r><w:t>前</w:t></w:r><w:commentRangeStart w:id="0"/>'
          '<w:del><w:r><w:delText>删除内容</w:delText></w:r></w:del>'
          '<w:ins><w:r><w:rPr><w:b w:val="0"/><w:i w:val="false"/><w:u w:val="none"/>'
          '</w:rPr><w:t>新</w:t><w:br/><w:t>文</w:t></w:r></w:ins>'
          '<w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r></w:p>',
      comments: _comment('0', '按最终正文定位'),
    );

    final result = await importDocx(file);

    expect(AnnotationAnchors.bodyText(result.content), '前新文');
    _expectRange(result.annotations.single, 1, 3, '新文');
    final character = TextParser.parse(result.content).first.characters.last;
    expect(character.bold, isFalse);
    expect(character.italic, isFalse);
    expect(character.underline, isFalse);
    expect(result.warnings, contains(contains('修订')));
  });

  test('reports corrupt comments while preserving body and unresolved markers', () async {
    final file = await _document(
      body: _range('0', '正文仍可读'),
      commentsXml: '<w:comments xmlns:w="$_wordNamespace"><w:comment',
    );

    final result = await importDocx(file);

    expect(AnnotationAnchors.bodyText(result.content), '正文仍可读');
    expect(result.annotations, hasLength(1));
    expect(result.annotations.single.isAnchored, isFalse);
    expect(result.warnings, isNotEmpty);
  });

  test('accepts documents with no comments without creating diagnostic notes', () async {
    final file = await _document(
      body: '<w:p><w:r><w:t>普通稿件</w:t></w:r></w:p>',
      includeComments: false,
      includeRelationship: false,
    );

    final result = await importDocx(file);

    expect(AnnotationAnchors.bodyText(result.content), '普通稿件');
    expect(result.annotations, isEmpty);
    expect(result.warnings, isEmpty);
  });
}

void _expectRange(ReadingAnnotation note, int start, int end, String quote) {
  expect(note.isAnchored, isTrue, reason: note.unresolvedReason);
  expect(note.source, 'docx');
  expect(note.ranges, hasLength(1));
  expect(note.ranges.single.start, start);
  expect(note.ranges.single.end, end);
  expect(note.ranges.single.quote, quote);
}

String _range(String id, String text) => '<w:p><w:commentRangeStart w:id="$id"/>'
    '<w:r><w:t>${const HtmlEscape(HtmlEscapeMode.element).convert(text)}</w:t></w:r>'
    '<w:commentRangeEnd w:id="$id"/><w:r><w:commentReference w:id="$id"/></w:r></w:p>';

String _comment(String id, String text) => '<w:comment w:id="$id" w:author="示例教练">'
    '<w:p><w:r><w:t>${const HtmlEscape(HtmlEscapeMode.element).convert(text)}</w:t>'
    '</w:r></w:p></w:comment>';

String _comments(String entries) => '<w:comments xmlns:w="$_wordNamespace">$entries</w:comments>';

Future<File> _document({
  required String body,
  String comments = '',
  String? commentsXml,
  String commentPart = 'word/comments.xml',
  String relationshipTarget = 'comments.xml',
  String? relationshipMode,
  bool includeRelationship = true,
  bool includeComments = true,
  Map<String, String> extraParts = const {},
}) async {
  final temp = await Directory.systemTemp.createTemp('bk_docx_comments_');
  addTearDown(() => temp.delete(recursive: true));
  final files = <String, String>{
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/$commentPart" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>'
        '</Types>',
    '_rels/.rels': '<Relationships xmlns="$_relationshipNamespace">'
        '<Relationship Id="rId1" Type="$_officeRelationship/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/document.xml': '<w:document xmlns:w="$_wordNamespace"><w:body>$body</w:body></w:document>',
    if (includeRelationship)
      'word/_rels/document.xml.rels': '<Relationships xmlns="$_relationshipNamespace">'
          '<Relationship Id="rIdComments" Type="$_officeRelationship/comments" '
          'Target="$relationshipTarget"${relationshipMode == null ? '' : ' TargetMode="$relationshipMode"'}/>'
          '</Relationships>',
    if (includeComments) commentPart: commentsXml ?? _comments(comments),
    ...extraParts,
  };
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return File(p.join(temp.path, '带批注的测试稿.docx'))
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}
