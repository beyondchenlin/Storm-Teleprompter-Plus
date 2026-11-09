import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_annotation_layer.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_glyph_ink_cache.dart';

// Keep the chosen safe band stable while exercising real native note shaping.
class _PendingInkCache extends ReadingGlyphInkCache {
  @override
  Rect? boundsFor(String text, TextStyle style, TextDirection direction, TextPainter painter) => null;
}

({ReadingAnnotationLayout notes, ReadingAnnotation note}) _layout(String text) {
  final cache = ReadingGlyphPainterCache(inkCache: _PendingInkCache());
  final body = ReadingTextLayout(
    line: TextParser.parsePlainText('ABCDEFGH').single,
    geometry: const ReadingTextGeometry(fontSize: 64, lineHeight: 1.5),
    width: 1100,
    direction: TextDirection.ltr,
  );
  final top = body.maximumGlyphBounds(body.placementAt(0), cache, resolveInk: false).top;
  final leading = 26 - top + 3;
  expect(leading, greaterThanOrEqualTo(0));
  final note = ReadingAnnotation(
    id: 'adaptive',
    text: text,
    ranges: const [AnnotationRange(start: 2, end: 3, quote: 'C')],
  );
  final notes = ReadingAnnotationLayout(
    textLayout: body,
    annotations: [note],
    glyphCache: cache,
    leadingSpace: leading,
  );
  addTearDown(notes.dispose);
  addTearDown(body.dispose);
  addTearDown(cache.dispose);
  expect(notes.rowAt(0).safeBand.height, closeTo(26, .001));
  return (notes: notes, note: note);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('固定行间空隙内两行短备注完整显示，字号自适应仍至少八像素', () {
    const text = '放慢语速\n把意思讲清楚';
    final value = _layout(text);
    final row = value.notes.rowAt(0);
    expect(row.labels, hasLength(1));
    final label = row.labels.single;
    final fontSize = label.painter.text!.style!.fontSize!;
    expect(fontSize, inInclusiveRange(8, 64 * .22));
    expect(fontSize, lessThan(64 * .22));
    expect(label.isTruncated, isFalse);
    expect(label.painter.computeLineMetrics(), hasLength(2));
    expect(label.painter.text!.toPlainText(), text);
    expect(label.rect.top, greaterThanOrEqualTo(row.safeBand.top - .01));
    expect(label.rect.bottom, lessThanOrEqualTo(row.safeBand.bottom + .01));
    expect(row.bodyBounds.any((rect) => rect.overlaps(label.occupiedBounds)), isFalse);
    expect(label.tail, label.rect.bottomCenter);
    expect(label.tip, label.anchor.frame.topCenter);
    final vector = label.tip - label.tail;
    expect(math.atan2(vector.dy.abs(), vector.dx.abs()) * 180 / math.pi, closeTo(17.5, .001));
    expect(value.notes.notesAt(label.rect.center).single.text, text);
  });

  test('长说明无法完整展示时保留最大清晰缩略字号与完整备注正文', () {
    final text = List.filled(100, '把这一段的意思讲清楚以后再慢慢继续。').join();
    final value = _layout(text);
    final row = value.notes.rowAt(0);
    expect(row.labels, hasLength(1));
    final label = row.labels.single;
    expect(label.isTruncated, isTrue);
    expect(label.painter.text!.style!.fontSize, closeTo(64 * .22, .0001));
    expect(label.painter.computeLineMetrics().length, inInclusiveRange(1, 3));
    expect(value.note.text, text);
    expect(value.notes.notesAt(label.rect.center).single.text, text);
    expect(row.bodyBounds.any((rect) => rect.overlaps(label.occupiedBounds)), isFalse);
  });
}
