import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/asr_session_service.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/services/asr/asr_preparation_exception.dart';
import 'package:storm_teleprompter_plus/services/asr_service.dart';

class _Settings extends Fake implements SettingsService {
  _Settings([this.settings = const AppSettings()]);
  final AppSettings settings;
  @override
  Future<AppSettings> loadSettings() async => settings;
}

class _Asr extends Fake implements AsrService {
  Completer<void>? loadingGate;
  final loadStarted = Completer<void>();
  Object? loadError;
  Object? microphoneError;
  String? loadedId;
  bool loaded = false;
  bool running = false;
  int microphoneStarts = 0;
  int cancellations = 0;
  void Function(String)? partial;

  @override
  bool get isModelLoaded => loaded;
  @override
  String? get currentModelId => loadedId;
  @override
  bool get isRunning => running;

  @override
  Future<void> loadModel(
    String modelId, {
    int numThreads = 0,
    double rule1MinTrailingSilence = 2.4,
    double rule2MinTrailingSilence = 1.2,
    double rule3MinUtteranceLength = 20,
    bool useSystemProxy = true,
    DownloadProgressCallback? onProgress,
  }) async {
    onProgress?.call(0.5, '正在从魔搭社区恢复中文语音模型：准备中');
    if (!loadStarted.isCompleted) loadStarted.complete();
    final gate = loadingGate;
    if (gate != null) await gate.future;
    if (loadError != null) throw loadError!;
    loaded = true;
    loadedId = modelId;
  }

  @override
  Future<void> cancelDownload() async {
    cancellations++;
    final gate = loadingGate;
    loadingGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(
        const AsrModelPreparationException('已取消语音模型准备', isCancelled: true),
      );
    }
  }

  @override
  Future<void> start({
    required void Function(String) onPartialResult,
    required void Function(String) onFinalResult,
    void Function(double)? onRmsUpdate,
    String? inputDeviceId,
    void Function(Object)? onError,
  }) async {
    if (microphoneError != null) throw microphoneError!;
    microphoneStarts++;
    partial = onPartialResult;
    running = true;
  }

  @override
  Future<void> stop() async => running = false;
  @override
  Future<void> unloadModel() async {
    loaded = false;
    loadedId = null;
  }

  @override
  Future<void> release() async {}
}

void main() {
  AsrSessionService create(
    _Asr asr, {
    AppSettings settings = const AppSettings(),
    void Function(int, {bool allowBackward})? position,
  }) {
    final session = AsrSessionService(
      _Settings(settings),
      position ?? (int index, {bool allowBackward = false}) {},
      asr: asr,
      initializeBindings: () {},
    );
    session.beginSession(
      articleId: 'public-fixture',
      content: '测试语音跟随功能正常',
      currentIndex: -1,
    );
    addTearDown(session.shutdown);
    return session;
  }

  test(
    'preparation publishes progress and starts the microphone only after readiness',
    () async {
      final asr = _Asr()..loadingGate = Completer<void>();
      final session = create(asr);
      final start = session.start();
      await asr.loadStarted.future;
      expect(session.status, AsrSessionStatus.loading);
      expect(session.message, contains('魔搭社区'));
      expect(asr.microphoneStarts, 0);
      asr.loadingGate!.complete();
      await start;
      expect(session.status, AsrSessionStatus.running);
      expect(session.message, isNull);
      expect(asr.loadedId, AppSettings.defaultAsrModelId);
      expect(asr.microphoneStarts, 1);
    },
  );

  test(
    'pause cancels preparation and a retry starts exactly one microphone',
    () async {
      final asr = _Asr()..loadingGate = Completer<void>();
      final session = create(asr);
      final start = session.start();
      final cancelled = expectLater(
        start,
        throwsA(isA<AsrModelPreparationException>()),
      );
      await asr.loadStarted.future;
      await session.pause();
      await cancelled;
      expect(session.status, AsrSessionStatus.paused);
      expect(asr.microphoneStarts, 0);
      expect(asr.cancellations, 1);
      expect(session.error, isNull);
      await session.start();
      expect(session.status, AsrSessionStatus.running);
      expect(asr.microphoneStarts, 1);
    },
  );

  test('an immediate pause wins before loading can start', () async {
    final asr = _Asr();
    final session = create(asr);
    final start = session.start();
    final cancelled = expectLater(
      start,
      throwsA(isA<AsrModelPreparationException>()),
    );
    await session.pause();
    await cancelled;
    expect(session.status, AsrSessionStatus.paused);
    expect(asr.microphoneStarts, 0);
  });

  test(
    'native initialization errors become actionable Chinese failures',
    () async {
      final asr = _Asr()
        ..loadError = Exception('Failed to create online recognizer');
      final session = create(asr);
      await expectLater(session.start(), throwsException);
      expect(session.status, AsrSessionStatus.error);
      expect(session.error, contains('语音模型加载失败'));
      expect(session.error, isNot(contains('Failed to create')));
      expect(asr.running, isFalse);
      expect(asr.microphoneStarts, 0);
    },
  );

  test('microphone failures have their own retry guidance', () async {
    final asr = _Asr()..microphoneError = StateError('Permission denied');
    final session = create(asr);
    await expectLater(session.start(), throwsStateError);
    expect(session.status, AsrSessionStatus.error);
    expect(session.error, contains('麦克风权限和设备连接'));
    expect(asr.running, isFalse);
  });

  test('repeated start retains the active transcript callbacks', () async {
    final asr = _Asr();
    final positions = <int>[];
    final session = create(
      asr,
      position: (int value, {bool allowBackward = false}) =>
          positions.add(value),
    );
    await session.start();
    await session.start();
    asr.partial!('测试语音');
    expect(asr.microphoneStarts, 1);
    expect(positions, isNotEmpty);
  });

  test('an existing non-default model selection is preserved', () async {
    final asr = _Asr();
    final session = create(
      asr,
      settings: const AppSettings(asrModelId: 'user-selected-model'),
    );
    await session.start();
    expect(asr.loadedId, 'user-selected-model');
  });
}
