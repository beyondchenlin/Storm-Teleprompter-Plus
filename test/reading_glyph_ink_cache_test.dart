import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_glyph_ink_cache.dart';

bool _fontLoaded = false;

Future<void> _loadFixtureFont() async {
  if (_fontLoaded) return;
  final loader = FontLoader('ReadingInkFixture')
    ..addFont(
      File(
        'test/fixtures/reading_emphasis/DejaVuSansMono-BoldOblique.ttf',
      ).readAsBytes().then(ByteData.sublistView),
    );
  await loader.load();
  _fontLoaded = true;
}

TextPainter _painter(String text, TextStyle style) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
)..layout();

const _style = TextStyle(
  color: Colors.white,
  fontFamily: 'ReadingInkFixture',
  fontSize: 64,
  height: ui.kTextHeightNone,
);

/// Independent, larger 3x raster; includes every nontransparent pixel rather
/// than comparing the implementation's stored dimensions to themselves.
Future<Rect> _actualInk(TextPainter painter) async {
  const padding = 160.0;
  const scale = 3.0;
  final width = ((painter.width + padding * 2) * scale).ceil();
  final height = ((painter.height + padding * 2) * scale).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  painter.paint(canvas, const Offset(padding, padding));
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    var left = width;
    var top = height;
    var right = -1;
    var bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (bytes[(y * width + x) * 4 + 3] == 0) continue;
        if (x < left) left = x;
        if (y < top) top = y;
        if (x > right) right = x;
        if (y > bottom) bottom = y;
      }
    }
    return right < 0
        ? Rect.zero
        : Rect.fromLTRB(
            left / scale - padding,
            top / scale - padding,
            (right + 1) / scale - padding,
            (bottom + 1) / scale - padding,
          );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实斜体重音和装饰墨迹均被测量框包含且原画笔布局不变', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache();
      final style = _style.copyWith(
        fontStyle: FontStyle.italic,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.combine([
          TextDecoration.underline,
          TextDecoration.lineThrough,
        ]),
        decorationColor: Colors.white,
        decorationThickness: 2,
      );
      final painter = _painter('Áj', style);
      final originalSize = painter.size;
      final originalText = painter.text;
      try {
        expect(
          cache.boundsFor('Áj', style, TextDirection.ltr, painter),
          isNull,
        );
        await cache.settled;
        final bounds = cache.boundsFor(
          'Áj',
          style,
          TextDirection.ltr,
          painter,
        )!;
        final actual = await _actualInk(painter);
        expect(actual.isEmpty, isFalse);
        expect(bounds.left, lessThanOrEqualTo(actual.left));
        expect(bounds.top, lessThanOrEqualTo(actual.top));
        expect(bounds.right, greaterThanOrEqualTo(actual.right));
        expect(bounds.bottom, greaterThanOrEqualTo(actual.bottom));
        expect(bounds.width, lessThan(actual.width + 5));
        expect(bounds.height, lessThan(actual.height + 5));
        expect(painter.size, originalSize);
        expect(painter.text, same(originalText));
        expect(cache.debugLivePictureCount, 0);
        expect(cache.debugLiveImageCount, 0);
      } finally {
        painter.dispose();
        cache.dispose();
        await cache.settled;
      }
    });
  });

  testWidgets('首次同步录图允许立即释放原画笔，缓存命中不重复测量或通知', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache();
      var notifications = 0;
      cache.addListener(() => notifications++);
      final original = _painter('j', _style);
      expect(cache.boundsFor('j', _style, TextDirection.ltr, original), isNull);
      expect(cache.boundsFor('j', _style, TextDirection.ltr, original), isNull);
      expect(cache.debugPendingCount, 1);
      original.dispose();
      await cache.settled;
      final replacement = _painter('j', _style);
      try {
        final bounds = cache.boundsFor(
          'j',
          _style,
          TextDirection.ltr,
          replacement,
        );
        expect(bounds, isNotNull);
        expect(cache.revision, 1);
        expect(notifications, 1);
        expect(
          cache.boundsFor('j', _style, TextDirection.ltr, replacement),
          same(bounds),
        );
        await cache.settled;
        expect(cache.revision, 1);
        expect(notifications, 1);
        expect(cache.debugPendingCount, 0);
      } finally {
        replacement.dispose();
        cache.dispose();
      }
    });
  });

  testWidgets('空白返回零框，装饰空格按真实采样结果决定墨迹范围', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache();
      final blank = _painter(' ', _style);
      final decoratedStyle = _style.copyWith(
        decoration: TextDecoration.underline,
        decorationColor: Colors.white,
      );
      final decorated = _painter(' ', decoratedStyle);
      try {
        expect(
          cache.boundsFor(' ', _style, TextDirection.ltr, blank),
          Rect.zero,
        );
        expect(cache.debugPendingCount, 0);
        expect(
          cache.boundsFor(' ', decoratedStyle, TextDirection.ltr, decorated),
          isNull,
        );
        expect(cache.debugPendingCount, 1);
        await cache.settled;
        expect(cache.revision, 1);
        final bounds = cache.boundsFor(
          ' ',
          decoratedStyle,
          TextDirection.ltr,
          decorated,
        )!;
        final actual = await _actualInk(decorated);
        if (actual.isEmpty) {
          // Native shaping can omit decoration on trailing whitespace.
          expect(bounds, Rect.zero);
        } else {
          expect(bounds.isEmpty, isFalse);
          expect(bounds.left, lessThanOrEqualTo(actual.left));
          expect(bounds.right, greaterThanOrEqualTo(actual.right));
          expect(bounds.top, lessThanOrEqualTo(actual.top));
          expect(bounds.bottom, greaterThanOrEqualTo(actual.bottom));
        }
      } finally {
        blank.dispose();
        decorated.dispose();
        cache.dispose();
        await cache.settled;
      }
    });
  });

  testWidgets('缓存、排队和并行数量有界，淘汰后按需重新测量', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache(
        capacity: 2,
        pendingLimit: 3,
        concurrency: 1,
      );
      final painters = {
        for (final text in ['A', 'B', 'C', 'D', 'E'])
          text: _painter(text, _style),
      };
      try {
        for (final entry in painters.entries) {
          expect(
            cache.boundsFor(entry.key, _style, TextDirection.ltr, entry.value),
            isNull,
          );
        }
        expect(cache.debugPendingCount, 3);
        expect(cache.debugActiveCount, 1);
        expect(cache.debugLivePictureCount, 3);
        await cache.settled;
        expect(cache.length, 2);
        expect(cache.debugPeakActiveCount, 1);
        expect(cache.debugLivePictureCount, 0);
        expect(cache.debugLiveImageCount, 0);
        expect(
          cache.boundsFor('C', _style, TextDirection.ltr, painters['C']!),
          isNotNull,
        );
        expect(
          cache.boundsFor('A', _style, TextDirection.ltr, painters['A']!),
          isNull,
        );
        await cache.settled;
        expect(cache.length, 2);
        expect(
          cache.boundsFor('A', _style, TextDirection.ltr, painters['A']!),
          isNotNull,
        );
      } finally {
        for (final painter in painters.values) {
          painter.dispose();
        }
        cache.dispose();
        await cache.settled;
      }
    });
  });

  testWidgets('触边失败仍通知腾出的名额，受限流正常字形可以继续测量', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache(pendingLimit: 1, concurrency: 1);
      final clippedStyle = _style.copyWith(
        decoration: TextDecoration.underline,
        decorationColor: Colors.white,
        decorationThickness: 1000,
      );
      final clipped = _painter('A', clippedStyle);
      final normal = _painter('B', _style);
      Rect? retriedBounds;
      var notifications = 0;
      cache.addListener(() {
        notifications++;
        retriedBounds = cache.boundsFor('B', _style, TextDirection.ltr, normal);
      });
      try {
        expect(cache.boundsFor('A', clippedStyle, TextDirection.ltr, clipped), isNull);
        expect(cache.boundsFor('B', _style, TextDirection.ltr, normal), isNull);
        expect(cache.debugPendingCount, 1);
        await cache.settled;
        expect(cache.boundsFor('A', clippedStyle, TextDirection.ltr, clipped), isNull);
        expect(retriedBounds, isNotNull);
        expect(retriedBounds!.isEmpty, isFalse);
        expect(notifications, 2);
        expect(cache.revision, 2);
        expect(cache.debugPendingCount, 0);
        expect(cache.debugLivePictureCount, 0);
        expect(cache.debugLiveImageCount, 0);
      } finally {
        clipped.dispose();
        normal.dispose();
        cache.dispose();
        await cache.settled;
      }
    });
  });

  testWidgets('超大字形保持保守回退且不分配采样图', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache();
      final style = _style.copyWith(fontSize: 4096);
      final painter = _painter('W', style);
      try {
        expect(cache.boundsFor('W', style, TextDirection.ltr, painter), isNull);
        expect(cache.boundsFor('W', style, TextDirection.ltr, painter), isNull);
        await cache.settled;
        expect(cache.debugPendingCount, 0);
        expect(cache.debugActiveCount, 0);
        expect(cache.debugLivePictureCount, 0);
        expect(cache.debugLiveImageCount, 0);
        expect(cache.revision, 0);
        expect(cache.length, 1);
      } finally {
        painter.dispose();
        cache.dispose();
      }
    });
  });

  testWidgets('排队与原生采样在途时释放安全，后续不发布结果或通知', (tester) async {
    await tester.runAsync(() async {
      await _loadFixtureFont();
      final cache = ReadingGlyphInkCache(pendingLimit: 8, concurrency: 2);
      var notifications = 0;
      cache.addListener(() => notifications++);
      for (final text in ['A', 'B', 'C', 'D', 'E', 'F']) {
        final painter = _painter(text, _style);
        cache.boundsFor(text, _style, TextDirection.ltr, painter);
        painter.dispose();
      }
      expect(cache.debugPendingCount, 6);
      expect(cache.debugActiveCount, 2);
      cache.dispose();
      await cache.settled;
      expect(notifications, 0);
      expect(cache.revision, 0);
      expect(cache.length, 0);
      expect(cache.debugPendingCount, 0);
      expect(cache.debugActiveCount, 0);
      expect(cache.debugLivePictureCount, 0);
      expect(cache.debugLiveImageCount, 0);
      final painter = _painter('A', _style);
      expect(cache.boundsFor('A', _style, TextDirection.ltr, painter), isNull);
      painter.dispose();
    });
    expect(tester.takeException(), isNull);
  });

  test('资源硬上限不能通过构造参数放大', () {
    expect(() => ReadingGlyphInkCache(capacity: 513), throwsRangeError);
    expect(() => ReadingGlyphInkCache(pendingLimit: 129), throwsRangeError);
    expect(() => ReadingGlyphInkCache(concurrency: 5), throwsRangeError);
    expect(() => ReadingGlyphInkCache(capacity: 0), throwsRangeError);
  });
}
