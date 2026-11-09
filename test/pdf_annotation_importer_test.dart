import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';
import 'package:storm_teleprompter_plus/services/files/import_batch.dart';
import 'package:storm_teleprompter_plus/services/files/pdf_annotation_geometry.dart';
import 'package:storm_teleprompter_plus/services/files/pdf_annotation_importer.dart';

File fixture(String name) => File('test/fixtures/annotations/$name');

ReadingAnnotation noteStartingWith(ImportedArticleDraft draft, String prefix) =>
    draft.annotations.singleWhere((note) => note.text.startsWith(prefix));

void main() {
  group('native PDF annotation import', () {
    late ImportedArticleDraft draft;
    late String body;

    setUpAll(() async {
      // This intentionally invokes the actual packaged PDFium library. There
      // is no mocked PDF decoder and no skip-on-missing-native-library path.
      draft = await importPdf(fixture('pdf_annotations_synthetic.pdf'));
      body = AnnotationAnchors.bodyText(draft.content);
    });

    test('extracts Chinese, entities and emoji without annotation text', () {
      expect(
        body,
        '知识需要节奏，知识需要停顿。'
        '先停顿，再强调，最后放慢。'
        '<A&B> "quote" 😀 after'
        '页尾：用轻声收尾。'
        '旋转页面依然需要重音。',
      );
      expect(draft.content, contains('&lt;A&amp;B&gt;'));
      expect(draft.content, contains('</p>\n<p>'));
      expect(body, isNot(contains('重读')));
      expect(body, isNot(contains('便笺')));
      expect(body, isNot(contains('自由文本')));
      expect(draft.annotations, hasLength(15));
      expect(draft.annotations.where((note) => note.isAnchored), hasLength(10));
      for (final note in draft.annotations.where((note) => note.isAnchored)) {
        for (final range in note.ranges) {
          expect(AnnotationAnchors.matches(body, range), isTrue);
        }
      }
    });

    test('anchors the selected occurrence rather than the first repeated word', () {
      final note = noteStartingWith(draft, '第二处知识');
      expect(note.ranges, hasLength(1));
      expect(note.ranges.single.quote, '知识');
      expect(note.ranges.single.start, body.indexOf('知识', 2));
      expect(note.ranges.single.start, isNot(body.indexOf('知识')));
    });

    test('preserves disjoint selected words without the intervening text', () {
      final note = noteStartingWith(draft, '两个不连续词');
      expect(note.isAnchored, isTrue);
      expect(note.ranges.map((range) => range.quote), ['停顿', '放慢']);
      expect(note.ranges.first.end, lessThan(note.ranges.last.start));
      expect(
        body.substring(note.ranges.first.end, note.ranges.last.start),
        contains('再强调'),
      );
    });

    test('maps across paragraph boundaries without counting HTML newlines', () {
      final note = noteStartingWith(draft, '跨行批注');
      expect(note.isAnchored, isTrue);
      expect(note.ranges.map((range) => range.quote).join(), '停顿。先停顿');
      expect(note.ranges.first.start, body.indexOf('停顿。'));
      final symbols = noteStartingWith(draft, '符号必须');
      expect(symbols.ranges.single.quote, '<A&B>');
      expect(symbols.ranges.single.start, body.indexOf('<A&B>'));
    });

    test('keeps a supplementary Unicode character as a complete UTF-16 range', () {
      final emoji = noteStartingWith(draft, '表情位置');
      expect(emoji.ranges.single.quote, '😀');
      expect(emoji.ranges.single.start, body.indexOf('😀'));
      expect(emoji.ranges.single.end - emoji.ranges.single.start, 2);
      final later = noteStartingWith(draft, '轻声');
      expect(later.ranges.single.start, body.indexOf('轻声'));
      expect(later.ranges.single.quote, '轻声');
    });

    test('imports all four native text-markup types', () {
      expect(noteStartingWith(draft, '节奏：').ranges.single.quote, '节奏');
      expect(noteStartingWith(draft, '轻声：').ranges.single.quote, '轻声');
      expect(noteStartingWith(draft, '收尾：').ranges.single.quote, '收尾');
    });

    test('inherits parent ranges for replies, including on a rotated page', () {
      final parent = noteStartingWith(draft, '第二处知识');
      final reply = noteStartingWith(draft, '回复：');
      expect(reply.isAnchored, isTrue);
      expect(reply.ranges.single.start, parent.ranges.single.start);
      expect(reply.ranges.single.quote, parent.ranges.single.quote);

      final rotated = noteStartingWith(draft, '旋转页回复');
      expect(rotated.page, 2);
      expect(rotated.isAnchored, isTrue);
      expect(rotated.ranges.single.quote, '重音');
      expect(rotated.ranges.single.start, body.lastIndexOf('重音'));
    });

    test('retains notes without true selections and explains each failure', () {
      for (final prefix in ['便笺：', '自由文本：', '箭头：', '缺少选区：', '空白区域的高亮：']) {
        final note = noteStartingWith(draft, prefix);
        expect(note.isAnchored, isFalse, reason: prefix);
        expect(note.ranges, isEmpty, reason: prefix);
        expect(note.unresolvedReason, isNotEmpty, reason: prefix);
        expect(note.source, 'pdf');
      }
      expect(draft.warnings.any((warning) => warning.contains('5 条备注')), isTrue);
      expect(draft.warnings.any((warning) => warning.contains('空白标记')), isTrue);
    });

    test('loads a file with Chinese and emoji in its Windows-safe path', () async {
      final directory = await Directory.systemTemp.createTemp('pdf_path_test_');
      addTearDown(() => directory.delete(recursive: true));
      final copy = await fixture('pdf_plain_synthetic.pdf').copy(
        '${directory.path}${Platform.pathSeparator}中文批注😀.pdf',
      );
      final result = await importPdf(copy);
      expect(result.title, '中文批注😀');
      expect(AnnotationAnchors.bodyText(result.content), '普通稿件，不含批注。');
      expect(result.annotations, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('preserves a scanned-page note when another page has body text', () async {
      final result = await importPdf(fixture('pdf_mixed_scanned_synthetic.pdf'));
      expect(AnnotationAnchors.bodyText(result.content), '第一页有正文，第二页是扫描件。');
      expect(result.annotations, hasLength(1));
      expect(result.annotations.single.page, 2);
      expect(result.annotations.single.text, '扫描页的备注也不能静默丢失。');
      expect(result.annotations.single.isAnchored, isFalse);
      expect(result.warnings.any((warning) => warning.contains('第 2 页')), isTrue);
    });

    test('reports scanned-only and blank files instead of creating empty scripts', () async {
      await expectLater(
        importPdf(fixture('pdf_scanned_synthetic.pdf')),
        throwsA(
          isA<PdfImportException>()
              .having((error) => error.message, 'message', contains('没有可提取的正文'))
              .having((error) => error.message, 'notes', contains('1 条备注')),
        ),
      );
      await expectLater(
        importPdf(fixture('pdf_empty_synthetic.pdf')),
        throwsA(isA<PdfImportException>().having(
          (error) => error.message,
          'message',
          contains('没有可提取的正文'),
        )),
      );
    });

    test('reports password protection and respects extraction restrictions', () async {
      await expectLater(
        importPdf(fixture('pdf_encrypted_synthetic.pdf')),
        throwsA(isA<PdfImportException>().having(
          (error) => error.message,
          'message',
          contains('文件已加密'),
        )),
      );
      await expectLater(
        importPdf(fixture('pdf_restricted_synthetic.pdf')),
        throwsA(isA<PdfImportException>().having(
          (error) => error.message,
          'message',
          contains('限制复制'),
        )),
      );
    });

    test('serializes parallel requests and continues after a failed import', () async {
      final results = await Future.wait([
        importPdf(fixture('pdf_plain_synthetic.pdf')),
        importPdf(fixture('pdf_annotations_synthetic.pdf')),
      ]);
      expect(results.first.annotations, isEmpty);
      expect(results.last.annotations, hasLength(15));

      final failed = importPdf(fixture('pdf_invalid_synthetic.pdf'));
      final next = importPdf(fixture('pdf_plain_synthetic.pdf'));
      await expectLater(
        failed,
        throwsA(isA<PdfImportException>().having(
          (error) => error.message,
          'corrupt-file explanation',
          contains('不是有效文档'),
        )),
      );
      expect(AnnotationAnchors.bodyText((await next).content), '普通稿件，不含批注。');
    });
  });

  group('selection geometry', () {
    PdfTextGlyph glyph(int start, int end, double x, double y) => PdfTextGlyph(
      start: start,
      end: end,
      bounds: PdfTextBounds(left: x - 0.5, bottom: y - 0.5, right: x + 0.5, top: y + 0.5),
    );
    const diamond = PdfTextQuad([
      PdfTextPoint(0, 10),
      PdfTextPoint(20, 10),
      PdfTextPoint(10, 20),
      PdfTextPoint(10, 0),
    ]);

    test('uses the actual rotated polygon rather than its large bounding box', () {
      final result = matchPdfAnnotationRanges(
        body: '甲乙',
        glyphs: [glyph(0, 1, 10, 10), glyph(1, 2, 1, 1)],
        quads: const [diamond],
      );
      expect(result.unresolvedReason, isNull);
      expect(result.ranges.single.quote, '甲');
    });

    test('does not silently keep a partial match of a multi-region annotation', () {
      final result = matchPdfAnnotationRanges(
        body: '甲',
        glyphs: [glyph(0, 1, 10, 10)],
        quads: const [
          diamond,
          PdfTextQuad([
            PdfTextPoint(100, 100),
            PdfTextPoint(110, 100),
            PdfTextPoint(100, 110),
            PdfTextPoint(110, 110),
          ]),
        ],
      );
      expect(result.ranges, isEmpty);
      expect(result.unresolvedReason, isNotNull);
    });

    test('expands a native surrogate code unit to its whole emoji', () {
      final result = matchPdfAnnotationRanges(
        body: '😀甲',
        glyphs: [glyph(0, 1, 10, 10), glyph(1, 2, 40, 40), glyph(2, 3, 50, 50)],
        quads: const [diamond],
      );
      expect(result.ranges.single.quote, '😀');
      expect(result.ranges.single.start, 0);
      expect(result.ranges.single.end, 2);
    });
  });
}
