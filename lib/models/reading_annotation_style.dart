import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'app_settings.dart';

/// Only the annotation foreground uses these preferences. Keeping them out of
/// ReadingTextGeometry prevents an appearance adjustment from reflowing text.
@immutable
class ReadingAnnotationStyle {
  static const defaultColor = AppSettings.defaultAnnotationColor;
  static const minimumFontSize = AppSettings.minAnnotationFontSize;
  static const maximumFontSize = AppSettings.maxAnnotationFontSize;

  /// Empty follows the manuscript body font, including platform fallback.
  final String fontFamily;

  /// Zero keeps the original automatic 22%-of-body size. A nonzero value is a
  /// preferred logical-pixel size; the renderer may reduce it to fit safely.
  final double fontSize;
  final int color;

  const ReadingAnnotationStyle({
    this.fontFamily = '',
    this.fontSize = 0,
    this.color = defaultColor,
  });

  factory ReadingAnnotationStyle.fromSettings(AppSettings settings) =>
      ReadingAnnotationStyle(
        fontFamily: settings.annotationFontFamily,
        fontSize: settings.annotationFontSize,
        color: settings.annotationColor,
      );

  double preferredFontSizeFor(double bodyFontSize) {
    if (!fontSize.isFinite || fontSize == 0) return bodyFontSize * .22;
    return fontSize.clamp(minimumFontSize, maximumFontSize).toDouble();
  }

  String effectiveFontFamily(String bodyFontFamily) =>
      fontFamily.trim().isEmpty ? bodyFontFamily : fontFamily.trim();

  // Imported or hand-edited settings must never create invisible reminders.
  Color get paintColor => Color(
    color < 0 || color > 0xFFFFFFFF ? defaultColor : color | 0xFF000000,
  );

  @override
  bool operator ==(Object other) =>
      other is ReadingAnnotationStyle &&
      fontFamily == other.fontFamily &&
      fontSize == other.fontSize &&
      color == other.color;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, color);
}

/// An immutable result for a bounded preview, never a mutable native painter.
@immutable
class ReadingAnnotationDisplayStatus {
  final int anchorCount;
  final int labelCount;
  final int reducedLabelCount;
  final int truncatedLabelCount;
  final double? smallestFontSize;
  final double? largestFontSize;

  const ReadingAnnotationDisplayStatus({
    this.anchorCount = 0,
    this.labelCount = 0,
    this.reducedLabelCount = 0,
    this.truncatedLabelCount = 0,
    this.smallestFontSize,
    this.largestFontSize,
  });

  bool get hasAnnotations => anchorCount > 0;
  int get hiddenLabelCount => anchorCount - labelCount;
  bool get hasAdaptation =>
      reducedLabelCount > 0 ||
      truncatedLabelCount > 0 ||
      hiddenLabelCount > 0;

  String get message {
    if (!hasAnnotations) return '选中原文字词，即可预览批注效果。';
    if (labelCount == 0) {
      return '当前行间留白不足，已保留字词框；点击字词框查看完整批注。';
    }
    String size(double value) => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    final smallest = smallestFontSize;
    final largest = largestFontSize;
    final range = smallest == null || largest == null
        ? ''
        : (largest - smallest).abs() < .05
        ? '${size(largest)} 像素'
        : '${size(smallest)}～${size(largest)} 像素';
    return [
      if (range.isNotEmpty)
        reducedLabelCount > 0
            ? '已按行间留白缩至 $range。'
            : '当前显示 $range。',
      if (truncatedLabelCount > 0) '长批注已省略，点击查看全文。',
      if (hiddenLabelCount > 0) '部分批注仅显示字词框，可点击查看全文。',
    ].join();
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingAnnotationDisplayStatus &&
      anchorCount == other.anchorCount &&
      labelCount == other.labelCount &&
      reducedLabelCount == other.reducedLabelCount &&
      truncatedLabelCount == other.truncatedLabelCount &&
      smallestFontSize == other.smallestFontSize &&
      largestFontSize == other.largestFontSize;

  @override
  int get hashCode => Object.hash(
    anchorCount,
    labelCount,
    reducedLabelCount,
    truncatedLabelCount,
    smallestFontSize,
    largestFontSize,
  );
}
