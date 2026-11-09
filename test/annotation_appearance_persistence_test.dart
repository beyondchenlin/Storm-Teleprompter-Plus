import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_backup.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/providers/article_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';

import 'support/reading_emphasis_test_backend.dart';

const _custom = AppSettings(
  fontSize: 76,
  annotationFontFamily: '微软雅黑',
  annotationFontSize: 20,
  annotationColor: 0xFFFFAA66,
  asrModelId: 'installed-model',
);
const _notes = [
  ReadingAnnotation(
    id: 'cue',
    text: '语气自然\n放慢语速',
    ranges: [AnnotationRange(start: 0, end: 2, quote: '学习')],
  ),
];

class _ArticlePreferences implements AppPreferences {
  final values = <String, String>{};
  int writes = 0;
  bool fail = false;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    if (fail) return false;
    values[key] = value;
    writes++;
    return true;
  }

  @override
  Future<bool> setStrings(Map<String, String> entries) async {
    if (fail) return false;
    values.addAll(entries);
    writes++;
    return true;
  }
}

void main() {
  group('批注外观设置模型', () {
    test('缺少批注外观字段时使用当前默认值，显式旧颜色保持原值', () {
      final settings = AppSettings.fromJson({
        'fontSize': 76,
        'asrModelId': 'installed-model',
      });
      expect(
        settings.toAnnotationAppearanceMap(),
        const AppSettings().toAnnotationAppearanceMap(),
      );
      expect(settings.annotationFontFamily, '');
      expect(settings.annotationFontSize, 0);
      expect(settings.annotationColor, 0xFF8FA9B8);
      expect(settings.fontSize, 76);
      expect(settings.asrModelId, 'installed-model');
      expect(
        AppSettings.fromJson({'annotationColor': 0xFF8BD1D0}).annotationColor,
        0xFF8BD1D0,
      );
    });

    test('默认、稿件、会话与备份均保留三项外观', () {
      final json =
          jsonDecode(jsonEncode(_custom.toJson())) as Map<String, dynamic>;
      expect(AppSettings.fromJson(json).toJson(), _custom.toJson());
      final expected = _custom.toAnnotationAppearanceMap();
      for (final map in [_custom.toTeleprompterMap(), _custom.toSessionMap()]) {
        expect(
          const AppSettings().mergeOverrides(map).toAnnotationAppearanceMap(),
          expected,
        );
      }
      final article = Article(
        id: 'one',
        title: '测试',
        content: '<p>学习方法。</p>',
        annotations: _notes,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        teleprompterSettings: _custom.toTeleprompterMap(),
      );
      final backup = AppBackup(
        createdAt: DateTime(2026),
        articles: [article],
        folders: const [],
        settings: _custom,
      );
      final restored = AppBackup.fromJson(
        jsonDecode(jsonEncode(backup.toJson())) as Map<String, dynamic>,
      );
      expect(restored.settings.toAnnotationAppearanceMap(), expected);
      expect(
        const AppSettings()
            .mergeOverrides(restored.articles.single.teleprompterSettings!)
            .toAnnotationAppearanceMap(),
        expected,
      );
      expect(
        restored.articles.single.annotations.single.text,
        _notes.single.text,
      );
    });

    test('损坏字段独立回退，字号有界且颜色保持可见', () {
      for (final invalid in [
        null,
        '20',
        <String>[],
        double.nan,
        double.infinity,
        -4,
      ]) {
        final settings = AppSettings.fromJson({
          'annotationFontFamily': 18,
          'annotationFontSize': invalid,
          'annotationColor': 'red',
          'showAnnotations': 'true',
          'fontSize': 76,
          'asrModelId': 'installed-model',
        });
        expect(
          settings.toAnnotationAppearanceMap(),
          const AppSettings().toAnnotationAppearanceMap(),
        );
        expect(settings.showAnnotations, isTrue);
        expect(settings.fontSize, 76);
        expect(settings.asrModelId, 'installed-model');
      }
      expect(
        AppSettings.fromJson({'annotationFontSize': 1}).annotationFontSize,
        8,
      );
      expect(
        AppSettings.fromJson({'annotationFontSize': 200}).annotationFontSize,
        36,
      );
      expect(
        AppSettings.fromJson({'annotationColor': 0x00112233}).annotationColor,
        0xFF112233,
      );
      expect(
        AppSettings.fromJson({'annotationColor': 0x44112233}).annotationColor,
        0xFF112233,
      );
      expect(
        AppSettings.fromJson({'annotationColor': -1}).annotationColor,
        AppSettings.defaultAnnotationColor,
      );
      expect(
        AppSettings.fromJson({'annotationColor': 0x100000000}).annotationColor,
        AppSettings.defaultAnnotationColor,
      );
      expect(
        AppSettings.fromJson({
          'annotationFontFamily': ' 微软雅黑 ',
        }).annotationFontFamily,
        '微软雅黑',
      );
      expect(
        AppSettings.fromJson({
          'annotationFontFamily': 'A\u0000B',
        }).annotationFontFamily,
        '',
      );
      expect(
        AppSettings.fromJson({
          'annotationFontFamily': 'A' * 201,
        }).annotationFontFamily,
        '',
      );
    });

    test('坏稿件覆盖不会抹掉有效的默认外观', () {
      final recovered = _custom.mergeOverrides({
        'annotationFontFamily': false,
        'annotationFontSize': double.nan,
        'annotationColor': <String>[],
        'showAnnotations': 5,
      });
      expect(
        recovered.toAnnotationAppearanceMap(),
        _custom.toAnnotationAppearanceMap(),
      );
      expect(recovered.showAnnotations, isTrue);
      final automatic = recovered.copyWith(
        annotationFontFamily: '',
        annotationFontSize: 0,
      );
      expect(automatic.annotationFontFamily, '');
      expect(automatic.annotationFontSize, 0);
      expect(
        recovered.copyWith(annotationFontSize: 100).annotationFontSize,
        36,
      );
    });
  });

  group('批注外观默认值与会话保存', () {
    late ReadingEmphasisTestBackend backend;
    late SettingsProvider provider;

    setUp(() async {
      backend = ReadingEmphasisTestBackend(settings: _custom);
      await backend.init();
      provider = SettingsProvider()..bindConnection(backend.connection);
      await provider.loadSettings();
    });

    tearDown(() {
      provider.dispose();
      backend.dispose();
    });

    test('修改立即预览，依次落盘，重新初始化后仍保留', () async {
      final writes = [
        provider.setAnnotationFontFamily('宋体'),
        provider.setAnnotationFontSize(24),
        provider.setAnnotationColor(0x00AABBCC),
      ];
      expect(provider.settings.annotationFontFamily, '宋体');
      expect(provider.settings.annotationFontSize, 24);
      expect(provider.settings.annotationColor, 0xFFAABBCC);
      await Future.wait(writes);
      final restarted = SettingsService(preferences: backend.preferences);
      await restarted.init();
      final loaded = await restarted.loadSettings();
      expect(
        loaded.toAnnotationAppearanceMap(),
        provider.settings.toAnnotationAppearanceMap(),
      );
      expect(loaded.fontSize, 76);
      expect(loaded.asrModelId, 'installed-model');
      expect(backend.preferences.maxActiveWrites, 1);
    });

    test('默认外观写盘失败抛错并保留选择，重载后可原样重试', () async {
      backend.preferences.returnFalse = true;
      await expectLater(
        provider.setDefaultAnnotationAppearance(
          fontFamily: '宋体',
          fontSize: 24,
          color: 0xFF88AAFF,
        ),
        throwsStateError,
      );
      expect(provider.settings.annotationFontFamily, '宋体');
      expect(provider.settings.annotationFontSize, 24);
      expect(provider.settings.annotationColor, 0xFF88AAFF);
      expect(
        (await backend.service.loadSettings()).toAnnotationAppearanceMap(),
        _custom.toAnnotationAppearanceMap(),
      );
      await provider.loadSettings();
      expect(provider.settings.annotationFontFamily, '宋体');
      expect(provider.settings.annotationFontSize, 24);
      expect(provider.settings.annotationColor, 0xFF88AAFF);
      backend.preferences.returnFalse = false;
      await provider.setDefaultAnnotationAppearance(
        fontFamily: provider.settings.annotationFontFamily,
        fontSize: provider.settings.annotationFontSize,
        color: provider.settings.annotationColor,
      );
      expect(
        (await backend.service.loadSettings()).toAnnotationAppearanceMap(),
        provider.settings.toAnnotationAppearanceMap(),
      );
      // 成功确认清理了旧意图，之后读取服务端的新值不再被旧选择覆盖。
      await backend.service.saveSettings(
        _custom.copyWith(annotationFontSize: 12),
      );
      await provider.loadSettings();
      expect(provider.settings.annotationFontSize, 12);
    });

    test('断线应用默认外观明确失败，重连保留选择同时读回其它新设置', () async {
      backend.connection.disconnectForRetry();
      await expectLater(
        provider.setDefaultAnnotationAppearance(color: 0xFF88AAFF),
        throwsStateError,
      );
      expect(provider.settings.annotationColor, 0xFF88AAFF);
      await backend.service.saveSettings(_custom.copyWith(fontSize: 94));
      backend.connection.reconnectTo(backend.server);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await provider.loadSettings();
      expect(provider.settings.annotationColor, 0xFF88AAFF);
      expect(provider.settings.fontSize, 94);
      expect(
        (await backend.service.loadSettings()).annotationColor,
        _custom.annotationColor,
      );
      await provider.setDefaultAnnotationAppearance(
        color: provider.settings.annotationColor,
      );
      expect(
        (await backend.service.loadSettings()).annotationColor,
        0xFF88AAFF,
      );
    });

    test('较旧保存的迟到确认不会清理较新但失败的外观选择', () async {
      backend.server.heldResponseTypes.add(WsMessageType.settingsSaveResponse);
      final first = provider.setDefaultAnnotationAppearance(fontSize: 16);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      backend.preferences.returnFalse = true;
      final second = provider.setDefaultAnnotationAppearance(color: 0xFF88AAFF);
      final failed = expectLater(second, throwsStateError);
      backend.server.releaseResponses(WsMessageType.settingsSaveResponse);
      await first;
      await failed;
      expect((await backend.service.loadSettings()).annotationFontSize, 16);
      expect(
        (await backend.service.loadSettings()).annotationColor,
        _custom.annotationColor,
      );
      await provider.loadSettings();
      expect(provider.settings.annotationFontSize, 16);
      expect(provider.settings.annotationColor, 0xFF88AAFF);
    });

    test('明确恢复全部默认值后不复活此前失败的批注选择', () async {
      backend.preferences.returnFalse = true;
      await expectLater(
        provider.setDefaultAnnotationAppearance(color: 0xFF88AAFF),
        throwsStateError,
      );
      backend.preferences.returnFalse = false;
      await provider.resetAllSettings();
      await provider.loadSettings();
      expect(
        provider.settings.toAnnotationAppearanceMap(),
        const AppSettings().toAnnotationAppearanceMap(),
      );
    });

    test('本稿件外观与默认值隔离，恢复默认一次同步三项', () async {
      provider.loadArticleOverrides({'fontSize': 90});
      await provider.setAnnotationAppearance(
        fontFamily: '宋体',
        fontSize: 16,
        color: 0xFF88AAFF,
      );
      expect(provider.mergedSettings.annotationFontFamily, '宋体');
      expect(provider.mergedSettings.annotationFontSize, 16);
      expect(provider.mergedSettings.annotationColor, 0xFF88AAFF);
      expect(provider.settings.toJson(), _custom.toJson());
      expect(backend.preferences.writes, isEmpty);
      final snapshot = Map<String, dynamic>.from(provider.articleOverrides);
      final receiver = SettingsProvider();
      addTearDown(receiver.dispose);
      receiver.applyRemoteTeleprompterSettings(snapshot);
      expect(
        receiver.mergedSettings.toAnnotationAppearanceMap(),
        provider.mergedSettings.toAnnotationAppearanceMap(),
      );
      final sentBefore = backend.connection.sentMessages.length;
      await provider.resetAnnotationAppearance();
      expect(backend.connection.sentMessages.length, sentBefore + 1);
      expect(
        provider.mergedSettings.toAnnotationAppearanceMap(),
        const AppSettings().toAnnotationAppearanceMap(),
      );
      expect(provider.mergedSettings.fontSize, 90);
      expect(provider.settings.toJson(), _custom.toJson());
      provider.clearArticleOverrides();
      expect(
        provider.mergedSettings.toAnnotationAppearanceMap(),
        _custom.toAnnotationAppearanceMap(),
      );
      provider.loadArticleOverrides(snapshot);
      expect(provider.mergedSettings.annotationFontSize, 16);
    });

    test('播放中修改新稿默认外观不会覆盖正在播放的稿件', () async {
      provider.loadArticleOverrides({
        'fontSize': 90,
        'annotationFontFamily': '宋体',
        'annotationFontSize': 18,
        'annotationColor': 0xFF88AAFF,
      });
      final active = Map<String, dynamic>.from(provider.articleOverrides);
      await provider.setDefaultAnnotationAppearance(
        fontFamily: '等线',
        fontSize: 26,
        color: 0xFFEE77AA,
      );
      expect(provider.articleOverrides, active);
      expect(provider.mergedSettings.annotationFontFamily, '宋体');
      expect(provider.mergedSettings.annotationFontSize, 18);
      expect(provider.mergedSettings.annotationColor, 0xFF88AAFF);
      expect(provider.settings.annotationFontFamily, '等线');
      expect(provider.settings.annotationFontSize, 26);
      expect(provider.settings.annotationColor, 0xFFEE77AA);
      expect(
        (await backend.service.loadSettings()).toAnnotationAppearanceMap(),
        provider.settings.toAnnotationAppearanceMap(),
      );
      final sent = backend.connection.sentMessages.last.data['settings'] as Map;
      expect(sent['annotationFontFamily'], '宋体');
      expect(sent['annotationFontSize'], 18);
      expect(sent['annotationColor'], 0xFF88AAFF);
      provider.loadArticleOverrides(null);
      expect(provider.mergedSettings.annotationFontFamily, '等线');
      expect(provider.mergedSettings.annotationFontSize, 26);
      expect(provider.mergedSettings.annotationColor, 0xFFEE77AA);
    });

    test('恢复默认外观只产生一次全局写入，不改变正文和识别模型', () async {
      final writesBefore = backend.preferences.writes.length;
      await provider.resetAnnotationAppearance();
      expect(backend.preferences.writes.length, writesBefore + 1);
      final stored = await backend.service.loadSettings();
      expect(
        stored.toAnnotationAppearanceMap(),
        const AppSettings().toAnnotationAppearanceMap(),
      );
      expect(stored.fontSize, 76);
      expect(stored.asrModelId, 'installed-model');
    });

    test('远端运行时刷新三项外观，保留该端正文排版并清理坏值', () {
      provider.applyRemoteTeleprompterSettings({
        'fontSize': 90,
        'annotationFontSize': 16,
      });
      provider.applyRemoteSyncedRuntimeSettings({
        'fontSize': 50,
        'annotationFontFamily': '宋体',
        'annotationFontSize': 22,
        'annotationColor': 0x0088AAFF,
        'showAnnotations': false,
      });
      expect(provider.mergedSettings.fontSize, 90);
      expect(provider.mergedSettings.annotationFontFamily, '宋体');
      expect(provider.mergedSettings.annotationFontSize, 22);
      expect(provider.mergedSettings.annotationColor, 0xFF88AAFF);
      expect(provider.mergedSettings.showAnnotations, isFalse);
      final before = provider.mergedSettings.toAnnotationAppearanceMap();
      provider.applyRemoteSyncedRuntimeSettings({
        'annotationFontFamily': 4,
        'annotationFontSize': double.nan,
        'annotationColor': -5,
      });
      expect(provider.mergedSettings.toAnnotationAppearanceMap(), before);
      provider.applyRemoteSyncedRuntimeSettings({
        'annotationFontSize': 0,
        'annotationFontFamily': '',
      });
      expect(provider.mergedSettings.annotationFontSize, 0);
      expect(provider.mergedSettings.annotationFontFamily, '');
      expect(provider.mergedSettings.annotationColor, 0xFF88AAFF);
    });
  });

  group('稿件外观与批注的原子持久化', () {
    late ReadingEmphasisTestBackend backend;
    late ArticleService service;
    late _ArticlePreferences preferences;
    late ArticleProvider articles;

    setUp(() async {
      backend = ReadingEmphasisTestBackend();
      await backend.init();
      preferences = _ArticlePreferences();
      service = ArticleService(preferences: preferences);
      await service.init();
      service.registerHandlers(backend.server);
      articles = ArticleProvider()..bindConnection(backend.connection);
    });

    tearDown(() {
      articles.dispose();
      backend.dispose();
    });

    test('创建和编辑通过真实协议一次保存正文、备注及外观', () async {
      final created = await articles.createArticle(
        title: '示例',
        content: '<p>学习方法。</p>',
        annotations: _notes,
        teleprompterSettings: _custom.toTeleprompterMap(),
      );
      expect(created, isNotNull);
      expect(preferences.writes, 1);
      expect(created!.teleprompterSettings, _custom.toTeleprompterMap());
      final changed = _custom
          .copyWith(annotationFontSize: 18)
          .toTeleprompterMap();
      final updated = await articles.updateArticle(
        created.id,
        title: '新标题',
        annotations: [_notes.single.copyWith(text: '慢一点')],
        teleprompterSettings: changed,
      );
      expect(preferences.writes, 2);
      expect(updated!.teleprompterSettings, changed);
      final restarted = ArticleService(preferences: preferences);
      await restarted.init();
      final loaded = (await restarted.loadArticles()).single;
      expect(loaded.title, '新标题');
      expect(loaded.annotations.single.text, '慢一点');
      expect(loaded.annotations.single.ranges.single.quote, '学习');
      expect(loaded.teleprompterSettings, changed);
    });

    test('稿件导出再导入保留外观与字词批注，并为副本创建新编号', () async {
      final source = await service.createArticle(
        title: '导入验证',
        content: '<p>学习方法。</p>',
        annotations: _notes,
        teleprompterSettings: _custom.toTeleprompterMap(),
      );
      final exported = await backend.server.request(
        WsMessageType.articleExport,
        data: {'id': source.id},
      );
      expect(exported.type, WsMessageType.articleExportResponse);
      final imported = await backend.server.request(
        WsMessageType.articleImport,
        data: {'article': exported.data['article']},
      );
      expect(imported.type, WsMessageType.articleImportResponse);
      final copied = Article.fromJson(
        imported.data['article'] as Map<String, dynamic>,
      );
      expect(copied.id, isNot(source.id));
      expect(copied.content, source.content);
      expect(copied.teleprompterSettings, source.teleprompterSettings);
      expect(
        copied.annotations.single.toJson(),
        source.annotations.single.toJson(),
      );
    });

    test('创建与更新落盘失败立即返回错误，并保留已有稿件完整快照', () async {
      final source = await service.createArticle(
        title: '已有稿',
        content: '<p>学习方法。</p>',
        annotations: _notes,
        teleprompterSettings: _custom.toTeleprompterMap(),
      );
      final before = source.toJson();
      preferences.fail = true;
      final create = await backend.server
          .request(
            WsMessageType.articleCreate,
            data: {
              'title': '不能保存的新稿',
              'content': '<p>新稿。</p>',
              'teleprompterSettings': _custom.toTeleprompterMap(),
            },
          )
          .timeout(const Duration(seconds: 1));
      expect(create.type, WsMessageType.error);
      expect(create.data['message'], contains('创建稿件失败'));
      final updated = await articles
          .updateArticle(
            source.id,
            title: '不能保存的标题',
            content: '<p>新稿。</p>',
            annotations: const [],
            teleprompterSettings: const AppSettings().toTeleprompterMap(),
          )
          .timeout(const Duration(seconds: 1));
      expect(updated, isNull);
      expect(articles.error, contains('更新稿件失败'));
      expect((await service.loadArticles()).single.toJson(), before);
      preferences.fail = false;
      final recovered = await articles.updateArticle(source.id, title: '保存恢复');
      expect(recovered!.title, '保存恢复');
      expect(recovered.teleprompterSettings, source.teleprompterSettings);
      expect(articles.error, isNull);
    });
  });
}
