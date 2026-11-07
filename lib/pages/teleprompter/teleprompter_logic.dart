part of '../teleprompter_page.dart';

/// 提词器页面逻辑 mixin
///
/// 包含全屏控制、滚轮调速、滚动进度和会话退出等页面逻辑。
mixin TeleprompterPageLogic<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  final ScrollController scrollController = ScrollController();
  final GlobalKey<TeleprompterTextLayerState> textLayerKey =
      GlobalKey<TeleprompterTextLayerState>();
  bool isFullScreen = false;

  TeleprompterProvider? _teleprompterProvider;
  SettingsProvider? _settingsProvider;
  ConnectionProvider? _connectionProvider;
  ArticleProvider? _articleProvider;
  _WindowEventListener? _windowListener;
  bool _remoteSessionEndSent = false;
  bool _viewportProgressUpdateScheduled = false;
  double? _pendingViewportProgress;
  Timer? _articleSettingsSaveTimer;
  // 所有提词页共享一个原生窗口，旧页退出清理必须先于新页窗口操作。
  static Future<void>? _windowTransition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _teleprompterProvider = context.read<TeleprompterProvider>();
    _settingsProvider = context.read<SettingsProvider>();
    _connectionProvider = context.read<ConnectionProvider>();
    _articleProvider = context.read<ArticleProvider>();
    _setupScrollListener();

    // 加载稿件特有的提词器设置覆盖
    final article = (widget as TeleprompterPage).article;
    _settingsProvider!.loadArticleOverrides(
      article.teleprompterSettings,
      notify: false,
    );
    _settingsProvider!.addListener(_scheduleArticleSettingsSave);

    // 监听窗口最大化/还原事件，确保标题栏正确显示
    if (_isDesktop) {
      _initWindowListener();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_connectionProvider!.isRemote) {
        // 接收端保留自身的投屏偏好，不修改远程会话协议。
        if (_settingsProvider!.mergedSettings.fullScreenMode) {
          unawaited(enterFullScreen());
        }
      } else if (_isDesktop) {
        // 本地每次进入都使用普通窗口，不能让旧全局/稿件的 true 值
        // 继续触发全屏，也不能继承首页已经最大化的原生窗口状态。
        unawaited(_prepareWindowedEntry());
      }
    });
  }

  /// 初始化窗口事件监听
  void _initWindowListener() async {
    try {
      await windowManager.ensureInitialized();
      if (!mounted) return;
      _windowListener = _WindowEventListener(this);
      windowManager.addListener(_windowListener!);
    } catch (e) {
      debugPrint('[WindowListener] 初始化失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsProvider?.removeListener(_scheduleArticleSettingsSave);
    _articleSettingsSaveTimer?.cancel();
    if (_windowListener != null) {
      windowManager.removeListener(_windowListener!);
    }
    // 退出时若为全屏则退出，但需避免在 dispose 中调用 setState
    if (isFullScreen) {
      unawaited(exitFullScreen(updateState: false));
    }
    // 保存稿件覆盖设置到稿件
    unawaited(_saveArticleOverrides());
    _sendRemoteSessionEndIfMaster();
    // 清除稿件覆盖
    _settingsProvider?.clearArticleOverrides(notify: false);
    scrollController.dispose();
    // 退出时停止提词器（不触发 notifyListeners，避免 defunct 异常）
    _teleprompterProvider?.stopAll();
    super.dispose();
  }

  /// 将稿件覆盖设置保存回稿件
  void _scheduleArticleSettingsSave() {
    final connection = _connectionProvider;
    if (connection == null || connection.isRemote || !connection.isConnected) {
      return;
    }
    _articleSettingsSaveTimer?.cancel();
    _articleSettingsSaveTimer = Timer(
      TeleprompterConstants.articleSettingsSaveDebounce,
      () => unawaited(_saveArticleOverrides()),
    );
  }

  Future<void> _saveArticleOverrides() async {
    if (!(widget as TeleprompterPage).persistArticleSettings) return;
    final connection = _connectionProvider;
    if (connection == null) return;
    if (connection.isRemote || connection.canRetryRemoteConnection) return;

    final overrides = _settingsProvider?.articleOverrides;
    if (overrides != null && overrides.isNotEmpty) {
      try {
        final article = (widget as TeleprompterPage).article;
        await _articleProvider?.updateArticleTeleprompterSettings(
          article.id,
          Map<String, dynamic>.from(overrides),
        );
      } catch (e) {
        debugPrint('[TeleprompterLogic] 保存稿件设置失败: $e');
      }
    }
  }

  Map<String, dynamic> _sessionEndData() {
    return {'articleId': (widget as TeleprompterPage).article.id};
  }

  bool _canEndRemoteSession(ConnectionProvider connection) {
    return !_remoteSessionEndSent &&
        connection.isLocal &&
        connection.isConnected;
  }

  void _sendRemoteSessionEndIfMaster() {
    final connection = _connectionProvider;
    if (connection == null) return;
    if (!_canEndRemoteSession(connection)) return;
    _remoteSessionEndSent = true;
    connection.send(
      WsMessage(
        type: WsMessageType.teleprompterEndSession,
        data: _sessionEndData(),
      ),
    );
  }

  Future<void> _endRemoteSessionIfMaster() async {
    final connection = _connectionProvider;
    if (connection == null) return;
    if (!_canEndRemoteSession(connection)) return;
    _remoteSessionEndSent = true;
    try {
      await connection.request(
        WsMessageType.teleprompterEndSession,
        data: _sessionEndData(),
        timeout: const Duration(seconds: 2),
      );
    } catch (e) {
      debugPrint('[TeleprompterLogic] 结束远程会话确认失败: $e');
      connection.send(
        WsMessage(
          type: WsMessageType.teleprompterEndSession,
          data: _sessionEndData(),
        ),
      );
    }
  }

  // ─── 全屏控制 ──────────────────────────────────────────

  bool get _isDesktop {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  /// 原生窗口操作串行执行，避免首次还原和快速手动切换互相覆盖。
  Future<void> _queueWindowTransition(Future<void> Function() transition) {
    final pending = _windowTransition;
    final next =
        (pending == null
                ? Future<void>.sync(transition)
                : pending.then((_) => transition()))
            .catchError((Object error, StackTrace stack) {
              debugPrint('[WindowTransition] 窗口切换失败: $error');
            });
    _windowTransition = next;
    return next.whenComplete(() {
      // 空闲后释放已完成的异步链，不让下一次会话依附旧页面的执行环境。
      if (identical(_windowTransition, next)) _windowTransition = null;
    });
  }

  Future<void> _prepareWindowedEntry() => _queueWindowTransition(() async {
    if (!mounted) return;
    var restoreTitleBar = false;
    try {
      await windowManager.ensureInitialized();
      if (!mounted) return;
      final wasFullScreen = await windowManager.isFullScreen();
      if (!mounted) return;
      if (wasFullScreen) {
        restoreTitleBar = true;
        await windowManager.setFullScreen(false);
      }
      if (!mounted) return;
      final wasMaximized = await windowManager.isMaximized();
      if (!mounted) return;
      if (wasMaximized) {
        restoreTitleBar = true;
        await windowManager.unmaximize();
      }
      // 交由系统恢复普通窗口的既有尺寸与位置，不覆盖用户窗口大小。
      restoreTitleBar = true;
    } catch (e) {
      debugPrint('[WindowEntry] 还原普通窗口失败: $e');
    } finally {
      // 已改变原生模式后即使页面离开，也要完成标题栏清理；仅查询
      // 尚未返回就销毁的页面则不会再发起窗口改动。
      if (restoreTitleBar) {
        try {
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        } catch (e) {
          debugPrint('[WindowEntry] 恢复标题栏失败: $e');
        }
      }
    }
  });

  Future<void> enterFullScreen() {
    if (isFullScreen || !mounted) return Future<void>.value();
    setState(() => isFullScreen = true);

    return _queueWindowTransition(() async {
      if (!mounted || !isFullScreen) return;
      if (_isDesktop) {
        try {
          // 先隐藏标题栏，再进入全屏，顺序很重要。
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (!mounted || !isFullScreen) return;
          await windowManager.setFullScreen(true);
        } catch (e) {
          debugPrint('[FullScreen] 全屏失败，降级处理: $e');
          if (!mounted || !isFullScreen) return;
          try {
            await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          } catch (_) {}
          if (!mounted || !isFullScreen) return;
          try {
            await windowManager.setFullScreen(true);
          } catch (_) {}
        }
      } else if (!kIsWeb) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        if (!mounted || !isFullScreen) return;
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  Future<void> exitFullScreen({bool updateState = true}) {
    if (!isFullScreen && updateState) return Future<void>.value();
    if (updateState && mounted) {
      setState(() => isFullScreen = false);
    } else {
      isFullScreen = false;
    }

    return _queueWindowTransition(() async {
      if (_isDesktop) {
        try {
          await windowManager.setFullScreen(false);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        } catch (e) {
          debugPrint('[FullScreen] 退出全屏失败: $e');
        }
      } else if (!kIsWeb) {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    });
  }

  void toggleFullScreen() {
    if (isFullScreen) {
      exitFullScreen();
    } else {
      enterFullScreen();
    }
  }

  // ─── 鼠标滚轮处理 ─────────────────────────────────────

  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final teleprompter = context.read<TeleprompterProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    final settings = settingsProvider.mergedSettings;
    if (context.read<ConnectionProvider>().isRemote) return;

    if (settings.scrollMode == ScrollMode.auto &&
        teleprompter.isPlaying &&
        (settings.isContinuousScroll || settings.autoSpeed != 0)) {
      // 自动模式：滚轮只调速，不滚动页面
      teleprompter.adjustSpeedByWheel(
        event.scrollDelta.dy,
        settingsProvider,
        stepMultiplier: _speedStepMultiplier(),
      );
      return;
    }

    if (settings.scrollMode == ScrollMode.auto &&
        teleprompter.isPlaying &&
        settings.autoSpeed == 0) {
      if (_speedModifierPressed()) {
        teleprompter.adjustSpeedByWheel(
          event.scrollDelta.dy,
          settingsProvider,
          stepMultiplier: _speedStepMultiplier(),
        );
        return;
      }

      final direction = event.scrollDelta.dy > 0 ? 1 : -1;
      final visualTarget = textLayerKey.currentState?.rawIndexForVisualLineMove(
        direction,
      );
      if (visualTarget != null) {
        teleprompter.setCurrentIndex(visualTarget);
      }
      return;
    }

    // 手动/ASR 模式：让滚动自然传播
  }

  int _speedStepMultiplier() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) return 10;
    if (keyboard.isShiftPressed) return 4;
    return 1;
  }

  bool _speedModifierPressed() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed || keyboard.isShiftPressed;
  }

  // ─── 手动滚动进度更新 ──────────────────────────────────

  void _setupScrollListener() {
    scrollController.addListener(_onScrollChanged);
  }

  void _onScrollChanged() {
    if (!mounted) return;
    if (!scrollController.hasClients) return;
    final maxScroll = scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    if (context.read<SettingsProvider>().mergedSettings.isContinuousScroll) {
      _scheduleViewportProgressUpdate(scrollController.offset / maxScroll);
      return;
    }
    // 扣除空气垫计算实际内容进度
    final viewportHeight = scrollController.position.viewportDimension;
    final topPad =
        textLayerKey.currentState?.topPadding ??
        viewportHeight * (TeleprompterConstants.topPaddingVh / 100);
    final bottomPad =
        textLayerKey.currentState?.bottomPadding ??
        viewportHeight * (TeleprompterConstants.bottomPaddingVh / 100);
    final contentExtent = maxScroll - topPad - bottomPad;
    if (contentExtent <= 0) {
      _scheduleViewportProgressUpdate(0.0);
      return;
    }
    final contentOffset = (scrollController.offset - topPad).clamp(
      0.0,
      contentExtent,
    );
    final progress = (contentOffset / contentExtent).clamp(0.0, 1.0);
    _scheduleViewportProgressUpdate(progress);
  }

  void _scheduleViewportProgressUpdate(double progress) {
    _pendingViewportProgress = progress;
    if (_viewportProgressUpdateScheduled) return;
    _viewportProgressUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportProgressUpdateScheduled = false;
      if (!mounted) return;
      final value = _pendingViewportProgress;
      _pendingViewportProgress = null;
      if (value == null) return;
      context.read<TeleprompterProvider>().setViewportProgress(value);
    });
  }

  // ─── 格式化工具 ────────────────────────────────────────

  String formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  /// 当前时间格式化 (HH:mm)
  String _formatCurrentTime() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}

/// 窗口事件监听器（用于最大化/还原时恢复标题栏）
class _WindowEventListener extends WindowListener {
  final TeleprompterPageLogic state;

  _WindowEventListener(this.state);

  @override
  void onWindowMaximize() {
    if (!state.isFullScreen) {
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
  }

  @override
  void onWindowUnmaximize() {
    if (!state.isFullScreen) {
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
  }
}
