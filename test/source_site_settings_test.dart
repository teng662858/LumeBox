import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import 'support/fake_source_manager.dart';

/// 单图源设置弹窗（换网址 / 账号登入）的界面验证：用替身管理器驱动**真实页面**，
/// 从图源行的菜单打开弹窗，选镜像 / 填域名后保存，断言写回了管理器。
///
/// 分辨率断言走的是模型里的**唯一优先级口径**（自定义域名 > 选中镜像 > 主站），
/// 因此这里同时验证了「界面存进去的值」与「脚本将拿到的 domain」一致。
void main() {
  const main = 'https://main.example';
  const mirror1 = 'https://m1.example';
  const mirror2 = 'https://m2.example';

  Future<FakeSourceManager> pumpPage(WidgetTester tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'a',
          name: '示例源',
          version: '1.0.0',
          enabled: true,
          siteConfig: SourceSiteConfig(mirrors: <String>[main, mirror1, mirror2]),
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceSectionPage(section: Section.novel, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    return manager;
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('网络配置'));
    await tester.pumpAndSettle();
    expect(find.text('源设置 · 示例源'), findsOneWidget);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('换网址：镜像列三档并标记主站，选择后保存写回管理器', (tester) async {
    final manager = await pumpPage(tester);
    await openSettings(tester);

    // 三个镜像都在，且第一个标了「主站」（脚本声明的下标 0）。
    expect(find.text('main.example'), findsOneWidget);
    expect(find.text('m1.example'), findsOneWidget);
    expect(find.text('m2.example'), findsOneWidget);
    expect(find.text('主站'), findsOneWidget);
    // 优先级说明固定出现在这一组里。
    expect(
      find.textContaining('自定义域名 > 选中镜像 > 主站'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('m1.example'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

    final saved = manager.siteConfigs.single.$2;
    expect(saved.mirrorIndex, 1, reason: '选中的是第 2 个镜像（下标 1）');
    expect(saved.resolvedDomain, mirror1);
  });

  testWidgets('换网址：自定义域名保存并优先于选中的镜像', (tester) async {
    final manager = await pumpPage(tester);
    await openSettings(tester);

    // 同时选一个非主站镜像，并填一个自定义域名。
    await tapVisible(tester, find.text('m2.example'));
    await tapVisible(
      tester,
      find.widgetWithText(TextField, '自定义域名（填了优先）'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, '自定义域名（填了优先）'),
      'custom.example',
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

    final saved = manager.siteConfigs.single.$2;
    expect(saved.mirrorIndex, 2);
    expect(saved.domainOverride, 'custom.example', reason: '存原文，归一在模型里做');
    expect(
      saved.resolvedDomain,
      'https://custom.example',
      reason: '自定义域名补 scheme 后压过选中的镜像',
    );
  });

  testWidgets('换网址：非法自定义域名不提交，弹窗留在原地', (tester) async {
    final manager = await pumpPage(tester);
    await openSettings(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '自定义域名（填了优先）'),
      'ftp://example.com',
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

    expect(manager.siteConfigs, isEmpty, reason: '非法域名不该写回');
    expect(find.text('源设置 · 示例源'), findsOneWidget, reason: '弹窗没有关掉');
    expect(find.textContaining('自定义域名只能是域名或 http(s) 地址'), findsOneWidget);
  });

  testWidgets('账号登入：账号与密码保存，密码默认遮蔽且可切换显示', (tester) async {
    final manager = await pumpPage(tester);
    await openSettings(tester);

    expect(find.textContaining('需要站点本身支持登录'), findsOneWidget);

    final password = find.widgetWithText(TextField, '密码');
    final field = tester.widget<TextField>(password);
    expect(field.obscureText, isTrue, reason: '密码默认遮蔽');

    await tester.enterText(
      find.widgetWithText(TextField, '账号'),
      'reader@example.com',
    );
    await tester.enterText(password, 'hunter2');
    await tester.pumpAndSettle();

    // 显示 / 隐藏切换只影响输入框，不改值。
    await tapVisible(tester, find.byTooltip('显示'));
    expect(tester.widget<TextField>(password).obscureText, isFalse);

    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
    final saved = manager.siteConfigs.single.$2;
    expect(saved.account, 'reader@example.com');
    expect(saved.password, 'hunter2');
  });

  testWidgets('脚本没声明镜像时：列表只剩「默认」一项，自定义域名照样能用', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceSectionPage(section: Section.novel, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await openSettings(tester);

    expect(find.text('默认（脚本未声明镜像）'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '自定义域名（填了优先）'),
      'https://only.example/',
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

    final saved = manager.siteConfigs.single.$2;
    expect(saved.mirrors, isEmpty);
    expect(
      saved.resolvedDomain,
      'https://only.example',
      reason: '没有镜像时自定义域名照样生效（并且去掉了尾斜杠）',
    );
  });
}
