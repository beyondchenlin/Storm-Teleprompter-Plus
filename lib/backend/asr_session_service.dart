import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/asr/asr_preparation_exception.dart';

import '../services/asr/alignment_engine.dart';
import '../services/asr/asr_transcript_normalizer.dart';
import '../services/asr_service.dart';
import '../services/text_parser.dart';
import 'settings_service.dart';
import 'ws_protocol.dart';
import 'ws_server.dart';

enum AsrSessionStatus { idle, loading, running, paused, error }

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
  static const int maxPartialAdvance = 4;
  static const int maxFinalAdvance = 6;

  static int limitAdvance({
    required int currentIndex,
    required int requestedIndex,
    required bool isFinal,
  }) {
    if (requestedIndex < 0 ||
        currentIndex < 0 ||
        requestedIndex <= currentIndex) {
      return requestedIndex;
    }
    final maxAdvance = isFinal ? maxFinalAdvance : maxPartialAdvance;
    return requestedIndex
        .clamp(currentIndex, currentIndex + maxAdvance)
        .toInt();
  }

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
  String _articleId = '';
  String _transcript = '';
  String _committedTranscript = '';
  String _partialTranscript = '';
  double _rms = 0;
  int _currentIndex = -1;
  AsrSessionStatus _status = AsrSessionStatus.idle;
  String? _error;
  String? _message;

  AsrSessionStatus get status => _status;
  String? get error => _error;
  String? get message => _message;
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
    _transcript = '';
    _committedTranscript = '';
    _partialTranscript = '';
    _rms = 0;
    _error = null;
    final alignmentText = TextParser.isHtml(content)
        ? TextParser.parse(
            content,
          ).expand((line) => line.characters).map((char) => char.char).join()
        : content;
    _alignment
      ..setScript(alignmentText)
      ..setCurrentIndex(currentIndex);
    _broadcastStatus();
  }

  /// 手动或自动移动当前字后，同步覆盖对齐锚点。
  void setCurrentIndex(int currentIndex) {
    if (_articleId.isEmpty) return;
    _currentIndex = currentIndex;
    _alignment.setCurrentIndex(currentIndex);
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
      _message = '正在启动麦克风…';
      _broadcastStatus();
      await _asr.start(
        onPartialResult: (text) {
          if (generation == _startGeneration) _handleTranscript(text, false);
        },
        onFinalResult: (text) {
          if (generation == _startGeneration) _handleTranscript(text, true);
        },
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

  void _handleTranscript(String text, bool isFinal) {
    final trimmed = normalizeAsrTranscript(text.trim());
    if (isFinal) {
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
    final result = _alignment.consumeTranscript(trimmed, isFinal);
    final alignedIndex = limitAdvance(
      currentIndex: _currentIndex,
      requestedIndex: result.index,
      isFinal: isFinal,
    );
    if (alignedIndex >= 0 &&
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
          'isFinal': isFinal,
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
        },
      ),
    );
  }

  void _handleRecognizerError(Object error) {
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
    'error': ?_error,
    'message': _message,
  };

  void _broadcastStatus() {
    _server?.broadcast(
      WsMessage(type: WsMessageType.asrStatus, data: _statusData()),
    );
  }
}
