import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/teleprompter_session.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';

void main() {
  test(
    'a stale manual position cannot replace the newest speech anchor',
    () async {
      final server = WsServer();
      final session = TeleprompterSession()..registerHandlers(server);
      final port = await server.start();
      final client = await WebSocket.connect('ws://127.0.0.1:$port');
      final messages = client
          .map((raw) => WsMessage.fromString(raw as String))
          .asBroadcastStream();
      addTearDown(() async {
        await client.close();
        await server.stop();
        session.dispose();
      });

      Future<WsMessage> request(
        String id,
        WsMessageType type,
        Map<String, dynamic> data,
      ) {
        final response = messages.firstWhere((message) => message.id == id);
        client.add(WsMessage(id: id, type: type, data: data).encode());
        return response.timeout(const Duration(seconds: 3));
      }

      await request('start', WsMessageType.teleprompterStartSession, {
        'articleId': 'synthetic-script',
      });
      final moved = await request('seek-new', WsMessageType.teleprompterSync, {
        'articleId': 'synthetic-script',
        'currentIndex': 40,
        'asrAnchorRevision': 2,
        'isPlaying': true,
      });
      expect(moved.data['asrAnchorRevision'], 2);
      expect(session.currentIndex, 40);
      final stale = await request('seek-old', WsMessageType.teleprompterSync, {
        'articleId': 'synthetic-script',
        'currentIndex': 5,
        'asrAnchorRevision': 1,
        'isPlaying': false,
      });
      expect(stale.data['currentIndex'], 40);
      expect(stale.data['asrAnchorRevision'], 2);
      expect(session.isPlaying, isTrue);
      await request('old-script', WsMessageType.teleprompterSync, {
        'articleId': 'another-script',
        'currentIndex': 2,
        'asrAnchorRevision': 3,
      });
      expect(session.currentIndex, 40);
    },
  );
}
