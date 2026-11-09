import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';
import 'package:storm_teleprompter_plus/services/files/docx_annotation_importer.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/editor/reading_annotation_preview.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';

import 'support/quick_workspace_test_host.dart';
import 'support/reading_ink_test_utils.dart';

final _notice = find.byKey(const ValueKey('annotation-font-size-notice'));
final _useSize = find.byKey(const ValueKey('use-teleprompter-font-size'));

ReadingAnnotation _note(int start, String quote) => ReadingAnnotation(
  id: 'imported-note',
  text: '重读',
  source: 'docx',
  page: 2,
  ranges: [
    AnnotationRange(start: start, end: start + quote.length, quote: quote),
  ],
);

Article _article(String content, List<ReadingAnnotation> notes) => Article(
  id: 'font-size-regression',
  title: '导入字号回归',
  content: content,
  annotations: notes,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<EditorPageState> _mount(
  WidgetTester tester,
  Article article, {
  QuickTestArticles? articles,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 950);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = articles ?? QuickTestArticles();
  store.upsertArticle(article);
  await mountQuickWorkspace(
    tester,
    EditorPage(article: article, quickMode: true, autoSave: false),
    store,
    QuickTestSettings(),
  );
  return quickEditor(tester);
}

Future<ReadingEmphasisLineState> _settlePreview(WidgetTester tester) async {
  final state = tester.state<ReadingEmphasisLineState>(
    find.descendant(
      of: find.byType(ReadingAnnotationPreview).first,
      matching: find.byType(ReadingEmphasisLine),
    ).first,
  );
  await settleReadingInk(tester, state.widget.glyphCache.inkCache);
  return state;
}

Future<void> _unmount(WidgetTester tester) async {
  final caches = tester
      .widgetList<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine))
      .map((line) => line.glyphCache.inkCache)
      .toSet();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  for (final cache in caches) {
    await settleReadingInk(tester, cache);
  }
}

List<Map<String, dynamic>> _notes(EditorPageState editor) =>
    editor.annotations.map((note) => note.toJson()).toList();

List<Map<String, Object?>> _formatWithoutSize(String content) => [
  for (final line in TextParser.parse(content))
    for (final character in line.characters)
      {
        'text': character.char,
        'rawIndex': character.rawIndex,
        'bold': character.bold,
        'italic': character.italic,
        'underline': character.underline,
        'strike': character.strikeThrough,
        'color': character.textColor,
        'background': character.backgroundColor,
      },
];

void _expectNoFixedSize(String content) {
  expect(
    TextParser.parse(content)
        .expand((line) => line.characters)
        .every((character) => character.fontSizePx == null),
    isTrue,
  );
}

void main() {
  testWidgets('真实办公软件批注样本保留原字号，明确一键适配后立即展开预览', (tester) async {
    final draft = (await tester.runAsync(
      () => importDocx(
        File('test/fixtures/annotations/wps_actual_annotations.docx'),
      ),
    ))!;
    expect(draft.annotations, hasLength(4));
    expect(
      TextParser.parse(draft.content)
          .expand((line) => line.characters)
          .every((character) => character.fontSizePx == 27),
      isTrue,
    );
    final articles = QuickTestArticles();
    final editor = await _mount(
      tester,
      _article(draft.content, draft.annotations),
      articles: articles,
    );
    final notes = _notes(editor);
    expect(editor.hasSmallAnnotationFontSize, isTrue);
    expect(_notice, findsOneWidget);
    expect(editor.quillController.selection.isCollapsed, isTrue);

    await tester.tap(_useSize);
    await tester.pump();
    _expectNoFixedSize(editor.contentController.text);
    expect(_notice, findsNothing);
    expect(_notes(editor), notes);
    expect(editor.showAnnotationPreview, isTrue);
    final preview = await _settlePreview(tester);
    final layout = preview.debugAnnotationLayout!;
    final labels = [
      for (var index = 0; index < preview.debugLayout.rows.length; index++)
        ...layout.rowAt(index).labels,
    ];
    expect(labels, isNotEmpty);
    expect(
      labels.any((label) => label.anchor.notes.any((note) => note.text == '重读')),
      isTrue,
    );
    await editor.save(force: true);
    _expectNoFixedSize(articles.articles.single.content);
    expect(
      articles.articles.single.annotations.map((note) => note.toJson()).toList(),
      notes,
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('只在批注对应字词过小时提示，一键保留其他格式并重新展开已收起预览', (tester) async {
    final editor = await _mount(
      tester,
      _article(
        '<p><span style="color: #148A9C; background-color: #FFF59D">'
        '<b><i><u><s>不</s></u></i></b></span>要忘记。</p>'
        '<p><span style="font-size: 13px">页脚</span></p>',
        [_note(0, '不')],
      ),
    );
    expect(editor.hasSmallAnnotationFontSize, isFalse);
    expect(_notice, findsNothing);
    editor.quillController.formatText(
      0,
      1,
      quill.Attribute.fromKeyValue(quill.Attribute.size.key, '27')!,
    );
    await tester.pump();
    expect(editor.hasSmallAnnotationFontSize, isTrue);
    expect(_notice, findsOneWidget);
    final body = AnnotationAnchors.bodyText(editor.contentController.text);
    final format = _formatWithoutSize(editor.contentController.text);
    final notes = _notes(editor);
    expect(format.first['bold'], isTrue);
    expect(format.first['italic'], isTrue);
    expect(format.first['underline'], isTrue);
    expect(format.first['strike'], isTrue);
    expect(format.first['color'], isNotNull);
    expect(format.first['background'], isNotNull);
    await _settlePreview(tester);
    editor.toggleAnnotationPreview();
    await tester.pump();
    expect(find.byType(ReadingAnnotationPreview), findsNothing);
    expect(_notice, findsOneWidget);

    await tester.tap(_useSize);
    await tester.pump();
    expect(editor.showAnnotationPreview, isTrue);
    expect(find.byType(ReadingAnnotationPreview), findsOneWidget);
    _expectNoFixedSize(editor.contentController.text);
    expect(AnnotationAnchors.bodyText(editor.contentController.text), body);
    expect(_formatWithoutSize(editor.contentController.text), format);
    expect(_notes(editor), notes);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('使用提词字号是独立可撤销操作，撤销与重做均保留正文和批注范围', (tester) async {
    final editor = await _mount(
      tester,
      _article(
        '<p><span style="font-size: 27px">甲不是乙</span></p>',
        [_note(1, '不是')],
      ),
    );
    final controller = editor.quillController;
    controller.document.history.lastRecorded = 0;
    controller.replaceText(
      0,
      0,
      '前',
      const TextSelection.collapsed(offset: 1),
    );
    await tester.pump();
    final delta = controller.document.toDelta().toJson();
    final notes = _notes(editor);
    expect(editor.annotations.single.ranges.single.start, 2);
    expect(controller.document.history.stack.undo, hasLength(1));
    // Adjacent typing would merge unless the size action starts its own group.
    controller.document.history.lastRecorded =
        DateTime.now().millisecondsSinceEpoch + 60000;

    await tester.tap(_useSize);
    await tester.pump();
    expect(controller.document.history.stack.undo, hasLength(2));
    expect(controller.selection.isCollapsed, isTrue);
    _expectNoFixedSize(editor.contentController.text);
    expect(_notes(editor), notes);
    controller.undo();
    await tester.pump();
    expect(controller.document.toDelta().toJson(), delta);
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '前甲不是乙');
    expect(_notes(editor), notes);
    expect(_notice, findsOneWidget);
    controller.redo();
    await tester.pump();
    _expectNoFixedSize(editor.contentController.text);
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '前甲不是乙');
    expect(_notes(editor), notes);
    expect(_notice, findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}
