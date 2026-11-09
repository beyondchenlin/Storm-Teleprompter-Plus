import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_preferences_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desktop batch commits all keys and concurrent saves merge latest data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atomic_preferences_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/application.json');
      final preferences = await AppPreferences.openFileForTesting(file);
      await preferences.setString('old', 'keep');
      final input = {
        'folders': 'new folders',
        'articles': 'new articles',
        'settings': 'new settings',
      };
      final batch = preferences.setStrings(input);
      input['articles'] = 'mutated after submit';
      final later = preferences.setString('later', 'preserved');
      expect(await batch, isTrue);
      expect(await later, isTrue);
      final decoded = jsonDecode(await file.readAsString());
      expect(decoded, {
        'old': 'keep',
        'folders': 'new folders',
        'articles': 'new articles',
        'settings': 'new settings',
        'later': 'preserved',
      });
      final reopened = await AppPreferences.openFileForTesting(file);
      expect(reopened.getString('articles'), 'new articles');
    },
  );

  test(
    'failed desktop replacement preserves the last successful in-memory snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atomic_preferences_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/application.json');
      final preferences = await AppPreferences.openFileForTesting(file);
      await preferences.setStrings({
        'articles': 'original',
        'settings': 'original',
      });
      // Only the private test path is blocked. This makes rename fail after the
      // temporary file was written and exercises the real publication boundary.
      await file.delete();
      final blocker = Directory(file.path);
      await blocker.create();
      await File('${blocker.path}/block').writeAsString('private test blocker');
      await expectLater(
        preferences.setStrings({
          'articles': 'replacement',
          'settings': 'replacement',
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(preferences.getString('articles'), 'original');
      expect(preferences.getString('settings'), 'original');
      await blocker.delete(recursive: true);
      await preferences.setString('next', 'retry succeeds');
      expect(jsonDecode(await file.readAsString()), {
        'articles': 'original',
        'settings': 'original',
        'next': 'retry succeeds',
      });
    },
  );

  test(
    'shared-preference batches use one snapshot and retain legacy keys',
    () async {
      SharedPreferences.setMockInitialValues({
        'articles': 'legacy articles',
        'unrelated': 'keep',
      });
      final shared = await SharedPreferences.getInstance();
      final preferences = AppPreferences.fromSharedPreferencesForTesting(
        shared,
      );
      expect(preferences.getString('articles'), 'legacy articles');
      await preferences.setStrings({
        'articles': 'restored articles',
        'settings': 'restored settings',
      });
      expect(preferences.getString('unrelated'), 'keep');
      final restarted = AppPreferences.fromSharedPreferencesForTesting(shared);
      expect(restarted.getString('articles'), 'restored articles');
      expect(restarted.getString('settings'), 'restored settings');
      expect(shared.getString('articles'), 'legacy articles');
      final newKeys = shared.getKeys().difference({'articles', 'unrelated'});
      expect(newKeys, hasLength(1));
      expect(jsonDecode(shared.getString(newKeys.single)!), {
        'articles': 'restored articles',
        'settings': 'restored settings',
      });
    },
  );
}
