import 'package:xml/xml.dart';

/// Converts a PDF rich-text comment to the same plain-text form as Contents.
/// Paragraphs and explicit line breaks carry coaching meaning, so flattening
/// XmlNode.innerText would silently join instructions the author separated.
String extractPdfRichAnnotationText(String rich) {
  late final XmlDocument document;
  try {
    document = XmlDocument.parse(rich.replaceAll('&nbsp;', '&#160;'));
  } on XmlFormatException {
    // An unreadable rich body must survive verbatim for manual repair.
    return rich;
  }

  const blocks = {
    'p',
    'div',
    'li',
    'tr',
    'blockquote',
    'pre',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
  };
  final text = StringBuffer();
  var endsWithBreak = false;

  void append(String value) {
    if (value.isEmpty) return;
    text.write(value);
    endsWithBreak = value.endsWith('\n') || value.endsWith('\r');
  }

  void boundary() {
    if (text.isNotEmpty && !endsWithBreak) append('\n');
  }

  void visit(XmlNode node, {bool preserveSpace = false}) {
    if (node is XmlText || node is XmlCDATA) {
      final value = node.value ?? '';
      final parent = node.parent;
      // Pretty-print indentation between paragraph elements is XML structure,
      // not an extra blank coaching line. Keep whitespace within inline runs
      // and honour xml:space="preserve" on the original rich-text body.
      final paragraphIndent =
          !preserveSpace &&
          value.trim().isEmpty &&
          parent != null &&
          parent.children.whereType<XmlElement>().any(
            (child) => blocks.contains(child.name.local.toLowerCase()),
          );
      if (!paragraphIndent) append(value);
      return;
    }
    if (node is! XmlElement) {
      for (final child in node.children) {
        visit(child, preserveSpace: preserveSpace);
      }
      return;
    }
    final name = node.name.local.toLowerCase();
    if (name == 'head' || name == 'style' || name == 'script') return;
    if (name == 'br') {
      // Two authored breaks are two breaks; only implicit block boundaries
      // are deduplicated against an already present newline.
      append('\n');
      return;
    }
    final space = node.getAttribute(
      'space',
      namespaceUri: 'http://www.w3.org/XML/1998/namespace',
    );
    final preserve =
        space == 'preserve' ||
        (space != 'default' && (preserveSpace || name == 'pre'));
    final isBlock = blocks.contains(name);
    if (isBlock) boundary();
    for (final child in node.children) {
      visit(child, preserveSpace: preserve);
    }
    if (isBlock) boundary();
  }

  visit(document);
  return text.toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
}
