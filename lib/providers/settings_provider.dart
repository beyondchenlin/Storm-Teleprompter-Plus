import 'dart:async';

import 'package:flutter/material.dart';
import '../backend/ws_protocol.dart';
import '../models/app_settings.dart';
import 'connection_provider.dart';

/// 应用设置状态管理（前端）
///
/// 通过 WebSocket 与后端通信，管理应用设置的读取、保存。
/// 同时支持稿件级别的设置覆盖（提词器设置与应用设置分离）。
class SettingsProvider with ChangeNotifier {
  AppSettings _settings = const AppSettings();
  bool _isLoading = false;

  ConnectionProvider? _connection;
  StreamSubscription<WsMessage>? _readingEmphasisSubscription;
  final Map<String, dynamic> _pendingReadingEmphasis = {};
  final Map<String, int> _pendingReadingEmphasisVersions = {};
  Map<String, dynamic> _confirmedReadingEmphasis = const AppSettings()
      .toReadingEmphasisMap();
  Future<void> _settingsWriteTail = Future<void>.value();
  int _ordinarySettingsEditVersion = 0;
  // 只保护当前连接的待保存普通设置，旧连接的失效写入不阻止重连加载。
  final Map<int, int> _ordinarySettingsQueuedWrites = {};
  int _readingEmphasisEditVersion = 0;
  int _readingEmphasisRevision = -1;
  int _readingEmphasisConnectionGeneration = 0;
  int _readingEmphasisQueuedWrites = 0;
  int? _pendingSettingsResetVersion;
  AppSettings? _pendingSettingsResetSnapshot;
  String? _readingEmphasisSaveError;
  bool _disposed = false;

  // ─── 稿件覆盖设置 ──────────────────────────────────────
  Map<String, dynamic> _articleOverrides = {};
  bool _articleOverridesActive = false;

  VoidCallback? _connectionListener;
  AppSettings get settings => _settings;
  bool get isLoading => _isLoading;
  bool get isSavingReadingEmphasis => _readingEmphasisQueuedWrites > 0;
  String? get readingEmphasisSaveError => _readingEmphasisSaveError;

  /// 合并稿件覆盖后的设置（提词器页面使用）
  AppSettings get mergedSettings => _articleOverrides.isNotEmpty
      ? _settings.mergeOverrides(_articleOverrides)
      : _settings;

  /// 当前活跃的稿件覆盖
  Map<String, dynamic> get articleOverrides =>
      Map.unmodifiable(_articleOverrides);

  /// 绑定连接
  void bindConnection(ConnectionProvider connection) {
    if (_connection != null && _connectionListener != null) {
      _connection!.removeListener(_connectionListener!);
    }
    _readingEmphasisSubscription?.cancel();
    _connection = connection;
    _readingEmphasisRevision = -1;
    _readingEmphasisConnectionGeneration++;
    _readingEmphasisSubscription = connection
        .listenTo(WsMessageType.settingsReadingEmphasisChanged)
        .listen(_handleReadingEmphasisChanged);
    var wasConnected = connection.isConnected;
    _connectionListener = () {
      final becameConnected = connection.isConnected && !wasConnected;
      wasConnected = connection.isConnected;
      if (!connection.isConnected) {
        // 服务重启后的版本号会从零开始；远程断线保留稿件仍需重置版本。
        _readingEmphasisRevision = -1;
        _readingEmphasisConnectionGeneration++;
      }
      if (!connection.isConnected && !connection.canRetryRemoteConnection) {
        _articleOverrides = {};
        _articleOverridesActive = false;
        _isLoading = false;
        notifyListeners();
      }
      if (becameConnected) {
        // 断线期间收不到广播；每次连通后主动取回服务端的当前版本。
        unawaited(loadSettings());
      }
    };
    connection.addListener(_connectionListener!);
  }

  /// 加载稿件覆盖设置
  void loadArticleOverrides(
    Map<String, dynamic>? overrides, {
    bool notify = true,
  }) {
    final next = _settings
        .mergeOverrides(Map<String, dynamic>.from(overrides ?? const {}))
        .toTeleprompterMap();
    final unchanged =
        _articleOverridesActive && _mapEquals(_articleOverrides, next);
    _articleOverridesActive = true;
    if (unchanged) return;
    _articleOverrides = next;
    if (notify) notifyListeners();
  }

  void applyRemoteTeleprompterSettings(Map<String, dynamic> settings) {
    final readingChanged = _seedReadingEmphasisFromSession(settings);
    final next = _settings.mergeOverrides(settings).toTeleprompterMap();
    final unchanged =
        _articleOverridesActive && _mapEquals(_articleOverrides, next);
    _articleOverridesActive = true;
    if (unchanged) {
      if (readingChanged) notifyListeners();
      return;
    }
    _articleOverrides = next;
    notifyListeners();
  }

  void applyRemoteSyncedRuntimeSettings(Map<String, dynamic> settings) {
    var changed = false;
    if (settings['scrollMode'] case final String modeName) {
      final mode = ScrollMode.values.firstWhere(
        (value) => value.name == modeName,
        orElse: () => mergedSettings.scrollMode,
      );
      if (_articleOverrides['scrollMode'] != mode.name) {
        _articleOverrides['scrollMode'] = mode.name;
        changed = true;
      }
    }
    if (settings.containsKey('wpm')) {
      final value = settings['wpm'];
      if (value is num) {
        final next = value.toInt();
        if (_articleOverrides['wpm'] != next) {
          _articleOverrides['wpm'] = next;
          changed = true;
        }
      }
    }
    for (final key in ['autoScrollMode', 'pixelsPerSecond', 'showAnnotations']) {
      if (settings.containsKey(key) &&
          _articleOverrides[key] != settings[key]) {
        _articleOverrides[key] = settings[key];
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 清除稿件覆盖设置
  bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  void clearArticleOverrides({bool notify = true}) {
    if (!_articleOverridesActive && _articleOverrides.isEmpty) return;
    _articleOverridesActive = false;
    _articleOverrides = {};
    if (notify) notifyListeners();
  }

  /// 内部辅助：在当前稿件覆盖激活时写入覆盖层，否则写入全局设置
  Future<void> _setAndSave({required Map<String, dynamic> overrideData}) async {
    if (_articleOverridesActive) {
      // 播放稿件时只更新当前稿件的完整设置快照。
      _articleOverrides.addAll(overrideData);
      notifyListeners();
    } else {
      // AppSettings 是提词器字段转换的唯一入口，避免 Provider 重复维护映射。
      _settings = _settings.mergeOverrides(overrideData);
      notifyListeners();
      await _saveSettings();
    }
    _syncTeleprompterSettingsToBackend();
  }

  Future<void> setShowAnnotations(bool value) =>
      _setAndSave(overrideData: {'showAnnotations': value});

  void _syncTeleprompterSettingsToBackend() {
    final connection = _connection;
    if (connection == null || !connection.isConnected || !connection.isLocal) {
      return;
    }
    connection.send(
      WsMessage(
        type: WsMessageType.teleprompterSettingsUpdate,
        data: {'settings': mergedSettings.toSessionMap()},
      ),
    );
  }

  /// 初始化并加载设置
  Future<void> init() async {
    await loadSettings();
  }

  /// 从后端加载设置
  Future<void> loadSettings() async {
    if (_disposed) return;
    final generation = _readingEmphasisConnectionGeneration;
    final ordinaryEditVersion = _ordinarySettingsEditVersion;
    final hadOrdinaryWrites = _ordinarySettingsQueuedWrites.containsKey(
      generation,
    );
    final pendingResetAtStart = _pendingSettingsResetVersion;
    _isLoading = true;
    notifyListeners();

    try {
      if (_connection != null && _connection!.isConnected) {
        final response = await _connection!.request(WsMessageType.settingsGet);
        if (!_disposed &&
            response.type == WsMessageType.settingsGetResponse &&
            generation == _readingEmphasisConnectionGeneration) {
          final loaded = AppSettings.fromJson(
            response.data['settings'] as Map<String, dynamic>,
          );
          // 失败或排队中的重置保留完整意图；迟到的读取不能回滚新编辑。
          if (_pendingSettingsResetSnapshot case final AppSettings pending) {
            _settings = pending;
          } else if (ordinaryEditVersion == _ordinarySettingsEditVersion &&
              !hadOrdinaryWrites &&
              !_ordinarySettingsQueuedWrites.containsKey(generation) &&
              pendingResetAtStart == null) {
            _settings = loaded;
          }
          final revision = response.data['readingEmphasisRevision'];
          if (revision is int && revision >= 0) {
            _acceptReadingEmphasisSnapshot(
              loaded.toReadingEmphasisMap(),
              revision,
            );
          } else {
            _confirmedReadingEmphasis = loaded.toReadingEmphasisMap();
            _projectReadingEmphasis();
          }
        }
      }
    } catch (e) {
      debugPrint('[SettingsProvider] 加载设置失败: $e');
    } finally {
      _isLoading = false;
      _notifyReadingEmphasis();
    }
  }

  /// 保存设置到后端
  Future<void> _saveSettings() async {
    final snapshot = _settings;
    final connection = _connection;
    final generation = _readingEmphasisConnectionGeneration;
    _ordinarySettingsEditVersion++;
    _rememberPendingResetSnapshot();
    try {
      if (connection != null && connection.isConnected) {
        _ordinarySettingsQueuedWrites.update(
          generation,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        try {
          await _enqueueSettingsWrite(
            () => _writeSettingsSnapshot(connection, generation, snapshot),
          );
        } finally {
          final remaining = _ordinarySettingsQueuedWrites[generation]! - 1;
          if (remaining == 0) {
            _ordinarySettingsQueuedWrites.remove(generation);
          } else {
            _ordinarySettingsQueuedWrites[generation] = remaining;
          }
        }
      }
    } catch (e) {
      debugPrint('[SettingsProvider] 保存设置失败: $e');
    }
  }

  /// 普通设置、阅读设置和重置共用顺序；失败不阻塞后续操作。
  Future<void> _enqueueSettingsWrite(Future<void> Function() operation) {
    final write = _settingsWriteTail.then((_) => operation());
    _settingsWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  void _checkSettingsConnection(
    ConnectionProvider? connection,
    int generation,
  ) {
    if (connection == null ||
        !identical(connection, _connection) ||
        generation != _readingEmphasisConnectionGeneration ||
        !connection.isConnected) {
      throw StateError('设置服务连接已变化，请连接后重试保存');
    }
  }

  Future<void> _writeSettingsSnapshot(
    ConnectionProvider connection,
    int generation,
    AppSettings snapshot,
  ) async {
    _checkSettingsConnection(connection, generation);
    final response = await connection.request(
      WsMessageType.settingsSave,
      data: {'settings': snapshot.toJson()},
    );
    _checkSettingsConnection(connection, generation);
    if (response.type != WsMessageType.settingsSaveResponse ||
        response.data['success'] != true) {
      throw StateError(response.data['message'] as String? ?? '设置服务未确认保存');
    }
  }

  void _rememberPendingResetSnapshot() {
    if (_pendingSettingsResetVersion != null) {
      _pendingSettingsResetSnapshot = _settings;
    }
  }

  /// 四项设置始终写入全局层，不写入稿件快照，也不重载稿件或识别会话。
  Future<void> setReadingEmphasisEnabled(bool value) =>
      _setReadingEmphasis({'readingEmphasisEnabled': value});

  Future<void> setCurrentCharColor(int value) =>
      _setReadingEmphasis({'currentCharColor': value});

  Future<void> setReadCharColor(int value) =>
      _setReadingEmphasis({'readCharColor': value});

  Future<void> setCurrentCharScale(double value) =>
      _setReadingEmphasis({'currentCharScale': value});

  Future<void> _setReadingEmphasis(Map<String, dynamic> patch) async {
    final validated = AppSettings.validateReadingEmphasisPatch(patch);
    final version = ++_readingEmphasisEditVersion;
    final versions = {for (final key in validated.keys) key: version};
    _pendingReadingEmphasis.addAll(validated);
    _pendingReadingEmphasisVersions.addAll(versions);
    _projectReadingEmphasis();
    _rememberPendingResetSnapshot();
    final save = _enqueueReadingEmphasisWrite(validated, versions);
    _syncTeleprompterSettingsToBackend();
    await save;
  }

  Future<void> retryReadingEmphasisSave() async {
    _readingEmphasisSaveError = null;
    if (_pendingSettingsResetVersion != null) {
      final defaults = const AppSettings().toReadingEmphasisMap();
      final desiredSettings = _settings;
      final desired = _settings.toReadingEmphasisMap();
      final version = ++_readingEmphasisEditVersion;
      // 每次重试都有独立版本，较早的完成不能清除较新的重试意图。
      _pendingSettingsResetVersion = version;
      _pendingSettingsResetSnapshot = desiredSettings;
      _pendingReadingEmphasis.addAll(desired);
      _pendingReadingEmphasisVersions.addAll({
        for (final key in desired.keys) key: version,
      });
      // 重置失败后的新编辑仍保留；重置确认后继续保存这些更新。
      await _enqueueReadingEmphasisWrite(
        defaults,
        {
          for (final key in defaults.keys)
            if (_pendingReadingEmphasis[key] == defaults[key] &&
                _pendingReadingEmphasisVersions.containsKey(key))
              key: _pendingReadingEmphasisVersions[key]!,
        },
        resetVersion: version,
        restoreAfterReset: desiredSettings,
      );
    }
    if (_pendingReadingEmphasis.isNotEmpty) {
      await _enqueueReadingEmphasisWrite(
        Map<String, dynamic>.from(_pendingReadingEmphasis),
        Map<String, int>.from(_pendingReadingEmphasisVersions),
      );
    } else {
      _notifyReadingEmphasis();
    }
  }

  Future<void> _enqueueReadingEmphasisWrite(
    Map<String, dynamic> patch,
    Map<String, int> versions, {
    int? resetVersion,
    AppSettings? restoreAfterReset,
  }) {
    final connection = _connection;
    final generation = _readingEmphasisConnectionGeneration;
    _readingEmphasisQueuedWrites++;
    _notifyReadingEmphasis();
    return _enqueueSettingsWrite(() async {
      try {
        _checkSettingsConnection(connection, generation);
        final response = await connection!.request(
          resetVersion == null
              ? WsMessageType.settingsReadingEmphasisPatch
              : WsMessageType.settingsReset,
          data: resetVersion == null ? {'patch': patch} : const {},
        );
        _checkSettingsConnection(connection, generation);
        final expectedType = resetVersion == null
            ? WsMessageType.settingsReadingEmphasisPatchResponse
            : WsMessageType.settingsResetResponse;
        if (response.type != expectedType || response.data['success'] != true) {
          throw StateError(response.data['message'] as String? ?? '设置服务未确认保存');
        }
        final snapshot = _readingSnapshot(response.data['settings']);
        final revision =
            response.data[resetVersion == null
                ? 'revision'
                : 'readingEmphasisRevision'];
        if (revision is! int || revision < 0) {
          throw StateError('设置服务返回了无效版本号');
        }
        // 重试期间先恢复重置后的普通字段，再让后续用户操作继续出队。
        // 两次请求作为同一个步骤，避免迟到的恢复覆盖刚改的字号或模型。
        if (restoreAfterReset != null) {
          await _writeSettingsSnapshot(
            connection,
            generation,
            restoreAfterReset,
          );
        }
        for (final entry in versions.entries) {
          if (_pendingReadingEmphasisVersions[entry.key] == entry.value) {
            _pendingReadingEmphasis.remove(entry.key);
            _pendingReadingEmphasisVersions.remove(entry.key);
          }
        }
        if (resetVersion != null &&
            _pendingSettingsResetVersion == resetVersion) {
          _pendingSettingsResetVersion = null;
          _pendingSettingsResetSnapshot = null;
        }
        // 旧响应不能覆盖更晚的广播，也不能覆盖滑块尚未确认的新预览。
        _acceptReadingEmphasisSnapshot(snapshot, revision);
        if (_pendingReadingEmphasis.isEmpty &&
            _pendingSettingsResetVersion == null) {
          _readingEmphasisSaveError = null;
        }
      } catch (_) {
        _readingEmphasisSaveError = '保存失败，当前预览尚未保存，请重试。';
        rethrow;
      } finally {
        _readingEmphasisQueuedWrites--;
        _notifyReadingEmphasis();
      }
    });
  }

  Map<String, dynamic> _readingSnapshot(Object? raw) {
    if (raw is! Map) throw const FormatException('缺少已保存的当前字突出设置');
    final values = <String, dynamic>{
      for (final key in AppSettings.readingEmphasisKeys)
        if (raw.containsKey(key)) key: raw[key],
    };
    if (values.length != AppSettings.readingEmphasisKeys.length) {
      throw const FormatException('当前字突出设置不完整');
    }
    return AppSettings.validateReadingEmphasisPatch(values);
  }

  bool _acceptReadingEmphasisSnapshot(
    Map<String, dynamic> snapshot,
    int revision,
  ) {
    if (revision >= _readingEmphasisRevision) {
      _readingEmphasisRevision = revision;
      _confirmedReadingEmphasis = snapshot;
    }
    return _projectReadingEmphasis();
  }

  bool _projectReadingEmphasis() {
    final next = _settings.withReadingEmphasisPatch({
      ..._confirmedReadingEmphasis,
      ..._pendingReadingEmphasis,
    });
    final changed = !_mapEquals(
      _settings.toReadingEmphasisMap(),
      next.toReadingEmphasisMap(),
    );
    _settings = next;
    return changed;
  }

  void _handleReadingEmphasisChanged(WsMessage message) {
    if (_disposed || _connection?.isConnected != true) return;
    try {
      final revision = message.data['revision'];
      if (revision is! int || revision < 0) return;
      final changed = _acceptReadingEmphasisSnapshot(
        _readingSnapshot(message.data['settings']),
        revision,
      );
      if (changed) {
        _notifyReadingEmphasis();
        _syncTeleprompterSettingsToBackend();
      }
    } catch (error) {
      debugPrint('[SettingsProvider] 忽略无效的当前字突出设置: $error');
    }
  }

  bool _seedReadingEmphasisFromSession(Map<String, dynamic> session) {
    // 全局设置已加载后，以专用设置事件的版本号为准，旧会话快照不能回滚它。
    if (_readingEmphasisRevision >= 0) return false;
    if (!AppSettings.readingEmphasisKeys.every(session.containsKey)) {
      return false;
    }
    try {
      _confirmedReadingEmphasis = _readingSnapshot(session);
      return _projectReadingEmphasis();
    } on FormatException {
      // 老客户端没有这些字段时沿用本机全局默认值。
    }
    return false;
  }

  void _notifyReadingEmphasis() {
    if (!_disposed) notifyListeners();
  }

  /// 更新字体大小
  Future<void> setFontSize(double fontSize) async {
    await _setAndSave(overrideData: {'fontSize': fontSize});
  }

  /// 更新行高
  Future<void> setLineHeight(double lineHeight) async {
    await _setAndSave(overrideData: {'lineHeight': lineHeight});
  }

  /// 更新滚动模式
  Future<void> setScrollMode(ScrollMode mode) async {
    if (_articleOverridesActive) {
      _articleOverrides['scrollMode'] = mode.name;
      notifyListeners();
    } else {
      _settings = _settings.copyWith(scrollMode: mode);
      notifyListeners();
      await _saveSettings();
    }
    _syncTeleprompterSettingsToBackend();
  }

  /// 更新 WPM
  Future<void> setWpm(int wpm) async {
    await _setAndSave(overrideData: {'wpm': wpm});
  }

  /// 再次点击自动标签时切换运动方式，各模式保留自己的速度。
  Future<void> toggleAutoScrollMode() async {
    final next = mergedSettings.autoScrollMode == AutoScrollMode.line
        ? AutoScrollMode.continuous
        : AutoScrollMode.line;
    await _setAndSave(overrideData: {'autoScrollMode': next.name});
  }

  /// 更新当前自动模式速度，不把反向速度截断为零。
  Future<void> setAutoSpeed(double speed) async {
    if (!speed.isFinite) return;
    if (mergedSettings.isContinuousScroll) {
      await _setAndSave(overrideData: {'pixelsPerSecond': speed});
    } else {
      await setWpm(speed.round());
    }
  }

  /// 切换镜像模式
  Future<void> toggleMirrorMode() async {
    await _setAndSave(overrideData: {'mirrorMode': !mergedSettings.mirrorMode});
  }

  /// 切换全屏模式
  Future<void> toggleFullScreenMode() async {
    _settings = _settings.copyWith(fullScreenMode: !_settings.fullScreenMode);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置全屏模式
  Future<void> setFullScreenMode(bool value) async {
    _settings = _settings.copyWith(fullScreenMode: value);
    notifyListeners();
    await _saveSettings();
  }

  /// 切换自动隐藏 UI
  Future<void> toggleAutoHideUI() async {
    _settings = _settings.copyWith(autoHideUI: !_settings.autoHideUI);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置自动隐藏延迟
  Future<void> setAutoHideDelay(int seconds) async {
    _settings = _settings.copyWith(autoHideDelaySeconds: seconds);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置 ASR 模型信息
  Future<void> setAsrModel(String id, String name) async {
    _settings = _settings.copyWith(asrModelId: id, asrModelName: name);
    notifyListeners();
    await _saveSettings();
  }

  Future<void> clearAsrModel() => setAsrModel('', '');

  Future<void> setAsrInputDevice(String id, String name) async {
    _settings = _settings.copyWith(
      asrInputDeviceId: id,
      asrInputDeviceName: name,
    );
    notifyListeners();
    await _saveSettings();
  }

  /// 更新主题色
  Future<void> setUiPrimaryColor(int hexColor) async {
    _settings = _settings.copyWith(uiPrimaryColor: hexColor);
    notifyListeners();
    await _saveSettings();
  }

  /// 更新提词器背景色
  Future<void> setTeleprompterBgColor(int hexColor) async {
    await _setAndSave(overrideData: {'teleprompterBgColor': hexColor});
  }

  /// 更新水平边距
  Future<void> setPaddingX(double value) async {
    await _setAndSave(overrideData: {'paddingX': value});
  }

  /// 更新阅读线偏移
  Future<void> setReadingLineOffset(double value) async {
    await _setAndSave(overrideData: {'readingLineOffset': value});
  }

  /// 更新进度条提示字号比例
  Future<void> setProgressInfoSizeRatio(double value) async {
    await _setAndSave(overrideData: {'progressInfoSizeRatio': value});
  }

  /// 更新 ASR 镜像 URL
  Future<void> setAsrMirrorUrl(String url) async {
    _settings = _settings.copyWith(asrMirrorUrl: url);
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setAsrAdvancedParameters({
    required int numThreads,
    required double rule1MinTrailingSilence,
    required double rule2MinTrailingSilence,
    required double rule3MinUtteranceLength,
    required bool useSystemProxy,
  }) async {
    _settings = _settings.copyWith(
      asrNumThreads: numThreads.clamp(0, 64),
      asrRule1MinTrailingSilence: rule1MinTrailingSilence.clamp(0.1, 20),
      asrRule2MinTrailingSilence: rule2MinTrailingSilence.clamp(0.1, 20),
      asrRule3MinUtteranceLength: rule3MinUtteranceLength.clamp(1, 300),
      asrUseSystemProxy: useSystemProxy,
    );
    notifyListeners();
    await _saveSettings();
  }

  /// 更新应用 UI 字体
  Future<void> setAppFontFamily(String fontFamily) async {
    _settings = _settings.copyWith(appFontFamily: fontFamily);
    notifyListeners();
    await _saveSettings();
  }

  /// 更新提词器正文字体
  Future<void> setTeleprompterFontFamily(String fontFamily) async {
    await _setAndSave(overrideData: {'teleprompterFontFamily': fontFamily});
  }

  /// 切换已读字符变灰
  Future<void> toggleGrayReadChars() async {
    await _setAndSave(
      overrideData: {'grayReadChars': !mergedSettings.grayReadChars},
    );
  }

  /// 更新字体颜色
  Future<void> setTextColor(int hexColor) async {
    await _setAndSave(overrideData: {'textColor': hexColor});
  }

  /// 更新字间距
  Future<void> setLetterSpacing(double value) async {
    await _setAndSave(overrideData: {'letterSpacing': value});
  }

  /// 切换当前字高亮
  Future<void> toggleHighlightCurrentChar() async {
    await _setAndSave(
      overrideData: {
        'highlightCurrentChar': !mergedSettings.highlightCurrentChar,
      },
    );
  }

  /// 切换默认加粗
  Future<void> toggleDefaultBold() async {
    await _setAndSave(
      overrideData: {'defaultBold': !mergedSettings.defaultBold},
    );
  }

  /// 切换当前字下划线
  Future<void> toggleUnderlineCurrentChar() async {
    await _setAndSave(
      overrideData: {
        'underlineCurrentChar': !mergedSettings.underlineCurrentChar,
      },
    );
  }

  /// 更新阅读区域框边框粗细
  Future<void> setReadingAreaBorderWidth(double value) async {
    await _setAndSave(overrideData: {'readingAreaBorderWidth': value});
  }

  /// 切换进度条显示 - 已用时间
  Future<void> toggleProgressShowTime() async {
    await _setAndSave(
      overrideData: {'progressShowTime': !mergedSettings.progressShowTime},
    );
  }

  /// 切换进度条显示 - 进度百分比
  Future<void> toggleProgressShowPercentage() async {
    await _setAndSave(
      overrideData: {
        'progressShowPercentage': !mergedSettings.progressShowPercentage,
      },
    );
  }

  /// 切换进度条显示 - 滚动速度
  Future<void> toggleProgressShowSpeed() async {
    await _setAndSave(
      overrideData: {'progressShowSpeed': !mergedSettings.progressShowSpeed},
    );
  }

  /// 切换进度条显示 - 当前时间
  Future<void> toggleProgressShowCurrentTime() async {
    await _setAndSave(
      overrideData: {
        'progressShowCurrentTime': !mergedSettings.progressShowCurrentTime,
      },
    );
  }

  /// 更新全局快速模式设置，不写入当前稿件覆盖层。
  Future<void> setQuickMode({
    bool? enabled,
    bool? autoSave,
    String? folderId,
  }) async {
    _settings = _settings.copyWith(
      quickModeEnabled: enabled,
      quickModeAutoSave: autoSave,
      quickModeFolderId: folderId,
    );
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setAppBrightnessMode(AppBrightnessMode mode) async {
    _settings = _settings.copyWith(appBrightnessMode: mode);
    notifyListeners();
    await _saveSettings();
  }

  /// 完全重置所有设置为默认值
  Future<void> resetAllSettings() async {
    _settings = const AppSettings();
    _ordinarySettingsEditVersion++;
    final defaults = _settings.toReadingEmphasisMap();
    final version = ++_readingEmphasisEditVersion;
    final versions = {for (final key in defaults.keys) key: version};
    _pendingSettingsResetVersion = version;
    _pendingSettingsResetSnapshot = _settings;
    _pendingReadingEmphasis.addAll(defaults);
    _pendingReadingEmphasisVersions.addAll(versions);
    _readingEmphasisSaveError = null;
    final save = _enqueueReadingEmphasisWrite(
      defaults,
      versions,
      resetVersion: version,
    );
    _syncTeleprompterSettingsToBackend();
    await save;
  }

  /// 批量更新设置
  Future<void> updateSettings(AppSettings newSettings) async {
    final readingChanged = !_mapEquals(
      _settings.toReadingEmphasisMap(),
      newSettings.toReadingEmphasisMap(),
    );
    _settings = newSettings;
    notifyListeners();
    final readingSave = readingChanged
        ? _setReadingEmphasis(newSettings.toReadingEmphasisMap())
        : Future<void>.value();
    await Future.wait([_saveSettings(), readingSave]);
  }

  @override
  void dispose() {
    _disposed = true;
    _readingEmphasisSubscription?.cancel();
    if (_connection != null && _connectionListener != null) {
      _connection!.removeListener(_connectionListener!);
    }
    super.dispose();
  }
}
