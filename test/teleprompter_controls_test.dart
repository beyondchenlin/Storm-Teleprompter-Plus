import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';

void main() {
  testWidgets('pinned overlays ignore auto-hide until unpinned', (
    tester,
  ) async {
    const settings = AppSettings(wpm: 0, autoHideDelaySeconds: 1);
    final provider = TeleprompterProvider()..loadScript('article', '测试正文');
    void listener() {}

    provider.addListener(listener);
    addTearDown(() {
      provider.removeListener(listener);
      provider.dispose();
    });

    provider.play(settings);
    provider.toggleControlsPinned(settings);
    await tester.pump(const Duration(seconds: 2));

    expect(provider.controlsPinned, isTrue);
    expect(provider.controlsVisible, isTrue);

    provider.toggleControls();
    expect(provider.controlsVisible, isTrue);

    provider.toggleControlsPinned(settings);
    await tester.pump(const Duration(seconds: 2));

    expect(provider.controlsPinned, isFalse);
    expect(provider.controlsVisible, isFalse);
    provider.stopAll();
  });

  test('ASR resume keeps a manually reset cursor at the start', () async {
    const settings = AppSettings(scrollMode: ScrollMode.asr);
    final connection = _FakeConnectionProvider();
    final provider = TeleprompterProvider()
      ..bindConnection(connection)
      ..loadScript('article', 'abcdef');
    addTearDown(() {
      provider.dispose();
      connection.dispose();
    });

    provider.play(settings);
    await _flushAsyncWork();
    connection.emit(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          'articleId': 'article',
          'status': 'running',
          'currentIndex': 4,
          'asrAnchorRevision': provider.asrAnchorRevision,
        },
      ),
    );
    await _flushAsyncWork();
    expect(provider.currentIndex, 4);

    provider.pause(settings);
    provider.resetToStart();
    await _flushAsyncWork();
    expect(provider.currentIndex, -1);
    expect(connection.sentSyncIndices, contains(-1));

    // 晚到的暂停状态仍携带旧位置，但状态消息不能覆盖手动游标。
    connection.emit(
      const WsMessage(
        type: WsMessageType.asrStatus,
        data: {'articleId': 'article', 'status': 'paused', 'currentIndex': 4},
      ),
    );
    await _flushAsyncWork();
    expect(provider.currentIndex, -1);

    connection.requestTypes.clear();
    provider.play(settings);
    await _flushAsyncWork();

    expect(provider.currentIndex, -1);
    final firstStart = connection.requestTypes.indexOf(WsMessageType.asrStart);
    final firstSync = connection.requestTypes.indexOf(
      WsMessageType.teleprompterSync,
    );
    expect(firstSync, greaterThanOrEqualTo(0));
    expect(firstStart, greaterThan(firstSync));
  });

  test(
    'manual seek rejects in-flight results from the previous anchor',
    () async {
      const settings = AppSettings(scrollMode: ScrollMode.asr);
      final connection = _FakeConnectionProvider();
      final provider = TeleprompterProvider()
        ..bindConnection(connection)
        ..loadScript('article', '第一句正文。第二句正文。第三句正文。');
      addTearDown(() {
        provider.dispose();
        connection.dispose();
      });
      provider.play(settings);
      await _flushAsyncWork();
      final oldRevision = provider.asrAnchorRevision;
      provider.setCurrentIndex(7);
      final newRevision = provider.asrAnchorRevision;
      expect(newRevision, greaterThan(oldRevision));
      for (final index in [2, 15]) {
        connection.emit(
          WsMessage(
            type: WsMessageType.asrResult,
            data: {
              'articleId': 'article',
              'status': 'running',
              'currentIndex': index,
              'allowBackward': true,
              'asrAnchorRevision': oldRevision,
            },
          ),
        );
      }
      await _flushAsyncWork();
      expect(provider.currentIndex, 7);
      connection.emit(
        WsMessage(
          type: WsMessageType.asrResult,
          data: {
            'articleId': 'article',
            'status': 'running',
            'currentIndex': 9,
            'asrAnchorRevision': newRevision,
            'followState': 'following',
          },
        ),
      );
      await _flushAsyncWork();
      expect(provider.currentIndex, 9);
      expect(provider.asrFollowState, 'following');
    },
  );

  test(
    'speech viewport animations never reset the recognition anchor',
    () async {
      const settings = AppSettings(
        scrollMode: ScrollMode.asr,
        autoScrollMode: AutoScrollMode.continuous,
      );
      final connection = _FakeConnectionProvider();
      final provider = TeleprompterProvider()
        ..bindConnection(connection)
        ..loadScript('article', '第一句正文。第二句正文。');
      addTearDown(() {
        provider.dispose();
        connection.dispose();
      });
      provider.play(settings);
      await _flushAsyncWork();
      connection.sentSyncIndices.clear();
      final revision = provider.asrAnchorRevision;
      provider.setViewportProgress(0.25);
      provider.setViewportProgress(0.4);
      await _flushAsyncWork();
      expect(connection.sentSyncIndices, isEmpty);
      expect(provider.asrAnchorRevision, revision);
      provider.setCurrentIndex(4);
      expect(connection.sentSyncIndices, [4]);
    },
  );

  test('repeat sentence preserves paragraph and decimal boundaries', () {
    final provider = TeleprompterProvider()
      ..loadScript('article', '<p>第一句。第二句是3.5倍。</p><p>第三段内容。</p>');
    addTearDown(provider.dispose);
    provider.setCurrentIndex(10);
    provider.restartCurrentSentence();
    expect(provider.currentIndex, 4);
    provider.setCurrentIndex(15);
    provider.restartCurrentSentence();
    expect(provider.currentIndex, 13);
    provider.setCurrentIndex(1);
    provider.restartCurrentSentence();
    expect(provider.currentIndex, 0);
  });

  test('reopening the same script keeps old speech packets obsolete', () async {
    const settings = AppSettings(scrollMode: ScrollMode.asr);
    final connection = _FakeConnectionProvider();
    final provider = TeleprompterProvider()
      ..bindConnection(connection)
      ..loadScript('article', '第一句正文。第二句正文。');
    addTearDown(() {
      provider.dispose();
      connection.dispose();
    });
    provider.play(settings);
    await _flushAsyncWork();
    provider.setCurrentIndex(8);
    final oldRevision = provider.asrAnchorRevision;
    provider.loadScript('article', '第一句正文。第二句正文。');
    provider.play(settings);
    await _flushAsyncWork();
    expect(provider.asrAnchorRevision, greaterThan(oldRevision));
    final newRevision = provider.asrAnchorRevision;
    connection.emit(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          'articleId': 'article',
          'status': 'running',
          'currentIndex': 10,
          'asrAnchorRevision': oldRevision,
        },
      ),
    );
    await _flushAsyncWork();
    expect(provider.currentIndex, -1);
    expect(provider.asrAnchorRevision, newRevision);
    connection.emit(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          'articleId': 'article',
          'status': 'running',
          'currentIndex': 3,
          'asrAnchorRevision': newRevision,
        },
      ),
    );
    await _flushAsyncWork();
    expect(provider.currentIndex, 3);
  });

  test('speech packets cannot move the cursor after switching modes', () async {
    const settings = AppSettings(scrollMode: ScrollMode.asr);
    final connection = _FakeConnectionProvider();
    final provider = TeleprompterProvider()
      ..bindConnection(connection)
      ..loadScript('article', '第一句正文。第二句正文。');
    addTearDown(() {
      provider.dispose();
      connection.dispose();
    });
    provider.play(settings);
    await _flushAsyncWork();
    provider.refreshAutoScrollSettings(const AppSettings(wpm: 0));
    connection.emit(
      WsMessage(
        type: WsMessageType.asrResult,
        data: {
          'articleId': 'article',
          'status': 'running',
          'currentIndex': 8,
          'asrAnchorRevision': provider.asrAnchorRevision,
        },
      ),
    );
    await _flushAsyncWork();
    expect(provider.currentIndex, -1);
  });

  test('a remote follower adopts the controller anchor when reopening', () {
    final connection = _RemoteConnectionProvider();
    final provider = TeleprompterProvider()..bindConnection(connection);
    addTearDown(() {
      provider.dispose();
      connection.dispose();
    });
    for (var reopen = 0; reopen < 5; reopen++) {
      provider.loadScript('article', '第一句正文。第二句正文。');
      provider.applyRemoteSync(
        currentIndex: 8,
        isPlaying: true,
        settings: const AppSettings(scrollMode: ScrollMode.asr),
        asrAnchorRevision: 1,
      );
      expect(provider.currentIndex, 8);
      expect(provider.asrAnchorRevision, 1);
    }
  });
}

Future<void> _flushAsyncWork() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

class _FakeConnectionProvider extends ConnectionProvider {
  final StreamController<WsMessage> _messages =
      StreamController<WsMessage>.broadcast();
  final List<WsMessageType> requestTypes = <WsMessageType>[];
  final List<int> sentSyncIndices = <int>[];

  @override
  bool get isConnected => true;

  @override
  bool get isLocal => true;

  @override
  List<String> get remoteDeviceIds => const <String>[];

  void emit(WsMessage message) => _messages.add(message);

  @override
  Stream<WsMessage> listenTo(WsMessageType type) {
    return _messages.stream.where((message) => message.type == type);
  }

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    requestTypes.add(type);
    await Future<void>.delayed(Duration.zero);
    return WsMessage(
      type: switch (type) {
        WsMessageType.asrStart => WsMessageType.asrStartResponse,
        WsMessageType.asrPause => WsMessageType.asrPauseResponse,
        _ => type,
      },
      data: {
        ...data,
        if (type == WsMessageType.asrStart || type == WsMessageType.asrPause)
          'articleId': 'article',
        if (type == WsMessageType.asrStart || type == WsMessageType.asrPause)
          'status': type == WsMessageType.asrStart ? 'running' : 'paused',
        if (type == WsMessageType.asrStart || type == WsMessageType.asrPause)
          'currentIndex': 4,
      },
    );
  }

  @override
  void send(WsMessage message) {
    if (message.type == WsMessageType.teleprompterSync) {
      sentSyncIndices.add((message.data['currentIndex'] as num).toInt());
    }
  }

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }
}

class _RemoteConnectionProvider extends _FakeConnectionProvider {
  @override
  bool get isLocal => false;
  @override
  bool get isRemote => true;
}
