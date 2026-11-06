import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';

import 'support/reading_emphasis_test_backend.dart';

Future<void> flushMessages() => Future<void>.delayed(Duration.zero);

void main() {
  late ReadingEmphasisTestBackend backend;
  late SettingsProvider provider;
  const original = AppSettings(fontSize: 82, asrModelId: 'old-model');

  setUp(() async {
    backend = ReadingEmphasisTestBackend(settings: original);
    await backend.init();
    provider = SettingsProvider()..bindConnection(backend.connection);
    await provider.loadSettings();
  });

  tearDown(() {
    provider.dispose();
    backend.dispose();
  });

  Future<void> failReset() async {
    backend.preferences.failWrites = true;
    await expectLater(provider.resetAllSettings(), throwsStateError);
    backend.preferences.failWrites = false;
  }

  Future<void> expectSaved(AppSettings expected) async {
    expect(provider.settings.toJson(), expected.toJson());
    expect((await backend.service.loadSettings()).toJson(), expected.toJson());
    final reopened = SettingsProvider()..bindConnection(backend.connection);
    await reopened.loadSettings();
    expect(reopened.settings.toJson(), expected.toJson());
    reopened.dispose();
  }

  test(
    'ordinary edits after a queued reset survive in operation order',
    () async {
      backend.server.holdPatchResponses = true;
      final reading = provider.setCurrentCharScale(1.15);
      await flushMessages();
      final reset = provider.resetAllSettings();
      final font = provider.setFontSize(97);
      final theme = provider.setAppBrightnessMode(AppBrightnessMode.light);
      final model = provider.setAsrModel('new-chinese-model', '中文模型');
      await flushMessages();
      expect(provider.settings.fontSize, 97);
      backend.server.releasePatchResponses();
      await Future.wait([reading, reset, font, theme, model]);
      await expectSaved(
        const AppSettings().copyWith(
          fontSize: 97,
          appBrightnessMode: AppBrightnessMode.light,
          asrModelId: 'new-chinese-model',
          asrModelName: '中文模型',
        ),
      );
    },
  );

  test(
    'retry preserves ordinary and reading edits made after failed reset',
    () async {
      await failReset();
      await provider.setFontSize(99);
      await provider.setAppBrightnessMode(AppBrightnessMode.light);
      await provider.setAsrModel('new-chinese-model', '中文模型');
      await provider.setCurrentCharScale(1.13);
      await provider.retryReadingEmphasisSave();
      await expectSaved(
        const AppSettings().copyWith(
          fontSize: 99,
          appBrightnessMode: AppBrightnessMode.light,
          asrModelId: 'new-chinese-model',
          asrModelName: '中文模型',
          currentCharScale: 1.13,
        ),
      );
      expect(provider.readingEmphasisSaveError, isNull);
    },
  );

  test(
    'loading after failed reset preserves its complete unsaved intent',
    () async {
      await failReset();
      await provider.loadSettings();
      expect(provider.settings.toJson(), const AppSettings().toJson());
      expect((await backend.service.loadSettings()).fontSize, 82);
      await provider.retryReadingEmphasisSave();
      await expectSaved(const AppSettings());
    },
  );

  test(
    'edits while reset retry awaits acknowledgement remain newest',
    () async {
      await failReset();
      await provider.setFontSize(91);
      await provider.setAsrModel('first-model', '第一次选择');
      await provider.setCurrentCharScale(1.13);
      backend.server.heldResponseTypes.add(WsMessageType.settingsResetResponse);
      final retry = provider.retryReadingEmphasisSave();
      await flushMessages();
      final font = provider.setFontSize(101);
      final model = provider.setAsrModel('latest-model', '最后选择');
      final reading = provider.setCurrentCharScale(1.14);
      backend.server.releaseResponses(WsMessageType.settingsResetResponse);
      await Future.wait([retry, font, model, reading]);
      await expectSaved(
        const AppSettings().copyWith(
          fontSize: 101,
          asrModelId: 'latest-model',
          asrModelName: '最后选择',
          currentCharScale: 1.14,
        ),
      );
    },
  );

  test(
    'failure restoring ordinary fields stays retryable without losing preview',
    () async {
      await failReset();
      await provider.setFontSize(99);
      await provider.setAppBrightnessMode(AppBrightnessMode.light);
      backend.server.heldResponseTypes.add(WsMessageType.settingsResetResponse);
      final retry = provider.retryReadingEmphasisSave();
      final failed = expectLater(retry, throwsStateError);
      await flushMessages();
      backend.preferences.failWrites = true;
      backend.server.releaseResponses(WsMessageType.settingsResetResponse);
      await failed;
      expect(provider.settings.fontSize, 99);
      expect(provider.settings.appBrightnessMode, AppBrightnessMode.light);
      expect(provider.readingEmphasisSaveError, isNotNull);
      backend.preferences.failWrites = false;
      await provider.loadSettings();
      expect(provider.settings.fontSize, 99);
      await provider.retryReadingEmphasisSave();
      await expectSaved(
        const AppSettings().copyWith(
          fontSize: 99,
          appBrightnessMode: AppBrightnessMode.light,
        ),
      );
      expect(provider.readingEmphasisSaveError, isNull);
    },
  );

  test(
    'a delayed load started during reset cannot restore pre-reset values',
    () async {
      backend.server.holdPatchResponses = true;
      final reading = provider.setCurrentCharScale(1.15);
      await flushMessages();
      final reset = provider.resetAllSettings();
      backend.server.heldResponseTypes.add(WsMessageType.settingsGetResponse);
      final loading = provider.loadSettings();
      await flushMessages();
      backend.server.releasePatchResponses();
      await Future.wait([reading, reset]);
      backend.server.releaseResponses(WsMessageType.settingsGetResponse);
      await loading;
      await expectSaved(const AppSettings());
    },
  );

  test(
    'a delayed load cannot overwrite ordinary edits made after it started',
    () async {
      backend.server.heldResponseTypes.add(WsMessageType.settingsGetResponse);
      final loading = provider.loadSettings();
      await flushMessages();
      await provider.setFontSize(101);
      backend.server.releaseResponses(WsMessageType.settingsGetResponse);
      await loading;
      await expectSaved(original.copyWith(fontSize: 101));
    },
  );

  test(
    'loading cannot replace ordinary edits already waiting in the write queue',
    () async {
      backend.server.holdPatchResponses = true;
      final reading = provider.setCurrentCharScale(1.15);
      await flushMessages();
      final font = provider.setFontSize(101);
      await provider.loadSettings();
      expect(provider.settings.fontSize, 101);
      backend.server.releasePatchResponses();
      await Future.wait([reading, font]);
      await provider.setAppBrightnessMode(AppBrightnessMode.light);
      await expectSaved(
        original.copyWith(
          fontSize: 101,
          currentCharScale: 1.15,
          appBrightnessMode: AppBrightnessMode.light,
        ),
      );
    },
  );

  test(
    'a load begun with pending writes stays stale after those writes finish',
    () async {
      backend.server.holdPatchResponses = true;
      final reading = provider.setCurrentCharScale(1.15);
      await flushMessages();
      final font = provider.setFontSize(101);
      backend.server.heldResponseTypes.add(WsMessageType.settingsGetResponse);
      final loading = provider.loadSettings();
      await flushMessages();
      backend.server.releasePatchResponses();
      await Future.wait([reading, font]);
      backend.server.releaseResponses(WsMessageType.settingsGetResponse);
      await loading;
      await expectSaved(
        original.copyWith(fontSize: 101, currentCharScale: 1.15),
      );
    },
  );

  test(
    'a later failed retry stays recoverable after an earlier retry succeeds',
    () async {
      await failReset();
      await provider.setFontSize(99);
      backend.server.heldResponseTypes.add(WsMessageType.settingsResetResponse);
      final first = expectLater(
        provider.retryReadingEmphasisSave(),
        throwsStateError,
      );
      await flushMessages();
      final second = expectLater(
        provider.retryReadingEmphasisSave(),
        throwsStateError,
      );
      backend.server.releaseResponses(WsMessageType.settingsResetResponse);
      backend.server.heldResponseTypes.add(WsMessageType.settingsResetResponse);
      await flushMessages();
      backend.preferences.failWrites = true;
      backend.server.releaseResponses(WsMessageType.settingsResetResponse);
      await Future.wait([first, second]);
      backend.preferences.failWrites = false;
      await provider.retryReadingEmphasisSave();
      await expectSaved(const AppSettings().copyWith(fontSize: 99));
      expect(provider.readingEmphasisSaveError, isNull);
    },
  );
}
