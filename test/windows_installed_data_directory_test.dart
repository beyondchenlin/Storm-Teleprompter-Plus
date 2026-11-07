import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

void main() {
  late Directory sandbox;
  late Directory executableDirectory;
  late Directory localAppData;
  late File marker;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bk-installed-data-');
    executableDirectory = await Directory(
      p.join(sandbox.path, '程序 安装目录'),
    ).create();
    localAppData = Directory(p.join(sandbox.path, '中文用户', 'Local'));
    marker = File(
      p.join(
        executableDirectory.path,
        StorageConstants.windowsInstalledMarkerFileName,
      ),
    );
  });

  tearDown(() async {
    appDataDirectoryOverride = null;
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('portable launch keeps existing adjacent data untouched', () async {
    final legacy = await Directory(
      p.join(executableDirectory.path, 'app_data'),
    ).create();
    final article = File(p.join(legacy.path, 'application.json'));
    await article.writeAsString('existing-user-data');
    final actual = await resolveWindowsAppDataDirectory(
      executableDirectory: executableDirectory,
      environment: {'LOCALAPPDATA': localAppData.path},
    );
    expect(actual.path, legacy.path);
    expect(await article.readAsString(), 'existing-user-data');
    expect(await localAppData.exists(), isFalse);
  });

  test('installed data survives a different program directory', () async {
    await marker.writeAsString('{"schemaVersion":1,"mode":"installed"}');
    final first = await resolveWindowsAppDataDirectory(
      executableDirectory: executableDirectory,
      environment: {'LOCALAPPDATA': localAppData.path},
    );
    await first.create(recursive: true);
    final article = File(p.join(first.path, 'application.json'));
    await article.writeAsString('preserved-settings-and-articles');
    final upgradedProgram = await Directory(
      p.join(sandbox.path, '另一安装位置'),
    ).create();
    await marker.copy(
      p.join(
        upgradedProgram.path,
        StorageConstants.windowsInstalledMarkerFileName,
      ),
    );
    final upgraded = await resolveWindowsAppDataDirectory(
      executableDirectory: upgradedProgram,
      environment: {'LOCALAPPDATA': localAppData.path},
    );
    expect(
      upgraded.path,
      p.join(localAppData.path, 'BKTeleprompter', 'app_data'),
    );
    expect(upgraded.path, first.path);
    expect(await article.readAsString(), 'preserved-settings-and-articles');
  });

  test(
    'damaged install marker cannot silently select another data store',
    () async {
      for (final contents in [
        '{broken',
        '{}',
        '{"schemaVersion":2,"mode":"installed"}',
      ]) {
        await marker.writeAsString(contents);
        await expectLater(
          resolveWindowsAppDataDirectory(
            executableDirectory: executableDirectory,
            environment: {'LOCALAPPDATA': localAppData.path},
          ),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(
        await Directory(p.join(executableDirectory.path, 'app_data')).exists(),
        isFalse,
      );
    },
  );

  test('installed mode rejects missing or relative user directory', () async {
    await marker.writeAsString('{"schemaVersion":1,"mode":"installed"}');
    for (final environment in <Map<String, String>>[
      {},
      {'LOCALAPPDATA': ''},
      {'LOCALAPPDATA': 'relative-user-folder'},
    ]) {
      await expectLater(
        resolveWindowsAppDataDirectory(
          executableDirectory: executableDirectory,
          environment: environment,
        ),
        throwsA(isA<FileSystemException>()),
      );
    }
  });
}
