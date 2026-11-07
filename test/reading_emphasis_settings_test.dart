import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/pages/settings_page.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/folder_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/theme/app_theme.dart';
import 'package:storm_teleprompter_plus/widgets/common/app_color_picker_dialog.dart';
import 'package:storm_teleprompter_plus/widgets/settings/reading_emphasis_settings_section.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/teleprompter_settings_panel.dart';

import 'support/reading_emphasis_test_backend.dart';

const _enabledKey = 'reading-emphasis-enabled';
const _currentColorKey = 'reading-emphasis-current-color';
const _readColorKey = 'reading-emphasis-read-color';
const _scaleKey = 'reading-emphasis-scale';
const _previewKey = 'reading-emphasis-preview';
const _previewCurrentKey = 'reading-emphasis-preview-current';
const _previewCurrentRestKey = 'reading-emphasis-preview-current-rest';
const _previewReadKey = 'reading-emphasis-preview-read';
const _previewUnreadKey = 'reading-emphasis-preview-unread';

void main() {
  testWidgets('应用设置与提词面板共享开关、颜色、实时倍率并保存到后端', (tester) async {
    final harness = await _mount(
      tester,
      Scaffold(
        body: Row(
          children: [
            const Expanded(child: SettingsPage()),
            TeleprompterSettingsPanel(onClose: () {}),
          ],
        ),
      ),
      size: const Size(1200, 1000),
    );
    final page = find.byType(SettingsPage);
    final panel = find.byType(TeleprompterSettingsPanel);
    await _reveal(tester, page, _within(page, _enabledKey));
    await _reveal(tester, panel, _within(panel, _enabledKey));

    await tester.tap(_within(page, _enabledKey));
    await tester.pumpAndSettle();
    expect(harness.settings.settings.readingEmphasisEnabled, isFalse);
    expect(
      tester.widget<SwitchListTile>(_within(panel, _enabledKey)).value,
      isFalse,
    );
    await tester.tap(_within(panel, _enabledKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(_within(page, _enabledKey)).value,
      isTrue,
    );

    await _pickColor(tester, _within(page, _currentColorKey), '#FF22CC88');
    await _pickColor(tester, _within(panel, _readColorKey), '#FF667788');
    for (final scope in [page, panel]) {
      await _reveal(tester, scope, _within(scope, _previewKey));
      expect(
        _previewStyle(tester, scope, _previewCurrentKey).color,
        const Color(0xFF22CC88),
      );
      expect(
        _previewStyle(tester, scope, _previewCurrentRestKey).color,
        const Color(0xFF22CC88),
      );
      expect(
        _previewStyle(tester, scope, _previewReadKey).color,
        const Color(0xFF667788),
      );
    }

    final slider = _within(panel, _scaleKey);
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final unreadBefore = tester.getRect(_within(panel, _previewUnreadKey));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveTo(tester.getTopRight(slider) + const Offset(-1, 24));
    await tester.pump();

    // 尚未松开鼠标时，两处设置与真实预览都已更新。
    expect(
      harness.settings.settings.currentCharScale,
      AppSettings.maxCurrentCharScale,
    );
    for (final scope in [page, panel]) {
      final value = tester.widget<Text>(
        _within(scope, 'reading-emphasis-scale-value'),
      );
      expect(value.data, '15%');
    }
    expect(tester.getRect(_within(panel, _previewUnreadKey)), unreadBefore);
    final readRect = tester.getRect(_within(panel, _previewReadKey));
    final currentRect = tester.getRect(_within(panel, _previewCurrentKey));
    final unreadRect = tester.getRect(_within(panel, _previewUnreadKey));
    final currentRestRect = tester.getRect(
      _within(panel, _previewCurrentRestKey),
    );
    expect(currentRect.top, greaterThanOrEqualTo(readRect.bottom));
    expect(currentRect.right, lessThanOrEqualTo(currentRestRect.left + 0.01));
    expect(unreadRect.top, greaterThanOrEqualTo(currentRestRect.bottom));
    await gesture.up();
    await tester.pumpAndSettle();

    final stored = await harness.backend.service.loadSettings();
    expect(stored.readingEmphasisEnabled, isTrue);
    expect(stored.currentCharColor, 0xFF22CC88);
    expect(stored.readCharColor, 0xFF667788);
    expect(stored.currentCharScale, AppSettings.maxCurrentCharScale);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets('播放中可调整阅读提示并保留独立已读开关（宽度 $width）', (tester) async {
      final harness = await _mount(
        tester,
        Scaffold(body: TeleprompterSettingsPanel(onClose: () {})),
        size: Size(width, 900),
      );
      harness.settings.loadArticleOverrides({'wpm': 0});
      harness.teleprompter
        ..loadScript('reading-ui-test', '测试播放中的阅读提示，不改变朗读位置。')
        ..setCurrentIndex(3)
        ..play(harness.settings.mergedSettings);
      await tester.pump();
      final panel = find.byType(TeleprompterSettingsPanel);
      final slider = _within(panel, _scaleKey);
      await _reveal(tester, panel, slider);
      final sliderWidget = tester.widget<Slider>(slider);
      expect(sliderWidget.onChanged, isNotNull);
      await tester.tapAt(tester.getTopLeft(slider) + const Offset(1, 24));
      await tester.pumpAndSettle();
      expect(harness.settings.settings.currentCharScale, 1);

      await _pickColor(tester, _within(panel, _currentColorKey), '#FFFF8800');
      await _pickColor(tester, _within(panel, _readColorKey), '#FF556677');
      final readSwitch = find.widgetWithText(SwitchListTile, '标记已读段落');
      await _reveal(tester, panel, readSwitch);
      expect(tester.widget<SwitchListTile>(readSwitch).onChanged, isNotNull);
      await tester.tap(readSwitch);
      await tester.pumpAndSettle();
      await _reveal(tester, panel, _within(panel, _previewKey));
      expect(harness.settings.mergedSettings.grayReadChars, isFalse);
      expect(_previewStyle(tester, panel, _previewReadKey).color, Colors.white);
      expect(
        _previewStyle(tester, panel, _previewCurrentKey).color,
        const Color(0xFFFF8800),
      );
      expect(
        _previewStyle(tester, panel, _previewCurrentRestKey).color,
        const Color(0xFFFF8800),
      );
      expect(
        _previewStyle(tester, panel, _previewUnreadKey).color,
        Colors.white,
      );

      await _reveal(tester, panel, _within(panel, _enabledKey));
      await tester.tap(_within(panel, _enabledKey));
      await tester.pumpAndSettle();
      expect(harness.settings.settings.readingEmphasisEnabled, isFalse);
      expect(
        _previewStyle(tester, panel, _previewCurrentKey).color,
        Colors.white,
      );
      expect(
        _previewStyle(tester, panel, _previewCurrentRestKey).color,
        Colors.white,
      );

      // 整段高亮关闭后，已读段落仍能独立开启，且不重新点亮当前段。
      await _reveal(tester, panel, readSwitch);
      await tester.tap(readSwitch);
      await tester.pumpAndSettle();
      await _reveal(tester, panel, _within(panel, _previewKey));
      expect(harness.settings.mergedSettings.grayReadChars, isTrue);
      expect(
        _previewStyle(tester, panel, _previewReadKey).color,
        const Color(0xFF556677),
      );
      expect(
        _previewStyle(tester, panel, _previewCurrentKey).color,
        Colors.white,
      );
      expect(
        _previewStyle(tester, panel, _previewCurrentRestKey).color,
        Colors.white,
      );
      expect(harness.teleprompter.isPlaying, isTrue);
      expect(harness.teleprompter.currentIndex, 3);

      // 匀速模式不提供字符定位，但这组全局设置仍可预先调整。
      await harness.settings.toggleAutoScrollMode();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Slider>(_within(panel, _scaleKey)).onChanged,
        isNotNull,
      );
      expect(find.text('语音跟随和按行模式生效'), findsOneWidget);
      expect(tester.takeException(), isNull);
      harness.teleprompter.pause(harness.settings.mergedSettings);
    });
  }

  testWidgets('窄窗应用设置可打开共享颜色选择器并取消修改', (tester) async {
    final harness = await _mount(
      tester,
      const SettingsPage(),
      size: const Size(320, 800),
    );
    final page = find.byType(SettingsPage);
    final colorTile = _within(page, _currentColorKey);
    await _reveal(tester, page, colorTile);
    await tester.tap(colorTile);
    await tester.pumpAndSettle();
    expect(find.byType(AppColorPickerDialog), findsOneWidget);
    await tester.enterText(_pickerInput(), '#FF112233');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(
      harness.settings.settings.currentCharColor,
      const AppSettings().currentCharColor,
    );
    expect(harness.backend.preferences.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧负字距显示有效零值，用户调整前不改存值', (tester) async {
    final harness = await _mount(
      tester,
      Scaffold(body: TeleprompterSettingsPanel(onClose: () {})),
      size: const Size(320, 900),
      initialSettings: const AppSettings(letterSpacing: -2),
    );
    final panel = find.byType(TeleprompterSettingsPanel);
    final label = find.text('字间距');
    await _reveal(tester, panel, label);
    final row = find.ancestor(of: label, matching: find.byType(Row)).first;
    final slider = find.descendant(of: row, matching: find.byType(Slider));
    final control = tester.widget<Slider>(slider);
    expect(control.min, 0);
    expect(control.value, 0);
    expect(find.text('负字距按0处理，保证放大空间'), findsOneWidget);
    expect(harness.settings.mergedSettings.letterSpacing, -2);
    expect(harness.backend.preferences.writes, isEmpty);

    await tester.tap(slider);
    await tester.pumpAndSettle();
    expect(
      harness.settings.mergedSettings.letterSpacing,
      inInclusiveRange(0, 10),
    );
    expect(find.text('负字距按0处理，保证放大空间'), findsNothing);
    final stored = await harness.backend.service.loadSettings();
    expect(stored.letterSpacing, harness.settings.mergedSettings.letterSpacing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败保留预览并统一提示，重试后确实写入', (tester) async {
    final harness = await _mount(tester, _sectionPage());
    harness.backend.preferences.failWrites = true;

    await tester.tap(find.byKey(const ValueKey(_enabledKey)));
    await tester.pumpAndSettle();

    expect(harness.settings.settings.readingEmphasisEnabled, isFalse);
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.text('当前设置尚未保存'), findsOneWidget);
    expect(harness.backend.preferences.writes, isEmpty);
    harness.backend.preferences.failWrites = false;
    await tester.ensureVisible(
      find.byKey(const ValueKey('reading-emphasis-retry')),
    );
    await tester.tap(find.byKey(const ValueKey('reading-emphasis-retry')));
    await tester.pumpAndSettle();

    final stored = await harness.backend.service.loadSettings();
    expect(stored.readingEmphasisEnabled, isFalse);
    expect(harness.backend.preferences.writes, hasLength(1));
    expect(find.text('当前设置尚未保存'), findsNothing);
    expect(harness.settings.readingEmphasisSaveError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重置等待后端确认，失败不提示成功', (tester) async {
    final harness = await _mount(
      tester,
      const SettingsPage(),
      initialSettings: const AppSettings(
        readingEmphasisEnabled: false,
        currentCharColor: 0xFF123456,
        currentCharScale: 1,
      ),
    );
    final page = find.byType(SettingsPage);
    final reset = find.widgetWithText(OutlinedButton, '重置所有设置');
    await _reveal(tester, page, reset);
    final gate = Completer<void>();
    harness.backend.preferences
      ..nextWriteGate = gate
      ..failWrites = true;
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pump();
    expect(find.text('设置已重置'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('重置失败，请重试'), findsOneWidget);
    expect(find.text('设置已重置'), findsNothing);

    harness.backend.preferences.failWrites = false;
    await _reveal(tester, page, reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pumpAndSettle();
    final stored = await harness.backend.service.loadSettings();
    expect(
      stored.toReadingEmphasisMap(),
      const AppSettings().toReadingEmphasisMap(),
    );
    expect(find.text('设置已重置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置组件销毁后颜色对话框返回不会保存失效选择', (tester) async {
    var showSection = true;
    late StateSetter updateHost;
    final harness = await _mount(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return showSection
                ? const SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: ReadingEmphasisSettingsSection(),
                  )
                : const Text('设置已关闭');
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey(_currentColorKey)));
    await tester.pumpAndSettle();
    await tester.enterText(_pickerInput(), '#FF112233');
    updateHost(() => showSection = false);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(
      harness.settings.settings.currentCharColor,
      const AppSettings().currentCharColor,
    );
    expect(harness.backend.preferences.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组件销毁后的保存失败不会访问失效界面', (tester) async {
    final harness = await _mount(tester, _sectionPage());
    final gate = Completer<void>();
    harness.backend.preferences
      ..nextWriteGate = gate
      ..failWrites = true;
    await tester.tap(find.byKey(const ValueKey(_enabledKey)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(harness.settings.readingEmphasisSaveError, isNotNull);
    expect(tester.takeException(), isNull);
  });
}

Widget _sectionPage() => const Scaffold(
  body: SingleChildScrollView(
    padding: EdgeInsets.all(16),
    child: ReadingEmphasisSettingsSection(),
  ),
);

Finder _within(Finder scope, String key) =>
    find.descendant(of: scope, matching: find.byKey(ValueKey(key)));

Finder _pickerInput() => find.descendant(
  of: find.byType(AppColorPickerDialog),
  matching: find.byType(TextField),
);

TextStyle _previewStyle(WidgetTester tester, Finder scope, String key) =>
    tester.widget<Text>(_within(scope, key)).style!;

Future<void> _reveal(WidgetTester tester, Finder scope, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find
          .descendant(of: scope, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
  }
  // 懒加载的长设置分组首次布局会修正滚动范围，重新对齐后再交互。
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    if (target.hitTestable().evaluate().isNotEmpty) return;
  }
  expect(target.hitTestable(), findsOneWidget);
}

Future<void> _pickColor(WidgetTester tester, Finder tile, String hex) async {
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
  expect(find.byType(AppColorPickerDialog), findsOneWidget);
  await tester.enterText(_pickerInput(), hex);
  await tester.tap(find.widgetWithText(FilledButton, '确定'));
  await tester.pumpAndSettle();
}

Future<_Harness> _mount(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(600, 900),
  AppSettings initialSettings = const AppSettings(),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final backend = ReadingEmphasisTestBackend(settings: initialSettings);
  await backend.init();
  final settings = SettingsProvider()..bindConnection(backend.connection);
  await settings.loadSettings();
  final teleprompter = TeleprompterProvider();
  // 设置通信走内存后端；页面的连接文案使用普通未连接状态。
  final pageConnection = ConnectionProvider();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    teleprompter.dispose();
    settings.dispose();
    pageConnection.dispose();
    backend.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<TeleprompterProvider>.value(value: teleprompter),
        ChangeNotifierProvider<ConnectionProvider>.value(value: pageConnection),
        ChangeNotifierProvider(create: (_) => FolderProvider()),
      ],
      child: MaterialApp(theme: AppTheme.darkTheme, home: home),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(backend, settings, teleprompter);
}

class _Harness {
  _Harness(this.backend, this.settings, this.teleprompter);

  final ReadingEmphasisTestBackend backend;
  final SettingsProvider settings;
  final TeleprompterProvider teleprompter;
}
