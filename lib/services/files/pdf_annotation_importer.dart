import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';
import 'package:xml/xml.dart';

import '../../models/reading_annotation.dart';
import 'import_batch.dart';
import 'pdf_annotation_geometry.dart';

class PdfImportException implements Exception {
  const PdfImportException(this.message, {this.nativeCode});

  final String message;
  /// Preserved for diagnostics; never infer a password error from an unknown
  /// code or from a search for an /Encrypt token in arbitrary file bytes.
  final int? nativeCode;

  @override
  String toString() => message;
}

Future<void> _pdfImportQueue = Future<void>.value();

/// Import from the main application isolate. The application has a single PDF
/// owner: all native work is serialized and runs in a background isolate.
/// No native pointer crosses the isolate boundary. If a PDF viewer is added
/// later, its PDFium lifecycle/worker must be coordinated with this owner.
Future<ImportedArticleDraft> importPdf(File file) {
  final path = file.absolute.path;
  final task = _pdfImportQueue.then(
    (_) => Isolate.run(() => _importPdfInWorker(path)),
  );
  // A failed file must not prevent the next queued import from running.
  _pdfImportQueue = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  return task;
}

const _maxDocumentBytes = 256 * 1024 * 1024;
const _maxTextCharacters = 2 * 1024 * 1024;
const _maxAnnotationStringBytes = 4 * 1024 * 1024;

ImportedArticleDraft _importPdfInWorker(String path) {
  final file = File(path);
  late final List<int> bytes;
  try {
    if (file.lengthSync() > _maxDocumentBytes) {
      throw const PdfImportException('文件超过 256 兆字节，请先拆分后再导入。');
    }
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    throw const PdfImportException('无法读取文件，请确认文件存在且未被其他程序独占。');
  }
  if (bytes.isEmpty) throw const PdfImportException('文件为空，无法导入正文和批注。');

  late final PDFium pdfium;
  try {
    pdfium = getPdfium();
    pdfium.FPDF_InitLibrary();
  } catch (_) {
    throw const PdfImportException('文档解析组件未能加载，请使用包含解析组件的完整安装包。');
  }

  final data = calloc<Uint8>(bytes.length);
  try {
    data.asTypedList(bytes.length).setAll(0, bytes);
    // The generated 0.2.1 binding resolves this symbol lazily. On Windows,
    // PDFium uses the OS thread's GetLastError slot, so doing the first symbol
    // lookup AFTER a failed load can overwrite its error. Resolve it before
    // loading and capture the result immediately, before other native calls.
    pdfium.FPDF_GetLastError();
    // Loading bytes, rather than a narrow C file path, also supports Chinese
    // filenames on Windows without depending on the active system code page.
    final document = pdfium.FPDF_LoadMemDocument64(
      data.cast<Void>(),
      bytes.length,
      nullptr,
    );
    final loadError = pdfium.FPDF_GetLastError();
    if (document == nullptr) {
      throw PdfImportException(_documentError(loadError), nativeCode: loadError);
    }
    try {
      // Bit 5 is the document's copy/extract permission. Unencrypted documents
      // return all permission bits set. Do not bypass a restricted document.
      if ((pdfium.FPDF_GetDocPermissions(document) & 0x10) == 0) {
        throw const PdfImportException('文件限制复制和提取文字，请取得权限后再导入。');
      }
      return _readDocument(pdfium, document, path);
    } finally {
      pdfium.FPDF_CloseDocument(document);
    }
  } finally {
    calloc.free(data);
    pdfium.FPDF_DestroyLibrary();
  }
}

String _documentError(int code) => switch (code) {
  2 => '无法读取文档数据，请重新保存文件后再导入。',
  3 => '文件不是有效文档或已经损坏，请在原软件中重新保存后再导入。',
  4 => '文件已加密，需要先在原软件中输入密码并另存为可读取的文件。',
  5 => '文件采用了不支持的加密保护，请在原软件中解除保护后再导入。',
  6 => '文档页面无法解析，请在原软件中重新保存后再导入。',
  _ => '文档解析失败，解析组件未提供可识别的原因。请检查文件是否需要密码或已经损坏，'
      '并在原软件中重新保存后再导入。',
};

ImportedArticleDraft _readDocument(
  PDFium pdfium,
  FPDF_DOCUMENT document,
  String path,
) {
  final pageCount = pdfium.FPDF_GetPageCount(document);
  if (pageCount <= 0) throw const PdfImportException('文件没有可读取的页面。');
  final builder = _BodyBuilder();
  final pages = <_ParsedPage>[];
  final warnings = <String>[];
  var characterCount = 0;

  for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
    final pageNumber = pageIndex + 1;
    final page = pdfium.FPDF_LoadPage(document, pageIndex);
    if (page == nullptr) {
      throw PdfImportException('第 $pageNumber 页无法读取，已中止导入以避免生成缺页稿件。');
    }
    try {
      final extracted = _readPage(pdfium, page, pageNumber, builder);
      characterCount += extracted.characterCount;
      if (characterCount > _maxTextCharacters) {
        throw const PdfImportException('文档正文超过两百万字符，请先拆分后再导入。');
      }
      pages.add(extracted);
      builder.endPage();
    } finally {
      pdfium.FPDF_ClosePage(page);
    }
  }

  final body = builder.body;
  final annotations = <ReadingAnnotation>[];
  var emptyComments = 0;
  for (final page in pages) {
    if (!page.hasVisibleText) {
      warnings.add(
        '第 ${page.number} 页没有可提取的正文文字（扫描页、空白页或缺少文字层）；该页备注仍会保留。',
      );
    }
    if (page.undecodableCharacters > 0) {
      warnings.add(
        '第 ${page.number} 页有 ${page.undecodableCharacters} 个字符无法解码，'
        '正文已用“�”标识，请核对原稿。',
      );
    }
    final byIndex = {for (final note in page.notes) note.index: note};
    final resolved = <int, PdfAnnotationMatch>{};

    PdfAnnotationMatch resolve(_RawNote note, Set<int> visiting) {
      final previous = resolved[note.index];
      if (previous != null) return previous;
      if (!visiting.add(note.index)) {
        return const PdfAnnotationMatch(
          unresolvedReason: '这条批注的回复关系形成循环，请重新选词定位。',
        );
      }
      late final PdfAnnotationMatch result;
      if (_textMarkupTypes.contains(note.subtype)) {
        result = matchPdfAnnotationRanges(
          body: body,
          glyphs: page.glyphs,
          quads: note.quads,
        );
      } else if (note.parentIndex != null && byIndex[note.parentIndex] != null) {
        result = resolve(byIndex[note.parentIndex]!, visiting);
      } else {
        result = PdfAnnotationMatch(
          unresolvedReason: _unresolvedReason(note.subtype, note.hasParent),
        );
      }
      visiting.remove(note.index);
      resolved[note.index] = result;
      return result;
    }

    for (final note in page.notes) {
      if (note.text.isEmpty) {
        emptyComments++;
        continue;
      }
      final match = resolve(note, <int>{});
      annotations.add(
        ReadingAnnotation(
          id: 'pdf-p${page.number}-a${note.index}',
          text: note.text,
          ranges: match.ranges,
          source: 'pdf',
          page: page.number,
          unresolvedReason: match.unresolvedReason,
        ),
      );
    }
  }

  if (body.replaceAll(RegExp(r'[\s\u200B-\u200F\uFEFF]'), '').isEmpty) {
    final notesMessage = annotations.isEmpty
        ? ''
        : '已发现 ${annotations.length} 条备注，但没有可供绑定的正文。';
    throw PdfImportException(
      '文件没有可提取的正文文字。$notesMessage'
      '扫描件需要先识别为可选中文字的文档，再导入本应用。',
    );
  }
  if (emptyComments > 0) {
    warnings.add('有 $emptyComments 条标记未保存备注文字，未将空白标记转换为阅读备注。');
  }
  final unresolvedCount = annotations.where((note) => !note.isAnchored).length;
  if (unresolvedCount > 0) {
    warnings.add('有 $unresolvedCount 条备注没有精确的原文范围，已保留为待定位备注，请选词后绑定。');
  }

  final name = path.split(RegExp(r'[\\/]')).last;
  return ImportedArticleDraft(
    title: name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim(),
    content: builder.html,
    annotations: List.unmodifiable(annotations),
    warnings: List.unmodifiable(warnings),
  );
}

_ParsedPage _readPage(
  PDFium pdfium,
  FPDF_PAGE page,
  int pageNumber,
  _BodyBuilder builder,
) {
  final glyphs = <PdfTextGlyph>[];
  var characterCount = 0;
  var undecodable = 0;
  var hasVisibleText = false;
  final textPage = pdfium.FPDFText_LoadPage(page);
  if (textPage != nullptr) {
    try {
      characterCount = pdfium.FPDFText_CountChars(textPage);
      if (characterCount < 0) {
        throw PdfImportException('第 $pageNumber 页的文字无法读取，请重新保存文件后再导入。');
      }
      if (characterCount > _maxTextCharacters) {
        throw const PdfImportException('单页正文超过两百万字符，请先拆分后再导入。');
      }
      using((arena) {
        final left = arena<Double>();
        final right = arena<Double>();
        final bottom = arena<Double>();
        final top = arena<Double>();
        var previousWasCarriageReturn = false;
        for (var index = 0; index < characterCount; index++) {
          final code = pdfium.FPDFText_GetUnicode(textPage, index);
          if (code == 13 || code == 10 || code == 12 || code == 0x2028 || code == 0x2029) {
            if (code != 10 || !previousWasCarriageReturn) builder.lineBreak();
            previousWasCarriageReturn = code == 13;
            continue;
          }
          previousWasCarriageReturn = false;
          final decoded = code > 0 && code <= 0x10ffff;
          if (!decoded) undecodable++;
          final text = String.fromCharCode(decoded ? code : 0xfffd);
          final start = builder.length;
          builder.add(text);
          if (text.trim().isNotEmpty) hasVisibleText = true;
          PdfTextBounds? bounds;
          if (pdfium.FPDFText_GetCharBox(
                textPage,
                index,
                left,
                right,
                bottom,
                top,
              ) !=
              0) {
            bounds = PdfTextBounds(
              left: left.value,
              bottom: bottom.value,
              right: right.value,
              top: top.value,
            );
          }
          glyphs.add(
            PdfTextGlyph(
              start: start,
              end: builder.length,
              bounds: bounds,
              isDecoded: decoded,
            ),
          );
        }
      });
    } finally {
      pdfium.FPDFText_ClosePage(textPage);
    }
  }

  final notes = <_RawNote>[];
  final count = pdfium.FPDFPage_GetAnnotCount(page);
  if (count < 0) {
    throw PdfImportException('第 $pageNumber 页的批注无法读取，请重新保存文件后再导入。');
  }
  for (var index = 0; index < count; index++) {
    final annot = pdfium.FPDFPage_GetAnnot(page, index);
    if (annot == nullptr) {
      throw PdfImportException('第 $pageNumber 页有批注无法读取，已中止导入以避免遗漏。');
    }
    try {
      final subtype = pdfium.FPDFAnnot_GetSubtype(annot);
      if (_nonCommentTypes.contains(subtype)) continue;
      final quads = <PdfTextQuad>[];
      if (_textMarkupTypes.contains(subtype)) {
        final quadCount = pdfium.FPDFAnnot_CountAttachmentPoints(annot);
        using((arena) {
          final quad = arena<FS_QUADPOINTSF>();
          for (var quadIndex = 0; quadIndex < quadCount; quadIndex++) {
            if (pdfium.FPDFAnnot_GetAttachmentPoints(annot, quadIndex, quad) == 0) {
              // A deliberately invalid quad makes the whole note unresolved.
              quads.add(const PdfTextQuad([]));
              continue;
            }
            final value = quad.ref;
            quads.add(
              PdfTextQuad([
                PdfTextPoint(value.x1, value.y1),
                PdfTextPoint(value.x2, value.y2),
                PdfTextPoint(value.x3, value.y3),
                PdfTextPoint(value.x4, value.y4),
              ]),
            );
          }
        });
      }
      int? parentIndex;
      var hasParent = false;
      using((arena) {
        final key = 'IRT'.toNativeUtf8(allocator: arena).cast<Char>();
        hasParent = pdfium.FPDFAnnot_HasKey(annot, key) != 0;
        final parent = pdfium.FPDFAnnot_GetLinkedAnnot(annot, key);
        if (parent != nullptr) {
          try {
            final found = pdfium.FPDFPage_GetAnnotIndex(page, parent);
            if (found >= 0) parentIndex = found;
          } finally {
            pdfium.FPDFPage_CloseAnnot(parent);
          }
        }
      });
      notes.add(
        _RawNote(
          index: index,
          subtype: subtype,
          text: _readNoteText(pdfium, annot),
          quads: quads,
          parentIndex: parentIndex,
          hasParent: hasParent,
        ),
      );
    } finally {
      pdfium.FPDFPage_CloseAnnot(annot);
    }
  }
  return _ParsedPage(
    number: pageNumber,
    glyphs: glyphs,
    notes: notes,
    characterCount: characterCount,
    undecodableCharacters: undecodable,
    hasVisibleText: hasVisibleText,
  );
}

String _readNoteText(PDFium pdfium, FPDF_ANNOTATION annot) {
  var text = _readString(pdfium, annot, 'Contents');
  if (text.trim().isEmpty) {
    final rich = _readString(pdfium, annot, 'RC');
    if (rich.trim().isNotEmpty) {
      try {
        text = XmlDocument.parse(rich.replaceAll('&nbsp;', '&#160;')).innerText;
      } on XmlParserException {
        // Retain the original rich content instead of inventing note text or
        // discarding a comment whose producer omitted its plain-text Contents.
        text = rich;
      }
    }
  }
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
}

String _readString(PDFium pdfium, FPDF_ANNOTATION annot, String name) {
  return using((arena) {
    final key = name.toNativeUtf8(allocator: arena).cast<Char>();
    final byteCount = pdfium.FPDFAnnot_GetStringValue(annot, key, nullptr, 0);
    if (byteCount <= 2) return '';
    if (byteCount > _maxAnnotationStringBytes || byteCount.isOdd) {
      throw const PdfImportException('文件中的批注文字过大或编码损坏，请在原软件中重新保存后再导入。');
    }
    final data = arena<Uint16>(byteCount ~/ 2);
    final received = pdfium.FPDFAnnot_GetStringValue(
      annot,
      key,
      data.cast<FPDF_WCHAR>(),
      byteCount,
    );
    if (received == 0 || received > byteCount || received.isOdd) {
      throw const PdfImportException('批注文字读取失败，请在原软件中重新保存后再导入。');
    }
    final units = data.asTypedList(received ~/ 2);
    var length = units.length;
    if (length > 0 && units[length - 1] == 0) length--;
    return String.fromCharCodes(units.take(length));
  });
}

const _textMarkupTypes = {
  FPDF_ANNOT_HIGHLIGHT,
  FPDF_ANNOT_UNDERLINE,
  FPDF_ANNOT_SQUIGGLY,
  FPDF_ANNOT_STRIKEOUT,
};

const _nonCommentTypes = {
  FPDF_ANNOT_LINK,
  FPDF_ANNOT_POPUP,
  FPDF_ANNOT_WIDGET,
  FPDF_ANNOT_SCREEN,
  FPDF_ANNOT_PRINTERMARK,
  FPDF_ANNOT_TRAPNET,
  FPDF_ANNOT_WATERMARK,
  FPDF_ANNOT_XFAWIDGET,
};

String _unresolvedReason(int subtype, bool hasParent) {
  if (hasParent) return '这条回复的原批注无法定位，请在稿件中重新选词。';
  return switch (subtype) {
    FPDF_ANNOT_TEXT => '便笺批注只保存页面位置，没有精确的选词范围，请重新选词定位。',
    FPDF_ANNOT_FREETEXT => '自由文本批注的文字框不是原文选区，请重新选词定位。',
    FPDF_ANNOT_LINE => '箭头或线条只保存端点，没有精确的选词范围，请重新选词定位。',
    _ => '这类图形批注没有精确的选词范围，备注已保留，请重新选词定位。',
  };
}

class _RawNote {
  const _RawNote({
    required this.index,
    required this.subtype,
    required this.text,
    required this.quads,
    required this.parentIndex,
    required this.hasParent,
  });

  final int index;
  final int subtype;
  final String text;
  final List<PdfTextQuad> quads;
  final int? parentIndex;
  final bool hasParent;
}

class _ParsedPage {
  const _ParsedPage({
    required this.number,
    required this.glyphs,
    required this.notes,
    required this.characterCount,
    required this.undecodableCharacters,
    required this.hasVisibleText,
  });

  final int number;
  final List<PdfTextGlyph> glyphs;
  final List<_RawNote> notes;
  final int characterCount;
  final int undecodableCharacters;
  final bool hasVisibleText;
}

class _BodyBuilder {
  final _body = StringBuffer();
  final _line = StringBuffer();
  final _paragraphs = <String>[];
  var length = 0;

  void add(String text) {
    _body.write(text);
    _line.write(text);
    length += text.length;
  }

  void lineBreak() {
    _paragraphs.add(_line.toString());
    _line.clear();
  }

  void endPage() {
    if (_line.isNotEmpty) lineBreak();
  }

  String get body => _body.toString();

  String get html => _paragraphs
      .map(
        (paragraph) =>
            '<p>${const HtmlEscape(HtmlEscapeMode.element).convert(paragraph)}</p>',
      )
      .join('\n');
}
