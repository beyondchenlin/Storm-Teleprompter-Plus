import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../utils/constants.dart';

/// The script and the controls occupy separate, bounded regions. The reading
/// anchor is expressed in the whole stage's coordinates, so hiding a toolbar
/// does not move the selected word when there is still room for its row.
class TeleprompterViewport extends StatelessWidget {
  final Widget? header;
  final double headerHeight;
  final Widget? footer;
  final double readingLineOffset;
  final bool showReadingLabel;
  final bool mirrorMode;
  final Color readingColor;
  final Widget Function(BuildContext context, double readingLineY) builder;

  const TeleprompterViewport({
    super.key,
    this.header,
    this.headerHeight = 0,
    this.footer,
    required this.readingLineOffset,
    required this.showReadingLabel,
    required this.mirrorMode,
    required this.readingColor,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight;
      final effectiveHeaderHeight = header == null
          ? 0.0
          : math.min(headerHeight, height * 0.24);
      final ratio = readingLineOffset > 0
          ? readingLineOffset.clamp(0.0, 1.0)
          : constraints.maxWidth < LayoutConstants.compactBreakpoint
          ? TeleprompterConstants.readingLineRatioMobile
          : TeleprompterConstants.readingLineRatioDesktop;

      return Column(
        children: [
          if (header != null)
            SizedBox(
              key: const ValueKey('teleprompter-header'),
              height: effectiveHeaderHeight,
              child: ClipRect(child: SingleChildScrollView(child: header!)),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bodyConstraints) {
                final labelHeight = showReadingLabel
                    ? math.min(22.0, bodyConstraints.maxHeight * 0.12)
                    : 0.0;
                return Column(
                  children: [
                    if (showReadingLabel)
                      SizedBox(
                        key: const ValueKey('reading-area-label'),
                        height: labelHeight,
                        child: Center(
                          child: Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.diagonal3Values(
                              mirrorMode ? -1 : 1,
                              1,
                              1,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '阅读区',
                                style: TextStyle(
                                  color: readingColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ClipRect(
                        key: const ValueKey('teleprompter-reading-viewport'),
                        child: builder(
                          context,
                          height * ratio - effectiveHeaderHeight - labelHeight,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (footer != null)
            ConstrainedBox(
              key: const ValueKey('teleprompter-footer'),
              constraints: BoxConstraints(maxHeight: height * 0.42),
              child: ClipRect(
                child: SingleChildScrollView(reverse: true, child: footer!),
              ),
            ),
        ],
      );
    },
  );
}
