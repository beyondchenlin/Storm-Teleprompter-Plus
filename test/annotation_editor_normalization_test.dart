import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';

import 'support/quick_workspace_test_host.dart';

ReadingAnnotation _note(
  String id,
  int start,
  String quote, [
  String text = '重读',
]) => ReadingAnnotation(
  id: id,
  text: text,
  ranges: [
    AnnotationRange(start: start, end: start + quote.length, quote: quote),
  ],
);

Article _article(String content, List<ReadingAnnotation> notes) => Article(
  id: 'normalization',
  title: '格式兼容',
  content: content,
  annotations: notes,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<EditorPageState> _mount(
  WidgetTester tester,
  Article article,
  QuickTestArticles articles,
) async {
  articles.upsertArticle(article);
  await mountQuickWorkspace(
    tester,
    EditorPage(article: article, quickMode: true, autoSave: false),
    articles,
    QuickTestSettings(),
  );
  return quickEditor(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void _wideViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 950);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('导入制表符和连续制表符在选择、保存、重新打开后保持原字和原范围', (tester) async {
    const content = '<p>甲\t\t乙</p><p>丙\t丁</p>';
    const body = '甲\t\t乙丙\t丁';
    final articles = QuickTestArticles();
    var editor = await _mount(
      tester,
      _article(content, [_note('first', 0, '甲\t\t乙'), _note('last', 6, '丁')]),
      articles,
    );
    expect(editor.quillController.document.toPlainText(), '甲\t\t乙\n丙\t丁\n');
    editor.quillController.updateSelection(
      const TextSelection.collapsed(offset: 2),
      quill.ChangeSource.local,
    );
    await tester.pump();
    expect(AnnotationAnchors.bodyText(editor.contentController.text), body);
    expect(editor.annotations.every((note) => note.isAnchored), isTrue);
    await editor.save(force: true);
    final saved = Article.fromJson(articles.articles.single.toJson());
    await _unmount(tester);
    editor = await _mount(tester, saved, articles);
    expect(AnnotationAnchors.bodyText(editor.contentController.text), body);
    expect(editor.annotations.first.ranges.single.quote, '甲\t\t乙');
    expect(editor.annotations.last.ranges.single.start, 6);
    expect(editor.annotations.every((note) => note.isAnchored), isTrue);
    await _unmount(tester);
  });

  testWidgets('软换行保留原段落和字词样式，保存重开不变成段落或空格', (tester) async {
    const content = '<p>甲<br><b>乙</b><br/>丙</p><p>丁</p>';
    final articles = QuickTestArticles();
    var editor = await _mount(
      tester,
      _article(content, [_note('across', 0, '甲乙丙'), _note('word', 1, '乙')]),
      articles,
    );
    expect(
      editor.quillController.document.toPlainText(),
      '甲\u2028乙\u2028丙\n丁\n',
    );
    editor.quillController.updateSelection(
      const TextSelection.collapsed(offset: 2),
      quill.ChangeSource.local,
    );
    await tester.pump();
    await editor.save(force: true);
    final saved = Article.fromJson(articles.articles.single.toJson());
    expect(RegExp('<br>').allMatches(saved.content), hasLength(2));
    final lines = TextParser.parse(saved.content);
    expect(lines.map((line) => line.text), ['甲', '乙', '丙', '丁']);
    expect(lines[1].characters.single.bold, isTrue);
    expect(identical(lines[0].paragraph, lines[1].paragraph), isTrue);
    expect(identical(lines[0].paragraph, lines[2].paragraph), isTrue);
    expect(identical(lines[0].paragraph, lines[3].paragraph), isFalse);
    expect(saved.annotations.every((note) => note.isAnchored), isTrue);
    await _unmount(tester);
    editor = await _mount(tester, saved, articles);
    expect(
      editor.quillController.document.toPlainText(),
      '甲\u2028乙\u2028丙\n丁\n',
    );
    expect(editor.annotations.first.ranges.single.quote, '甲乙丙');
    expect(editor.annotations.last.ranges.single.start, 1);
    await _unmount(tester);
  });

  testWidgets('软换行后新建批注与点击真实预览标签定位原文都选中同一个字', (tester) async {
    _wideViewport(tester);
    final articles = QuickTestArticles();
    final editor = await _mount(
      tester,
      _article('<p>甲<br>乙丙</p>', const []),
      articles,
    );
    editor.quillController.updateSelection(
      const TextSelection(baseOffset: 2, extentOffset: 3),
      quill.ChangeSource.local,
    );
    unawaited(editor.addAnnotation());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('annotation-text-input')),
      '重读',
    );
    await tester.tap(find.text('保存批注'));
    await tester.pumpAndSettle();
    expect(editor.annotations.single.ranges.single.start, 1);
    expect(editor.annotations.single.ranges.single.quote, '乙');
    editor.quillController.updateSelection(
      const TextSelection.collapsed(offset: 0),
      quill.ChangeSource.local,
    );
    await tester.pump();
    final chip = find.widgetWithText(ActionChip, '乙 · 重读');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();
    expect(
      editor.quillController.selection,
      const TextSelection(baseOffset: 2, extentOffset: 3),
    );
    expect(
      editor.quillController.document.toPlainText().substring(
        editor.quillController.selection.start,
        editor.quillController.selection.end,
      ),
      '乙',
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('旧纯文本首次初始化明确映射多处换行，选词和保存重开不会失锚', (tester) async {
    _wideViewport(tester);
    const source = '甲\n乙\n丙';
    final articles = QuickTestArticles();
    var editor = await _mount(
      tester,
      _article(source, [
        _note('middle', 2, '乙'),
        _note('across', 0, source, '慢读'),
      ]),
      articles,
    );
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '甲乙丙');
    expect(editor.annotations.first.ranges.single.start, 1);
    expect(editor.annotations.first.ranges.single.end, 2);
    expect(editor.annotations.last.ranges.single.quote, '甲乙丙');
    expect(editor.annotations.last.ranges.single.end, 3);
    expect(editor.annotations.every((note) => note.isAnchored), isTrue);
    await tester.tap(find.widgetWithText(ActionChip, '乙 · 重读'));
    await tester.pump();
    expect(
      editor.quillController.selection,
      const TextSelection(baseOffset: 2, extentOffset: 3),
    );
    await editor.save(force: true);
    final saved = Article.fromJson(articles.articles.single.toJson());
    expect(saved.annotations.every((note) => note.isAnchored), isTrue);
    await _unmount(tester);
    editor = await _mount(tester, saved, articles);
    expect(editor.annotations.first.ranges.single.start, 1);
    expect(editor.annotations.last.ranges.single.quote, '甲乙丙');
    expect(editor.annotations.every((note) => note.isAnchored), isTrue);
    await _unmount(tester);
  });

  testWidgets('纯文本换行转换保留代理对、回车和重复词的确切出现位置', (tester) async {
    const source = '甲\r\n不是😀\n不是乙';
    final second = source.lastIndexOf('不是');
    final emoji = source.indexOf('😀');
    final articles = QuickTestArticles();
    final editor = await _mount(
      tester,
      _article(source, [
        _note('second', second, '不是'),
        _note('emoji', emoji, '😀'),
      ]),
      articles,
    );
    final after = AnnotationAnchors.bodyText(editor.contentController.text);
    expect(after, '甲\r不是😀不是乙');
    expect(editor.annotations.first.ranges.single.start, second - 2);
    expect(editor.annotations.last.ranges.single.start, emoji - 1);
    expect(
      editor.annotations.last.ranges.single.end -
          editor.annotations.last.ranges.single.start,
      2,
    );
    expect(editor.annotations.every((note) => note.isAnchored), isTrue);
    await editor.save(force: true);
    expect(
      articles.articles.single.annotations.first.ranges.single.start,
      after.lastIndexOf('不是'),
    );
    await _unmount(tester);
  });
}
