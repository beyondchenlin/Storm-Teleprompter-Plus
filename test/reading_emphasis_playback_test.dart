import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';

void main() {
  test(
    'changing reading appearance preserves the live recognition cursor',
    () async {
      final connection = _RecognitionConnection();
      final teleprompter = TeleprompterProvider()
        ..bindConnection(connection)
        ..loadScript('appearance-test', '今天我们一起测试中文提词效果。');
      addTearDown(() {
        teleprompter.dispose();
        connection.dispose();
      });

      const original = AppSettings(
        scrollMode: ScrollMode.asr,
        autoHideUI: false,
      );
      teleprompter.play(original);
      await connection.started.future;
      await Future<void>.delayed(Duration.zero);
      connection.emitResult(5);
      await Future<void>.delayed(Duration.zero);
      expect(teleprompter.currentIndex, 5);
      expect(teleprompter.isPlaying, isTrue);
      final requestsBeforeAppearanceChange = List<WsMessageType>.from(
        connection.requests,
      );

      for (final scale in [1.0, 1.05, 1.10, 1.15, 1.0]) {
        teleprompter.refreshAutoScrollSettings(
          original.copyWith(
            readingEmphasisEnabled: scale != 1.0,
            currentCharColor: 0xFF00FF88,
            readCharColor: 0xFF888888,
            currentCharScale: scale,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(teleprompter.currentIndex, 5);
      expect(teleprompter.isPlaying, isTrue);
      expect(
        connection.requests.where((type) => type == WsMessageType.asrStart),
        hasLength(1),
      );
      expect(connection.requests, requestsBeforeAppearanceChange);

      connection.emitResult(9);
      await Future<void>.delayed(Duration.zero);
      expect(teleprompter.currentIndex, 9);
      expect(teleprompter.asrTranscript, '今天我们一起测试');
    },
  );
}

class _RecognitionConnection extends ConnectionProvider {
  final _messages = StreamController<WsMessage>.broadcast();
  final requests = <WsMessageType>[];
  final started = Completer<void>();
  int anchorRevision = 0;

  @override
  bool get isConnected => true;

  @override
  bool get isLocal => true;

  @override
  List<String> get remoteDeviceIds => const [];

  @override
  Stream<WsMessage> listenTo(WsMessageType type) =>
      _messages.stream.where((message) => message.type == type);

  void emitResult(int index) {
    _messages.add(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          'articleId': 'appearance-test',
          'status': 'running',
          'currentIndex': index,
          'text': '今天我们一起测试',
          'asrAnchorRevision': anchorRevision,
        },
      ),
    );
  }

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    requests.add(type);
    if (type == WsMessageType.teleprompterSync) {
      anchorRevision = (data['asrAnchorRevision'] as num?)?.toInt() ?? 0;
    }
    if (type == WsMessageType.asrStart && !started.isCompleted) {
      started.complete();
    }
    return WsMessage(
      type: type == WsMessageType.asrStart
          ? WsMessageType.asrStartResponse
          : type,
      data: {
        'success': true,
        'articleId': 'appearance-test',
        'status': 'running',
      },
    );
  }

  @override
  void send(WsMessage message) {}

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }
}
