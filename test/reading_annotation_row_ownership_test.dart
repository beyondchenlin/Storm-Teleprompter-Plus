import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_annotation_layer.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_emphasis_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('视觉行矩形小数重叠时，批注字形包络和框仍只属于各自的视觉行', () {
    const text = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final body = ReadingTextLayout(
      line: TextParser.parsePlainText(text).single,
      geometry: const ReadingTextGeometry(fontSize: 40, lineHeight: 1.8),
      width: 235,
      direction: TextDirection.ltr,
    );
    final cache = ReadingGlyphPainterCache();
    addTearDown(body.dispose);
    addTearDown(cache.dispose);
    expect(body.rows.length, greaterThan(2));

    // Reproduce native font metric rounding independently of the test font:
    // adjacent line rectangles overlap by 0.4 px, while their glyph baselines
    // and logical text boundaries remain distinct and unchanged.
    for (var index = 1; index < body.rows.length; index++) {
      final row = body.rows[index];
      body.rows[index] = ReadingVisualRow(
        start: row.start,
        end: row.end,
        top: body.rows[index - 1].bottom - .4,
        height: row.height,
        baseline: row.baseline,
      );
    }
    final marked = body.rows[1].start;
    final notes = ReadingAnnotationLayout(
      textLayout: body,
      annotations: [
        ReadingAnnotation(
          id: 'second-row',
          text: '重读',
          ranges: [
            AnnotationRange(
              start: marked,
              end: marked + 1,
              quote: text.substring(marked, marked + 1),
            ),
          ],
        ),
      ],
      glyphCache: cache,
    );
    addTearDown(notes.dispose);

    // This deliberately remains an overlap-based paint query. The annotation
    // path must no longer confuse it with exact line membership.
    final first = body.rows.first;
    expect(
      body.placementsIn(Rect.fromLTWH(0, first.top, body.width, first.height))
          .any((placement) => identical(placement.row, body.rows[1])),
      isTrue,
    );

    final seen = <int>{};
    for (var index = 0; index < body.rows.length; index++) {
      final row = body.rows[index];
      final owned = body.placementsForRow(index).toList();
      expect(owned, isNotEmpty);
      expect(owned.length, row.end - row.start);
      for (final placement in owned) {
        expect(identical(placement.row, row), isTrue);
        expect(seen.add(placement.grapheme.rawStart), isTrue);
      }
      final annotationRow = notes.rowAt(index);
      expect(annotationRow.bodyBounds.length, owned.length);
      expect(annotationRow.anchors, hasLength(index == 1 ? 1 : 0));
      final expectedBounds = owned
          .map((placement) => body.maximumGlyphBounds(placement, cache))
          .toList();
      expect(annotationRow.bodyBounds, orderedEquals(expectedBounds));
    }
    expect(seen.length, text.length);
    expect(body.placementsForRow(-1), isEmpty);
    expect(body.placementsForRow(body.rows.length), isEmpty);
  });
}
