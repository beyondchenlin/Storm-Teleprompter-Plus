import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/constants.dart';

@visibleForTesting
bool usesPortableDesktopDataDirectory({
  required bool isWindows,
  required bool isLinux,
  required bool isMacOS,
}) => !isMacOS && (isWindows || isLinux);

@visibleForTesting
Directory? appDataDirectoryOverride;

/// 安装版与程序更新相互独立；便携版继续使用原有程序旁数据目录。
///
/// 安装标记只决定模式，不接受来自标记的任意数据路径。标记损坏或缺少
/// 用户目录时明确报错，避免静默切换到另一个目录而表现为稿件丢失。
@visibleForTesting
Future<Directory> resolveWindowsAppDataDirectory({
  required Directory executableDirectory,
  required Map<String, String> environment,
}) async {
  final marker = File(
    p.join(
      executableDirectory.path,
      StorageConstants.windowsInstalledMarkerFileName,
    ),
  );
  if (!await marker.exists()) {
    return Directory(
      p.join(
        executableDirectory.path,
        StorageConstants.desktopDataDirectoryName,
      ),
    );
  }

  Object? configuration;
  try {
    configuration = jsonDecode(await marker.readAsString());
  } on FormatException {
    throw FileSystemException('安装信息已损坏，请重新安装软件。', marker.path);
  }
  if (configuration is! Map<String, dynamic> ||
      configuration['schemaVersion'] != 1 ||
      configuration['mode'] != 'installed') {
    throw FileSystemException('安装信息不受支持，请重新安装软件。', marker.path);
  }
  final localAppData = environment['LOCALAPPDATA']?.trim();
  if (localAppData == null ||
      localAppData.isEmpty ||
      !p.isAbsolute(localAppData)) {
    throw const FileSystemException('未能读取当前用户的数据目录，请重新登录系统后重试。');
  }
  return Directory(
    p.join(
      localAppData,
      StorageConstants.windowsUserDataDirectoryName,
      StorageConstants.desktopDataDirectoryName,
    ),
  );
}

/// 返回当前平台使用的持久数据根目录。
///
/// 微软桌面安装版使用当前用户的固定目录，升级和卸载程序不触碰稿件。
/// 无安装标记的微软桌面便携版和 Linux 版保持原有程序旁数据目录；
/// macOS 以及移动版本使用平台应用支持目录。
Future<Directory> getAppDataDirectory() async {
  final override = appDataDirectoryOverride;
  if (override != null) {
    if (!await override.exists()) await override.create(recursive: true);
    return override;
  }

  final Directory directory;
  if (Platform.isWindows) {
    directory = await resolveWindowsAppDataDirectory(
      executableDirectory: File(Platform.resolvedExecutable).parent,
      environment: Platform.environment,
    );
  } else if (usesPortableDesktopDataDirectory(
    isWindows: false,
    isLinux: Platform.isLinux,
    isMacOS: Platform.isMacOS,
  )) {
    directory = Directory(
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        StorageConstants.desktopDataDirectoryName,
      ),
    );
  } else {
    directory = await getApplicationSupportDirectory();
  }

  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}
