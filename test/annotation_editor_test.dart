import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/widgets/editor/reading_annotation_preview.dart';

import 'support/quick_workspace_test_host.dart';

void main() {
  testWidgets(
    'editing an imported long note preserves its complete trailing content',
    (tester) async {
      final articles = QuickTestArticles();
      final settings = QuickTestSettings();
      final longText = '原${List.filled(2100, '声').join()}保留尾部说明';
      final note = ReadingAnnotation(
        id: 'long-note',
        text: longText,
        source: 'docx',
        ranges: const [AnnotationRange(start: 0, end: 2, quote: '学习')],
      );
      final article = Article(
        id: 'long-import',
        title: '长批注',
        content: '<p>学习不是记住</p>',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        annotations: [note],
      );
      articles.upsertArticle(article);
      await mountQuickWorkspace(
        tester,
        EditorPage(article: article, quickMode: true, autoSave: false),
        articles,
        settings,
      );
      final editor = tester.state<EditorPageState>(find.byType(EditorPage));
      unawaited(editor.editExistingAnnotation(note));
      await tester.pumpAndSettle();
      final edited = '改${longText.substring(1)}';
      await tester.enterText(
        find.byKey(const ValueKey('annotation-text-input')),
        edited,
      );
      await tester.pump();
      await tester.tap(find.text('保存批注'));
      await tester.pumpAndSettle();
      await editor.save(force: true);
      expect(editor.annotations.single.text, edited);
      expect(articles.articles.single.annotations.single.text, edited);
      expect(articles.articles.single.annotations.single.text.length,
          longText.length);
      expect(editor.annotations.single.text, endsWith('保留尾部说明'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'selected word note is saved atomically and stays out of body text',
    (tester) async {
      final articles = QuickTestArticles();
      final settings = QuickTestSettings();
      await mountQuickWorkspace(
        tester,
        const EditorPage(quickMode: true, autoSave: false),
        articles,
        settings,
      );
      final editor = tester.state<EditorPageState>(find.byType(EditorPage));
      editor.quillController.replaceText(
        0,
        0,
        '学习不是记住',
        const TextSelection(baseOffset: 2, extentOffset: 3),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-reading-annotation')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('annotation-text-input')),
        '重读',
      );
      await tester.pump();
      final preview = tester.widget<ReadingAnnotationPreview>(
        find.byKey(const ValueKey('live-annotation-preview')),
      );
      expect(preview.annotations.single.text, '重读');
      expect(preview.annotations.single.ranges.single.quote, '不');
      await tester.tap(find.text('保存批注'));
      await tester.pumpAndSettle();
      expect(editor.annotations.single.ranges.single.quote, '不');
      expect(editor.annotations.single.ranges.single.start, 2);
      expect(editor.contentController.text, isNot(contains('重读')));
      expect(find.byType(ReadingAnnotationPreview), findsOneWidget);
      await editor.save(force: true);
      expect(articles.articles.single.annotations.single.text, '重读');
      expect(articles.articles.single.content, editor.contentController.text);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'editing before a note preserves it, editing its word requires repair',
    (tester) async {
      final articles = QuickTestArticles();
      final settings = QuickTestSettings();
      final article = Article(
        id: 'a',
        title: '测试',
        content: '<p>学习不是记住</p>',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        annotations: const [
          ReadingAnnotation(
            id: 'n',
            text: '重读',
            ranges: [AnnotationRange(start: 2, end: 3, quote: '不')],
          ),
        ],
      );
      articles.upsertArticle(article);
      await mountQuickWorkspace(
        tester,
        EditorPage(article: article, quickMode: true, autoSave: false),
        articles,
        settings,
      );
      final editor = tester.state<EditorPageState>(find.byType(EditorPage));
      editor.quillController.replaceText(
        0,
        0,
        '今天',
        const TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      expect(editor.annotations.single.ranges.single.start, 4);
      expect(editor.annotations.single.isAnchored, isTrue);
      editor.quillController.replaceText(
        4,
        1,
        '要',
        const TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      expect(editor.annotations.single.isAnchored, isFalse);
      expect(editor.annotations.single.text, '重读');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'unbound imported note can be attached to the current selection',
    (tester) async {
      final articles = QuickTestArticles();
      final settings = QuickTestSettings();
      final article = Article(
        id: 'b',
        title: '测试',
        content: '<p>先理解再表达</p>',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        annotations: const [
          ReadingAnnotation(
            id: 'unbound',
            text: '停一秒',
            source: 'pdf',
            unresolvedReason: '便笺没有字词范围',
          ),
        ],
      );
      articles.upsertArticle(article);
      await mountQuickWorkspace(
        tester,
        EditorPage(article: article, quickMode: true, autoSave: false),
        articles,
        settings,
      );
      final editor = tester.state<EditorPageState>(find.byType(EditorPage));
      editor.quillController.updateSelection(
        const TextSelection(baseOffset: 1, extentOffset: 3),
        quill.ChangeSource.local,
      );
      unawaited(editor.manageAnnotations());
      await tester.pumpAndSettle();
      await tester.tap(find.text('绑定到所选字词'));
      await tester.pumpAndSettle();
      expect(editor.annotations.single.isAnchored, isTrue);
      expect(editor.annotations.single.ranges.single.quote, '理解');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await editor.save(force: true);
      expect(
        articles.articles.single.annotations.single.ranges.single.start,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'numeric HTML entities round-trip without changing annotated original text',
    (tester) async {
      final articles = QuickTestArticles();
      final settings = QuickTestSettings();
      final article = Article(
        id: 'entities',
        title: '实体',
        content: '<p>甲&#x1F600;乙</p>',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        annotations: const [
          ReadingAnnotation(
            id: 'emoji',
            text: '语气轻快',
            ranges: [AnnotationRange(start: 1, end: 3, quote: '😀')],
          ),
        ],
      );
      articles.upsertArticle(article);
      await mountQuickWorkspace(
        tester,
        EditorPage(article: article, quickMode: true, autoSave: false),
        articles,
        settings,
      );
      final editor = tester.state<EditorPageState>(find.byType(EditorPage));
      expect(editor.quillController.document.toPlainText(), '甲😀乙\n');
      editor.quillController.updateSelection(
        const TextSelection(baseOffset: 1, extentOffset: 3),
        quill.ChangeSource.local,
      );
      await tester.pump();
      await editor.save(force: true);
      expect(articles.articles.single.annotations.single.isAnchored, isTrue);
      expect(
        articles.articles.single.annotations.single.ranges.single.quote,
        '😀',
      );
      expect(articles.articles.single.content, isNot(contains('&amp;#')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
