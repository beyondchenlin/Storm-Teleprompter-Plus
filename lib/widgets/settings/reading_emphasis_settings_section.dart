import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_settings.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../common/app_color_picker_dialog.dart';

/// 应用设置与提词面板共用的全局阅读提示设置。
///
/// 所有控件直接观察同一份设置；预览固定当前位置，不模拟语音识别。
class ReadingEmphasisSettingsSection extends StatelessWidget {
  const ReadingEmphasisSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SettingsProvider>();
    final settings = provider.settings;
    final maxEnlargement = ((AppSettings.maxCurrentCharScale - 1) * 100)
        .roundToDouble();
    final enlargement = ((settings.currentCharScale - 1) * 100)
        .clamp(0.0, maxEnlargement)
        .toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('reading-emphasis-enabled'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('整段高亮', style: TextStyle(fontSize: 14)),
          subtitle: const Text('语音跟随和按行模式生效', style: TextStyle(fontSize: 12)),
          value: settings.readingEmphasisEnabled,
          onChanged: (value) =>
              _save(context, () => provider.setReadingEmphasisEnabled(value)),
        ),
        _buildColorTile(
          context,
          key: const ValueKey('reading-emphasis-current-color'),
          title: '当前段颜色',
          color: Color(settings.currentCharColor),
          defaultColor: Color(const AppSettings().currentCharColor),
          save: provider.setCurrentCharColor,
        ),
        _buildColorTile(
          context,
          key: const ValueKey('reading-emphasis-read-color'),
          title: '已读段颜色',
          color: Color(settings.readCharColor),
          defaultColor: Color(const AppSettings().readCharColor),
          save: provider.setReadCharColor,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Text('当前字放大幅度', style: TextStyle(fontSize: 14)),
            ),
            Text(
              '${enlargement.round()}%',
              key: const ValueKey('reading-emphasis-scale-value'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          key: const ValueKey('reading-emphasis-scale'),
          value: enlargement,
          min: 0,
          max: maxEnlargement,
          divisions: maxEnlargement.toInt(),
          label: '${enlargement.round()}%',
          semanticFormatterCallback: (value) => '放大 ${value.round()}%',
          onChanged: (value) => _save(
            context,
            () => provider.setCurrentCharScale(1 + value / 100),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('0%', style: TextStyle(fontSize: 12)),
            Text(
              '${maxEnlargement.round()}%',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '效果预览 · 整段变色，“正”为朗读位置',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondaryFor(context),
          ),
        ),
        const SizedBox(height: 8),
        _ReadingEmphasisPreview(
          settings: settings,
          appearance: provider.mergedSettings,
        ),
        const SizedBox(height: 8),
        Text(
          '按原稿分段，自动折行不拆段。对所有稿件生效，调整后自动保存',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textMutedFor(context),
          ),
        ),
        if (provider.readingEmphasisSaveError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text('当前设置尚未保存')),
                TextButton(
                  key: const ValueKey('reading-emphasis-retry'),
                  onPressed: provider.isSavingReadingEmphasis
                      ? null
                      : () async {
                          ScaffoldMessenger.maybeOf(
                            context,
                          )?.hideCurrentSnackBar();
                          await _save(
                            context,
                            provider.retryReadingEmphasisSave,
                          );
                        },
                  child: Text(provider.isSavingReadingEmphasis ? '保存中…' : '重试'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildColorTile(
    BuildContext context, {
    required Key key,
    required String title,
    required Color color,
    required Color defaultColor,
    required Future<void> Function(int) save,
  }) {
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.borderFor(context)),
        ),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        AppColorHex.format(color),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () async {
        final selected = await AppColorPickerDialog.show(
          context,
          title: title,
          currentColor: color,
          resetColor: defaultColor,
        );
        if (!context.mounted || selected == null) return;
        await _save(context, () => save(selected.toARGB32()));
      },
    );
  }

  Future<void> _save(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    }
  }
}

class _ReadingEmphasisPreview extends StatelessWidget {
  const _ReadingEmphasisPreview({
    required this.settings,
    required this.appearance,
  });

  final AppSettings settings;
  final AppSettings appearance;

  @override
  Widget build(BuildContext context) {
    final baseColor = Color(
      appearance.textColor == 0 ? 0xFFFFFFFF : appearance.textColor,
    );
    final currentColor = settings.readingEmphasisEnabled
        ? Color(settings.currentCharColor)
        : baseColor;
    final previewFontSize = MediaQuery.textScalerOf(context).scale(24);
    final baseStyle = TextStyle(
      fontSize: 24,
      height: 1.5,
      letterSpacing: 0,
      color: baseColor,
      fontFamily: appearance.teleprompterFontFamily.isEmpty
          ? null
          : appearance.teleprompterFontFamily,
      fontWeight: appearance.defaultBold ? FontWeight.w700 : FontWeight.w400,
    );

    return Container(
      key: const ValueKey('reading-emphasis-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color(appearance.teleprompterBgColor),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderFor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '上一段已读。',
            key: const ValueKey('reading-emphasis-preview-read'),
            style: baseStyle.copyWith(
              color: appearance.grayReadChars
                  ? Color(settings.readCharColor)
                  : baseColor,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 只改变当前字的可选形状；整段的颜色始终保持一致。
              // 固定预留最大倍率，调整时其余文字不移动也不受挤压。
              SizedBox(
                width: previewFontSize * AppSettings.maxCurrentCharScale + 4,
                height: previewFontSize * 1.5 * AppSettings.maxCurrentCharScale,
                child: Center(
                  child: Transform.scale(
                    key: const ValueKey('reading-emphasis-preview-scale'),
                    scale: settings.readingEmphasisEnabled
                        ? settings.currentCharScale
                        : 1,
                    child: Text(
                      '正',
                      key: const ValueKey('reading-emphasis-preview-current'),
                      style: baseStyle.copyWith(
                        color: currentColor,
                        fontWeight: appearance.highlightCurrentChar
                            ? (appearance.defaultBold
                                  ? FontWeight.w900
                                  : FontWeight.w700)
                            : baseStyle.fontWeight,
                        decoration: appearance.underlineCurrentChar
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: currentColor,
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                '在读。这一段。',
                key: const ValueKey('reading-emphasis-preview-current-rest'),
                style: baseStyle.copyWith(color: currentColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '下一段未读。',
            key: const ValueKey('reading-emphasis-preview-unread'),
            style: baseStyle,
          ),
        ],
      ),
    );
  }
}
