import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/pages/teleprompter_page.dart';
import 'package:storm_teleprompter_plus/providers/article_provider.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/widgets/settings/reading_annotation_appearance_dialog.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';

import 'support/reading_ink_test_utils.dart';

class _LocalConnection extends ConnectionProvider {
  final requests = <WsMessageType>[];
  final sent = <WsMessage>[];
  @override
  bool get isConnected => true;
  @override
  bool get isLocal => true;
  @override
  bool get isRemote => false;
  @override
  bool get canRetryRemoteConnection => false;
  @override
  void send(WsMessage message) => sent.add(message);
  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    requests.add(type);
    return WsMessage(type: type, data: const {'success': true});
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final caches = tester.widgetList<ReadingEmphasisLine>(
    find.byType(ReadingEmphasisLine),
  ).map((line) => line.glyphCache.inkCache).toSet();
  for (final cache in caches) {
    await settleReadingInk(tester, cache);
  }
  await tester.pumpAndSettle();
}

Future<({TeleprompterProvider teleprompter, _LocalConnection connection})> _open(
  WidgetTester tester,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const windowChannel = MethodChannel('window_manager');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'isFullScreen' || call.method == 'isMaximized') {
          return false;
        }
        return null;
      });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(windowChannel, null));
  final settings = SettingsProvider();
  final connection = _LocalConnection();
  final articles = ArticleProvider();
  final article = Article(
    id: 'modal-shortcuts', title: '对话框快捷键',
    content: '<p>把知识讲清楚，让观众听得懂。</p>',
    createdAt: DateTime(2026), updatedAt: DateTime(2026),
    annotations: const [ReadingAnnotation(
      id: 'cue', text: '重读',
      ranges: [AnnotationRange(start: 3, end: 6, quote: '讲清楚')],
    )],
    teleprompterSettings: const AppSettings(fontSize: 40, wpm: 0, autoHideUI: false).toTeleprompterMap(),
  );
  final teleprompter = TeleprompterProvider()..loadScript(article.id, article.content);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<TeleprompterProvider>.value(value: teleprompter),
      ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
      ChangeNotifierProvider<ArticleProvider>.value(value: articles),
    ],
    child: MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => TeleprompterPage(article: article, persistArticleSettings: false),
        )),
        child: const Text('打开提词'),
      ),
    ))),
  ));
  await tester.tap(find.text('打开提词'));
  await _settle(tester);
  addTearDown(() async {
    final caches = tester.widgetList<ReadingEmphasisLine>(find.byType(ReadingEmphasisLine))
        .map((line) => line.glyphCache.inkCache).toSet();
    await tester.pumpWidget(const SizedBox.shrink());
    for (final cache in caches) {
      await settleReadingInk(tester, cache);
    }
    await tester.pumpAndSettle();
    teleprompter.dispose();
    settings.dispose();
    connection.dispose();
    articles.dispose();
  });
  return (teleprompter: teleprompter, connection: connection);
}

void main() {
  testWidgets('外观对话框拦住播放快捷键，退出键只取消对话框且仍可正常离开提词', (tester) async {
    final session = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('playback-annotation-appearance')));
    await _settle(tester);
    expect(find.byType(ReadingAnnotationAppearanceDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('annotation-size-slider')));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(session.teleprompter.isPlaying, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byType(ReadingAnnotationAppearanceDialog), findsNothing);
    expect(find.byType(TeleprompterPage), findsOneWidget);
    expect(session.connection.requests, isNot(contains(WsMessageType.teleprompterEndSession)));
    // 退出键没有提前把播放页置为退出中；下一次退出能够完成整个会话。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byType(TeleprompterPage), findsNothing);
    expect(session.connection.requests.where((type) => type == WsMessageType.teleprompterEndSession), hasLength(1));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('空格按下后打开对话框再松开，不会让后续播放快捷键失效', (tester) async {
    final session = await _open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(session.teleprompter.isPlaying, isTrue);
    await tester.tap(find.byKey(const ValueKey('playback-annotation-appearance')));
    await _settle(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.tap(find.text('取消'));
    await _settle(tester);
    // The production key debounce uses the real wall clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(session.teleprompter.isPlaying, isFalse);
    expect(session.connection.requests, isNot(contains(WsMessageType.teleprompterEndSession)));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
