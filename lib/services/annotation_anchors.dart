import '../models/reading_annotation.dart';
import 'text_parser.dart';

/// Uses exactly the same raw character positions as reading and speech sync.
/// HTML paragraph breaks do not consume an index; plain-text newlines do.
class AnnotationAnchors {
  AnnotationAnchors._();

  static String bodyText(String content) {
    final lines = TextParser.isHtml(content)
        ? TextParser.parse(content)
        : TextParser.parsePlainText(content);
    final buffer = StringBuffer();
    for (final line in lines) {
      for (final character in line.characters) {
        while (buffer.length < character.rawIndex) {
          buffer.write('\n');
        }
        buffer.write(character.char);
      }
    }
    return buffer.toString();
  }

  static bool matches(String body, AnnotationRange range) =>
      range.start >= 0 &&
      range.end > range.start &&
      range.end <= body.length &&
      range.quote.isNotEmpty &&
      body.substring(range.start, range.end) == range.quote;

  static List<ReadingAnnotation> validate(
    String content,
    List<ReadingAnnotation> notes,
  ) {
    if (notes.isEmpty) return const [];
    final body = bodyText(content);
    return List.unmodifiable(
      notes.map((note) {
        if (!note.isAnchored) return note;
        if (note.ranges.every((range) => matches(body, range))) return note;
        return note.copyWith(unresolvedReason: '原文已变更，请重新选择对应字词');
      }),
    );
  }

  /// Remap one editor operation through its unchanged prefix and suffix.
  /// Never search for repeated words. Edits touching a selection require a
  /// deliberate reattachment; unchanged selections shift without losing notes.
  static List<ReadingAnnotation> remap(
    String previousContent,
    String nextContent,
    List<ReadingAnnotation> notes,
  ) {
    if (notes.isEmpty) return const [];
    final before = bodyText(previousContent);
    final after = bodyText(nextContent);
    if (before == after) return validate(nextContent, notes);
    var prefix = 0;
    while (prefix < before.length &&
        prefix < after.length &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < before.length &&
        suffix < after.length &&
        before.codeUnitAt(before.length - suffix - 1) ==
            after.codeUnitAt(after.length - suffix - 1)) {
      suffix++;
    }
    // Identical adjacent words admit several equally valid text diffs. The
    // entire ambiguous interval is invalidated rather than guessing which
    // occurrence was inserted/deleted (e.g. 不是不是 -> 不是).
    final shorter = before.length < after.length ? before.length : after.length;
    final ambiguous = prefix + suffix > shorter;
    final editStart = ambiguous ? shorter - suffix : prefix;
    final oldEnd = ambiguous
        ? prefix +
              (before.length > after.length ? before.length - after.length : 0)
        : before.length - suffix;
    final delta = after.length - before.length;
    return List.unmodifiable(
      notes.map((note) {
        if (!note.isAnchored) return note;
        final moved = <AnnotationRange>[];
        for (final range in note.ranges) {
          if (!matches(before, range)) {
            return note.copyWith(unresolvedReason: '原文范围已失效，请重新选择字词');
          }
          if (range.end <= editStart) {
            moved.add(range);
          } else if (range.start >= oldEnd) {
            moved.add(range.shifted(delta));
          } else {
            return note.copyWith(unresolvedReason: '批注对应的字词已编辑，请重新定位');
          }
        }
        if (!moved.every((range) => matches(after, range))) {
          return note.copyWith(unresolvedReason: '正文变更后无法确认范围，请重新定位');
        }
        return note.copyWith(ranges: moved);
      }),
    );
  }
}
