import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/usage_guide_page.dart';

void main() {
  testWidgets('usage guide lists every section and all five speech modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: const UsageGuidePage()),
    );
    await tester.pumpAndSettle();

    for (final title in [
      '第一次使用',
      '源与订阅',
      '小说与漫画朗读',
      '漫画与美图',
      '视频与播放器',
      'Bangumi 追番同步',
      '收藏、历史与搜索',
      '数据、备份与隐私',
      '常见问题',
    ]) {
      expect(find.text(title), findsOneWidget);
    }

    // 第一次使用默认展开，先确认正文真的挂在页面上。
    expect(find.textContaining('总订阅导入导出'), findsOneWidget);

    await tester.tap(find.text('小说与漫画朗读'));
    await tester.pumpAndSettle();
    for (final mode in [
      '系统自带 TTS',
      '本地离线 VITS · sherpa-onnx',
      'Kokoro 离线朗读',
      '在线云端 TTS · 简易（正则）',
      '在线云端 TTS · AI 增强',
    ]) {
      expect(find.textContaining(mode), findsWidgets);
    }
    expect(find.textContaining('/v1/audio/speech'), findsOneWidget);
    expect(find.textContaining('密钥保存在设备钥匙串'), findsOneWidget);
    for (final provider in ['Azure Speech', '火山引擎', 'voice_type']) {
      expect(find.textContaining(provider), findsWidgets);
    }
    expect(find.textContaining('自动排序'), findsOneWidget);

    await tester.ensureVisible(find.text('漫画与美图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('漫画与美图'));
    await tester.pumpAndSettle();
    expect(find.textContaining('漫画朗读（OCR + 同一套 TTS）'), findsOneWidget);
    expect(find.textContaining('读到本章末'), findsOneWidget);

    await tester.ensureVisible(find.text('Bangumi 追番同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bangumi 追番同步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Access Token'), findsWidgets);
    expect(find.textContaining('立即同步'), findsOneWidget);

    await tester.ensureVisible(find.text('常见问题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('常见问题'));
    await tester.pumpAndSettle();
    expect(find.textContaining('关于 LumeBox'), findsOneWidget);
  });

  testWidgets('settings page exposes the usage guide entry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const SettingsPage(runtimeAvailable: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('诊断与关于'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('诊断与关于'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('使用说明'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('使用说明'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('使用说明'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '使用说明'), findsOneWidget);
    expect(find.text('第一次使用'), findsOneWidget);
  });

  testWidgets('usage guide fits a 320pt screen at 2x text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const UsageGuidePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
