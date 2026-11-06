import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

/// 使用真实设置服务和协议处理器，只替换磁盘与套接字；不初始化录音设备。
class ReadingEmphasisTestBackend {
  ReadingEmphasisTestBackend({AppSettings settings = const AppSettings()}) {
    preferences.values[StorageConstants.settingsKey] = jsonEncode(
      settings.toJson(),
    );
    service = SettingsService(preferences: preferences);
    connection = ReadingEmphasisTestConnection(server);
  }

  final preferences = ReadingEmphasisTestPreferences();
  final server = ReadingEmphasisTestServer();
  late final SettingsService service;
  late final ReadingEmphasisTestConnection connection;

  Future<void> init() async {
    await service.init();
    service.registerHandlers(server);
  }

  void dispose() {
    connection.dispose();
    server.dispose();
  }
}

class ReadingEmphasisTestPreferences implements AppPreferences {
  final values = <String, String>{};
  final writes = <Map<String, dynamic>>[];
  bool failWrites = false;
  bool returnFalse = false;
  bool mutateCacheBeforeFailure = false;
  Completer<void>? nextWriteGate;
  int activeWrites = 0;
  int maxActiveWrites = 0;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    final gate = nextWriteGate;
    nextWriteGate = null;
    try {
      if (gate != null) await gate.future;
      if (mutateCacheBeforeFailure) values[key] = value;
      if (failWrites) throw StateError('测试写入失败');
      if (returnFalse) return false;
      values[key] = value;
      writes.add(jsonDecode(value) as Map<String, dynamic>);
      return true;
    } finally {
      activeWrites--;
    }
  }
}

class ReadingEmphasisTestServer extends WsServer {
  final _requests = StreamController<WsRequest>.broadcast();
  final broadcasts = StreamController<WsMessage>.broadcast();
  final requestsSent = <WsMessage>[];
  final _pending = <String, Completer<WsMessage>>{};
  final _heldResponses = <WsMessage>[];
  int _requestId = 0;
  bool holdPatchResponses = false;

  @override
  Stream<WsRequest> get requests => _requests.stream;

  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
  }) {
    final id = 'test-${++_requestId}';
    final completer = Completer<WsMessage>();
    _pending[id] = completer;
    final message = WsMessage(type: type, id: id, data: data);
    requestsSent.add(message);
    _requests.add(WsRequest(clientId: 'test-client', message: message));
    return completer.future;
  }

  @override
  void respond(String clientId, WsMessage message) {
    if (holdPatchResponses &&
        message.type == WsMessageType.settingsReadingEmphasisPatchResponse) {
      _heldResponses.add(message);
      return;
    }
    _pending.remove(message.id)?.complete(message);
  }

  void releasePatchResponses() {
    holdPatchResponses = false;
    final held = List<WsMessage>.from(_heldResponses);
    _heldResponses.clear();
    for (final response in held) {
      respond('test-client', response);
    }
  }

  @override
  void broadcast(WsMessage message) => broadcasts.add(message);

  @override
  void dispose() {
    _requests.close();
    broadcasts.close();
    super.dispose();
  }
}

class ReadingEmphasisTestConnection extends ChangeNotifier
    implements ConnectionProvider {
  ReadingEmphasisTestConnection(this.server) {
    _bindMessages();
  }

  ReadingEmphasisTestServer server;
  final _messages = StreamController<WsMessage>.broadcast();
  StreamSubscription<WsMessage>? _subscription;
  final sentMessages = <WsMessage>[];
  bool connected = true;
  bool remote = false;
  bool retryRemoteConnection = false;

  void _bindMessages() {
    _subscription?.cancel();
    _subscription = server.broadcasts.stream.listen(_messages.add);
  }

  void reconnectTo(ReadingEmphasisTestServer next) {
    server = next;
    _bindMessages();
    connected = true;
    notifyListeners();
  }

  void disconnectForRetry() {
    connected = false;
    retryRemoteConnection = true;
    notifyListeners();
  }

  @override
  bool get isConnected => connected;
  @override
  bool get isLocal => !remote;
  @override
  bool get isRemote => remote;
  @override
  bool get canRetryRemoteConnection => retryRemoteConnection;
  @override
  String? get clientId => 'test-client';

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) => server.request(type, data: data);

  @override
  void send(WsMessage message) => sentMessages.add(message);

  @override
  Stream<WsMessage> listenTo(WsMessageType type) =>
      _messages.stream.where((message) => message.type == type);

  @override
  void dispose() {
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
