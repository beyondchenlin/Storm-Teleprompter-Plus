import 'dart:convert';
import '../models/app_settings.dart';
import '../services/app_preferences.dart';
import '../utils/constants.dart';
import 'ws_protocol.dart';
import 'ws_server.dart';

/// 设置管理后端服务
///
/// 处理应用设置和提词器设置的读取、保存和重置。
class SettingsService {
  SettingsService({AppPreferences? preferences})
    : _providedPreferences = preferences;

  final AppPreferences? _providedPreferences;
  late AppPreferences _prefs;
  WsServer? _server;
  Future<void> _pendingWrite = Future<void>.value();
  int _readingEmphasisRevision = 0;
  AppSettings? _persistedSettings;

  /// 初始化存储
  Future<void> init() async {
    _prefs = _providedPreferences ?? await AppPreferences.getInstance();
  }

  /// 注册消息处理器到 WsServer
  void registerHandlers(WsServer server) {
    _server = server;
    server.requests.listen((request) {
      switch (request.message.type) {
        case WsMessageType.settingsGet:
          _handleSettingsGet(server, request);
          break;
        case WsMessageType.settingsSave:
          _handleSettingsSave(server, request);
          break;
        case WsMessageType.settingsReadingEmphasisPatch:
          _handleReadingEmphasisPatch(server, request);
          break;
        case WsMessageType.settingsReset:
          _handleSettingsReset(server, request);
          break;
        default:
          break;
      }
    });
  }

  Future<void> _handleSettingsGet(WsServer server, WsRequest request) async {
    await _pendingWrite;
    final settings = _readStoredSettings();
    server.respond(
      request.clientId,
      WsMessage(
        type: WsMessageType.settingsGetResponse,
        id: request.message.id,
        data: {
          'settings': settings.toJson(),
          'readingEmphasisRevision': _readingEmphasisRevision,
        },
      ),
    );
  }

  Future<void> _handleSettingsSave(WsServer server, WsRequest request) async {
    try {
      final settingsJson = request.message.data['settings'];
      if (settingsJson is! Map<String, dynamic>) {
        throw const FormatException('缺少设置数据');
      }
      final incoming = AppSettings.fromJson(settingsJson);
      // 旧的全量设置快照不能覆盖这四项全局设置；它们走专用局部更新。
      await _updateSettings(
        (current) =>
            incoming.withReadingEmphasisPatch(current.toReadingEmphasisMap()),
      );
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.settingsSaveResponse,
          id: request.message.id,
          data: {'success': true},
        ),
      );
    } catch (e) {
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.error,
          id: request.message.id,
          data: {'message': '保存设置失败: $e'},
        ),
      );
    }
  }

  Future<void> _handleReadingEmphasisPatch(
    WsServer server,
    WsRequest request,
  ) async {
    try {
      final patch = request.message.data['patch'];
      if (patch is! Map<String, dynamic>) {
        throw const FormatException('缺少当前字突出设置');
      }
      final validated = AppSettings.validateReadingEmphasisPatch(patch);
      final saved = await _updateSettings(
        (current) => current.withReadingEmphasisPatch(validated),
      );
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.settingsReadingEmphasisPatchResponse,
          id: request.message.id,
          data: {
            'success': true,
            'settings': saved.settings.toReadingEmphasisMap(),
            'revision': saved.revision,
          },
        ),
      );
    } catch (error) {
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.error,
          id: request.message.id,
          data: {'message': '保存当前字突出设置失败：$error'},
        ),
      );
    }
  }

  Future<void> _handleSettingsReset(WsServer server, WsRequest request) async {
    try {
      final saved = await _updateSettings((_) => const AppSettings());
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.settingsResetResponse,
          id: request.message.id,
          data: {
            'settings': saved.settings.toJson(),
            'readingEmphasisRevision': saved.revision,
            'success': true,
          },
        ),
      );
    } catch (error) {
      server.respond(
        request.clientId,
        WsMessage(
          type: WsMessageType.error,
          id: request.message.id,
          data: {'message': '重置设置失败：$error'},
        ),
      );
    }
  }

  // ─── 底层存储操作 ───────────────────────────────────────

  /// 加载应用设置
  Future<AppSettings> loadSettings() async {
    await _pendingWrite;
    return _readStoredSettings();
  }

  AppSettings _readStoredSettings() {
    // 只缓存最后成功的快照，兼容先改内存再返回写入失败的存储实现。
    final cached = _persistedSettings;
    if (cached != null) return cached;
    final jsonStr = _prefs.getString(StorageConstants.settingsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _persistedSettings = const AppSettings();
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _persistedSettings = AppSettings.fromJson(json);
    } catch (_) {
      return _persistedSettings = const AppSettings();
    }
  }

  /// 保存应用设置
  Future<void> saveSettings(AppSettings settings) async {
    // 显式备份恢复保留完整替换语义，包括当前字突出设置。
    await _updateSettings((_) => settings);
  }

  /// 串行完成读取、合并和落盘，避免局部更新与旧全量保存互相覆盖。
  Future<({AppSettings settings, int revision})> _updateSettings(
    AppSettings Function(AppSettings current) update,
  ) {
    final write = _pendingWrite.then((_) async {
      final current = _readStoredSettings();
      final next = update(current);
      final success = await _prefs.setString(
        StorageConstants.settingsKey,
        jsonEncode(next.toJson()),
      );
      if (!success) throw StateError('设置文件写入失败');
      _persistedSettings = next;

      final before = current.toReadingEmphasisMap();
      final after = next.toReadingEmphasisMap();
      if (AppSettings.readingEmphasisKeys.any(
        (key) => before[key] != after[key],
      )) {
        _readingEmphasisRevision++;
        _server?.broadcast(
          WsMessage(
            type: WsMessageType.settingsReadingEmphasisChanged,
            data: {'settings': after, 'revision': _readingEmphasisRevision},
          ),
        );
      }
      return (settings: next, revision: _readingEmphasisRevision);
    });
    // 一次写入失败不阻断后续重试，也不吞掉本次调用者收到的异常。
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }
}
