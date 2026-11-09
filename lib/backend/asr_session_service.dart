import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/asr/asr_preparation_exception.dart';
import '../services/asr/asr_recognition_event.dart';

import '../services/asr/alignment_engine.dart';
import '../services/asr/asr_transcript_normalizer.dart';
import '../services/asr_service.dart';
import '../services/text_parser.dart';
import 'settings_service.dart';
import 'ws_protocol.dart';
import 'ws_server.dart';

enum AsrSessionStatus { idle, loading, running, paused, error }

enum AsrFollowState { listening, following, waiting }

/// Owns recognition for the backend. UI clients only receive processed data.
typedef AsrPositionChanged =
    void Function(int currentIndex, {bool allowBackward});

class AsrSessionService {
  AsrSessionService(
    this._settingsService,
    this._onCurrentIndexChanged, {
    AsrService? asr,
    void Function()? initializeBindings,
  }) : _asr = asr ?? AsrService.instance,
       _initializeBindings = initializeBindings ?? AsrService.init;

  static const unloadDelay = Duration(seconds: 20);

  final SettingsService _settingsService;
  final AsrPositionChanged _onCurrentIndexChanged;
  final AsrService _asr;
  final void Function() _initializeBindings;
  final TeleprompterAlignment _alignment = TeleprompterAlignment();
  WsServer? _server;
  Timer? _unloadTimer;
  Future<void>? _pendingUnload;
  Future<void>? _startOperation;
  Future<void>? _pauseOperation;
  int _startGeneration = 0;
  int _recognitionEpoch = 0;
  int _anchorRevision = 0;
  int _lastSegmentId = -1;
  int _lastEventRevision = -1;
  String? _lastEventText;
  bool _segmentFinal = false;
  final AsrRecognitionSequencer _legacySequencer = AsrRecognitionSequencer();
  String _articleId = '';
  String _transcript = '';
  String _committedTranscript = '';
  String _partialTranscript = '';
  double _rms = 0;
  int _currentIndex = -1;
  AsrSessionStatus _status = AsrSessionStatus.idle;
  AsrFollowState _followState = AsrFollowState.listening;
  String? _error;
  String? _message;

  AsrSessionStatus get status => _status;
  String? get error => _error;
  String? get message => _message;
  AsrFollowState get followState => _followState;
  int get currentIndex => _currentIndex;
  int get anchorRevision => _anchorRevision;
  String get transcript => _transcript;
  String? _loadedConfigKey;
  DateTime? _lastRmsBroadcastAt;

  void registerHandlers(WsServer server) {
    _server = server;
    server.requests.listen((request) {
      switch (request.message.type) {
        case WsMessageType.asrStart:
          unawaited(_handleStart(server, request));
        case WsMessageType.asrPause:
          unawaited(_handlePause(server, request));
        default:
          break;
      }
    });
  }

  void beginSession({
    required String articleId,
    required String content,
    required int currentIndex,
  }) {
    _articleId = articleId;
    _currentIndex = currentIndex;
    _anchorRevision = 0;
    _transcript = '';
    _committedTranscript = '';
    _partialTranscript = '';
    _rms = 0;
    _error = null;
    final parsedLines = TextParser.isHtml(content)
        ? TextParser.parse(content)
        : null;
    final alignmentText = parsedLines == null
        ? content
        : parsedLines
              .expand((line) => line.characters)
              .map((char) => char.char)
              .join();
    // HTML block breaks do not occupy a displayed raw character index. Pass
    // their positions separately; inserting '\n' would shift every later cue.
    final boundaries = parsedLines
        ?.where((line) => line.characters.isNotEmpty)
        .map((line) => line.characters.first.rawIndex);
    _alignment
      ..setScript(alignmentText, sentenceBoundaries: boundaries ?? const [])
      ..setCurrentIndex(currentIndex);
    _beginRecognitionEpoch(resetNative: true);
    _broadcastStatus();
  }

  /// Explicit position changes start a new recognition epoch. Ordinary status
  /// synchronization at the same position must not discard a live utterance.
  void setCurrentIndex(int currentIndex, {int? anchorRevision}) {
    if (_articleId.isEmpty) return;
    if (anchorRevision != null && anchorRevision < _anchorRevision) return;
    final revisionChanged =
        anchorRevision != null && anchorRevision != _anchorRevision;
    if (!revisionChanged && currentIndex == _currentIndex) return;
    if (anchorRevision != null) _anchorRevision = anchorRevision;
    _currentIndex = currentIndex;
    _alignment.setCurrentIndex(currentIndex);
    _beginRecognitionEpoch(resetNative: true);
    _broadcastStatus();
  }

  void _beginRecognitionEpoch({required bool resetNative}) {
    _recognitionEpoch++;
    _legacySequencer.reset(_recognitionEpoch);
    _lastSegmentId = -1;
    _lastEventRevision = -1;
    _lastEventText = null;
    _segmentFinal = false;
    _partialTranscript = '';
    _transcript = _committedTranscript;
    _followState = AsrFollowState.listening;
    // A recorder can be waiting for permissions while its decoder stream
    // already exists. Reset that stream too, before isRunning becomes true.
    if (resetNative && _asr.isModelLoaded) {
      try {
        _asr.resetRecognition(epoch: _recognitionEpoch);
      } catch (error) {
        _handleRecognizerError(error);
        unawaited(_asr.stop());
      }
    }
  }

  Future<void> pause() {
    final activePause = _pauseOperation;
    if (activePause != null) return activePause;
    final operation = _pauseInternal();
    _pauseOperation = operation;
    return operation.whenComplete(() {
      if (identical(_pauseOperation, operation)) _pauseOperation = null;
    });
  }

  Future<void> _pauseInternal() async {
    _startGeneration++;
    _beginRecognitionEpoch(resetNative: false);
    _alignment.setCurrentIndex(_currentIndex);
    final startOperation = _startOperation;
    if (_status == AsrSessionStatus.loading) await _asr.cancelDownload();
    if (startOperation != null) {
      try {
        await startOperation;
      } catch (_) {
        // Cancellation/error belongs to the original start; pause still wins.
      }
    }
    await _asr.stop();
    _rms = 0;
    _message = null;
    _status = AsrSessionStatus.paused;
    _broadcastStatus();
  }

  Future<void> endSession() async {
    _unloadTimer?.cancel();
    await pause();
    _unloadTimer = Timer(unloadDelay, () {
      _pendingUnload = _unloadAfterSession();
    });
  }

  Future<void> _unloadAfterSession() async {
    await _asr.unloadModel();
    _loadedConfigKey = null;
    _status = AsrSessionStatus.idle;
    _broadcastStatus();
  }

  Future<void> shutdown() async {
    _unloadTimer?.cancel();
    await pause();
    await _asr.unloadModel();
    _loadedConfigKey = null;
    _articleId = '';
    _message = null;
    _status = AsrSessionStatus.idle;
  }

  Future<void> release() async {
    await shutdown();
    await _asr.release();
  }

  Future<void> start() async {
    final pendingPause = _pauseOperation;
    if (pendingPause != null) await pendingPause;
    if (_status == AsrSessionStatus.running && _asr.isRunning) return;
    final activeOperation = _startOperation;
    if (activeOperation != null) {
      await activeOperation;
      return;
    }
    final generation = ++_startGeneration;
    final operation = _startInternal(generation);
    _startOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_startOperation, operation)) _startOperation = null;
    }
  }

  void _checkStartGeneration(int generation) {
    if (generation != _startGeneration) {
      throw const AsrModelPreparationException('已取消语音启动', isCancelled: true);
    }
  }

  Future<void> _startInternal(int generation) async {
    if (_articleId.isEmpty) throw StateError('当前没有活动的提词会话');
    if (_status == AsrSessionStatus.running && _asr.isRunning) return;
    _unloadTimer?.cancel();
    await _pendingUnload;
    _pendingUnload = null;
    _checkStartGeneration(generation);
    _error = null;
    _message = '正在准备中文语音识别…';
    _status = AsrSessionStatus.loading;
    _broadcastStatus();
    var phase = 'model';
    try {
      final settings = await _settingsService.loadSettings();
      _checkStartGeneration(generation);
      final modelId = settings.asrModelId.trim().isEmpty
          ? AppSettings.defaultAsrModelId
          : settings.asrModelId;
      final configKey = [
        modelId,
        settings.asrNumThreads,
        settings.asrRule1MinTrailingSilence,
        settings.asrRule2MinTrailingSilence,
        settings.asrRule3MinUtteranceLength,
      ].join('|');
      _initializeBindings();
      if (!_asr.isModelLoaded ||
          _asr.currentModelId != modelId ||
          _loadedConfigKey != configKey) {
        DateTime? lastProgressAt;
        await _asr.loadModel(
          modelId,
          numThreads: settings.asrNumThreads,
          rule1MinTrailingSilence: settings.asrRule1MinTrailingSilence,
          rule2MinTrailingSilence: settings.asrRule2MinTrailingSilence,
          rule3MinUtteranceLength: settings.asrRule3MinUtteranceLength,
          useSystemProxy: settings.asrUseSystemProxy,
          onProgress: (value, message) {
            if (generation != _startGeneration) return;
            _message = message;
            final now = DateTime.now();
            if (value == 1 ||
                lastProgressAt == null ||
                now.difference(lastProgressAt!) >=
                    const Duration(milliseconds: 100)) {
              lastProgressAt = now;
              _broadcastStatus();
            }
          },
        );
        _checkStartGeneration(generation);
        _loadedConfigKey = configKey;
      }
      _checkStartGeneration(generation);
      phase = 'microphone';
      _beginRecognitionEpoch(resetNative: false);
      _alignment.setCurrentIndex(_currentIndex);
      _message = '正在启动麦克风…';
      _broadcastStatus();
      final callbackEpoch = _recognitionEpoch;
      await _asr.start(
        onPartialResult: (text) {
          if (generation == _startGeneration &&
              callbackEpoch == _recognitionEpoch) {
            _handleLegacyTranscript(text, false);
          }
        },
        onFinalResult: (text) {
          if (generation == _startGeneration &&
              callbackEpoch == _recognitionEpoch) {
            _handleLegacyTranscript(text, true);
          }
        },
        onRecognitionEvent: (event) {
          if (generation == _startGeneration) _handleRecognitionEvent(event);
        },
        recognitionEpoch: callbackEpoch,
        onRmsUpdate: (value) {
          if (generation == _startGeneration) _handleRms(value);
        },
        inputDeviceId: settings.asrInputDeviceId,
        onError: (error) {
          if (generation == _startGeneration) _handleRecognizerError(error);
        },
      );
      _checkStartGeneration(generation);
      if (!_asr.isRunning) throw StateError('麦克风采集启动后已中断');
      _message = null;
      _status = AsrSessionStatus.running;
      _broadcastStatus();
    } catch (error, stackTrace) {
      debugPrint('[AsrSessionService] 语音启动失败 ($phase): $error\n$stackTrace');
      if (generation != _startGeneration) {
        await _asr.stop();
        rethrow;
      }
      _status = AsrSessionStatus.error;
      _message = null;
      _error = error is AsrModelPreparationException
          ? error.message
          : phase == 'microphone'
          ? '麦克风启动失败。请检查麦克风权限和设备连接，再点击语音重试。'
          : '语音模型加载失败。请重新启动应用后点击语音重试；仍失败时请重新安装。';
      _broadcastStatus();
      rethrow;
    }
  }

  Future<void> _handleStart(WsServer server, WsRequest request) async {
    var success = true;
    try {
      await start();
    } catch (_) {
      success = false;
    }
    server.respond(
      request.clientId,
      WsMessage(
        type: WsMessageType.asrStartResponse,
        id: request.message.id,
        data: _statusData(success: success),
      ),
    );
  }

  Future<void> _handlePause(WsServer server, WsRequest request) async {
    await pause();
    server.respond(
      request.clientId,
      WsMessage(
        type: WsMessageType.asrPauseResponse,
        id: request.message.id,
        data: _statusData(success: true),
      ),
    );
  }

  void _handleLegacyTranscript(String text, bool isFinal) {
    final event = _legacySequencer.update(text, isFinal: isFinal);
    if (event != null) _handleRecognitionEvent(event);
  }

  void _handleRecognitionEvent(AsrRecognitionEvent event) {
    if (event.epoch != _recognitionEpoch ||
        event.segmentId < 0 ||
        event.revision <= 0 ||
        event.segmentId < _lastSegmentId) {
      return;
    }
    if (event.segmentId == _lastSegmentId &&
        (_segmentFinal || event.revision <= _lastEventRevision)) {
      return;
    }
    if (event.segmentId != _lastSegmentId) {
      // Normally the native recognizer always closes its previous segment.
      // If a transport drops that final event, never reuse its cumulative
      // transcript as the starting point of a different utterance.
      if (_lastSegmentId >= 0 && !_segmentFinal) {
        _alignment.setCurrentIndex(_currentIndex);
        _committedTranscript = appendAsrTranscript(
          _committedTranscript,
          _partialTranscript,
        );
      }
      _lastSegmentId = event.segmentId;
      _lastEventRevision = -1;
      _lastEventText = null;
      _segmentFinal = false;
    }
    _lastEventRevision = event.revision;
    final trimmed = normalizeAsrTranscript(event.text);
    if (!event.isFinal && trimmed == _lastEventText) return;
    _lastEventText = trimmed;
    _segmentFinal = event.isFinal;
    if (event.isFinal) {
      if (trimmed.isNotEmpty) {
        _committedTranscript = appendAsrTranscript(
          _committedTranscript,
          trimmed,
        );
      }
      _partialTranscript = '';
    } else {
      _partialTranscript = trimmed;
    }
    _transcript = composeAsrDisplayText(
      _committedTranscript,
      _partialTranscript,
    );
    final result = _alignment.consumeTranscript(trimmed, event.isFinal);
    final alignedIndex = result.index;
    _followState = result.meta.isWaiting
        ? AsrFollowState.waiting
        : result.meta.matchedLength > 0
        ? AsrFollowState.following
        : AsrFollowState.listening;
    if (alignedIndex >= 0 &&
        alignedIndex != _currentIndex &&
        (alignedIndex >= _currentIndex || result.meta.allowBackward)) {
      _currentIndex = alignedIndex;
      _onCurrentIndexChanged(
        _currentIndex,
        allowBackward: result.meta.allowBackward,
      );
    }
    _server?.broadcast(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          ..._statusData(),
          'segment': trimmed,
          'isFinal': event.isFinal,
          'recognitionEpoch': event.epoch,
          'segmentId': event.segmentId,
          'segmentRevision': event.revision,
          'allowBackward': result.meta.allowBackward,
        },
      ),
    );
  }

  void _handleRms(double value) {
    _rms = value;
    final now = DateTime.now();
    final previous = _lastRmsBroadcastAt;
    if (previous != null &&
        now.difference(previous) < const Duration(milliseconds: 50)) {
      return;
    }
    _lastRmsBroadcastAt = now;
    _server?.broadcast(
      WsMessage(
        type: WsMessageType.asrStatus,
        data: {
          'articleId': _articleId,
          'status': _status.name,
          'rms': _rms,
          'currentIndex': _currentIndex,
          'asrAnchorRevision': _anchorRevision,
          'followState': _followState.name,
        },
      ),
    );
  }

  void _handleRecognizerError(Object error) {
    _startGeneration++;
    _recognitionEpoch++;
    _status = AsrSessionStatus.error;
    debugPrint('[AsrSessionService] 麦克风采集失败: $error');
    _message = null;
    _error = '麦克风采集已中断。请检查设备连接和麦克风权限，再点击语音重试。';
    _rms = 0;
    _broadcastStatus();
  }

  Map<String, dynamic> _statusData({bool? success}) => {
    'success': ?success,
    'articleId': _articleId,
    'status': _status.name,
    'text': _transcript,
    'rms': _rms,
    'currentIndex': _currentIndex,
    'asrAnchorRevision': _anchorRevision,
    'followState': _followState.name,
    'error': ?_error,
    'message': _message,
  };

  void _broadcastStatus() {
    _server?.broadcast(
      WsMessage(type: WsMessageType.asrStatus, data: _statusData()),
    );
  }
}
