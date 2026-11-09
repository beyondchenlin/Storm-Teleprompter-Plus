import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/pages/teleprompter_page.dart';
import 'package:storm_teleprompter_plus/widgets/common/app_color_picker_dialog.dart';
import 'package:storm_teleprompter_plus/widgets/editor/reading_annotation_preview.dart';
import 'package:storm_teleprompter_plus/widgets/settings/reading_annotation_appearance_dialog.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';

import 'support/quick_workspace_test_host.dart';
import 'support/reading_ink_test_utils.dart';

Article _article() => Article(
  id: 'appearance-editor',
  title: '批注外观测试',
  content: '<p>把知识讲清楚，让观众听得懂。</p>',
  annotations: const [ReadingAnnotation(
    id: 'cue', text: '重读',
    ranges: [AnnotationRange(start: 3, end: 6, quote: '讲清楚')],
  )],
  teleprompterSettings: const AppSettings(
    fontSize: 52,
    lineHeight: 1.7,
    annotationFontFamily: 'SimSun',
    annotationFontSize: 12,
    annotationColor: 0xFF8BD1D0,
  ).toTeleprompterMap(),
  createdAt: DateTime(2026), updatedAt: DateTime(2026),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final caches = tester.widgetList<ReadingEmphasisLine>(
    find.byType(ReadingEmphasisLine),
  ).map((line) => line.glyphCache.inkCache).toSet();
  for (final cache in caches) { await settleReadingInk(tester, cache); }
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  final caches = tester.widgetList<ReadingEmphasisLine>(
    find.byType(ReadingEmphasisLine),
  ).map((line) => line.glyphCache.inkCache).toSet();
  await tester.pumpWidget(const SizedBox.shrink());
  for (final cache in caches) { await settleReadingInk(tester, cache); }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('本稿外观实时预览，取消不修改，应用后与批注一同保存重开', (tester) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final article = _article();
    final articles = QuickTestArticles()..upsertArticle(article);
    final settings = QuickTestSettings();
    await mountQuickWorkspace(tester,
      EditorPage(article: article, quickMode: true, autoSave: false), articles, settings);
    final editor = quickEditor(tester);
    final originalNotes = editor.annotations.map((note) => note.toJson()).toList();
    final opening = editor.editAnnotationAppearance();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('annotation-size-20')));
    await tester.tap(find.byKey(const ValueKey('annotation-color-4294947722')));
    await _settle(tester);
    final preview = tester.widget<ReadingAnnotationPreview>(
      find.byKey(const ValueKey('annotation-appearance-preview')),
    );
    expect(preview.settings!.annotationFontSize, 20);
    expect(preview.settings!.annotationFontFamily, 'SimSun');
    expect(preview.settings!.annotationColor, 0xFFFFB38A);
    expect(preview.settings!.fontSize, 52);
    expect(editor.annotationPreviewSettings.annotationFontSize, 12);
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await _settle(tester);
    await opening;
    expect(editor.isDirty, isFalse);
    expect(editor.annotationPreviewSettings.annotationColor, 0xFF8BD1D0);

    final secondOpening = editor.editAnnotationAppearance();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('annotation-size-20')));
    await tester.tap(find.byKey(const ValueKey('annotation-color-4294947722')));
    await tester.tap(find.byKey(const ValueKey('annotation-appearance-apply')));
    await _settle(tester);
    await secondOpening;
    expect(editor.isDirty, isTrue);
    await editor.save(force: true);
    final saved = articles.articles.single;
    expect(saved.teleprompterSettings!['annotationFontSize'], 20);
    expect(saved.teleprompterSettings!['annotationColor'], 0xFFFFB38A);
    expect(saved.teleprompterSettings!['annotationFontFamily'], 'SimSun');
    expect(saved.annotations.map((note) => note.toJson()).toList(), originalNotes);
    expect(settings.settings.annotationFontSize, 0);
    await _unmount(tester);
    await mountQuickWorkspace(tester,
      EditorPage(article: saved, quickMode: true, autoSave: false), articles, settings);
    expect(quickEditor(tester).annotationPreviewSettings.annotationFontSize, 20);
    expect(quickEditor(tester).annotationPreviewSettings.annotationColor, 0xFFFFB38A);
    await _unmount(tester);
  });

  testWidgets('保存失败保留新稿且不会开始播放旧的成功快照', (tester) async {
    final article = _article();
    final articles = QuickTestArticles()..upsertArticle(article);
    await mountQuickWorkspace(tester, EditorPage(article: article), articles, QuickTestSettings());
    final editor = quickEditor(tester);
    editor.quillController.replaceText(0, 0, '新版本', const TextSelection.collapsed(offset: 3));
    articles.fail = true;
    await editor.quickStartTeleprompter();
    await tester.pumpAndSettle();
    expect(find.byType(TeleprompterPage), findsNothing);
    expect(editor.isDirty, isTrue);
    expect(editor.contentController.text, contains('新版本'));
    expect(articles.articles.single.content, article.content);
    expect(find.text('保存失败，当前修改仍保留在编辑器中，请重试后开始提词'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('未保存临时稿播放调整外观后返回编辑器保留效果，不强制落盘', (tester) async {
    final articles = QuickTestArticles();
    final settings = QuickTestSettings();
    await mountQuickWorkspace(tester,
      const EditorPage(quickMode: true, autoSave: false), articles, settings);
    final editor = quickEditor(tester);
    editor.quillController.replaceText(0, 0, '临时正文', const TextSelection.collapsed(offset: 4));
    final playing = editor.quickStartTeleprompter();
    await tester.pumpAndSettle();
    await settings.setAnnotationAppearance(fontFamily: 'SimHei', fontSize: 18, color: 0xFFC9B5FF);
    await tester.pump();
    Navigator.of(tester.element(find.byType(TeleprompterPage))).pop();
    await tester.pumpAndSettle();
    await playing;
    expect(editor.annotationPreviewSettings.annotationFontSize, 18);
    expect(editor.annotationPreviewSettings.annotationFontFamily, 'SimHei');
    expect(editor.annotationPreviewSettings.annotationColor, 0xFFC9B5FF);
    expect(articles.writes, 0);
    await _unmount(tester);
  });

  testWidgets('普通稿件保存失败时系统返回不会丢弃当前正文或外观', (tester) async {
    final article = _article();
    final articles = QuickTestArticles()..upsertArticle(article);
    await mountQuickWorkspace(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => EditorPage(article: article)),
      ), child: const Text('编辑')),
    )), articles, QuickTestSettings());
    await tester.tap(find.text('编辑'));
    await _settle(tester);
    final editor = quickEditor(tester);
    editor.quillController.replaceText(0, 0, '未存', const TextSelection.collapsed(offset: 2));
    editor.applyAnnotationAppearance(editor.annotationPreviewSettings.copyWith(annotationFontSize: 20));
    articles.fail = true;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsOneWidget);
    expect(find.text('保存稿件？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(editor.contentController.text, contains('未存'));
    expect(editor.annotationPreviewSettings.annotationFontSize, 20);
    expect(articles.articles.single.content, article.content);
    articles.fail = false;
    await editor.requestExit();
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsNothing);
    expect(articles.articles.single.teleprompterSettings!['annotationFontSize'], 20);
    await _unmount(tester);
  });

  testWidgets('无批注当前字也能预览邻近备注，窄窗口恢复默认只改外观', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppSettings? result;
    final article = _article();
    final initial = const AppSettings().mergeOverrides(article.teleprompterSettings!);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        result = await ReadingAnnotationAppearanceDialog.show(context,
          initialSettings: initial, content: article.content,
          annotations: article.annotations, focusRawIndex: -1);
      }, child: const Text('打开')),
    ))));
    await tester.tap(find.text('打开'));
    await _settle(tester);
    final preview = tester.widget<ReadingAnnotationPreview>(find.byKey(const ValueKey('annotation-appearance-preview')));
    expect(preview.focusRawIndex, 3);
    await tester.tap(find.byKey(const ValueKey('annotation-appearance-reset')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('annotation-appearance-apply')));
    await _settle(tester);
    expect(result!.annotationFontSize, 0);
    expect(result!.annotationFontFamily, '');
    expect(result!.annotationColor, AppSettings.defaultAnnotationColor);
    expect(result!.fontSize, initial.fontSize);
    expect(result!.lineHeight, initial.lineHeight);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('无效颜色代码不能提交旧颜色，批注自定义颜色保持可见', (tester) async {
    Color? selected;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        selected = await AppColorPickerDialog.show(context,
          title: '批注颜色', currentColor: Colors.white, enableAlpha: false);
      }, child: const Text('打开')),
    ))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '#12');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确定')).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '#00336699');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(selected!.toARGB32(), 0xFF336699);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
