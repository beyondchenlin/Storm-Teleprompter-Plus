import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/reading_glyph_ink_cache.dart';

/// Native raster callbacks can belong to the widget test's fake async zone.
/// Waiting for the whole queue inside runAsync would block the fake-zone
/// microtasks that finish that queue. Alternate real native events with frame
/// pumps, and require two fully idle passes so notification-triggered requests
/// are included as well. This also waits for disposal of in-flight resources.
Future<void> settleReadingInk(
  WidgetTester tester,
  ReadingGlyphInkCache cache,
) async {
  var idlePasses = 0;
  for (var pass = 0; pass < 600; pass++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    final idle =
        cache.debugPendingCount == 0 &&
        cache.debugActiveCount == 0 &&
        cache.debugLivePictureCount == 0 &&
        cache.debugLiveImageCount == 0;
    idlePasses = idle ? idlePasses + 1 : 0;
    if (idlePasses >= 2) return;
  }
  fail(
    '墨迹测量未在有界轮次内完成：'
    '等待=${cache.debugPendingCount}，运行=${cache.debugActiveCount}，'
    '绘图=${cache.debugLivePictureCount}，图像=${cache.debugLiveImageCount}',
  );
}
