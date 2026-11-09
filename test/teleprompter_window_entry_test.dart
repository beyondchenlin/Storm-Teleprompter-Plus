import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/pages/teleprompter_page.dart';
import 'package:storm_teleprompter_plus/providers/article_provider.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:window_manager/window_manager.dart';

const _windowChannel = MethodChannel('window_manager');

/// 只替换原生窗口通道；页面、快捷键、导航和设置合并都走真实代码。
class _NativeWindow {
  final List<MethodCall> calls = [];
  bool fullScreen = false;
  bool maximized = false;
  String titleBar = 'normal';
  Completer<void>? fullScreenQueryGate;
  Completer<void>? enterFullScreenGate;
  Completer<void>? leaveFullScreenGate;

  List<bool> get fullScreenRequests => calls
      .where((call) => call.method == 'setFullScreen')
      .map((call) => (call.arguments as Map)['isFullScreen'] as bool)
      .toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'isFullScreen':
        await fullScreenQueryGate?.future;
        return fullScreen;
      case 'isMaximized':
        return maximized;
      case 'setFullScreen':
        final next = (call.arguments as Map)['isFullScreen'] as bool;
        await (next ? enterFullScreenGate : leaveFullScreenGate)?.future;
        fullScreen = next;
      case 'unmaximize':
        maximized = false;
      case 'maximize':
        maximized = true;
      case 'setTitleBarStyle':
        titleBar = (call.arguments as Map)['titleBarStyle'] as String;
    }
    return null;
  }
}

class _RemoteConnection extends ConnectionProvider {
  @override
  bool get isRemote => true;
  @override
  bool get isLocal => false;
  @override
  bool get isConnected => true;
  @override
  bool get canRetryRemoteConnection => false;
}

class _TestSession {
  final SettingsProvider settings;
  final TeleprompterProvider teleprompter;
  final ConnectionProvider connection;
  final ArticleProvider articles;

  _TestSession(
    this.settings,
    this.teleprompter,
    this.connection,
    this.articles,
  );

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleWindow(tester);
    teleprompter.dispose();
    settings.dispose();
    connection.dispose();
    articles.dispose();
  }
}

Future<void> _settleWindow(WidgetTester tester) async {
  await tester.pump();
  // 原生全屏切换有 50 毫秒标题栏过渡；它自身不会主动请求下一帧。
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

Future<_TestSession> _openTeleprompter(
  WidgetTester tester,
  _NativeWindow window, {
  bool savedFullScreen = false,
  bool legacyArticleFullScreen = false,
  bool remote = false,
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_windowChannel, window.handle);
  final settings = SettingsProvider();
  await settings.setFullScreenMode(savedFullScreen);
  final article = Article(
    id: 'window-entry-test',
    title: '窗口入口测试',
    content: '这是一段测试正文。\n这是下一段正文。',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    teleprompterSettings: legacyArticleFullScreen
        ? {'fullScreenMode': true, 'fontSize': 64.0}
        : null,
  );
  final teleprompter = TeleprompterProvider()
    ..loadScript(article.id, article.content);
  final connection = remote ? _RemoteConnection() : ConnectionProvider();
  final articles = ArticleProvider();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<TeleprompterProvider>.value(value: teleprompter),
        ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
        ChangeNotifierProvider<ArticleProvider>.value(value: articles),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TeleprompterPage(
                    article: article,
                    persistArticleSettings: false,
                  ),
                ),
              ),
              child: const Text('打开提词'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开提词'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  if (settle) await _settleWindow(tester);
  return _TestSession(settings, teleprompter, connection, articles);
}

void _windowsTest(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(
    description,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowChannel, null);
  });

  test('全屏默认关闭；旧显式值及其他个性化设置不被迁移重置', () {
    expect(const AppSettings().fullScreenMode, isFalse);
    expect(AppSettings.fromJson({}).fullScreenMode, isFalse);
    final legacy = AppSettings.fromJson({
      'fullScreenMode': true,
      'fontSize': 72.0,
      'mirrorMode': true,
    });
    final restored = AppSettings.fromJson(legacy.toJson());
    expect(restored.fullScreenMode, isTrue);
    expect(restored.fontSize, 72);
    expect(restored.mirrorMode, isTrue);
  });

  _windowsTest('本地旧全局和稿件全屏值不触发自动全屏，也不重置普通窗口尺寸', (tester) async {
    final window = _NativeWindow();
    final session = await _openTeleprompter(
      tester,
      window,
      savedFullScreen: true,
      legacyArticleFullScreen: true,
    );
    expect(find.byTooltip('全屏'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsNothing);
    expect(window.fullScreenRequests, isEmpty);
    expect(
      window.calls.map((call) => call.method),
      isNot(contains('unmaximize')),
    );
    expect(
      window.calls.map((call) => call.method),
      isNot(
        anyOf(
          contains('setBounds'),
          contains('setSize'),
          contains('setPosition'),
        ),
      ),
    );
    expect(session.settings.settings.fullScreenMode, isTrue);
    expect(session.settings.mergedSettings.fontSize, 64);
    expect(window.titleBar, 'normal');
    expect(tester.takeException(), isNull);
    await session.close(tester);
  });

  _windowsTest('继承原生全屏和最大化时先退全屏再还原普通窗', (tester) async {
    final window = _NativeWindow()
      ..fullScreen = true
      ..maximized = true;
    final session = await _openTeleprompter(tester, window);
    expect(window.fullScreen, isFalse);
    expect(window.maximized, isFalse);
    expect(window.fullScreenRequests, [false]);
    final methods = window.calls.map((call) => call.method).toList();
    expect(
      methods.indexOf('setFullScreen'),
      lessThan(methods.indexOf('unmaximize')),
    );
    expect(window.titleBar, 'normal');
    expect(find.byTooltip('全屏'), findsOneWidget);
    await session.close(tester);
  });

  _windowsTest('手动全屏按钮仍可放大与还原，退出后再次进入仍为普通窗', (tester) async {
    final window = _NativeWindow();
    final session = await _openTeleprompter(
      tester,
      window,
      savedFullScreen: true,
    );
    await tester.tap(find.byTooltip('全屏'));
    await _settleWindow(tester);
    expect(window.fullScreen, isTrue);
    expect(window.titleBar, 'hidden');
    await tester.tap(find.byTooltip('退出全屏'));
    await _settleWindow(tester);
    expect(window.fullScreen, isFalse);
    expect(window.titleBar, 'normal');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleWindow(tester);
    expect(find.byType(TeleprompterPage), findsNothing);
    await tester.tap(find.text('打开提词'));
    await _settleWindow(tester);
    expect(find.byTooltip('全屏'), findsOneWidget);
    expect(window.fullScreenRequests, [true, false]);
    await session.close(tester);
  });

  _windowsTest('全屏快捷键和退出快捷键保持工作且恢复标题栏', (tester) async {
    final window = _NativeWindow();
    final session = await _openTeleprompter(tester, window);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await _settleWindow(tester);
    expect(window.fullScreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleWindow(tester);
    expect(window.fullScreen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await _settleWindow(tester);
    expect(window.fullScreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleWindow(tester);
    expect(find.byType(TeleprompterPage), findsNothing);
    expect(window.fullScreen, isFalse);
    expect(window.titleBar, 'normal');
    expect(tester.takeException(), isNull);
    await session.close(tester);
  });

  _windowsTest('初始化未结束时手动全屏按顺序执行，不被晚到的窗口还原覆盖', (tester) async {
    final gate = Completer<void>();
    final window = _NativeWindow()
      ..fullScreen = true
      ..maximized = true
      ..fullScreenQueryGate = gate;
    final session = await _openTeleprompter(tester, window, settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(window.fullScreenRequests, isEmpty);
    gate.complete();
    await _settleWindow(tester);
    expect(window.fullScreenRequests, [false, true]);
    expect(window.fullScreen, isTrue);
    expect(window.maximized, isFalse);
    await session.close(tester);
    expect(window.fullScreen, isFalse);
  });

  _windowsTest('全屏过渡时立即退出，不会在离开页面后迟到地进入全屏', (tester) async {
    final window = _NativeWindow();
    final session = await _openTeleprompter(tester, window);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleWindow(tester);
    expect(find.byType(TeleprompterPage), findsNothing);
    expect(window.fullScreenRequests, [false]);
    expect(window.fullScreen, isFalse);
    expect(window.titleBar, 'normal');
    expect(tester.takeException(), isNull);
    await session.close(tester);
  });

  _windowsTest('入口查询尚未返回时销毁页面，不再操作原生窗口', (tester) async {
    final gate = Completer<void>();
    final window = _NativeWindow()
      ..fullScreen = true
      ..maximized = true
      ..fullScreenQueryGate = gate;
    final session = await _openTeleprompter(tester, window, settle: false);
    await session.close(tester);
    gate.complete();
    await _settleWindow(tester);
    expect(window.fullScreenRequests, isEmpty);
    expect(
      window.calls.map((call) => call.method),
      isNot(contains('unmaximize')),
    );
    expect(
      window.calls.map((call) => call.method),
      isNot(contains('setTitleBarStyle')),
    );
    expect(tester.takeException(), isNull);
  });

  _windowsTest('入口退全屏已开始时销毁，仍完成正常标题栏清理', (tester) async {
    final gate = Completer<void>();
    final window = _NativeWindow()
      ..fullScreen = true
      ..titleBar = 'hidden'
      ..leaveFullScreenGate = gate;
    final session = await _openTeleprompter(tester, window, settle: false);
    expect(window.fullScreenRequests, [false]);
    await session.close(tester);
    gate.complete();
    await _settleWindow(tester);
    expect(window.fullScreen, isFalse);
    expect(window.titleBar, 'normal');
    expect(tester.takeException(), isNull);
  });

  _windowsTest('旧页清理先于新页手动全屏，跨页面窗口操作也不会交错', (tester) async {
    final gate = Completer<void>();
    final window = _NativeWindow()..enterFullScreenGate = gate;
    final previous = await _openTeleprompter(tester, window);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await _settleWindow(tester);
    expect(window.fullScreenRequests, [true]);
    await previous.close(tester);
    final next = await _openTeleprompter(tester, window, settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(window.fullScreenRequests, [true]);
    gate.complete();
    await _settleWindow(tester);
    expect(window.fullScreenRequests, [true, false, true]);
    expect(window.fullScreen, isTrue);
    expect(window.titleBar, 'hidden');
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    await next.close(tester);
  });

  _windowsTest('进入后允许用户手动最大化，重建和设置变化不强行还原', (tester) async {
    final window = _NativeWindow();
    final session = await _openTeleprompter(tester, window);
    await windowManager.maximize();
    await session.settings.setAutoSpeed(20);
    await _settleWindow(tester);
    expect(window.maximized, isTrue);
    expect(
      window.calls.map((call) => call.method),
      isNot(contains('unmaximize')),
    );
    expect(window.fullScreenRequests, isEmpty);
    await session.close(tester);
  });

  _windowsTest('远程接收端保留旧全屏偏好，不被本地入口还原策略干扰', (tester) async {
    final window = _NativeWindow()..maximized = true;
    final session = await _openTeleprompter(
      tester,
      window,
      remote: true,
      savedFullScreen: true,
    );
    expect(window.fullScreenRequests, [true]);
    expect(window.fullScreen, isTrue);
    expect(
      window.calls.map((call) => call.method),
      isNot(contains('unmaximize')),
    );
    await session.close(tester);
    expect(window.fullScreen, isFalse);
    expect(window.titleBar, 'normal');
  });
}