import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'asr_preparation_exception.dart';

typedef ModelPreparationProgress = void Function(double value, String message);

class AsrModelFile {
  const AsrModelFile({
    required this.role,
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.url,
  });

  final String role;
  final String name;
  final int bytes;
  final String sha256;
  final Uri url;
}

/// The packaged manifest is the single identity shared by the installer and app.
class AsrModelManifest {
  const AsrModelManifest({
    required this.modelId,
    required this.modelFamily,
    required this.sampleRate,
    required this.files,
  });

  static const assetPath = 'assets/asr/zipformer2-ced.manifest.json';

  factory AsrModelManifest.parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['schemaVersion'] != 1 ||
        json['modelId'] != 'zipformer2-ced' ||
        json['modelFamily'] != 'zipformer' ||
        json['sampleRate'] != 16000) {
      throw const FormatException('内置语音模型清单版本不受支持');
    }
    final files = <AsrModelFile>[];
    final names = <String>{};
    final roles = <String>{};
    for (final item in json['files'] as List<dynamic>) {
      final value = item as Map<String, dynamic>;
      final role = value['role'] as String;
      final name = value['name'] as String;
      final bytes = value['bytes'] as int;
      final digest = value['sha256'] as String;
      final url = Uri.parse(value['url'] as String);
      if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
          name == '.' ||
          name == '..' ||
          !names.add(name.toLowerCase()) ||
          !roles.add(role) ||
          bytes <= 0 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          url.scheme != 'https' ||
          url.host != 'modelscope.cn') {
        throw const FormatException('内置语音模型清单内容无效');
      }
      files.add(
        AsrModelFile(
          role: role,
          name: name,
          bytes: bytes,
          sha256: digest,
          url: url,
        ),
      );
    }
    if (files.length != 4 ||
        !roles.containsAll({'encoder', 'decoder', 'joiner', 'tokens'})) {
      throw const FormatException('内置语音模型清单缺少必要文件');
    }
    return AsrModelManifest(
      modelId: json['modelId'] as String,
      modelFamily: json['modelFamily'] as String,
      sampleRate: json['sampleRate'] as int,
      files: List.unmodifiable(files),
    );
  }

  final String modelId;
  final String modelFamily;
  final int sampleRate;
  final List<AsrModelFile> files;
  int get totalBytes => files.fold(0, (sum, file) => sum + file.bytes);
  AsrModelFile fileForRole(String role) =>
      files.singleWhere((file) => file.role == role);

  Future<bool> isFileValid(File file, AsrModelFile expected) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if (await file.length() != expected.bytes) return false;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == expected.sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> isDirectoryValid(Directory directory) async {
    for (final expected in files) {
      if (!await isFileValid(
        File(p.join(directory.path, expected.name)),
        expected,
      )) {
        return false;
      }
    }
    return true;
  }
}

/// Repairs only the reserved built-in model, leaving every other selection alone.
/// Files are verified before a staged directory is atomically published.
class AsrModelStore {
  AsrModelStore({
    required this.manifest,
    required this.modelRoot,
    this.bundledDirectory,
    http.Client Function()? clientFactory,
    this.fallbackClientFactory,
    this.timeLimit = const Duration(minutes: 8),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final AsrModelManifest manifest;
  final Directory modelRoot;
  final Directory? bundledDirectory;
  final http.Client Function() _clientFactory;
  final Future<http.Client> Function()? fallbackClientFactory;
  final Duration timeLimit;
  http.Client? _activeClient;
  bool _cancelled = false;
  bool _timedOut = false;
  Future<Directory>? _preparation;

  void cancel() {
    _cancelled = true;
    _activeClient?.close();
  }

  void _checkCancelled() {
    if (_timedOut) {
      throw const AsrModelPreparationException('语音模型准备超时。请检查网络连接，再点击语音重试。');
    }
    if (_cancelled) {
      throw const AsrModelPreparationException('已取消语音模型准备', isCancelled: true);
    }
  }

  Future<Directory> prepare({ModelPreparationProgress? onProgress}) {
    return _preparation ??= _prepare(onProgress).whenComplete(() {
      _preparation = null;
    });
  }

  Future<Directory> _prepare(ModelPreparationProgress? onProgress) async {
    _cancelled = false;
    _timedOut = false;
    final timer = Timer(timeLimit, () {
      _timedOut = true;
      _activeClient?.close();
    });
    Directory? staging;
    final target = Directory(p.join(modelRoot.path, manifest.modelId));
    try {
      onProgress?.call(0, '正在校验中文语音模型…');
      if (await manifest.isDirectoryValid(target)) {
        _checkCancelled();
        onProgress?.call(1, '中文语音模型已就绪');
        return target;
      }
      _checkCancelled();
      await modelRoot.create(recursive: true);
      staging = await modelRoot.createTemp(
        '.' + manifest.modelId + '.preparing-',
      );
      var verifiedBytes = 0;
      for (final expected in manifest.files) {
        _checkCancelled();
        final destination = File(p.join(staging.path, expected.name));
        final existing = File(p.join(target.path, expected.name));
        final bundled = bundledDirectory == null
            ? null
            : File(p.join(bundledDirectory!.path, expected.name));
        if (await manifest.isFileValid(existing, expected)) {
          await existing.copy(destination.path);
        } else if (bundled != null &&
            await manifest.isFileValid(bundled, expected)) {
          onProgress?.call(
            verifiedBytes / manifest.totalBytes * 0.98,
            '正在恢复内置中文语音模型…',
          );
          await bundled.copy(destination.path);
        } else {
          await _downloadFile(expected, destination, (received) {
            final downloaded = (verifiedBytes + received) / (1024 * 1024);
            final total = manifest.totalBytes / (1024 * 1024);
            final message =
                '正在从魔搭社区恢复中文语音模型：' +
                downloaded.toStringAsFixed(1) +
                ' / ' +
                total.toStringAsFixed(1) +
                ' 兆字节';
            onProgress?.call(
              (verifiedBytes + received) / manifest.totalBytes * 0.98,
              message,
            );
          });
        }
        _checkCancelled();
        if (!await manifest.isFileValid(destination, expected)) {
          throw const AsrModelPreparationException(
            '语音模型文件校验失败。请检查磁盘空间和网络，再点击语音重试。',
          );
        }
        verifiedBytes += expected.bytes;
      }
      _checkCancelled();
      onProgress?.call(0.99, '正在完成中文语音模型准备…');
      final backup = Directory(staging.path + '.previous');
      final hadPrevious = await target.exists();
      if (hadPrevious) await target.rename(backup.path);
      try {
        await staging.rename(target.path);
        staging = null;
      } catch (_) {
        if (hadPrevious && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete(recursive: true);
      onProgress?.call(1, '中文语音模型已就绪');
      return target;
    } catch (error) {
      _checkCancelled();
      if (error is AsrModelPreparationException) rethrow;
      throw AsrModelPreparationException(
        '中文语音模型准备失败。请检查网络连接和磁盘空间，再点击语音重试。',
        cause: error,
      );
    } finally {
      timer.cancel();
      _activeClient?.close();
      _activeClient = null;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<void> _downloadFile(
    AsrModelFile expected,
    File destination,
    void Function(int bytes) onBytes,
  ) async {
    Object? lastError;
    // Domestic source first. If requested, retry using the user's system proxy.
    final attempts = fallbackClientFactory == null ? 1 : 2;
    for (var attempt = 0; attempt < attempts; attempt++) {
      _checkCancelled();
      final client = attempt == 0
          ? _clientFactory()
          : await fallbackClientFactory!();
      _activeClient = client;
      IOSink? sink;
      try {
        final response = await client
            .send(http.Request('GET', expected.url))
            .timeout(const Duration(seconds: 30));
        _checkCancelled();
        if (response.statusCode != 200) {
          throw HttpException('模型下载返回状态码 ' + response.statusCode.toString());
        }
        if (response.contentLength != null &&
            response.contentLength != expected.bytes) {
          throw const FormatException('下载文件长度与模型清单不一致');
        }
        sink = destination.openWrite();
        var received = 0;
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          _checkCancelled();
          received += chunk.length;
          if (received > expected.bytes) {
            throw const FormatException('下载文件超出预期长度');
          }
          sink.add(chunk);
          onBytes(received);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        _checkCancelled();
        if (!await manifest.isFileValid(destination, expected)) {
          throw const FormatException('下载文件内容校验失败');
        }
        return;
      } catch (error) {
        _checkCancelled();
        lastError = error;
      } finally {
        await sink?.close();
        client.close();
        if (identical(_activeClient, client)) _activeClient = null;
      }
    }
    throw AsrModelPreparationException(
      '无法从魔搭社区恢复中文语音模型。请检查网络连接，再点击语音重试。',
      cause: lastError,
    );
  }
}
