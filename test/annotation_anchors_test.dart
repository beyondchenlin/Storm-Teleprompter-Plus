import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';

ReadingAnnotation note(int start, String quote) => ReadingAnnotation(
  id: 'note-$start', text: '放慢语速\n把意思讲清楚',
  ranges: [AnnotationRange(start: start, end: start + quote.length, quote: quote)],
);

void main() {
  test('HTML entities and paragraph breaks share displayed reading offsets', () {
    const content = '<p>甲&amp;&lt;乙&gt;&#x1F600;</p><p>不是<br>记住</p>';
    expect(AnnotationAnchors.bodyText(content), '甲&<乙>😀不是记住');
    expect(AnnotationAnchors.bodyText('甲\n乙'), '甲\n乙');
    expect(TextParser.parse('<p>&amp;lt;</p>').single.text, '&lt;');
    expect(TextParser.parse('<p>甲<').single.characters.last.rawIndex, 1);
    expect(AnnotationAnchors.validate(content, [note(7, '不是')]).single.isAnchored, isTrue);
  });

  test('insertions before a selected word shift only its exact range', () {
    final moved = AnnotationAnchors.remap('<p>学习不是记住</p>',
      '<p>今天学习不是记住</p>', [note(2, '不')]).single;
    expect(moved.isAnchored, isTrue);
    expect(moved.ranges.single.start, 4);
    expect(moved.ranges.single.end, 5);
    expect(moved.text, '放慢语速\n把意思讲清楚');
  });

  test('formatting and manual line wrapping never shift anchors', () {
    final moved = AnnotationAnchors.remap('<p>能够用得出来</p>',
      '<p>能够<b>用得</b><br>出来</p>', [note(2, '用得出来')]).single;
    expect(moved.ranges.single.start, 2);
    expect(moved.isAnchored, isTrue);
  });

  test('edited annotated word is retained as unbound, never guessed by search', () {
    final moved = AnnotationAnchors.remap('<p>不是记住，不是背诵</p>',
      '<p>不要记住，不是背诵</p>', [note(0, '不是')]).single;
    expect(moved.isAnchored, isFalse);
    expect(moved.text, isNotEmpty);
    expect(moved.ranges.single.quote, '不是');
  });

  test('ambiguous repeated-word deletion cannot silently bind another occurrence', () {
    final moved = AnnotationAnchors.remap('<p>不是不是</p>',
      '<p>不是</p>', [note(0, '不是'), note(2, '不是')]);
    expect(moved.every((entry) => !entry.isAnchored), isTrue);
  });

  test('invalid persisted quote cannot paint and can be deliberately reattached', () {
    final original = note(2, '错词');
    final invalid = AnnotationAnchors.validate('<p>学习知识</p>', [original]).single;
    expect(invalid.isAnchored, isFalse);
    final repaired = invalid.copyWith(
      ranges: [const AnnotationRange(start: 2, end: 4, quote: '知识')],
      clearUnresolvedReason: true,
    );
    expect(AnnotationAnchors.validate('<p>学习知识</p>', [repaired]).single.isAnchored, isTrue);
  });

  test('article round trip preserves multiranges, unbound notes, and old files', () {
    final article = Article(id: 'a', title: '测试', content: '<p>学习知识</p>',
      createdAt: DateTime(2026), updatedAt: DateTime(2026),
      annotations: [note(0, '学习'), const ReadingAnnotation(id: 'pdf-1', text: '停一秒',
        source: 'pdf', page: 2, unresolvedReason: '便笺没有选词范围')]);
    expect(Article.fromJson(article.toJson()).toJson(), article.toJson());
    final legacy = article.toJson()..remove('annotations');
    expect(Article.fromJson(legacy).annotations, isEmpty);
    expect(article.copyWith(title: '新标题').annotations.length, 2);
  });
}
