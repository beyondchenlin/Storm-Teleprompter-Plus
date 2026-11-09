import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  AppPreferences._(this._preferences) {
    final stored = _preferences.getString(_snapshotKey);
    if (stored != null) {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        if (entry.value is String) _values[entry.key] = entry.value as String;
      }
    }
  }

  final SharedPreferences _preferences;
  final Map<String, String> _values = {};
  Future<void> _pendingWrite = Future<void>.value();
  static const _snapshotKey = 'bk_atomic_preferences_snapshot_v1';

  static Future<AppPreferences>? _instance;

  static Future<AppPreferences> getInstance() {
    return _instance ??= SharedPreferences.getInstance().then(AppPreferences._);
  }

  String? getString(String key) => _values[key] ?? _preferences.getString(key);

  Future<bool> setString(String key, String value) => setStrings({key: value});

  Future<bool> setStrings(Map<String, String> replacements) {
    final captured = Map<String, String>.from(replacements);
    final write = _pendingWrite.then((_) async {
      final snapshot = Map<String, String>.from(_values)..addAll(captured);
      final success = await _preferences.setString(
        _snapshotKey,
        jsonEncode(snapshot),
      );
      if (success) {
        _values
          ..clear()
          ..addAll(snapshot);
      }
      return success;
    });
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }
}
