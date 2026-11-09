import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/reading_annotation.dart';
import '../../services/font_service.dart';
import '../common/app_color_picker_dialog.dart';
import '../editor/reading_annotation_preview.dart';

/// Changes remain local until applied. Both the controls and the preview use
/// the same snapshot, so cancelling cannot silently change another manuscript.
class ReadingAnnotationAppearanceDialog extends StatefulWidget {
  const ReadingAnnotationAppearanceDialog({
    super.key,
    required this.initialSettings,
    this.content = '',
    this.annotations = const [],
    this.focusRawIndex,
    this.scopeLabel = '应用到本稿件的全部批注',
  });

  final AppSettings initialSettings;
  final String content;
  final List<ReadingAnnotation> annotations;
  final int? focusRawIndex;
  final String scopeLabel;

  static Future<AppSettings?> show(
    BuildContext context, {
    required AppSettings initialSettings,
    String content = '',
    List<ReadingAnnotation> annotations = const [],
    int? focusRawIndex,
    String scopeLabel = '应用到本稿件的全部批注',
  }) => showDialog<AppSettings>(
    context: context,
    builder: (_) => ReadingAnnotationAppearanceDialog(
      initialSettings: initialSettings,
      content: content,
      annotations: annotations,
      focusRawIndex: focusRawIndex,
      scopeLabel: scopeLabel,
    ),
  );

  @override
  State<ReadingAnnotationAppearanceDialog> createState() =>
      _ReadingAnnotationAppearanceDialogState();
}

class _ReadingAnnotationAppearanceDialogState
    extends State<ReadingAnnotationAppearanceDialog> {
  static const _sampleContent =
      '<p>把知识讲清楚，让观众听得懂。</p>'
      '<p>关键的地方放慢一点，再继续。</p>';
  static const _sampleNotes = [
    ReadingAnnotation(
      id: 'appearance-sample',
      text: '放慢语速\n把意思讲清楚',
      ranges: [AnnotationRange(start: 3, end: 6, quote: '讲清楚')],
    ),
  ];
  static const _colors = <(String, int)>[
    ('青白', 0xFF8BD1D0),
    ('纯白', 0xFFFFFFFF),
    ('暖黄', 0xFFFFD875),
    ('浅橙', 0xFFFFB38A),
    ('浅粉', 0xFFFFACCA),
    ('淡紫', 0xFFC9B5FF),
    ('浅绿', 0xFFB7DEA0),
  ];

  late AppSettings _settings;
  ReadingAnnotationPreviewStatus? _previewStatus;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  void _update(AppSettings settings) => setState(() {
    _settings = settings;
    _previewStatus = null;
  });

  void _onPreviewStatus(ReadingAnnotationPreviewStatus status) {
    if (mounted && _previewStatus != status) {
      setState(() => _previewStatus = status);
    }
  }

  Future<void> _chooseFont() async {
    final font = await showDialog<String>(
      context: context,
      builder: (_) =>
          _AnnotationFontPicker(selected: _settings.annotationFontFamily),
    );
    if (mounted && font != null) {
      _update(_settings.copyWith(annotationFontFamily: font));
    }
  }

  Future<void> _chooseColor() async {
    final color = await AppColorPickerDialog.show(
      context,
      title: '批注颜色',
      currentColor: Color(_settings.annotationColor),
      resetColor: const Color(AppSettings.defaultAnnotationColor),
      enableAlpha: false,
    );
    if (mounted && color != null) {
      _update(_settings.copyWith(annotationColor: color.toARGB32()));
    }
  }

  Widget _controls() {
    final automatic = _settings.annotationFontSize == 0;
    final size = automatic
        ? (_settings.fontSize * .22).clamp(8.0, 36.0).toDouble()
        : _settings.annotationFontSize;
    final background = Color(_settings.teleprompterBgColor);
    final foreground = Color(_settings.annotationColor);
    final light = math.max(
      background.computeLuminance(),
      foreground.computeLuminance(),
    );
    final dark = math.min(
      background.computeLuminance(),
      foreground.computeLuminance(),
    );
    final lowContrast = (light + .05) / (dark + .05) < 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('批注字体', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          key: const ValueKey('annotation-font-picker'),
          onPressed: _chooseFont,
          icon: const Icon(Icons.font_download_outlined, size: 18),
          label: Text(
            annotationFontDisplayName(_settings.annotationFontFamily),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          automatic ? '批注字号 · 自动' : '批注字号 · ${size.round()} 像素',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final preset in const <(String, double)>[
              ('自动', 0),
              ('小 · 10', 10),
              ('中 · 14', 14),
              ('大 · 20', 20),
            ])
              ChoiceChip(
                key: ValueKey('annotation-size-${preset.$2.round()}'),
                label: Text(preset.$1),
                selected: _settings.annotationFontSize == preset.$2,
                onSelected: (_) =>
                    _update(_settings.copyWith(annotationFontSize: preset.$2)),
              ),
          ],
        ),
        Slider(
          key: const ValueKey('annotation-size-slider'),
          min: AppSettings.minAnnotationFontSize,
          max: AppSettings.maxAnnotationFontSize,
          divisions: 28,
          value: size,
          label: '${size.round()} 像素',
          semanticFormatterCallback: (value) => '${value.round()} 像素',
          onChanged: (value) => _update(
            _settings.copyWith(annotationFontSize: value.roundToDouble()),
          ),
        ),
        Text(
          automatic
              ? '自动按正文的 22% 显示；拖动滑块可指定 8–36 像素。'
              : '这是首选字号；行间空间不足时自动缩小，正文行距保持不变。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        const Text('批注颜色', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final choice in _colors)
              Tooltip(
                message: choice.$1,
                child: Semantics(
                  label: '${choice.$1}批注',
                  selected: _settings.annotationColor == choice.$2,
                  child: InkWell(
                    key: ValueKey('annotation-color-${choice.$2}'),
                    borderRadius: BorderRadius.circular(18),
                    onTap: () =>
                        _update(_settings.copyWith(annotationColor: choice.$2)),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(choice.$2),
                        border: Border.all(color: Colors.black26),
                      ),
                      child: _settings.annotationColor == choice.$2
                          ? const Icon(
                              Icons.check,
                              size: 20,
                              color: Color(0xFF152126),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('annotation-custom-color'),
            onPressed: _chooseColor,
            icon: Icon(Icons.color_lens_outlined, color: foreground, size: 20),
            label: const Text('自定义颜色'),
          ),
        ),
        const Text('备注文字、字词框和引线使用同一颜色。', style: TextStyle(fontSize: 12)),
        if (lowContrast) ...[
          const SizedBox(height: 8),
          const Text(
            '当前颜色与提词背景接近，请在预览里确认是否清楚。',
            style: TextStyle(fontSize: 12, color: Color(0xFFD99930)),
          ),
        ],
      ],
    );
  }

  Widget _preview(double height) {
    final hasNotes =
        widget.content.isNotEmpty &&
        widget.annotations.any((note) => note.isAnchored);
    var focus = widget.focusRawIndex;
    if (hasNotes &&
        !widget.annotations.any(
          (note) =>
              note.isAnchored &&
              note.ranges.any(
                (range) =>
                    focus != null && range.start <= focus && focus < range.end,
              ),
        )) {
      final notes = widget.annotations
          .where((note) => note.isAnchored)
          .toList();
      focus =
          (notes
                      .where((note) => note.ranges.first.start >= (focus ?? 0))
                      .firstOrNull ??
                  notes.first)
              .ranges
              .first
              .start;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          hasNotes ? '本稿件效果 · 实时预览' : '示例效果 · 实时预览',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ReadingAnnotationPreview(
          key: const ValueKey('annotation-appearance-preview'),
          settings: _settings,
          content: hasNotes ? widget.content : _sampleContent,
          annotations: hasNotes ? widget.annotations : _sampleNotes,
          focusRawIndex: hasNotes ? focus : 3,
          height: height,
          onLayoutStatus: _onPreviewStatus,
        ),
        const SizedBox(height: 8),
        Text(
          _previewStatus?.message ?? '正在计算当前行间可用空间…',
          key: const ValueKey('annotation-appearance-status'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        const Text(
          '显示当前字词附近的局部内容；实际换行随提词窗口宽度变化。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final available = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('批注外观'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      content: SizedBox(
        width: 900,
        height: math.max(180, math.min(540, available.height - 184)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 720) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 320,
                    child: SingleChildScrollView(child: _controls()),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.scopeLabel,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          _preview(
                            math.max(
                              140,
                              math.min(310, constraints.maxHeight - 120),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.scopeLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _preview(190),
                  const Divider(height: 28),
                  _controls(),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('annotation-appearance-reset'),
          onPressed: () => _update(
            _settings.copyWith(
              annotationFontFamily: '',
              annotationFontSize: 0,
              annotationColor: AppSettings.defaultAnnotationColor,
            ),
          ),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('annotation-appearance-apply'),
          onPressed: () => Navigator.pop(context, _settings),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

String annotationFontDisplayName(String family) {
  const names = {
    '': '跟随正文字体',
    'Microsoft YaHei': '微软雅黑',
    'Microsoft YaHei UI': '微软雅黑（界面）',
    'SimHei': '黑体',
    'SimSun': '宋体',
    'NSimSun': '新宋体',
    'KaiTi': '楷体',
    'FangSong': '仿宋',
    'DengXian': '等线',
    'Noto Sans SC': '思源黑体',
    'Noto Serif SC': '思源宋体',
  };
  return names[family] ??
      (RegExp(r'[A-Za-z]').hasMatch(family) ? '$family（系统字体）' : family);
}

class _AnnotationFontPicker extends StatefulWidget {
  const _AnnotationFontPicker({required this.selected});
  final String selected;
  @override
  State<_AnnotationFontPicker> createState() => _AnnotationFontPickerState();
}

class _AnnotationFontPickerState extends State<_AnnotationFontPicker> {
  late final Future<List<String>> _fonts;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _fonts = FontService().getAvailableFonts();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择批注字体'),
    content: SizedBox(
      width: 400,
      height: math.min(
        400,
        math.max(120, MediaQuery.sizeOf(context).height - 220),
      ),
      child: Column(
        children: [
          TextField(
            key: const ValueKey('annotation-font-search'),
            decoration: const InputDecoration(
              hintText: '搜索字体名称',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<String>>(
              future: _fonts,
              builder: (context, snapshot) {
                final fonts = <String>{'', widget.selected, ...?snapshot.data}
                    .where(
                      (font) =>
                          _query.isEmpty ||
                          font.toLowerCase().contains(_query) ||
                          annotationFontDisplayName(
                            font,
                          ).toLowerCase().contains(_query),
                    )
                    .toList();
                if (fonts.isEmpty) return const Center(child: Text('没有匹配的字体'));
                return ListView.builder(
                  itemCount: fonts.length,
                  itemBuilder: (context, index) {
                    final font = fonts[index];
                    return ListTile(
                      title: Text(
                        annotationFontDisplayName(font),
                        style: TextStyle(
                          fontFamily: font.isEmpty ? null : font,
                        ),
                      ),
                      subtitle: const Text('重读 · 停一秒'),
                      trailing: font == widget.selected
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(context, font),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
