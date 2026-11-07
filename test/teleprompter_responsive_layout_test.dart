import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/pages/teleprompter_page.dart';
import 'package:storm_teleprompter_plus/providers/article_provider.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/services/asr_service.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_text_layer.dart';

class _LayoutConnection extends ConnectionProvider {
  final messages = StreamController<WsMessage>.broadcast();
  Completer<WsMessage>? preparation;
  int startRequests = 0;
  int pauseRequests = 0;

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (type == WsMessageType.asrStart && preparation != null) {
      startRequests++;
      return preparation!.future;
    }
    if (type == WsMessageType.asrPause) {
      pauseRequests++;
      return WsMessage(
        type: WsMessageType.asrPauseResponse,
        data: {
          'success': true,
          'articleId': 'responsive-layout',
          'status': 'paused',
        },
      );
    }
    return WsMessage(type: type, data: {'success': true});
  }

  @override
  bool get isConnected => true;
  @override
  bool get isLocal => true;
  @override
  List<String> get remoteDeviceIds => const [];
  @override
  Stream<WsMessage> listenTo(WsMessageType type) =>
      messages.stream.where((message) => message.type == type);
  @override
  void send(WsMessage message) {}
  @override
  void dispose() {
    messages.close();
    super.dispose();
  }
}

class _PageHarness {
  final WidgetTester tester;
  final settings = SettingsProvider();
  final teleprompter = TeleprompterProvider();
  final connection = _LayoutConnection();
  final articles = ArticleProvider();
  final captureKey = GlobalKey();
  final article = Article(
    id: 'responsive-layout',
    title: '混合字号与阅读区测试',
    content:
        '<p><span style="font-size: 128px">大字重点</span>正常正文。</p>' +
        List.filled(25, '<p>中文提词阅读位置稳定，文字和工具栏各自占位。</p>').join(),
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  _PageHarness(this.tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      teleprompter.dispose();
      settings.dispose();
      connection.dispose();
      articles.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> init() async {
    SharedPreferences.setMockInitialValues({});
    await settings.setFullScreenMode(false);
    await settings.toggleAutoHideUI();
    await settings.setWpm(0);
    settings.applyRemoteTeleprompterSettings(
      settings.mergedSettings.copyWith(currentCharScale: 1.15).toJson(),
    );
    settings.clearArticleOverrides(notify: false);
    teleprompter.bindConnection(connection);
    teleprompter.loadScript(article.id, article.content);
    teleprompter.setCurrentIndex(1);
    teleprompter.play(settings.mergedSettings);
    teleprompter.pause(settings.mergedSettings);
  }

  Future<void> show(Size size, {double textScale = 1, double dpr = 1}) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<TeleprompterProvider>.value(
            value: teleprompter,
          ),
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          ChangeNotifierProvider<ArticleProvider>.value(value: articles),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: TeleprompterPage(
              article: article,
              persistArticleSettings: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TeleprompterTextLayerState get layer => tester
      .state<TeleprompterTextLayerState>(find.byType(TeleprompterTextLayer));
  TeleprompterTextLayer get layerWidget =>
      tester.widget<TeleprompterTextLayer>(find.byType(TeleprompterTextLayer));
  Rect get viewport => tester.getRect(
    find.byKey(const ValueKey('teleprompter-reading-viewport')),
  );
  Rect get currentRow => layer.debugCurrentRowRect!.shift(
    tester.getTopLeft(find.byType(TeleprompterTextLayer)),
  );

  void expectSeparateRegions() {
    final header = tester.getRect(
      find.byKey(const ValueKey('teleprompter-header')),
    );
    final footer = tester.getRect(
      find.byKey(const ValueKey('teleprompter-footer')),
    );
    final label = tester.getRect(
      find.byKey(const ValueKey('reading-area-label')),
    );
    expect(header.bottom, lessThanOrEqualTo(label.top + 0.01));
    expect(label.bottom, lessThanOrEqualTo(viewport.top + 0.01));
    expect(viewport.bottom, lessThanOrEqualTo(footer.top + 0.01));
    expect(viewport.height, greaterThan(0));
    expect(currentRow.top, greaterThanOrEqualTo(viewport.top - 0.5));
    expect(currentRow.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
    expect(currentRow.left, greaterThanOrEqualTo(viewport.left));
    expect(currentRow.right, lessThanOrEqualTo(viewport.right));
    expect(tester.takeException(), isNull);
  }
}

void main() {
  const cases = [
    (size: Size(320, 480), scale: 1.0, dpr: 1.0),
    (size: Size(390, 680), scale: 2.0, dpr: 1.0),
    (size: Size(640, 240), scale: 1.5, dpr: 1.0),
    (size: Size(960, 540), scale: 1.0, dpr: 1.5),
    (size: Size(1920, 1080), scale: 1.0, dpr: 1.0),
    (size: Size(2560, 1440), scale: 1.0, dpr: 1.5),
    (size: Size(280, 120), scale: 2.0, dpr: 1.0),
  ];
  for (final config in cases) {
    testWidgets('实际页面独立占位且完整容纳放大行 ${config.size} ${config.scale}', (
      tester,
    ) async {
      final harness = _PageHarness(tester);
      await harness.init();
      await harness.show(config.size, textScale: config.scale, dpr: config.dpr);
      harness.expectSeparateRegions();
      expect(harness.settings.mergedSettings.fontSize, 64);
      final glyph = tester.widget<ReadingEmphasisLine>(
        find.byType(ReadingEmphasisLine).first,
      );
      expect(glyph.geometry.fontScale, lessThanOrEqualTo(1));
      if (config.size.height >= 1080) expect(glyph.geometry.fontScale, 1);
    });
  }

  testWidgets('短窗适配后音量事件与逐字推进复用整篇测量缓存', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.show(const Size(640, 240), textScale: 1.5);
    final measured = harness.layer.debugMetricsBuildCount;
    final line = tester.widget<ReadingEmphasisLine>(
      find.byType(ReadingEmphasisLine).first,
    );
    expect(line.geometry.fontScale, lessThan(1));
    for (var index = 20; index < 50; index++) {
      harness.connection.messages.add(
        WsMessage(
          type: WsMessageType.asrResult,
          data: {
            'articleId': harness.article.id,
            'status': 'running',
            'rms': index / 100,
          },
        ),
      );
      harness.teleprompter.setCurrentIndex(index);
      await tester.pump(const Duration(milliseconds: 16));
      expect(harness.layer.debugMetricsBuildCount, measured);
    }
    expect(harness.teleprompter.rms, 0.49);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏显隐保持当前字屏幕坐标，窗口重排仍定位同一字符', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    harness.teleprompter.setCurrentIndex(70);
    await harness.show(const Size(1200, 900));
    final before = harness.currentRow.center.dy;
    final index = harness.teleprompter.currentIndex;
    harness.teleprompter.toggleControls();
    await tester.pumpAndSettle();
    expect(harness.currentRow.center.dy, closeTo(before, 0.5));
    harness.teleprompter.toggleControls();
    await tester.pumpAndSettle();
    expect(harness.currentRow.center.dy, closeTo(before, 0.5));
    await harness.show(const Size(320, 480), textScale: 1.5);
    harness.expectSeparateRegions();
    expect(harness.teleprompter.currentIndex, index);
    await harness.show(const Size(1920, 1080), dpr: 1.5);
    harness.expectSeparateRegions();
    expect(harness.teleprompter.currentIndex, index);
  });

  testWidgets('窗口高度调整和工具栏显隐保持连续模式的阅读锚点', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.settings.toggleAutoScrollMode();
    await harness.show(const Size(1000, 800));
    harness.layerWidget.scrollController.jumpTo(1200);
    await tester.pump();
    final anchor = harness.layer.rawIndexAtViewport();
    harness.teleprompter.toggleControls();
    await tester.pumpAndSettle();
    expect(harness.layer.rawIndexAtViewport(), anchor);
    await harness.show(const Size(1000, 1000));
    expect(harness.layer.rawIndexAtViewport(), anchor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('语音错误和准备进度占用底部区域，长提示不盖住正文', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.settings.setScrollMode(ScrollMode.asr);
    await harness.show(const Size(600, 500));
    harness.connection.messages.add(
      WsMessage(
        type: WsMessageType.asrStatus,
        data: {
          'articleId': harness.article.id,
          'status': 'error',
          'error': '语音文件校验失败，请重新准备模型后重试。' * 8,
        },
      ),
    );
    await tester.pumpAndSettle();
    final footer = tester.getRect(
      find.byKey(const ValueKey('teleprompter-footer')),
    );
    expect(footer.top, greaterThanOrEqualTo(harness.viewport.bottom));
    expect(find.textContaining('语音文件校验失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    harness.connection.preparation = Completer<WsMessage>();
    harness.teleprompter.play(harness.settings.mergedSettings);
    await tester.pump();
    harness.connection.messages.add(
      WsMessage(
        type: WsMessageType.asrStatus,
        data: {
          'articleId': harness.article.id,
          'status': 'loading',
          'message': '正在校验默认中文模型，已完成 80%',
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在校验默认中文模型，已完成 80%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    harness.teleprompter.pause(harness.settings.mergedSettings);
    harness.connection.preparation!.complete(
      WsMessage(
        type: WsMessageType.asrStartResponse,
        data: {'success': true, 'status': 'running'},
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('首次安装尚无默认模型时点击语音进入后端准备流程', (tester) async {
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('bk_fresh_layout_'),
    ))!;
    appDataDirectoryOverride = Directory('${temporary.path}/app_data');
    addTearDown(() async {
      appDataDirectoryOverride = null;
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    expect(
      await tester.runAsync(
        () => AsrService.instance.isModelDownloaded(
          AppSettings.defaultAsrModelId,
        ),
      ),
      isFalse,
    );
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.show(const Size(1000, 700));
    await tester.tap(find.text('语音'));
    await tester.pumpAndSettle();
    expect(harness.settings.mergedSettings.scrollMode, ScrollMode.asr);
    expect(harness.settings.settings.asrModelId, AppSettings.defaultAsrModelId);
    expect(find.text('需要语音识别模型'), findsNothing);
    harness.connection.preparation = Completer<WsMessage>();
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(harness.connection.startRequests, 1);
    expect(harness.teleprompter.isAsrLoading, isTrue);
    harness.teleprompter.pause(harness.settings.mergedSettings);
    harness.connection.preparation!.complete(
      WsMessage(
        type: WsMessageType.asrStartResponse,
        data: {'success': true, 'status': 'running'},
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.teleprompter.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('准备超过自动隐藏时间仍显示进度且可点击暂停取消', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.settings.toggleAutoHideUI();
    await harness.settings.setScrollMode(ScrollMode.asr);
    await harness.show(const Size(1000, 700));
    harness.connection.preparation = Completer<WsMessage>();
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    harness.connection.messages.add(
      WsMessage(
        type: WsMessageType.asrStatus,
        data: {
          'articleId': harness.article.id,
          'status': 'loading',
          'message': '正在恢复中文语音模型，已完成 20%',
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(harness.teleprompter.controlsVisible, isFalse);
    expect(find.text('正在恢复中文语音模型，已完成 20%'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    final beforePause = harness.connection.pauseRequests;
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();
    expect(harness.teleprompter.isPlaying, isFalse);
    expect(harness.connection.pauseRequests, greaterThan(beforePause));
    harness.connection.preparation!.complete(
      WsMessage(
        type: WsMessageType.asrStartResponse,
        data: {'success': true, 'status': 'running'},
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.teleprompter.isPlaying, isFalse);
    expect(find.text('正在恢复中文语音模型，已完成 20%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅读框实际像素只在侧边距内，不划过文字列', (tester) async {
    final harness = _PageHarness(tester);
    await harness.init();
    await harness.show(const Size(1000, 800));
    final row = harness.currentRow;
    final viewport = harness.viewport;
    final counts = await tester.runAsync(() async {
      final boundary =
          harness.captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      var inText = 0;
      var inGutter = 0;
      for (var y = viewport.top.ceil(); y < viewport.bottom.floor(); y++) {
        for (var x = 0; x < image.width; x++) {
          final at = (y * image.width + x) * 4;
          if (bytes[at] < 223 ||
              bytes[at + 1] < 175 ||
              bytes[at + 1] > 185 ||
              bytes[at + 2] > 3 ||
              bytes[at + 3] < 250)
            continue;
          if (x >= row.left && x < row.right) {
            inText++;
          } else {
            inGutter++;
          }
        }
      }
      image.dispose();
      return (inText: inText, inGutter: inGutter);
    });
    expect(counts!.inGutter, greaterThan(0));
    expect(counts.inText, 0);
    expect(tester.takeException(), isNull);
  });
}
