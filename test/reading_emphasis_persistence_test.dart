import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

import 'support/reading_emphasis_test_backend.dart';

Future<void> flushMessages() => Future<void>.delayed(Duration.zero);

void main() {
  group('reading emphasis settings model', () {
    test('old settings gain defaults without losing the selected model', () {
      final migrated = AppSettings.fromJson({
        'asrModelId': 'installed-chinese-model',
        'asrInputDeviceId': 'microphone-2',
        'fontSize': 82,
        'scrollMode': 'asr',
      });

      expect(migrated.toReadingEmphasisMap(), {
        'readingEmphasisEnabled': true,
        'currentCharColor': 0xFFFFD54F,
        'readCharColor': 0xFF999999,
        'currentCharScale': 1.10,
      });
      expect(migrated.asrModelId, 'installed-chinese-model');
      expect(migrated.asrInputDeviceId, 'microphone-2');
      expect(migrated.fontSize, 82);
      expect(migrated.scrollMode, ScrollMode.asr);
    });

    test(
      'invalid stored fields recover individually and keep other settings',
      () {
        final recovered = AppSettings.fromJson({
          'asrModelId': 'installed-model',
          'readingEmphasisEnabled': 'false',
          'currentCharColor': -1,
          'readCharColor': 0x100000000,
          'currentCharScale': double.nan,
        });
        expect(
          recovered.toReadingEmphasisMap(),
          const AppSettings().toReadingEmphasisMap(),
        );
        expect(recovered.asrModelId, 'installed-model');
        expect(
          AppSettings.fromJson({'currentCharScale': 9}).currentCharScale,
          1.15,
        );
        expect(
          AppSettings.fromJson({'currentCharScale': -2}).currentCharScale,
          1.0,
        );
        expect(
          AppSettings.fromJson({
            'currentCharScale': double.infinity,
          }).currentCharScale,
          1.10,
        );
      },
    );

    test(
      'article overrides cannot replace global emphasis, but session snapshots include it',
      () {
        final global = const AppSettings().copyWith(
          readingEmphasisEnabled: false,
          currentCharColor: 0xFF112233,
          readCharColor: 0xFF445566,
          currentCharScale: 1.13,
        );
        final merged = global.mergeOverrides({
          'fontSize': 92,
          'grayReadChars': false,
          'readingEmphasisEnabled': true,
          'currentCharColor': 'invalid',
          'readCharColor': -1,
          'currentCharScale': double.nan,
        });
        expect(merged.toReadingEmphasisMap(), global.toReadingEmphasisMap());
        expect(merged.fontSize, 92);
        expect(merged.grayReadChars, false);
        expect(
          merged.toTeleprompterMap().keys.toSet().intersection(
            AppSettings.readingEmphasisKeys,
          ),
          isEmpty,
        );
        for (final entry in global.toReadingEmphasisMap().entries) {
          expect(merged.toSessionMap()[entry.key], entry.value);
        }
        expect(
          AppSettings.fromJson(global.toJson()).toReadingEmphasisMap(),
          global.toReadingEmphasisMap(),
        );
      },
    );
  });

  group('reading emphasis persistence and live updates', () {
    late ReadingEmphasisTestBackend backend;
    late SettingsProvider provider;
    const original = AppSettings(
      asrModelId: 'installed-chinese-model',
      asrInputDeviceId: 'microphone-2',
      asrNumThreads: 2,
      fontSize: 82,
      scrollMode: ScrollMode.asr,
    );

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

    test(
      'preview updates immediately, persists globally, and preserves article formatting and ASR',
      () async {
        provider.loadArticleOverrides({'fontSize': 93, 'grayReadChars': false});
        final articleBefore = Map<String, dynamic>.from(
          provider.articleOverrides,
        );
        final gate = Completer<void>();
        backend.preferences.nextWriteGate = gate;

        final saving = provider.setCurrentCharScale(1.15);
        expect(provider.settings.currentCharScale, 1.15);
        expect(provider.mergedSettings.currentCharScale, 1.15);
        expect(provider.mergedSettings.fontSize, 93);
        expect(provider.isSavingReadingEmphasis, isTrue);
        expect(provider.articleOverrides, articleBefore);
        await flushMessages();
        expect(backend.preferences.activeWrites, 1);
        final before =
            jsonDecode(
                  backend.preferences.getString(StorageConstants.settingsKey)!,
                )
                as Map<String, dynamic>;
        expect(before['currentCharScale'], 1.10);

        gate.complete();
        await saving;
        final stored = await backend.service.loadSettings();
        expect(
          stored.toJson(),
          original.copyWith(currentCharScale: 1.15).toJson(),
        );
        expect(provider.isSavingReadingEmphasis, isFalse);
        expect(provider.readingEmphasisSaveError, isNull);
        expect(provider.articleOverrides, articleBefore);
        expect(
          backend.connection.sentMessages.every(
            (message) =>
                message.type == WsMessageType.teleprompterSettingsUpdate,
          ),
          isTrue,
        );
        expect(
          backend
              .connection
              .sentMessages
              .last
              .data['settings']['currentCharScale'],
          1.15,
        );
        expect(
          backend.server.requestsSent.any(
            (message) =>
                message.type == WsMessageType.asrStart ||
                message.type == WsMessageType.teleprompterStartSession,
          ),
          isFalse,
        );

        final reopened = SettingsProvider()..bindConnection(backend.connection);
        await reopened.loadSettings();
        expect(reopened.settings.currentCharScale, 1.15);
        reopened.dispose();
      },
    );

    test(
      'rapid edits remain at the newest preview while old acknowledgements arrive',
      () async {
        backend.server.holdPatchResponses = true;
        final pending = [
          provider.setCurrentCharScale(1.01),
          provider.setCurrentCharScale(1.12),
          provider.setCurrentCharColor(0xFF00CCEE),
          provider.setReadCharColor(0xFF777777),
          provider.setReadingEmphasisEnabled(false),
          provider.setCurrentCharScale(1.15),
        ];
        await flushMessages();
        expect(backend.preferences.writes.length, 1);
        expect(provider.settings.currentCharScale, 1.15);
        expect(provider.settings.currentCharColor, 0xFF00CCEE);
        expect(provider.settings.readingEmphasisEnabled, isFalse);

        backend.server.releasePatchResponses();
        await Future.wait(pending);
        final stored = await backend.service.loadSettings();
        expect(
          stored.toReadingEmphasisMap(),
          provider.settings.toReadingEmphasisMap(),
        );
        expect(stored.currentCharScale, 1.15);
        expect(stored.readCharColor, 0xFF777777);
        expect(stored.asrModelId, original.asrModelId);
        expect(backend.preferences.maxActiveWrites, 1);
        expect(provider.isSavingReadingEmphasis, isFalse);
      },
    );

    test(
      'stale legacy full saves cannot overwrite a concurrent emphasis patch',
      () async {
        final gate = Completer<void>();
        backend.preferences.nextWriteGate = gate;
        final changing = provider.setCurrentCharColor(0xFF00FF88);
        await flushMessages();
        final legacy = backend.server.request(
          WsMessageType.settingsSave,
          data: {'settings': original.copyWith(fontSize: 99).toJson()},
        );
        gate.complete();
        await changing;
        expect((await legacy).type, WsMessageType.settingsSaveResponse);
        var stored = await backend.service.loadSettings();
        expect(stored.currentCharColor, 0xFF00FF88);
        expect(stored.fontSize, 99);
        expect(stored.asrModelId, original.asrModelId);

        final oldVersion = original.toJson()
          ..removeWhere(
            (key, _) => AppSettings.readingEmphasisKeys.contains(key),
          );
        await backend.server.request(
          WsMessageType.settingsSave,
          data: {'settings': oldVersion},
        );
        stored = await backend.service.loadSettings();
        expect(stored.currentCharColor, 0xFF00FF88);
      },
    );

    test(
      'external patches update an active local page and stale broadcasts are ignored',
      () async {
        provider.loadArticleOverrides({'fontSize': 96});
        final result = await backend.server.request(
          WsMessageType.settingsReadingEmphasisPatch,
          data: {
            'patch': {'currentCharColor': 0xFF44CC88, 'currentCharScale': 1.14},
          },
        );
        expect(result.data['success'], isTrue);
        await flushMessages();
        expect(provider.mergedSettings.currentCharColor, 0xFF44CC88);
        expect(provider.mergedSettings.currentCharScale, 1.14);
        expect(provider.mergedSettings.fontSize, 96);
        expect(provider.settings.asrModelId, original.asrModelId);

        backend.server.broadcast(
          WsMessage(
            type: WsMessageType.settingsReadingEmphasisChanged,
            data: {'settings': original.toReadingEmphasisMap(), 'revision': 0},
          ),
        );
        await flushMessages();
        expect(provider.settings.currentCharScale, 1.14);
      },
    );

    test(
      'late local acknowledgement does not roll back a newer external change',
      () async {
        backend.server.holdPatchResponses = true;
        final local = provider.setCurrentCharColor(0xFFFF0000);
        await flushMessages();
        final external = backend.server.request(
          WsMessageType.settingsReadingEmphasisPatch,
          data: {
            'patch': {'currentCharColor': 0xFF00FF00},
          },
        );
        await flushMessages();
        expect(provider.settings.currentCharColor, 0xFFFF0000);
        backend.server.releasePatchResponses();
        await local;
        await external;
        expect(provider.settings.currentCharColor, 0xFF00FF00);
        expect(
          (await backend.service.loadSettings()).currentCharColor,
          0xFF00FF00,
        );
      },
    );

    test(
      'save failure keeps an unsaved preview and retries all pending fields',
      () async {
        backend.preferences.failWrites = true;
        backend.preferences.mutateCacheBeforeFailure = true;
        await expectLater(
          provider.setReadCharColor(0xFF1188EE),
          throwsStateError,
        );
        expect(provider.settings.readCharColor, 0xFF1188EE);
        expect(provider.readingEmphasisSaveError, isNotNull);
        expect(provider.isSavingReadingEmphasis, isFalse);
        expect(
          (await backend.service.loadSettings()).readCharColor,
          original.readCharColor,
        );

        backend.preferences.failWrites = false;
        await provider.setCurrentCharScale(1.12);
        expect(provider.readingEmphasisSaveError, isNotNull);
        await provider.retryReadingEmphasisSave();
        final stored = await backend.service.loadSettings();
        expect(stored.readCharColor, 0xFF1188EE);
        expect(stored.currentCharScale, 1.12);
        expect(stored.asrModelId, original.asrModelId);
        expect(provider.readingEmphasisSaveError, isNull);
      },
    );

    test(
      'a storage false result is an error rather than a successful save',
      () async {
        backend.preferences.returnFalse = true;
        await expectLater(
          provider.setReadingEmphasisEnabled(false),
          throwsStateError,
        );
        expect(provider.readingEmphasisSaveError, isNotNull);
        expect(
          (await backend.service.loadSettings()).readingEmphasisEnabled,
          isTrue,
        );
        backend.preferences.returnFalse = false;
        await provider.retryReadingEmphasisSave();
        expect(
          (await backend.service.loadSettings()).readingEmphasisEnabled,
          isFalse,
        );
      },
    );

    test(
      'invalid patch types, unknown fields, non-finite scales and out-of-range values never persist',
      () async {
        final invalid = <Map<String, dynamic>>[
          {},
          {'asrModelId': 'unwanted-model'},
          {'readingEmphasisEnabled': 'false'},
          {'currentCharColor': -1},
          {'readCharColor': 0x100000000},
          {'currentCharColor': 1.5},
          {'currentCharScale': double.nan},
          {'currentCharScale': double.infinity},
          {'currentCharScale': '1.10'},
          {'currentCharScale': 0.99},
          {'currentCharScale': 1.16},
        ];
        for (final patch in invalid) {
          final result = await backend.server.request(
            WsMessageType.settingsReadingEmphasisPatch,
            data: {'patch': patch},
          );
          expect(result.type, WsMessageType.error, reason: '$patch');
        }
        await expectLater(
          provider.setCurrentCharScale(double.nan),
          throwsFormatException,
        );
        await expectLater(
          provider.setCurrentCharColor(-1),
          throwsFormatException,
        );
        expect(backend.preferences.writes, isEmpty);
        expect(
          (await backend.service.loadSettings()).toJson(),
          original.toJson(),
        );
        expect(provider.settings.currentCharScale, original.currentCharScale);
      },
    );

    test(
      'explicit reset is ordered with slider changes and later edits win',
      () async {
        final writes = [
          provider.setCurrentCharScale(1.15),
          provider.resetAllSettings(),
          provider.setCurrentCharScale(1.12),
        ];
        await Future.wait(writes);
        final stored = await backend.service.loadSettings();
        expect(
          stored.toJson(),
          const AppSettings().copyWith(currentCharScale: 1.12).toJson(),
        );
        expect(
          provider.settings.toReadingEmphasisMap(),
          stored.toReadingEmphasisMap(),
        );
        expect(provider.readingEmphasisSaveError, isNull);
      },
    );

    test(
      'reset failure can be retried without discarding edits made after the failure',
      () async {
        await provider.setCurrentCharColor(0xFF00CCEE);
        backend.preferences.failWrites = true;
        await expectLater(provider.resetAllSettings(), throwsStateError);
        backend.preferences.failWrites = false;
        await provider.setCurrentCharScale(1.13);
        await provider.retryReadingEmphasisSave();
        final stored = await backend.service.loadSettings();
        expect(
          stored.toJson(),
          const AppSettings().copyWith(currentCharScale: 1.13).toJson(),
        );
        expect(
          provider.settings.toReadingEmphasisMap(),
          stored.toReadingEmphasisMap(),
        );
        expect(provider.readingEmphasisSaveError, isNull);
      },
    );

    test(
      'explicit backup replacement restores emphasis and notifies the active provider',
      () async {
        await provider.setCurrentCharScale(1.15);
        final restored = original.copyWith(
          currentCharColor: 0xFFAABBCC,
          readCharColor: 0xFF667788,
          currentCharScale: 1.03,
          readingEmphasisEnabled: false,
        );
        await backend.service.saveSettings(restored);
        await flushMessages();
        expect(
          provider.settings.toReadingEmphasisMap(),
          restored.toReadingEmphasisMap(),
        );
        await provider.loadSettings();
        expect(provider.settings.toJson(), restored.toJson());
      },
    );

    test(
      'remote reconnection accepts a restarted service revision without clearing the article',
      () async {
        backend.connection.remote = true;
        provider.loadArticleOverrides({'fontSize': 91});
        await provider.setCurrentCharScale(1.11);
        await provider.setCurrentCharScale(1.12);
        await provider.setCurrentCharScale(1.13);
        backend.connection.disconnectForRetry();
        expect(provider.mergedSettings.fontSize, 91);

        final restarted = ReadingEmphasisTestBackend(settings: original);
        await restarted.init();
        backend.connection.reconnectTo(restarted.server);
        await provider.loadSettings();
        expect(provider.settings.currentCharScale, original.currentCharScale);
        expect(provider.mergedSettings.fontSize, 91);
        await restarted.server.request(
          WsMessageType.settingsReadingEmphasisPatch,
          data: {
            'patch': {'currentCharScale': 1.02},
          },
        );
        await flushMessages();
        expect(provider.settings.currentCharScale, 1.02);
        restarted.dispose();
      },
    );
  });
}
