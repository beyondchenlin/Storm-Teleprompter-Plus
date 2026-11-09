import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

typedef _InkKey = ({
  String text,
  TextStyle style,
  TextDirection direction,
  Size size,
  TextScaler scaler,
  TextAlign alignment,
  ui.Locale? locale,
  StrutStyle? strut,
  TextWidthBasis widthBasis,
  ui.TextHeightBehavior? heightBehavior,
  int? maxLines,
  String? ellipsis,
});

class _InkJob {
  final _InkKey key;
  ui.Picture? picture;
  final int width;
  final int height;
  final double padding;

  _InkJob(this.key, this.picture, this.width, this.height, this.padding);
}

/// Measures ink without changing the caller's paragraph layout or its painter.
///
/// [boundsFor] receives the caller's opaque, white, background-free measurement
/// painter, with all requested text decorations retained. Its picture is
/// recorded synchronously: an owner may immediately evict/dispose the painter.
/// Rasterization and transparent-pixel scanning then finish asynchronously.
/// Null means that the caller must retain its conservative font envelope.
class ReadingGlyphInkCache extends ChangeNotifier {
  static const int maximumCachedEntries = 512;
  static const int maximumPendingMeasurements = 128;
  static const int maximumConcurrentMeasurements = 4;
  static const int maximumRasterDimension = 2048;
  static const int maximumRasterPixels = 1024 * 1024;
  static const double rasterScale = 2;
  static const double boundsTolerance = 1;

  final int capacity;
  final int pendingLimit;
  final int concurrency;
  final _cache = LinkedHashMap<_InkKey, Rect?>();
  final _pending = <_InkKey>{};
  final _queue = Queue<_InkJob>();
  Completer<void>? _settledCompleter;
  bool _disposed = false;
  bool _notificationScheduled = false;
  int _revision = 0;
  int _active = 0;
  int _peakActive = 0;
  int _livePictures = 0;
  int _liveImages = 0;

  ReadingGlyphInkCache({
    int capacity = maximumCachedEntries,
    int pendingLimit = maximumPendingMeasurements,
    int concurrency = maximumConcurrentMeasurements,
  }) : capacity = _limit(capacity, maximumCachedEntries, 'capacity'),
       pendingLimit = _limit(
         pendingLimit,
         maximumPendingMeasurements,
         'pendingLimit',
       ),
       concurrency = _limit(
         concurrency,
         maximumConcurrentMeasurements,
         'concurrency',
       );

  static int _limit(int value, int maximum, String name) {
    if (value < 1 || value > maximum) {
      throw RangeError.range(value, 1, maximum, name);
    }
    return value;
  }

  int get revision => _revision;

  /// Waits for queued/in-flight captures and their coalesced notifications.
  /// A disposed cache still waits for native work to release its resources.
  Future<void> get settled => _settledCompleter?.future ?? Future<void>.value();

  @visibleForTesting
  int get length => _cache.length;
  @visibleForTesting
  int get debugPendingCount => _pending.length;
  @visibleForTesting
  int get debugActiveCount => _active;
  @visibleForTesting
  int get debugPeakActiveCount => _peakActive;
  @visibleForTesting
  int get debugLivePictureCount => _livePictures;
  @visibleForTesting
  int get debugLiveImageCount => _liveImages;

  Rect? boundsFor(
    String text,
    TextStyle style,
    TextDirection direction,
    TextPainter painter,
  ) {
    if (_disposed) return null;
    // Native shaping determines whether decorated whitespace has visible ink.
    if (text.isEmpty ||
        (text.trim().isEmpty &&
            (style.decoration == null ||
                style.decoration == TextDecoration.none))) {
      return Rect.zero;
    }
    // Glyphs are short grapheme clusters; do not retain unbounded input keys.
    if (text.length > 512) return null;
    final key = (
      text: text,
      style: style,
      direction: direction,
      size: painter.size,
      scaler: painter.textScaler,
      alignment: painter.textAlign,
      locale: painter.locale,
      strut: painter.strutStyle,
      widthBasis: painter.textWidthBasis,
      heightBehavior: painter.textHeightBehavior,
      maxLines: painter.maxLines,
      ellipsis: painter.ellipsis,
    );
    if (_cache.containsKey(key)) {
      final cached = _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }
    if (_pending.contains(key) || _pending.length >= pendingLimit) return null;
    final job = _record(key, painter);
    if (job == null) {
      // A known unsupported size/capture must not allocate again every frame.
      _remember(key, null);
      return null;
    }
    _settledCompleter ??= Completer<void>();
    _pending.add(key);
    _queue.add(job);
    _pump();
    return null;
  }

  _InkJob? _record(_InkKey key, TextPainter painter) {
    final size = key.size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 0 ||
        size.height < 0) {
      return null;
    }
    final fontSize = painter.textScaler.scale(key.style.fontSize ?? 14);
    if (!fontSize.isFinite || fontSize < 0) return null;
    var effectMargin = (key.style.foreground?.strokeWidth ?? 0).abs();
    for (final shadow in key.style.shadows ?? const <Shadow>[]) {
      effectMargin = math.max(
        effectMargin,
        shadow.offset.distance + shadow.blurRadius * 3,
      );
    }
    // Leave room above accents, below decoration, and on both italic bearings.
    final padding = math.max(
      8.0,
      math.max(fontSize, size.height) * .75 + effectMargin + 2,
    );
    if (!padding.isFinite) return null;
    final roundedPadding = padding.ceilToDouble();
    final scaledWidth = (size.width + roundedPadding * 2) * rasterScale;
    final scaledHeight = (size.height + roundedPadding * 2) * rasterScale;
    if (scaledWidth > maximumRasterDimension ||
        scaledHeight > maximumRasterDimension ||
        scaledWidth * scaledHeight > maximumRasterPixels) {
      return null;
    }
    final width = scaledWidth.ceil();
    final height = scaledHeight.ceil();
    if (width <= 0 || height <= 0 || width * height > maximumRasterPixels) {
      return null;
    }
    final recorder = ui.PictureRecorder();
    try {
      final canvas = Canvas(recorder)..scale(rasterScale);
      painter.paint(canvas, Offset(roundedPadding, roundedPadding));
      final picture = recorder.endRecording();
      _livePictures++;
      return _InkJob(key, picture, width, height, roundedPadding);
    } catch (_) {
      if (recorder.isRecording) recorder.endRecording().dispose();
      return null;
    }
  }

  void _pump() {
    while (!_disposed && _active < concurrency && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      _peakActive = math.max(_peakActive, _active);
      unawaited(_measure(job));
    }
  }

  Future<void> _measure(_InkJob job) async {
    ui.Image? image;
    try {
      image = await job.picture!.toImage(job.width, job.height);
      _liveImages++;
      if (_disposed) return;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (_disposed) return;
      Rect? result;
      if (data != null && data.lengthInBytes >= job.width * job.height * 4) {
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        var left = job.width;
        var top = job.height;
        var right = -1;
        var bottom = -1;
        for (var y = 0; y < job.height; y++) {
          var alpha = y * job.width * 4 + 3;
          for (var x = 0; x < job.width; x++, alpha += 4) {
            if (bytes[alpha] == 0) continue;
            if (x < left) left = x;
            if (y < top) top = y;
            if (x > right) right = x;
            if (y > bottom) bottom = y;
          }
        }
        if (right < 0) {
          result = Rect.zero;
        } else if (left > 0 &&
            top > 0 &&
            right < job.width - 1 &&
            bottom < job.height - 1) {
          // Edge-touching ink may be clipped. Keep null in that case rather
          // than publishing a deceptively small rectangle.
          result = Rect.fromLTRB(
            left / rasterScale - job.padding,
            top / rasterScale - job.padding,
            (right + 1) / rasterScale - job.padding,
            (bottom + 1) / rasterScale - job.padding,
          ).inflate(boundsTolerance);
        }
      }
      _remember(job.key, result, completedMeasurement: true);
    } catch (_) {
      if (!_disposed) {
        _remember(job.key, null, completedMeasurement: true);
      }
    } finally {
      if (image != null) {
        image.dispose();
        _liveImages--;
      }
      _releasePicture(job);
      _pending.remove(job.key);
      _active--;
      _pump();
      _completeIfSettled();
    }
  }

  void _releasePicture(_InkJob job) {
    final picture = job.picture;
    if (picture == null) return;
    job.picture = null;
    picture.dispose();
    _livePictures--;
  }

  void _remember(
    _InkKey key,
    Rect? bounds, {
    bool completedMeasurement = false,
  }) {
    if (_disposed) return;
    _cache.remove(key);
    if (_cache.length >= capacity) _cache.remove(_cache.keys.first);
    _cache[key] = bounds;
    // Completing native work also frees a slot. Even a failed capture must
    // wake callers whose other visible glyphs were rejected by pendingLimit.
    // A synchronous known-size rejection frees no slot and needs no repaint.
    if (bounds == null && !completedMeasurement) return;
    _revision++;
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
      _completeIfSettled();
    });
  }

  void _completeIfSettled() {
    if (_active != 0 ||
        _pending.isNotEmpty ||
        _queue.isNotEmpty ||
        _notificationScheduled) {
      return;
    }
    final completer = _settledCompleter;
    _settledCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _pending.remove(job.key);
      _releasePicture(job);
    }
    _cache.clear();
    // Native work cannot be cancelled. Its finally block releases its picture
    // and image after the outstanding native operation returns; it never
    // publishes a result or notifies listeners after disposal.
    super.dispose();
    _completeIfSettled();
  }
}
