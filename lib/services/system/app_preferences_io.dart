import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/constants.dart';
import 'app_data_directory.dart';

class AppPreferences {
  AppPreferences._shared(this._sharedPreferences, this._values)
    : _file = null,
      assert(_values != null);

  AppPreferences._file(this._file, this._values) : _sharedPreferences = null;

  final SharedPreferences? _sharedPreferences;
  final File? _file;
  final Map<String, String>? _values;
  Future<void> _pendingWrite = Future<void>.value();

  static Future<AppPreferences>? _instance;
  static const _sharedSnapshotKey = 'bk_atomic_preferences_snapshot_v1';

  static Future<AppPreferences> getInstance() {
    return _instance ??= _create();
  }

  static Future<AppPreferences> _create() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return fromSharedPreferencesForTesting(
        await SharedPreferences.getInstance(),
      );
    }

    final dataDirectory = await getAppDataDirectory();
    final file = File(
      p.join(dataDirectory.path, StorageConstants.desktopPreferencesFileName),
    );
    return openFileForTesting(file);
  }

  /// Uses the same file transaction path with a private temporary test file.
  @visibleForTesting
  static Future<AppPreferences> openFileForTesting(File file) async {
    final values = <String, String>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is String) {
              values[entry.key as String] = entry.value as String;
            }
          }
        }
      } catch (error) {
        debugPrint('[AppPreferences] 读取应用数据失败，将使用空数据: $error');
      }
    }
    return AppPreferences._file(file, values);
  }

  /// A single stored overlay makes multi-key restores atomic on platforms
  /// backed by shared preferences too. Unchanged legacy keys remain readable.
  @visibleForTesting
  static AppPreferences fromSharedPreferencesForTesting(
    SharedPreferences preferences,
  ) {
    final values = <String, String>{};
    final stored = preferences.getString(_sharedSnapshotKey);
    if (stored != null) {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        if (entry.value is String) values[entry.key] = entry.value as String;
      }
    }
    return AppPreferences._shared(preferences, values);
  }

  String? getString(String key) {
    return _values?[key] ?? _sharedPreferences?.getString(key);
  }

  Future<bool> setString(String key, String value) => setStrings({key: value});

  /// Commit related keys together; failed writes never publish partial values.
  Future<bool> setStrings(Map<String, String> replacements) async {
    final captured = Map<String, String>.from(replacements);

    final write = _pendingWrite.then((_) async {
      // 在队列执行时基于最后成功写入的值合并，失败值不能进入其他保存。
      final values = _values!;
      final snapshot = Map<String, String>.from(values)..addAll(captured);
      if (!await _writeSnapshot(snapshot)) return false;
      values
        ..clear()
        ..addAll(snapshot);
      return true;
    });
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<bool> _writeSnapshot(Map<String, String> snapshot) async {
    final preferences = _sharedPreferences;
    if (preferences != null) {
      return preferences.setString(_sharedSnapshotKey, jsonEncode(snapshot));
    }
    final file = _file!;
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    await temporaryFile.writeAsString(jsonEncode(snapshot), flush: true);
    // 同目录替换保留旧文件直到新文件就绪；Windows 原生重命名支持替换。
    await temporaryFile.rename(file.path);
    return true;
  }
}
