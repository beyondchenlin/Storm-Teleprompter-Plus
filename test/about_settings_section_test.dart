import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/app_release_service.dart';
import 'package:storm_teleprompter_plus/pages/log_viewer_page.dart';
import 'package:storm_teleprompter_plus/widgets/settings/about_settings_section.dart';

void main() {
  test('local development version resolves to the Git commit hash', () async {
    final version = await AppVersionInfo.load();

    expect(version.value, matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  testWidgets('about page exposes project, updates, license, and logs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AboutSettingsSection(
              versionLoader: () async => const AppVersionInfo('1234abcd'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关于 BK 提词器'), findsOneWidget);
    await tester.tap(find.text('关于 BK 提词器'));
    await tester.pumpAndSettle();

    expect(find.text('BK 提词器'), findsNWidgets(2));
    expect(find.text('访问项目主页'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('陈林'), findsOneWidget);
    expect(find.text('beyond.chenlin@gmail.com'), findsOneWidget);
    expect(find.text('Copyright (c) 2026 陈林'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.textContaining('版本 1234abcd'), findsNWidgets(2));

    await tester.ensureVisible(find.text('开源许可'));
    await tester.tap(find.text('开源许可'));
    await tester.pumpAndSettle();

    expect(find.text('MIT（开源许可证）'), findsWidgets);
    expect(find.textContaining('Copyright (c) 2026 Html5syt'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Image));
    for (var index = 0; index < 10; index++) {
      await tester.tap(find.byType(Image));
    }
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerPage), findsOneWidget);
  });
}
