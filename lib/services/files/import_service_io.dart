import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'docx_annotation_importer.dart';
import 'import_batch.dart';
import 'pdf_annotation_importer.dart';

/// 原生平台稿件导入服务。
///
/// 单文件解析统一生成 HTML 正文；批量导入在此基础上扫描目录并记录相对路径，
/// 由页面层负责在后端中创建对应的文件夹和稿件。
class ImportService {
  static const supportedExtensions = {'.txt', '.docx', '.pdf', '.html', '.htm'};

  Future<ImportedArticleDraft?> importFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final lower = path.toLowerCase();
    if (lower.endsWith('.txt')) return _importTxt(file);
    if (lower.endsWith('.docx')) return importDocx(file);
    if (lower.endsWith('.pdf')) return importPdf(file);
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return _importHtml(file);
    }
    return null;
  }

  Future<ImportBatchDraft> importPaths(List<String> paths) async {
    final folders = <ImportedFolderDraft>[];
    final files = <ImportedFileDraft>[];
    final failures = <String>[];
    var skippedCount = 0;
    final seenFolders = <String>{};
    final seenSources = <String>{};
    final usedRootNames = <String>{};

    for (final sourcePath in paths) {
      final normalized = p.normalize(sourcePath);
      if (!seenSources.add(_pathKey(normalized))) continue;

      try {
        final type = await FileSystemEntity.type(
          normalized,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          final rootName = _uniqueRootName(
            p.basename(normalized),
            usedRootNames,
          );
          skippedCount += await _importDirectory(
            Directory(normalized),
            rootName: rootName,
            folders: folders,
            files: files,
            failures: failures,
            seenFolders: seenFolders,
          );
        } else if (type == FileSystemEntityType.file) {
          final supported = await _importFileIntoBatch(
            normalized,
            const [],
            files: files,
            failures: failures,
          );
          if (!supported) skippedCount++;
        } else {
          failures.add('${p.basename(normalized)}: 路径不存在或无法读取');
        }
      } catch (error) {
        failures.add('${p.basename(normalized)}: 无法读取（$error）');
      }
    }

    return ImportBatchDraft(
      folders: folders,
      files: files,
      failures: failures,
      skippedCount: skippedCount,
    );
  }

  Future<int> _importDirectory(
    Directory root, {
    required String rootName,
    required List<ImportedFolderDraft> folders,
    required List<ImportedFileDraft> files,
    required List<String> failures,
    required Set<String> seenFolders,
  }) async {
    final rootParts = [rootName];
    _addFolder(rootParts, folders, seenFolders);
    var skippedCount = 0;

    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = p.relative(entity.path, from: root.path);
        final relativeParts = p.split(relative);
        if (entity is Directory) {
          _addFolder([...rootParts, ...relativeParts], folders, seenFolders);
          continue;
        }
        if (entity is! File) continue;
        final supported = await _importFileIntoBatch(
          entity.path,
          [...rootParts, ...relativeParts.take(relativeParts.length - 1)],
          files: files,
          failures: failures,
        );
        if (!supported) skippedCount++;
      }
    } catch (error) {
      failures.add('$rootName: 无法读取文件夹（$error）');
    }
    return skippedCount;
  }

  void _addFolder(
    List<String> parts,
    List<ImportedFolderDraft> folders,
    Set<String> seenFolders,
  ) {
    final key = parts.map(_pathKey).join('/');
    if (seenFolders.add(key)) {
      folders.add(ImportedFolderDraft(List.unmodifiable(parts)));
    }
  }

  Future<bool> _importFileIntoBatch(
    String path,
    List<String> relativeFolderPath, {
    required List<ImportedFileDraft> files,
    required List<String> failures,
  }) async {
    if (!supportedExtensions.contains(p.extension(path).toLowerCase())) {
      return false;
    }
    try {
      final article = await importFile(path);
      if (article == null) {
        failures.add('${p.basename(path)}: 不支持的文件格式');
        return true;
      }
      files.add(
        ImportedFileDraft(
          sourcePath: path,
          relativeFolderPath: List.unmodifiable(relativeFolderPath),
          article: article,
        ),
      );
    } catch (error) {
      failures.add('${p.basename(path)}: $error');
    }
    return true;
  }

  String _pathKey(String value) =>
      Platform.isWindows ? value.toLowerCase() : value;

  String _uniqueRootName(String requested, Set<String> usedNames) {
    var candidate = requested;
    var suffix = 2;
    while (!usedNames.add(_pathKey(candidate))) {
      candidate = '$requested ($suffix)';
      suffix++;
    }
    return candidate;
  }

  Future<ImportedArticleDraft> _importTxt(File file) async {
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    return ImportedArticleDraft(
      title: _titleFromPath(file.path),
      content: _plainTextToParagraphHtml(text),
    );
  }

  Future<ImportedArticleDraft> _importHtml(File file) async {
    // 应用导出的稿件本身就是编辑器可读取的 HTML，无需再次转换样式。
    final content = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    return ImportedArticleDraft(
      title: _titleFromPath(file.path),
      content: content,
    );
  }

  String _plainTextToParagraphHtml(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map(
          (line) =>
              '<p>${const HtmlEscape(HtmlEscapeMode.element).convert(line)}</p>',
        )
        .join('\n');
  }

  String _titleFromPath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
  }
}
