import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';

import 'support/reading_emphasis_test_backend.dart';

Future<void> flushConnectionMessages() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('阅读设置断线重连', () {
    late ReadingEmphasisTestBackend backend;
    late SettingsProvider provider;
    const original = AppSettings(
      asrModelId: 'installed-chinese-model',
      fontSize: 82,
    );

    setUp(() async {
      backend = ReadingEmphasisTestBackend(settings: original);
      await backend.init();
      backend.connection.remote = true;
      provider = SettingsProvider()..bindConnection(backend.connection);
      // 仅初始化时加载；重连必须由真实连接通知自动恢复权威设置。
      await provider.loadSettings();
      provider.loadArticleOverrides({'fontSize': 91, 'grayReadChars': false});
    });

    tearDown(() {
      provider.dispose();
      backend.dispose();
    });

    test('旧连接里等待的普通保存不阻止新连接加载权威值', () async {
      backend.server.holdPatchResponses = true;
      final reading = provider.setCurrentCharScale(1.15);
      final readingFailed = expectLater(reading, throwsStateError);
      await flushConnectionMessages();
      provider.clearArticleOverrides();
      final font = provider.setFontSize(101);
      backend.connection.disconnectForRetry();
      await backend.service.saveSettings(original.copyWith(fontSize: 88));
      await flushConnectionMessages();
      backend.connection.reconnectTo(backend.server);
      await flushConnectionMessages();
      final previewAfterReconnect = provider.settings.fontSize;
      backend.server.releasePatchResponses();
      await Future.wait([readingFailed, font]);
      expect(previewAfterReconnect, 88);
      expect(provider.settings.fontSize, 88);
      expect((await backend.service.loadSettings()).fontSize, 88);
      expect(provider.settings.currentCharScale, 1.15);
    });

    test('自动加载断线期间修改的四项权威设置并保留稿件覆盖', () async {
      final articleBefore = Map<String, dynamic>.from(
        provider.articleOverrides,
      );
      final changedWhileDisconnected = original.copyWith(
        readingEmphasisEnabled: false,
        currentCharColor: 0xFF123456,
        readCharColor: 0xFF654321,
        currentCharScale: 1.04,
      );

      backend.connection.disconnectForRetry();
      await backend.service.saveSettings(changedWhileDisconnected);
      // 先排空断线期间的广播，避免把迟到广播误当作重连加载。
      await flushConnectionMessages();
      expect(
        provider.settings.toReadingEmphasisMap(),
        original.toReadingEmphasisMap(),
      );

      backend.connection.reconnectTo(backend.server);
      await flushConnectionMessages();

      expect(
        provider.settings.toReadingEmphasisMap(),
        changedWhileDisconnected.toReadingEmphasisMap(),
      );
      expect(
        provider.mergedSettings.toReadingEmphasisMap(),
        changedWhileDisconnected.toReadingEmphasisMap(),
      );
      expect(provider.articleOverrides, articleBefore);
      expect(provider.mergedSettings.fontSize, 91);
      expect(provider.mergedSettings.grayReadChars, isFalse);
    });

    test('恢复其他权威字段时保留保存失败的新预览与稿件覆盖', () async {
      final articleBefore = Map<String, dynamic>.from(
        provider.articleOverrides,
      );
      backend.preferences.failWrites = true;
      await expectLater(provider.setCurrentCharScale(1.15), throwsStateError);
      backend.preferences.failWrites = false;
      expect(provider.settings.currentCharScale, 1.15);
      expect(provider.readingEmphasisSaveError, isNotNull);

      backend.connection.disconnectForRetry();
      final changedWhileDisconnected = original.copyWith(
        readingEmphasisEnabled: false,
        currentCharColor: 0xFF007799,
        readCharColor: 0xFF445566,
        currentCharScale: 1.03,
      );
      await backend.service.saveSettings(changedWhileDisconnected);
      await flushConnectionMessages();

      backend.connection.reconnectTo(backend.server);
      await flushConnectionMessages();

      final expectedPreview = changedWhileDisconnected.copyWith(
        currentCharScale: 1.15,
      );
      expect(
        provider.settings.toReadingEmphasisMap(),
        expectedPreview.toReadingEmphasisMap(),
      );
      expect(
        provider.mergedSettings.toReadingEmphasisMap(),
        expectedPreview.toReadingEmphasisMap(),
      );
      expect(provider.articleOverrides, articleBefore);
      expect(provider.mergedSettings.fontSize, 91);
      expect(provider.mergedSettings.grayReadChars, isFalse);
    });
  });
}
