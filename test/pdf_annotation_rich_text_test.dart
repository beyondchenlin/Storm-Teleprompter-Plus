import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/files/pdf_annotation_importer.dart';
import 'package:storm_teleprompter_plus/services/files/pdf_annotation_text.dart';

void main() {
  test('retains authored rich comment paragraphs, breaks and inline words', () {
    expect(
      extractPdfRichAnnotationText(
        '<body xmlns="http://www.w3.org/1999/xhtml">'
        '<p><span>放慢</span><span>语速</span></p>'
        '<p>停一秒<br/>再继续</p></body>',
      ),
      '放慢语速\n停一秒\n再继续',
    );
  });

  test('does not double newlines at nested block and source boundaries', () {
    expect(
      extractPdfRichAnnotationText(
        '<body>\n  <div>\n    <p>第一行\n第二行\n</p>\n'
        '    <p>第三行</p>\n  </div>\n</body>',
      ),
      '第一行\n第二行\n第三行',
    );
    expect(
      extractPdfRichAnnotationText('<body><p>先停<br/><br/>再说</p></body>'),
      '先停\n\n再说',
    );
  });

  test('handles namespaced paragraphs, entities, and preserved whitespace', () {
    expect(
      extractPdfRichAnnotationText(
        '<x:body xmlns:x="http://www.w3.org/1999/xhtml">'
        '<x:p>轻声&amp;放慢&nbsp;一点</x:p><x:p>收尾</x:p></x:body>',
      ),
      '轻声&放慢\u00a0一点\n收尾',
    );
    expect(
      extractPdfRichAnnotationText(
        '<body><p xml:space="preserve">先说\n\n再停  一秒</p></body>',
      ),
      '先说\n\n再停  一秒',
    );
  });

  test('retains malformed rich comment text for manual recovery', () {
    const rich = '<body><p>不能丢失的批注';
    expect(extractPdfRichAnnotationText(rich), rich);
  });

  test('native PDF import preserves RC-only comment line structure', () async {
    final draft = await importPdf(
      File('test/fixtures/annotations/pdf_rich_comment_synthetic.pdf'),
    );
    expect(draft.annotations, hasLength(1));
    final note = draft.annotations.single;
    expect(note.text, '放慢语速\n停一秒\n再继续');
    expect(note.isAnchored, isTrue);
    expect(note.ranges.single.quote, '节奏');
  });
}
