import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';

const _voiceSettings = AppSettings(
  scrollMode: ScrollMode.asr,
  autoHideUI: false,
);

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

WsMessage _status(
  String status, {
  WsMessageType type = WsMessageType.asrStatus,
  String? message,
  String? error,
}) => WsMessage(
  type: type,
  data: {
    'articleId': 'voice-test',
    'status': status,
    if (message != null) 'message': message,
    if (error != null) 'error': error,
  },
);

void main() {
  late _VoiceConnection connection;
  late TeleprompterProvider provider;

  setUp(() async {
    connection = _VoiceConnection();
    provider = TeleprompterProvider()
      ..bindConnection(connection)
      ..loadScript('voice-test', '现在测试语音跟随和暂停恢复。');
    await _flush();
  });

  tearDown(() async {
    provider.dispose();
    connection.dispose();
    await _flush();
  });

  test(
    'preparation progress is shown and cleared when recognition starts',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      expect(provider.isAsrLoading, isTrue);
      connection.emit(_status('loading', message: '正在下载中文模型：50%'));
      expect(provider.asrMessage, '正在下载中文模型：50%');
      connection.starts.single.complete(
        _status('running', type: WsMessageType.asrStartResponse),
      );
      await _flush();
      expect(provider.asrStatus, 'running');
      expect(provider.asrMessage, isNull);
      expect(provider.asrError, isNull);
      expect(provider.isPlaying, isTrue);
    },
  );

  test(
    'recognizer errors pause playback and keep a useful retry message',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      connection.starts.single.complete(
        _status(
          'error',
          type: WsMessageType.asrStartResponse,
          error: '无法读取麦克风，请检查系统权限后重试。',
        ),
      );
      await _flush();
      expect(provider.isPlaying, isFalse);
      expect(provider.state, TeleprompterState.paused);
      expect(provider.controlsVisible, isTrue);
      expect(provider.asrMessage, isNull);
      expect(provider.asrError, contains('麦克风'));
      // One pause comes from loadScript; the failed start must explicitly send
      // another cancellation instead of only changing the frontend play state.
      expect(
        connection.requestTypes.where((type) => type == WsMessageType.asrPause),
        hasLength(2),
      );

      provider.pause(_voiceSettings);
      await _flush();
      expect(provider.asrError, contains('麦克风'));
    },
  );

  test('a disconnected service cannot leave a false playing state', () async {
    connection.connected = false;
    provider.play(_voiceSettings);
    await _flush();
    expect(provider.isPlaying, isFalse);
    expect(provider.asrStatus, 'error');
    expect(provider.asrError, contains('连接已断开'));
    expect(provider.controlsVisible, isTrue);
    expect(connection.starts, isEmpty);
  });

  test(
    'pause during preparation ignores a late successful start response',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      final pending = connection.starts.single;
      provider.pause(_voiceSettings);
      await _flush();
      pending.complete(
        _status('running', type: WsMessageType.asrStartResponse),
      );
      await _flush();
      expect(provider.isPlaying, isFalse);
      expect(provider.asrStatus, 'paused');
      expect(provider.asrMessage, isNull);
    },
  );

  test(
    'an older failed request cannot overwrite a resumed voice session',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      final previous = connection.starts.single;
      provider.pause(_voiceSettings);
      await _flush();
      provider.play(_voiceSettings);
      await _flush();
      expect(connection.starts, hasLength(2));
      previous.completeError(Exception('obsolete native recognizer error'));
      await _flush();
      expect(provider.isPlaying, isTrue);
      expect(provider.isAsrLoading, isTrue);
      expect(provider.asrError, isNull);
      connection.starts.last.complete(
        _status('running', type: WsMessageType.asrStartResponse),
      );
      await _flush();
      expect(provider.asrStatus, 'running');
    },
  );

  test(
    'an error broadcast invalidates the pending successful response',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      final pending = connection.starts.single;
      connection.emit(_status('error', error: '语音准备失败，请重试。'));
      expect(provider.isPlaying, isFalse);
      pending.complete(
        _status('running', type: WsMessageType.asrStartResponse),
      );
      await _flush();
      expect(provider.asrStatus, 'error');
      expect(provider.asrError, contains('语音准备失败'));
    },
  );
  test(
    'unexpected native request failures are logged and explained in Chinese',
    () async {
      provider.play(_voiceSettings);
      await _flush();
      connection.starts.single.completeError(
        Exception('Failed to create online recognizer'),
      );
      await _flush();
      expect(provider.isPlaying, isFalse);
      expect(provider.asrError, contains('语音启动失败'));
      expect(provider.asrError, isNot(contains('Failed')));
      expect(provider.asrMessage, isNull);
      expect(
        connection.requestTypes.where((type) => type == WsMessageType.asrPause),
        hasLength(2),
      );
    },
  );
}

class _VoiceConnection extends ChangeNotifier implements ConnectionProvider {
  final _messages = StreamController<WsMessage>.broadcast(sync: true);
  final starts = <Completer<WsMessage>>[];
  final sentMessages = <WsMessage>[];
  final requestTypes = <WsMessageType>[];
  bool connected = true;

  void emit(WsMessage message) => _messages.add(message);

  @override
  bool get isConnected => connected;
  @override
  bool get isLocal => true;
  @override
  bool get isRemote => false;
  @override
  bool get canRetryRemoteConnection => false;
  @override
  List<String> get remoteDeviceIds => const [];

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) {
    requestTypes.add(type);
    if (type == WsMessageType.asrStart) {
      final result = Completer<WsMessage>();
      starts.add(result);
      return result.future;
    }
    if (type == WsMessageType.asrPause) {
      return Future.value(
        _status('paused', type: WsMessageType.asrPauseResponse),
      );
    }
    return Future.value(WsMessage(type: type, data: const {'success': true}));
  }

  @override
  void send(WsMessage message) => sentMessages.add(message);

  @override
  Stream<WsMessage> listenTo(WsMessageType type) =>
      _messages.stream.where((message) => message.type == type);

  @override
  void dispose() {
    for (final pending in starts) {
      if (!pending.isCompleted) {
        pending.complete(
          _status('paused', type: WsMessageType.asrStartResponse),
        );
      }
    }
    _messages.close();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
