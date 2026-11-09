import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/backup_service.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/models/app_backup.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/folder.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

class _BatchPreferences implements AppPreferences {
  final data = <String, String>{};
  int singleWrites = 0;
  int batchWrites = 0;
  bool failBatch = false;
  Completer<void>? nextSingleGate;
  Completer<void>? singleStarted;
  Completer<void>? nextBatchGate;
  Completer<void>? batchStarted;

  @override
  String? getString(String key) => data[key];

  @override
  Future<bool> setString(String key, String value) async {
    singleWrites++;
    final gate = nextSingleGate;
    nextSingleGate = null;
    singleStarted?.complete();
    singleStarted = null;
    if (gate != null) await gate.future;
    data[key] = value;
    return true;
  }

  @override
  Future<bool> setStrings(Map<String, String> values) async {
    batchWrites++;
    final gate = nextBatchGate;
    nextBatchGate = null;
    batchStarted?.complete();
    batchStarted = null;
    if (gate != null) await gate.future;
    if (failBatch) return false;
    data.addAll(values);
    return true;
  }
}

AppBackup _backup() {
  final now = DateTime(2026, 11, 9);
  return AppBackup(
    createdAt: now,
    articles: [
      Article(
        id: 'restored-script',
        title: '恢复稿',
        content: '<p>保持节奏</p>',
        annotations: const [
          ReadingAnnotation(
            id: 'restored-note',
            text: '放慢语速\n停一秒',
            ranges: [AnnotationRange(start: 2, end: 4, quote: '节奏')],
          ),
        ],
        folderId: 'restored-folder',
        createdAt: now,
        updatedAt: now,
        teleprompterSettings: const AppSettings(
          annotationFontSize: 20,
          annotationColor: 0xFFFFCC66,
        ).toTeleprompterMap(),
      ),
    ],
    folders: [Folder(id: 'restored-folder', name: '恢复文件夹', createdAt: now)],
    settings: const AppSettings(
      fontSize: 80,
      annotationFontSize: 20,
      annotationColor: 0xFFFFCC66,
      currentCharColor: 0xFF66FFCC,
    ),
  );
}

void main() {
  late _BatchPreferences preferences;
  late ArticleService articles;
  late SettingsService settings;
  late BackupService backup;

  setUp(() async {
    preferences = _BatchPreferences();
    articles = ArticleService(preferences: preferences);
    settings = SettingsService(preferences: preferences);
    await articles.init();
    await settings.init();
    backup = BackupService(articles, settings);
    final folder = await articles.createFolder(name: '原文件夹');
    await articles.createArticle(title: '原稿', content: '原正文', folderId: folder.id);
    await settings.saveSettings(const AppSettings(fontSize: 60));
    preferences.singleWrites = 0;
  });

  test('one durable write restores all data and updates the settings cache', () async {
    await backup.restoreBackup(_backup());
    expect(preferences.batchWrites, 1);
    expect(preferences.singleWrites, 0);
    expect((await articles.loadFolders()).single.id, 'restored-folder');
    final restored = (await articles.loadArticles()).single;
    expect(restored.folderId, 'restored-folder');
    expect(restored.annotations.single.text, '放慢语速\n停一秒');
    expect(restored.teleprompterSettings!['annotationFontSize'], 20);
    final applied = await settings.loadSettings();
    expect(applied.fontSize, 80);
    expect(applied.annotationColor, 0xFFFFCC66);
    expect(applied.currentCharColor, 0xFF66FFCC);
    final restarted = SettingsService(preferences: preferences);
    await restarted.init();
    expect((await restarted.loadSettings()).toJson(), applied.toJson());
  });

  test('a failed restore leaves all prior data and the cached settings intact', () async {
    final before = Map<String, String>.from(preferences.data);
    preferences.failBatch = true;
    await expectLater(backup.restoreBackup(_backup()), throwsStateError);
    expect(preferences.data, before);
    expect(preferences.batchWrites, 1);
    expect(preferences.singleWrites, 0);
    expect((await articles.loadArticles()).single.title, '原稿');
    expect((await articles.loadFolders()).single.name, '原文件夹');
    expect((await settings.loadSettings()).fontSize, 60);

    preferences.failBatch = false;
    await articles.createArticle(title: '恢复失败后新建', content: '保留原稿');
    expect((await articles.loadArticles()).map((item) => item.title), contains('原稿'));
    await backup.restoreBackup(_backup());
    expect((await articles.loadArticles()).single.id, 'restored-script');
  });

  test('queued article edits cannot overwrite a successful restore snapshot', () async {
    final firstGate = Completer<void>();
    final started = Completer<void>();
    preferences.nextSingleGate = firstGate;
    preferences.singleStarted = started;
    final first = articles.createArticle(title: '恢复前排队稿', content: '旧队列');
    await started.future;
    final restore = backup.restoreBackup(_backup());
    final after = articles.createArticle(title: '恢复后排队稿', content: '新队列');
    await Future<void>.delayed(Duration.zero);
    expect(preferences.batchWrites, 0);
    firstGate.complete();
    await first;
    await restore;
    await after;
    expect(
      (await articles.loadArticles()).map((item) => item.title),
      unorderedEquals(['恢复稿', '恢复后排队稿']),
    );
  });

  test('settings saves and readers wait for the atomic backup commit', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    preferences.nextBatchGate = gate;
    preferences.batchStarted = started;
    final restore = backup.restoreBackup(_backup());
    await started.future;
    final later = settings.saveSettings(const AppSettings(fontSize: 96));
    var readCompleted = false;
    final read = articles.loadArticles().then((value) {
      readCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(preferences.singleWrites, 0);
    expect(readCompleted, isFalse);
    expect(jsonDecode(preferences.data[StorageConstants.articlesKey]!).single['title'], '原稿');
    gate.complete();
    await restore;
    await later;
    expect((await read).single.id, 'restored-script');
    expect((await settings.loadSettings()).fontSize, 96);
  });

  test('different stores are rejected before either store is changed', () async {
    final separate = _BatchPreferences();
    final differentSettings = SettingsService(preferences: separate);
    await differentSettings.init();
    final before = Map<String, String>.from(preferences.data);
    await expectLater(
      BackupService(articles, differentSettings).restoreBackup(_backup()),
      throwsStateError,
    );
    expect(preferences.data, before);
    expect(separate.data, isEmpty);
    expect(preferences.batchWrites, 0);
    expect(separate.batchWrites, 0);
  });

  test('export waits for an in-flight restore and returns one consistent backup', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    preferences.nextBatchGate = gate;
    preferences.batchStarted = started;
    final restore = backup.restoreBackup(_backup());
    await started.future;
    var exported = false;
    final exporting = backup.exportBackup().then((value) {
      exported = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(exported, isFalse);
    gate.complete();
    await restore;
    final result = await exporting;
    expect(result.articles.single.folderId, result.folders.single.id);
    expect(result.articles.single.id, 'restored-script');
    expect(result.settings.annotationColor, 0xFFFFCC66);
  });
}
