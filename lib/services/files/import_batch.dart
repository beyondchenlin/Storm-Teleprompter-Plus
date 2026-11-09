import '../../models/reading_annotation.dart';

class ImportedArticleDraft {
  const ImportedArticleDraft({
    required this.title,
    required this.content,
    this.annotations = const [],
    this.warnings = const [],
  });

  final String title;
  final String content;
  final List<ReadingAnnotation> annotations;
  final List<String> warnings;
}

class ImportedFolderDraft {
  const ImportedFolderDraft(this.relativePath);

  final List<String> relativePath;
}

class ImportedFileDraft {
  const ImportedFileDraft({
    required this.sourcePath,
    required this.relativeFolderPath,
    required this.article,
  });

  final String sourcePath;
  final List<String> relativeFolderPath;
  final ImportedArticleDraft article;
}

class ImportBatchDraft {
  const ImportBatchDraft({
    this.folders = const [],
    this.files = const [],
    this.failures = const [],
    this.skippedCount = 0,
  });

  final List<ImportedFolderDraft> folders;
  final List<ImportedFileDraft> files;
  final List<String> failures;
  final int skippedCount;
}
