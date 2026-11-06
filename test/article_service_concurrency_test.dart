import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/folder.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

/// 模拟桌面存储：保存成功前，读取只能看到最后成功提交的字符串。
class _DelayedPreferences implements AppPreferences {
  final values = <String, String>{};
  final writes = <String>[];
  final _barriers = <_WriteBarrier>[];
  _WriteBarrier? _nextBarrier;
  int activeWrites = 0;
  int maxActiveWrites = 0;

  _WriteBarrier blockNextWrite({bool fail = false, bool returnFalse = false}) {
    final barrier = _WriteBarrier(fail: fail, returnFalse: returnFalse);
    _barriers.add(barrier);
    _nextBarrier = barrier;
    return barrier;
  }

  void releaseAll() {
    for (final barrier in _barriers) {
      if (!barrier.release.isCompleted) barrier.release.complete();
    }
  }

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    final barrier = _nextBarrier;
    _nextBarrier = null;
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      if (barrier != null) {
        barrier.started.complete();
        await barrier.release.future;
        if (barrier.fail) throw StateError('测试磁盘写入失败');
        if (barrier.returnFalse) return false;
      }
      values[key] = value;
      writes.add(key);
      return true;
    } finally {
      activeWrites--;
    }
  }
}

class _WriteBarrier {
  _WriteBarrier({required this.fail, required this.returnFalse});

  final bool fail;
  final bool returnFalse;
  final started = Completer<void>();
  final release = Completer<void>();
}

Future<void> _flushMessages() => Future<void>.delayed(Duration.zero);

void main() {
  late _DelayedPreferences preferences;
  late ArticleService service;

  setUp(() async {
    preferences = _DelayedPreferences();
    service = ArticleService(preferences: preferences);
    await service.init();
  });

  tearDown(() => preferences.releaseAll());

  test(
    'concurrent creates retain both articles while the first write is blocked',
    () async {
      final barrier = preferences.blockNextWrite();
      final first = service.createArticle(title: '甲稿件', content: '甲正文');
      await barrier.started.future;
      final second = service.createArticle(title: '乙稿件', content: '乙正文');
      var readFinished = false;
      final reading = service.loadArticles().then((value) {
        readFinished = true;
        return value;
      });
      await _flushMessages();

      expect(preferences.getString(StorageConstants.articlesKey), isNull);
      expect(preferences.activeWrites, 1);
      expect(readFinished, isFalse);
      barrier.release.complete();
      final created = await Future.wait([first, second]);
      final stored = await reading;
      expect(
        stored.map((article) => article.id),
        unorderedEquals(created.map((article) => article.id)),
      );
      expect(
        stored.map((article) => article.title),
        unorderedEquals(['甲稿件', '乙稿件']),
      );
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'concurrent partial updates to one article retain all changed fields',
    () async {
      final original = await service.createArticle(title: '原题', content: '原文');
      final barrier = preferences.blockNextWrite();
      final content = service.updateArticle(original.id, content: '新正文');
      await barrier.started.future;
      final title = service.updateArticle(original.id, title: '新标题');
      final formatting = service.updateArticle(
        original.id,
        teleprompterSettings: {'fontSize': 90, 'mirrorMode': true},
      );
      barrier.release.complete();
      await Future.wait([content, title, formatting]);

      final saved = (await service.loadArticles()).single;
      expect(saved.id, original.id);
      expect(saved.title, '新标题');
      expect(saved.content, '新正文');
      expect(saved.teleprompterSettings, {'fontSize': 90, 'mirrorMode': true});
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'concurrent folder creates retain both folders and reads wait for commit',
    () async {
      final barrier = preferences.blockNextWrite();
      final first = service.createFolder(name: '甲目录');
      await barrier.started.future;
      final second = service.createFolder(name: '乙目录');
      var readFinished = false;
      final reading = service.loadFolders().then((value) {
        readFinished = true;
        return value;
      });
      await _flushMessages();
      expect(readFinished, isFalse);
      expect(preferences.activeWrites, 1);
      barrier.release.complete();
      await Future.wait([first, second]);

      expect(
        (await reading).map((folder) => folder.name),
        unorderedEquals(['甲目录', '乙目录']),
      );
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test('folder rename and move merge in submission order', () async {
    final parent = await service.createFolder(name: '上级');
    final child = await service.createFolder(name: '原名');
    final barrier = preferences.blockNextWrite();
    final rename = service.renameFolder(child.id, '新名');
    await barrier.started.future;
    final move = service.moveFolder(child.id, parent.id);
    barrier.release.complete();
    await Future.wait([rename, move]);

    final saved = (await service.loadFolders()).singleWhere(
      (folder) => folder.id == child.id,
    );
    expect(saved.name, '新名');
    expect(saved.parentId, parent.id);
    expect(preferences.maxActiveWrites, 1);
  });

  test(
    'folder deletion and article updates share a queue across both tables',
    () async {
      final folder = await service.createFolder(name: '待删除');
      final child = await service.createFolder(
        name: '子目录',
        parentId: folder.id,
      );
      final article = await service.createArticle(
        title: '稿件',
        content: '原文',
        folderId: folder.id,
      );
      final barrier = preferences.blockNextWrite();
      final deletion = service.deleteFolder(folder.id);
      await barrier.started.future;
      final update = service.updateArticle(article.id, content: '删除期间编辑的正文');
      barrier.release.complete();
      expect(await deletion, isTrue);
      await update;

      final folders = await service.loadFolders();
      expect(folders.single.id, child.id);
      expect(folders.single.parentId, isNull);
      final saved = (await service.loadArticles()).single;
      expect(saved.folderId, isNull);
      expect(saved.content, '删除期间编辑的正文');
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'recursive copy finishes before a later article deletion can change its snapshot',
    () async {
      final folder = await service.createFolder(name: '原目录');
      final article = await service.createArticle(
        title: '原稿',
        content: '正文',
        folderId: folder.id,
      );
      final barrier = preferences.blockNextWrite();
      final copying = service.copyFolder(folder.id, null);
      await barrier.started.future;
      final deletion = service.deleteArticle(article.id);
      barrier.release.complete();
      final copied = (await copying)!;
      expect(await deletion, isTrue);

      final saved = (await service.loadArticles()).single;
      expect(saved.id, copied.articles.single.id);
      expect(saved.folderId, copied.folders.single.id);
      expect(saved.content, '正文');
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'explicit replacement is queued before subsequent creates in both tables',
    () async {
      await service.createArticle(title: '旧稿', content: '旧文');
      final now = DateTime(2026, 1, 1);
      final restoredArticle = Article(
        id: 'restored-article',
        title: '恢复稿',
        content: '恢复正文',
        createdAt: now,
        updatedAt: now,
      );
      final restoredFolder = Folder(
        id: 'restored-folder',
        name: '恢复目录',
        createdAt: now,
      );
      final barrier = preferences.blockNextWrite();
      final replaceArticles = service.replaceArticles([restoredArticle]);
      await barrier.started.future;
      final createArticle = service.createArticle(
        title: '随后新增',
        content: '新正文',
      );
      final replaceFolders = service.replaceFolders([restoredFolder]);
      final createFolder = service.createFolder(name: '随后新增目录');
      barrier.release.complete();
      await replaceArticles;
      await createArticle;
      await replaceFolders;
      await createFolder;

      expect(
        (await service.loadArticles()).map((article) => article.title),
        unorderedEquals(['恢复稿', '随后新增']),
      );
      expect(
        (await service.loadFolders()).map((folder) => folder.name),
        unorderedEquals(['恢复目录', '随后新增目录']),
      );
      final diskArticles =
          jsonDecode(preferences.values[StorageConstants.articlesKey]!) as List;
      expect(diskArticles, hasLength(2));
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'a failed write does not poison the queue or leak the rejected article',
    () async {
      final barrier = preferences.blockNextWrite(fail: true);
      final rejected = service.createArticle(title: '失败稿件', content: '未保存');
      final rejection = expectLater(rejected, throwsA(isA<StateError>()));
      await barrier.started.future;
      final succeeding = service.createArticle(title: '成功稿件', content: '已保存');
      barrier.release.complete();
      await rejection;
      await succeeding;
      await service.createFolder(name: '失败后目录');

      expect((await service.loadArticles()).single.title, '成功稿件');
      expect((await service.loadFolders()).single.name, '失败后目录');
      expect(preferences.maxActiveWrites, 1);
    },
  );

  test(
    'a storage false result is a failure and later folder writes still succeed',
    () async {
      final barrier = preferences.blockNextWrite(returnFalse: true);
      final rejected = service.createFolder(name: '失败目录');
      final rejection = expectLater(rejected, throwsA(isA<StateError>()));
      await barrier.started.future;
      final succeeding = service.createFolder(name: '成功目录');
      barrier.release.complete();
      await rejection;
      await succeeding;

      expect((await service.loadFolders()).single.name, '成功目录');
      expect(preferences.writes, [StorageConstants.foldersKey]);
      expect(preferences.maxActiveWrites, 1);
    },
  );
}
