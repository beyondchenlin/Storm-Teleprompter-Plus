import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/asr_session_service.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/services/asr/asr_preparation_exception.dart';
import 'package:storm_teleprompter_plus/services/asr/asr_recognition_event.dart';
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
  int recognitionResets = 0;
  int epoch = 0;
  Object? resetError;
  Completer<void>? microphoneGate;
  final microphoneStarting = Completer<void>();
  void Function(String)? partial;
  void Function(String)? finalResult;
  void Function(AsrRecognitionEvent)? event;
  void Function(Object)? captureError;
  final sequencer = AsrRecognitionSequencer();

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
    void Function(AsrRecognitionEvent)? onRecognitionEvent,
    int recognitionEpoch = 0,
    void Function(double)? onRmsUpdate,
    String? inputDeviceId,
    void Function(Object)? onError,
  }) async {
    if (microphoneError != null) throw microphoneError!;
    microphoneStarts++;
    partial = onPartialResult;
    finalResult = onFinalResult;
    event = onRecognitionEvent;
    captureError = onError;
    epoch = recognitionEpoch;
    sequencer.reset(epoch);
    if (!microphoneStarting.isCompleted) microphoneStarting.complete();
    if (microphoneGate != null) await microphoneGate!.future;
    running = true;
  }

  @override
  void resetRecognition({required int epoch}) {
    recognitionResets++;
    if (resetError != null) throw resetError!;
    this.epoch = epoch;
    sequencer.reset(epoch);
  }

  void emit(String text, {bool isFinal = false}) {
    final value = sequencer.update(text, isFinal: isFinal);
    if (value != null) event!(value);
  }

  void failCapture(Object error) {
    running = false;
    captureError?.call(error);
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
    String content = '测试语音跟随功能正常',
    int currentIndex = -1,
  }) {
    final session = AsrSessionService(
      _Settings(settings),
      position ?? (int index, {bool allowBackward = false}) {},
      asr: asr,
      initializeBindings: () {},
    );
    session.beginSession(
      articleId: 'public-fixture',
      content: content,
      currentIndex: currentIndex,
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

  test(
    'one partial result is accepted once and final only commits it',
    () async {
      final asr = _Asr();
      final positions = <int>[];
      final session = create(
        asr,
        position: (int index, {bool allowBackward = false}) =>
            positions.add(index),
      );
      await session.start();
      asr.emit('测试语音跟随');
      final first = session.currentIndex;
      expect(first, 5);
      for (var revision = 2; revision <= 12; revision++) {
        // Even a producer that gives identical text a new revision cannot make
        // the service repeatedly chase a target with a per-callback limit.
        asr.event!(
          AsrRecognitionEvent(
            epoch: asr.epoch,
            segmentId: 0,
            revision: revision,
            text: '测试语音跟随',
            isFinal: false,
          ),
        );
      }
      asr.event!(
        AsrRecognitionEvent(
          epoch: asr.epoch,
          segmentId: 0,
          revision: 13,
          text: '测试语音跟随',
          isFinal: true,
        ),
      );
      asr.event!(
        AsrRecognitionEvent(
          epoch: asr.epoch,
          segmentId: 0,
          revision: 14,
          text: '测试语音跟随功能正常',
          isFinal: true,
        ),
      );
      expect(session.currentIndex, first);
      expect(positions, [first]);
      expect(session.transcript, '测试语音跟随');
    },
  );

  test(
    'separate identical utterances advance separate script occurrences',
    () async {
      const phrase = '重要的事情需要认真对待';
      const script = '$phrase。$phrase。';
      final asr = _Asr();
      final session = create(asr, content: script);
      await session.start();
      asr.emit(phrase, isFinal: true);
      expect(session.currentIndex, phrase.length - 1);
      asr.emit(phrase, isFinal: true);
      expect(session.currentIndex, script.length - 2);
      expect(session.transcript, '$phrase\n$phrase');
    },
  );

  test(
    'confirmed progress is not clipped to an unrelated callback budget',
    () async {
      const first = '我们现在开始';
      const second = '认真学习如何建立正确的知识联系';
      final asr = _Asr();
      final session = create(asr, content: '$first$second。');
      await session.start();
      asr.emit(first, isFinal: true);
      expect(session.currentIndex, first.length - 1);
      asr.emit(second, isFinal: true);
      expect(session.currentIndex, first.length + second.length - 1);
    },
  );

  test(
    'manual anchoring rejects late epochs and ignores duplicate sync',
    () async {
      final asr = _Asr();
      final session = create(asr);
      await session.start();
      final oldEpoch = asr.epoch;
      final oldLegacyPartial = asr.partial!;
      session.setCurrentIndex(5, anchorRevision: 1);
      expect(asr.epoch, greaterThan(oldEpoch));
      expect(session.anchorRevision, 1);
      final resets = asr.recognitionResets;
      session.setCurrentIndex(5, anchorRevision: 1);
      expect(asr.recognitionResets, resets);
      session.setCurrentIndex(5, anchorRevision: 2);
      expect(asr.recognitionResets, resets + 1);
      session.setCurrentIndex(0, anchorRevision: 1);
      expect(session.currentIndex, 5);
      asr.event!(
        AsrRecognitionEvent(
          epoch: oldEpoch,
          segmentId: 0,
          revision: 100,
          text: '测试语音跟随功能正常',
          isFinal: true,
        ),
      );
      expect(session.currentIndex, 5);
      oldLegacyPartial('测试语音跟随功能正常');
      expect(session.currentIndex, 5);
      asr.emit('功能正常', isFinal: true);
      expect(session.currentIndex, 9);
    },
  );

  test(
    'manual anchoring during microphone startup resets its pending epoch',
    () async {
      final asr = _Asr()..microphoneGate = Completer<void>();
      final session = create(asr);
      final starting = session.start();
      await asr.microphoneStarting.future;
      final oldEpoch = asr.epoch;
      expect(asr.running, isFalse);
      session.setCurrentIndex(5, anchorRevision: 1);
      expect(asr.epoch, greaterThan(oldEpoch));
      asr.microphoneGate!.complete();
      await starting;
      asr.emit('功能正常', isFinal: true);
      expect(session.currentIndex, 9);
    },
  );

  test(
    'pause and a new session invalidate callbacks from the previous run',
    () async {
      final asr = _Asr();
      final session = create(asr);
      await session.start();
      final previousListener = asr.event!;
      final previousEpoch = asr.epoch;
      await session.pause();
      session.beginSession(
        articleId: 'next-fixture',
        content: '开始讲解新的课程内容。',
        currentIndex: -1,
      );
      await session.start();
      expect(asr.epoch, greaterThan(previousEpoch));
      previousListener(
        AsrRecognitionEvent(
          epoch: asr.epoch,
          segmentId: 0,
          revision: 1,
          text: '开始讲解新的课程内容',
          isFinal: true,
        ),
      );
      expect(session.currentIndex, -1);
      asr.emit('开始讲解新的课程内容', isFinal: true);
      expect(session.currentIndex, 9);
    },
  );

  test('HTML logical lines preserve displayed character offsets', () async {
    final asr = _Asr();
    final session = create(asr, content: '<p>甲乙丙丁</p><p>戊己庚辛</p>');
    await session.start();
    asr.emit('甲乙丙丁', isFinal: true);
    expect(session.currentIndex, 3);
    asr.emit('戊己庚辛', isFinal: true);
    expect(session.currentIndex, 7);
  });

  test(
    'off-script speech reports waiting without a microphone error',
    () async {
      final asr = _Asr();
      final session = create(asr);
      await session.start();
      expect(session.followState, AsrFollowState.listening);
      asr.emit('大家先喝口水然后等一会再继续');
      expect(session.currentIndex, -1);
      expect(session.followState, AsrFollowState.waiting);
      expect(session.error, isNull);
      expect(session.status, AsrSessionStatus.running);
    },
  );

  test(
    'a decoder reset failure pauses recognition with actionable guidance',
    () async {
      final asr = _Asr();
      final session = create(asr);
      await session.start();
      asr.resetError = StateError('decoder unavailable');
      session.setCurrentIndex(5, anchorRevision: 1);
      expect(session.status, AsrSessionStatus.error);
      expect(session.error, contains('语音重试'));
      expect(asr.running, isFalse);
    },
  );

  test(
    'capture failure rejects late events and retries from the saved position',
    () async {
      final asr = _Asr();
      final session = create(asr);
      await session.start();
      asr.emit('测试语音跟随', isFinal: true);
      final oldEvent = asr.event!;
      final oldError = asr.captureError!;
      final oldEpoch = asr.epoch;
      asr.failCapture(StateError('microphone stream closed'));
      expect(session.status, AsrSessionStatus.error);
      expect(session.currentIndex, 5);
      oldEvent(
        AsrRecognitionEvent(
          epoch: oldEpoch,
          segmentId: 1,
          revision: 1,
          text: '功能正常',
          isFinal: true,
        ),
      );
      expect(session.currentIndex, 5);
      await session.start();
      expect(asr.microphoneStarts, 2);
      expect(session.status, AsrSessionStatus.running);
      expect(session.error, isNull);
      oldError(StateError('late failure from the old capture'));
      expect(session.status, AsrSessionStatus.running);
      asr.emit('功能正常', isFinal: true);
      expect(session.currentIndex, 9);
    },
  );
}
