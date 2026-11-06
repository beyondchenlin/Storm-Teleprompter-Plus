import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

void main() {
  late Directory directory;
  late File dataFile;
  late AppPreferences preferences;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('storm-preferences-');
    appDataDirectoryOverride = directory;
    dataFile = File(
      '${directory.path}${Platform.pathSeparator}'
      '${StorageConstants.desktopPreferencesFileName}',
    );
    preferences = await AppPreferences.getInstance();
  });

  tearDownAll(() async {
    appDataDirectoryOverride = null;
    await directory.delete(recursive: true);
  });

  test('a failed disk write cannot leak its value into a later save', () async {
    await preferences.setString('reading-color', 'original');
    final beforeFailure = await dataFile.readAsString();
    final blockedTemporaryFile = Directory('${dataFile.path}.tmp');
    await blockedTemporaryFile.create();
    try {
      await expectLater(
        preferences.setString('reading-color', 'unsaved'),
        throwsA(isA<FileSystemException>()),
      );
      expect(preferences.getString('reading-color'), 'original');
      expect(await dataFile.readAsString(), beforeFailure);
    } finally {
      await blockedTemporaryFile.delete();
    }

    await preferences.setString('unrelated-setting', 'saved');
    final persisted = jsonDecode(await dataFile.readAsString()) as Map;
    expect(persisted['reading-color'], 'original');
    expect(persisted['unrelated-setting'], 'saved');
  });

  test(
    'queued writes merge successful values without dropping other keys',
    () async {
      await Future.wait([
        preferences.setString('current-color', 'yellow'),
        preferences.setString('current-scale', '1.05'),
        preferences.setString('current-scale', '1.15'),
        preferences.setString('read-color', 'gray'),
      ]);
      final persisted = jsonDecode(await dataFile.readAsString()) as Map;
      expect(persisted['current-color'], 'yellow');
      expect(persisted['current-scale'], '1.15');
      expect(persisted['read-color'], 'gray');
      expect(preferences.getString('current-scale'), '1.15');
    },
  );

  test(
    'replacing an existing preferences file succeeds without a delete step',
    () async {
      await preferences.setString('replacement', 'first');
      expect(await dataFile.exists(), isTrue);
      await preferences.setString('replacement', 'second');
      expect(
        (jsonDecode(await dataFile.readAsString()) as Map)['replacement'],
        'second',
      );
      expect(await File('${dataFile.path}.tmp').exists(), isFalse);
    },
  );
}
