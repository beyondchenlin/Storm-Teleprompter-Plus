import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/services/annotation_anchors.dart';

import 'support/quick_workspace_test_host.dart';

ReadingAnnotation _note(String id, int start, String quote) => ReadingAnnotation(
  id: id,
  text: '原始提示',
  source: 'docx',
  page: 2,
  ranges: [AnnotationRange(start: start, end: start + quote.length, quote: quote)],
);

Future<EditorPageState> _mount(
  WidgetTester tester,
  String body,
  List<ReadingAnnotation> notes, {
  QuickTestArticles? articles,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 950);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final article = Article(
    id: 'history',
    title: '撤销回归',
    content: '<p>$body</p>',
    annotations: notes,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
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

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void _replace(
  EditorPageState editor,
  int start,
  int length,
  String text, {
  bool merge = false,
}) {
  // Make grouping deterministic without waiting on the machine's wall clock.
  editor.quillController.document.history.lastRecorded = merge
      ? DateTime.now().millisecondsSinceEpoch + 60000
      : 0;
  editor.quillController.replaceText(
    start,
    length,
    text,
    TextSelection.collapsed(offset: start + text.length),
  );
}

void _select(EditorPageState editor, int start, int end) =>
    editor.quillController.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      quill.ChangeSource.local,
    );

Future<void> _finishNoteDialog(WidgetTester tester, String text) async {
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('annotation-text-input')), text);
  await tester.tap(find.text('保存批注'));
  await tester.pumpAndSettle();
}

Future<void> _addNote(
  WidgetTester tester,
  EditorPageState editor,
  int start,
  int end,
  String text,
) async {
  _select(editor, start, end);
  unawaited(editor.addAnnotation());
  await _finishNoteDialog(tester, text);
}

Future<void> _editNote(
  WidgetTester tester,
  EditorPageState editor,
  String text,
) async {
  unawaited(editor.editExistingAnnotation(editor.annotations.single));
  await _finishNoteDialog(tester, text);
}

void _expectAnchor(ReadingAnnotation note, int start, String quote) {
  expect(note.isAnchored, isTrue);
  expect(note.ranges.single.start, start);
  expect(note.ranges.single.end, start + quote.length);
  expect(note.ranges.single.quote, quote);
}

void main() {
  testWidgets('正文撤销恢复导入锚点但保留最新备注内容和来源，重做再次待定位', (tester) async {
    final articles = QuickTestArticles();
    final editor = await _mount(
      tester,
      '开始不是结束',
      [_note('imported', 2, '不是')],
      articles: articles,
    );
    _replace(editor, 2, 2, '应该');
    expect(editor.annotations.single.isAnchored, isFalse);
    await _editNote(tester, editor, '最新提示\n停一秒再重读');
    editor.quillController.undo();
    await tester.pump();
    _expectAnchor(editor.annotations.single, 2, '不是');
    expect(editor.annotations.single.text, '最新提示\n停一秒再重读');
    expect(editor.annotations.single.source, 'docx');
    expect(editor.annotations.single.page, 2);
    editor.quillController.redo();
    expect(editor.annotations.single.isAnchored, isFalse);
    expect(editor.annotations.single.text, '最新提示\n停一秒再重读');
    editor.quillController.undo();
    await editor.save(force: true);
    final saved = Article.fromJson(articles.articles.single.toJson());
    _expectAnchor(saved.annotations.single, 2, '不是');
    expect(saved.annotations.single.text, '最新提示\n停一秒再重读');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('先手动添加批注再编辑正文，撤销和重做保留同一条新批注', (tester) async {
    final editor = await _mount(tester, '甲不是乙', const []);
    await _addNote(tester, editor, 1, 3, '只重读这里');
    final id = editor.annotations.single.id;
    _replace(editor, 1, 2, '应该');
    expect(editor.annotations.single.isAnchored, isFalse);
    editor.quillController.undo();
    _expectAnchor(editor.annotations.single, 1, '不是');
    expect(editor.annotations.single.id, id);
    editor.quillController.redo();
    expect(editor.annotations.single.isAnchored, isFalse);
    expect(editor.annotations.single.id, id);
    expect(editor.annotations.single.text, '只重读这里');
    await _unmount(tester);
  });

  testWidgets('插入正文后新建批注，撤销保留待定位备注，重做恢复确切范围和最新文字', (tester) async {
    final editor = await _mount(tester, '甲乙', const []);
    _replace(editor, 1, 0, '不是');
    await _addNote(tester, editor, 1, 3, '插入后添加');
    final id = editor.annotations.single.id;
    editor.quillController.undo();
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '甲乙');
    expect(editor.annotations.single.isAnchored, isFalse);
    expect(editor.annotations.single.id, id);
    await _editNote(tester, editor, '待定位时修改的最新提示');
    editor.quillController.redo();
    _expectAnchor(editor.annotations.single, 1, '不是');
    expect(editor.annotations.single.id, id);
    expect(editor.annotations.single.text, '待定位时修改的最新提示');
    await _unmount(tester);
  });

  testWidgets('重复词只由真实撤销恢复各自位置，手工重新输入相同正文不恢复', (tester) async {
    final editor = await _mount(tester, '不是不是', [
      _note('first', 0, '不是'),
      _note('second', 2, '不是'),
    ]);
    _replace(editor, 0, 2, '');
    expect(editor.annotations.every((note) => !note.isAnchored), isTrue);
    editor.quillController.undo();
    _expectAnchor(editor.annotations[0], 0, '不是');
    _expectAnchor(editor.annotations[1], 2, '不是');
    editor.quillController.redo();
    expect(editor.annotations.every((note) => !note.isAnchored), isTrue);
    _replace(editor, 0, 0, '不是');
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '不是不是');
    expect(editor.annotations.every((note) => !note.isAnchored), isTrue);
    expect(editor.quillController.hasRedo, isFalse);
    await _unmount(tester);
  });

  testWidgets('已在批注管理删除的备注不会被正文撤销或重做复活', (tester) async {
    final editor = await _mount(tester, '甲不是乙', [_note('removed', 1, '不是')]);
    _replace(editor, 1, 2, '应该');
    unawaited(editor.manageAnnotations());
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(editor.annotations, isEmpty);
    editor.quillController.undo();
    expect(editor.annotations, isEmpty);
    editor.quillController.redo();
    expect(editor.annotations, isEmpty);
    await _unmount(tester);
  });

  testWidgets('连续输入合并成一个真实撤销组时恢复组开始前的锚点', (tester) async {
    final editor = await _mount(tester, '甲不是乙', [_note('merged', 1, '不是')]);
    _replace(editor, 0, 0, '前');
    _expectAnchor(editor.annotations.single, 2, '不是');
    _replace(editor, 2, 2, '应该', merge: true);
    expect(editor.quillController.document.history.stack.undo, hasLength(1));
    expect(editor.annotations.single.isAnchored, isFalse);
    editor.quillController.undo();
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '甲不是乙');
    _expectAnchor(editor.annotations.single, 1, '不是');
    editor.quillController.redo();
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '前甲应该乙');
    expect(editor.annotations.single.isAnchored, isFalse);
    await _unmount(tester);
  });

  testWidgets('合并组中人工改绑到第二个重复词，撤销不擅自改回第一个词', (tester) async {
    final editor = await _mount(tester, '甲不是乙不是丙', [_note('rebound', 1, '不是')]);
    _replace(editor, 0, 0, '前');
    _select(editor, 5, 7);
    unawaited(editor.manageAnnotations());
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定到所选字词'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    _expectAnchor(editor.annotations.single, 5, '不是');
    _replace(editor, 8, 0, '后', merge: true);
    expect(editor.quillController.document.history.stack.undo, hasLength(1));
    editor.quillController.undo();
    expect(AnnotationAnchors.bodyText(editor.contentController.text), '甲不是乙不是丙');
    expect(editor.annotations.single.isAnchored, isFalse);
    editor.quillController.redo();
    _expectAnchor(editor.annotations.single, 5, '不是');
    expect(editor.annotations.single.id, 'rebound');
    await _unmount(tester);
  });
}
