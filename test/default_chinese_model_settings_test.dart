import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';

void main() {
  test('a new user has a ready selected Chinese model', () {
    const settings = AppSettings();
    expect(settings.asrModelId, 'zipformer2-ced');
    expect(settings.asrModelName, '中文语音模型（内置）');
    expect(settings.asrMirrorUrl, isEmpty);
  });

  test(
    'missing and empty legacy model choices migrate to the bundled model',
    () {
      for (final json in <Map<String, dynamic>>[
        {},
        {'asrModelId': '', 'asrModelName': ''},
        {'asrModelId': '   ', 'asrModelName': '旧的空选择'},
        {'asrModelId': 'zipformer2-ced'},
      ]) {
        final settings = AppSettings.fromJson(json);
        expect(settings.asrModelId, AppSettings.defaultAsrModelId);
        expect(settings.asrModelName, AppSettings.defaultAsrModelName);
        final reloaded = AppSettings.fromJson(settings.toJson());
        expect(reloaded.asrModelId, settings.asrModelId);
        expect(reloaded.asrModelName, settings.asrModelName);
      }
    },
  );

  test('explicit alternate models and user proxy preferences stay intact', () {
    final settings = AppSettings.fromJson({
      'asrModelId': 'custom-offline-model',
      'asrModelName': '用户导入模型',
      'asrMirrorUrl': 'https://example.invalid/models/',
      'asrUseSystemProxy': false,
      'fontSize': 72,
    });
    expect(settings.asrModelId, 'custom-offline-model');
    expect(settings.asrModelName, '用户导入模型');
    expect(settings.asrMirrorUrl, 'https://example.invalid/models/');
    expect(settings.asrUseSystemProxy, isFalse);
    expect(settings.fontSize, 72);
  });
}
