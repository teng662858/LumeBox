import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/shared/widgets/cat_site_tile.dart';
import 'package:lume_box/shared/widgets/source_card_metrics.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

/// 猫源「选择站点」面板的专用外观：
/// - 单列 / 双列统一 51 高；
/// - 全局柔和阴影；未选中 1px 浅灰描边，选中态动态主题色描边；
/// - 没有左侧字母图标、没有右侧三点；
/// - 文字单行居中，双列再窄也只省略、不折行；
/// - 长按整行拖拽，左滑露出「设置」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final service = CatService.instance;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_cat_picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
  });

  tearDown(() async {
    service.subscriptions.clear();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    // Windows 上 sqlite / 配置文件的句柄释放偶尔晚于 tearDown；重试几次，
    // 避免临时目录清理失败把已经通过的界面断言判成失败。
    for (var i = 0; i < 5 && root.existsSync(); i++) {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.runAsync(service.boot);
    // 先让板块页按「没有订阅」的稳定状态落地，避免新建订阅触发自动加载，
    // 页面里的转圈会让 pumpAndSettle 一直等下去（与猫源拖拽测试同一顺序）。
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: const CatPage()),
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    service.subscriptions
      ..clear()
      ..add(
        CatSubscription(
          id: 'demo',
          name: '牛二',
          url: 'https://example.test/source',
          automatic: false,
          sites: const <CatSite>[
            CatSite(subscriptionId: 'demo', key: 'a', name: '豆瓣|首页', api: '/a'),
            CatSite(
              subscriptionId: 'demo',
              key: 'b',
              name: '日期:20261017',
              api: '/b',
            ),
            CatSite(subscriptionId: 'demo', key: 'c', name: '配置|中心', api: '/c'),
            CatSite(subscriptionId: 'demo', key: 'd', name: '我的|网盘', api: '/d'),
            CatSite(subscriptionId: 'demo', key: 'e', name: '玩偶|4K', api: '/e'),
            CatSite(subscriptionId: 'demo', key: 'f', name: '多多|4K', api: '/f'),
          ],
        ),
      );
    service.siteColumns = 1;

    expect(find.text('切换'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-cat-source-picker')));
    await tester.pumpAndSettle();
  }

  testWidgets('猫源选择面板：16pt 基线、51 高、主题色描边、居中与左滑菜单', (tester) async {
    await pumpPicker(tester);

    final tiles = find.byType(CatSiteTile);
    expect(tiles, findsWidgets);

    for (final element in tiles.evaluate()) {
      final tile = find.byWidget(element.widget);
      expect(tester.getSize(tile).height, 51, reason: '单列 / 双列统一 51 高');
      final card = find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('cat-site-card')),
      );
      expect(card, findsOneWidget);
      final decoration =
          tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
      expect(decoration.borderRadius, SourceCardMetrics.borderRadius);
      final border = decoration.border! as Border;
      expect(border.top.width, 1);
      final selectedTile = tester.widget<CatSiteTile>(tile).selected;
      expect(
        border.top.color,
        selectedTile
            ? Theme.of(tester.element(tile)).primaryColor
            : SourceCardMetrics.unselectedBorder,
        reason: '未选中 1px 浅灰；选中态读取当前主题色',
      );
      expect(
        decoration.boxShadow,
        SourceCardMetrics.shadow,
        reason: '紧凑轻阴影不压过 1px 描边',
      );
      final material = tester.widget<Material>(
        find.descendant(of: tile, matching: find.byType(Material)).first,
      );
      expect(material.shape, isNull, reason: '没有 Material 描边');
      expect(
        find.descendant(of: tile, matching: find.byType(SourceIcon)),
        findsNothing,
        reason: '猫源行不许再有左侧字母图标',
      );
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.more_vert)),
        findsNothing,
        reason: '猫源行不许再有右侧三点',
      );
      final text = find.descendant(of: tile, matching: find.byType(Text)).first;
      final widget = tester.widget<Text>(text);
      expect(widget.maxLines, 1);
      expect(widget.overflow, TextOverflow.ellipsis);
      expect(widget.textAlign, TextAlign.center);
      expect(
        tester.getSize(text).height,
        lessThan(20),
        reason: '文字必须保持一行（15pt 行高 1.2 ≈ 18）',
      );
    }

    // 最左侧卡片外边缘必须与「加载或刷新包内站点」的文本左基线对齐。
    final subtitle = find.text('加载或刷新包内站点');
    expect(subtitle, findsOneWidget);
    expect(
      tester.getTopLeft(tiles.first).dx,
      closeTo(tester.getTopLeft(subtitle).dx, .01),
      reason: '卡片不应比上方订阅文字更靠内',
    );

    // 底下的板块页头部也可能显示同一个站点名；所有查找都限定在猫源卡片里。
    Finder tileText(String label) => find
        .descendant(of: find.byType(CatSiteTile), matching: find.text(label))
        .first;

    // 单列：长日期也只占一行。
    final dateText = tileText('日期:20261017');
    expect(tester.getSize(dateText).height, lessThan(20));
    expect(
      tester
          .getSize(
            find
                .ancestor(of: dateText, matching: find.byType(CatSiteTile))
                .first,
          )
          .height,
      51,
      reason: '单列卡片 51 高',
    );

    // 双列：两列同一行，长日期仍然单行。
    await tester.tap(find.text('双列列表'));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(tileText('豆瓣|首页'));
    final second = tester.getTopLeft(dateText);
    expect((first.dy - second.dy).abs(), lessThan(1), reason: '双列应并排');
    expect(tester.getSize(dateText).height, lessThan(20), reason: '双列也不许折行');
    expect(
      tester
          .getSize(
            find
                .ancestor(of: dateText, matching: find.byType(CatSiteTile))
                .first,
          )
          .height,
      51,
      reason: '双列卡片同样 51 高，只由列数决定宽度',
    );

    // 左滑露出菜单；长按拖拽由 SourceDragTile 负责（布局测试另有用例）。
    final firstTile = find
        .ancestor(of: tileText('豆瓣|首页'), matching: find.byType(CatSiteTile))
        .first;
    final before = tester.getTopLeft(firstTile);
    await tester.drag(firstTile, const Offset(-90, 0));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(firstTile);
    expect(after.dx, lessThan(before.dx - 40), reason: '左滑应把卡片推开，露出右侧菜单');
    // 菜单按钮已在树里（每张卡片各一个），左滑后第一张的按钮移到卡片右侧、
    // 成为可见/可点的操作区。
    expect(find.text('设置'), findsWidgets);

    // 让 CatPage 先卸载，释放阅读库句柄；不在这里 pumpAndSettle，
    // 页面退出时可能还有未完成的入场动画/定时器。
    service.subscriptions.clear();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('猫源卡片选中态：主题色描边、浅色底', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: CatSiteTile(label: '选中的站点', selected: true, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byType(CatSiteTile);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: tile,
                    matching: find.byKey(const ValueKey('cat-site-card')),
                  ),
                )
                .decoration
            as BoxDecoration;
    final primary = Theme.of(tester.element(tile)).primaryColor;
    expect(decoration.borderRadius, SourceCardMetrics.borderRadius);
    expect(
      decoration.color,
      Color.alphaBlend(primary.withValues(alpha: .08), LumeTheme.surface),
      reason: '选中态铺一层极浅主题色',
    );
    final border = decoration.border! as Border;
    expect(border.top.width, 1);
    expect(
      border.top.color,
      primary,
      reason: '选中态边框读取 Theme.of(context).primaryColor，不写死紫色',
    );
    final material = tester.widget<Material>(
      find.descendant(of: tile, matching: find.byType(Material)).first,
    );
    expect(material.shape, isNull, reason: 'Material 本身不重复画描边');
  });
}
