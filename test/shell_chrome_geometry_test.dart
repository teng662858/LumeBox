import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_source_manager.dart';

/// 顶栏 / 底栏的纵向位置（用户口径）：
/// 1. 顶部导航（标题 + 图标 + 页签）整条贴近状态栏，只留一小段安全边距——
///    不许「往下陷」；
/// 2. 底部 Dock 悬浮在 iOS 安全区上方 8pt（完整避开底部横条）；
/// 3. 两端移动之后，中间内容区自动撑开占满剩余空间；
/// 4. 只移动容器，不缩放控件——图标按钮仍是 42 的触达尺寸。
///
/// 设备取 1320×2868@3x（440×956pt，刘海机 59 / 34），与真机反馈的机型一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 440.0;
  const height = 956.0;
  const statusInset = 59.0;
  const bottomInset = 34.0;

  late Directory root;
  late ShellDockController controller;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_chrome');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    LumeJsEngine.debugSupportedOverride = true;
    // 外观参数是应用级单例：上一例把高度拉到 90 / 离底改成 -25 后，下一例
    // 若不复位就会带着它跑（横屏、键盘等列都按默认 54/4 断言）。
    ShellSettingsController.instance.resetForTesting();
    controller = ShellDockController();
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    ShellSettingsController.instance.resetForTesting();
    controller.dispose();
    LumeJsEngine.debugSupportedOverride = null;
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        navigatorObservers: <NavigatorObserver>[ShellDockObserver(controller)],
        home: AppShell(controller: controller, desktopRail: false),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dock 胶囊本体（Dock 的 key 挂在外层容器上，量它量不到圆角条）。
  Finder dockCapsule() => find
      .descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.byType(ClipRRect),
      )
      .first;

  /// 挂一个**真实板块页**（视频：标题 + 右上角图标 + 书架/探索页签）。
  Future<void> pumpBoard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPage(
          catalog: const _NoKernelCatalog(),
          sourceManager: FakeSourceManager(
            sources: const <SourceDescriptor>[
              SourceDescriptor(
                id: 'a',
                name: '示例源',
                version: '1.0',
                enabled: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder homePanel() => find
      .ancestor(of: find.byTooltip('播放历史'), matching: find.byType(GlassPanel))
      .first;
  testWidgets('首页标题、操作与源选择合为一个紧凑模块并避让状态栏', (tester) async {
    await pumpBoard(tester);
    expect(find.byType(AppBar), findsNothing);
    final panel = tester.getRect(homePanel());
    expect(panel.top, closeTo(trimmedTopInset(statusInset), 1));
    expect(panel.height, lessThan(160));
    final title = tester.getRect(find.text('视频'));
    final source = tester.getRect(find.text('示例源'));
    expect(source.top, greaterThan(title.bottom));
    expect(source.bottom, lessThan(panel.bottom));
    expect(find.byType(TabBar), findsNothing);
  });
  testWidgets('合并顶部保持至少32点图标触达尺寸', (tester) async {
    await pumpBoard(tester);
    for (final button
        in find
            .descendant(of: homePanel(), matching: find.byType(IconButton))
            .evaluate()) {
      final rect = tester.getRect(find.byWidget(button.widget));
      expect(rect.width, greaterThanOrEqualTo(32));
      expect(rect.height, greaterThanOrEqualTo(32));
      expect(rect.top, greaterThanOrEqualTo(trimmedTopInset(statusInset)));
    }
  });

  testWidgets('底部 Dock 悬浮在屏幕底边之上 + 左右宽度（用户口径第十二次）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 用户口径第七次：**保留一小段悬浮留白**——上一版怼死屏幕底边「改过头了」。
    // 本轮（第十三次）：留白 8 → 4，往下沉、更贴近 Home Indicator，但仍不贴死。
    final gap = height - capsule.bottom;
    expect(
      gap,
      closeTo(bottomInset + 4, 0.01),
      reason: '胶囊要悬浮在安全区之上 4pt（实测 $gap）',
    );
    // 用户口径第十三次：左右再收窄——外边距 16 → 24，两侧留出明显的空白。
    expect(capsule.width, closeTo(width - 48, 0.01), reason: '胶囊按屏宽减左右各 24 摆放');
    expect(capsule.left, closeTo(24, 0.01), reason: '胶囊居中：左侧留白 24');
    // 加宽是**稍微**：两侧仍要留白（不铺满屏宽）。
    expect(capsule.left, greaterThan(0));
    expect(width - capsule.right, closeTo(capsule.left, 0.01));

    // 收窄容器**不许收窄点击区域**：五项平分之后每项仍要够手指点（≥44）。
    final items = find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.byType(InkWell),
        )
        .evaluate()
        .toList();
    expect(items, isNotEmpty);
    for (final element in items) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        rect.width,
        greaterThanOrEqualTo(44.0),
        reason: '收窄胶囊后每项只剩 ${rect.width} 宽，点不到',
      );
      expect(
        rect.height,
        greaterThanOrEqualTo(44.0),
        reason: '每项高度 ${rect.height} 太小，容易误触',
      );
    }

    // 而**里面的内容**要避开手势条：图标与文字整体上缩一档；
    // 「内容离屏幕底边」的总净空固定 20（外框留白 + 内部避让）。
    const inset = 20.0;
    final item = tester.getRect(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.novel.label),
          )
          .first,
    );
    expect(
      height - item.bottom,
      greaterThanOrEqualTo(inset),
      reason:
          '胶囊里的文字要避开系统手势条（至少离底边 ${inset}pt，'
          '实测 ${height - item.bottom}）',
    );

    // 图标与文字间距 4，整体在 60 高的内容条里严格垂直居中。
    final novelLabel = find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text(Section.novel.label),
        )
        .first;
    final novelItem = find
        .ancestor(of: novelLabel, matching: find.byType(InkWell))
        .first;
    // 图标槽：Column 里的第一块 SizedBox（高 22）；选中胶囊是独立背景层，
    // 不再挂在单个页签里，所以这里量图标槽而不是旧版的 40×22 底座。
    final iconSlot = tester.getRect(
      find.descendant(of: novelItem, matching: find.byType(SizedBox)).first,
    );
    final label = tester.getRect(novelLabel);
    expect(label.top - iconSlot.bottom, closeTo(4, 0.6), reason: '图标与文字间距 4px');
    expect(
      (iconSlot.top + label.bottom) / 2,
      closeTo(tester.getRect(novelItem).center.dy, 1.5),
      reason: '图标 + 文字整体垂直居中',
    );
  });

  testWidgets('负离底 + 90 高：真实 Dock 压进安全区且变高', (tester) async {
    await pumpShell(tester);

    await ShellSettingsController.instance.setAppearance(
      const DockAppearance(height: 90, safeGap: -25),
    );
    await tester.pumpAndSettle();

    final capsule = tester.getRect(dockCapsule());
    expect(capsule.height, closeTo(90, .01), reason: '高度 90 档位仍然生效');
    expect(
      height - capsule.bottom,
      closeTo(bottomInset - 25, 0.01),
      reason: '负留白从安全区里扣，胶囊离屏幕底边只剩 ${bottomInset - 25}pt',
    );
  });

  testWidgets('横屏安全区：胶囊避开左右刘海并保持居中', (tester) async {
    await pumpShell(tester);
    tester.view.physicalSize = const Size(956 * 3, 440 * 3);
    tester.view.viewPadding = const FakeViewPadding(
      left: 59 * 3,
      right: 59 * 3,
      bottom: 21 * 3,
    );
    tester.view.padding = const FakeViewPadding(
      left: 59 * 3,
      right: 59 * 3,
      bottom: 21 * 3,
    );
    await tester.pumpAndSettle();
    final capsule = tester.getRect(dockCapsule());
    expect(capsule.left, closeTo(59 + 24, 0.01));
    expect(956 - capsule.right, closeTo(59 + 24, 0.01));
    expect(440 - capsule.bottom, closeTo(21 + 4, 0.01));
    expect(capsule.height, closeTo(54, 0.01));
  });

  testWidgets('键盘弹出时隐藏胶囊且取消列表底部导航避让', (tester) async {
    await pumpShell(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320 * 3);
    tester.view.padding = const FakeViewPadding(top: statusInset * 3);
    await tester.pumpAndSettle();
    expect(tester.getRect(dockCapsule()).top, greaterThan(height));
    final dockContext = tester.element(find.byKey(AppShell.dockKey));
    expect(ShellDockScope.bottomInset(dockContext), 0);
    tester.view.viewInsets = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    await tester.pumpAndSettle();
    expect(
      height - tester.getRect(dockCapsule()).bottom,
      closeTo(bottomInset + 4, 0.01),
    );
  });

  testWidgets('切换页签时水滴用弹簧滑过去，带轻微过冲', (tester) async {
    await pumpShell(tester);

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    expect(pillFinder, findsOneWidget, reason: '水滴必须是独立的一层');

    final before = tester.getRect(pillFinder);
    expect(before.width, greaterThan(0));
    expect(before.height, greaterThan(0));

    Finder comicTab() => find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text(Section.comic.label),
        )
        .first;

    await tester.tap(comicTab());
    await tester.pump();
    // 前 20ms：水滴已经离开小说、但还没到漫画——是「滑过去」而不是硬闪。
    await tester.pump(const Duration(milliseconds: 20));
    final moving = tester.getRect(pillFinder);
    expect(moving.left, greaterThan(before.left), reason: '水滴应开始向右滑动');
    expect(
      moving.left,
      lessThan(before.left + 120),
      reason: '20ms 时不该已经瞬移到目标槽位',
    );

    // 采样一整段弹簧轨迹：SpringSimulation 会越过目标再被拉回。
    final samples = <double>[];
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      samples.add(tester.getRect(pillFinder).left);
    }
    final peak = samples.reduce((a, b) => a > b ? a : b);

    await tester.pumpAndSettle();
    final after = tester.getRect(pillFinder);
    expect(after.left, greaterThan(before.left), reason: '水滴应停在漫画槽位');
    expect(peak, greaterThan(after.left + .5), reason: '弹簧要越过目标再回来，才有水滴回弹的果冻感');
    expect(after.width, closeTo(before.width, .01), reason: '停稳后宽度回到基准');
    expect(after.height, closeTo(before.height, .01));
  });

  testWidgets('动效时长改的是弹簧软硬；关掉动效立即吸附', (tester) async {
    await pumpShell(tester);

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );

    Finder novelTab() => find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text(Section.novel.label),
        )
        .first;
    Finder comicTab() => find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text(Section.comic.label),
        )
        .first;

    /// 固定看松手后 60ms 的行程比例：时长越短 → 弹簧越硬 → 走得越远。
    Future<double> progressAfter60ms(int ms) async {
      await ShellSettingsController.instance.setAppearance(
        DockAppearance(animationMs: ms),
      );
      await tester.pumpAndSettle();
      await tester.tap(novelTab());
      await tester.pumpAndSettle();
      final start = tester.getRect(pillFinder).left;

      await tester.tap(comicTab());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final during = tester.getRect(pillFinder).left;
      await tester.pumpAndSettle();
      final end = tester.getRect(pillFinder).left;

      expect(end, greaterThan(start), reason: '两槽之间必须有位移');
      return (during - start) / (end - start);
    }

    final soft = await progressAfter60ms(400);
    final stiff = await progressAfter60ms(150);
    expect(
      stiff,
      greaterThan(soft + .1),
      reason: '150ms 的弹簧应在同样 60ms 内走得更远（$stiff vs $soft）',
    );

    // 关掉「点击弹跳动效」：同一帧就该在目标上，不再有补间。
    await ShellSettingsController.instance.setAppearance(
      const DockAppearance(animateSelection: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(novelTab());
    await tester.pumpAndSettle();
    final start = tester.getRect(pillFinder).left;

    await tester.tap(comicTab());
    await tester.pump();
    final immediate = tester.getRect(pillFinder).left;
    await tester.pumpAndSettle();
    final settled = tester.getRect(pillFinder).left;

    expect(settled, greaterThan(start), reason: '仍应切到漫画槽位');
    expect(immediate, closeTo(settled, .01), reason: '关掉动效后水滴应立即吸附，而不是从旧位置滑过去');
  });

  testWidgets('水平拖拽水滴：跟手、速度拉宽，松手吸附最近页签', (tester) async {
    await pumpShell(tester);

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    final before = tester.getRect(pillFinder);

    // 从当前水滴中心起手，快速往右拖两段（足够跨进漫画槽位）。
    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));

    final dragging = tester.getRect(pillFinder);
    expect(
      dragging.center.dx,
      greaterThan(before.center.dx + 20),
      reason: '拖动时水滴中心要跟着手指走',
    );
    expect(
      dragging.width,
      greaterThan(before.width + 2),
      reason: '滑动速度要像橡皮筋一样把水滴拉宽',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    final settled = tester.getRect(pillFinder);
    final comicCenter = tester.getCenter(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.comic.label),
          )
          .first,
    );
    expect(
      settled.center.dx,
      closeTo(comicCenter.dx, 1.5),
      reason: '松手后应吸附到离手指最近的漫画页签中心',
    );
    expect(settled.width, closeTo(before.width, .5), reason: '吸附完成后水滴宽度回到基准值');
  });

  testWidgets('按下时水滴按当前尺寸膨胀，松手弹回', (tester) async {
    await pumpShell(tester);

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    final before = tester.getRect(pillFinder);

    final gesture = await tester.startGesture(before.center);
    // 先推一帧让按压 Ticker 启动，再推进到按满。
    await tester.pump();
    // 按压反馈快于松手回弹；两者都从当前动效时长推导。
    await tester.pump(const Duration(milliseconds: 700));
    final pressed = tester.getRect(pillFinder);
    expect(
      pressed.width,
      greaterThan(before.width + 1),
      reason: '按到底后水滴边缘应按当前宽度比例膨胀',
    );
    final capsule = tester.getRect(dockCapsule());
    expect(pressed.top, lessThan(capsule.top), reason: '水滴必须能鼓出长胶囊上沿');
    expect(pressed.bottom, greaterThan(capsule.bottom), reason: '下沿也不能被胶囊裁平');
    expect(capsule.width, greaterThan(width - 48), reason: '长胶囊随按压轻微伸展');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(pillFinder).width,
      closeTo(before.width, .5),
      reason: '松手后水球应弹回基准宽度',
    );
    expect(tester.getRect(pillFinder).height, closeTo(before.height, .1));
    expect(tester.getRect(dockCapsule()).width, closeTo(width - 48, .1));
  });

  testWidgets('按压清晰度基于当前磨砂强度动态降低，松手回到设置值', (tester) async {
    await pumpShell(tester);
    final modules = FloatingModules.instance;
    addTearDown(() => modules.reset(FloatingModule.dock));
    modules.set(
      FloatingModule.dock,
      modules.style(FloatingModule.dock).copyWith(blur: 3),
    );
    await tester.pump();

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    Finder dropBlur() =>
        find.descendant(of: pillFinder, matching: find.byType(BackdropFilter));
    double sigma() {
      final text = tester.widget<BackdropFilter>(dropBlur()).filter.toString();
      return double.parse(
        RegExp(r'ImageFilter\.blur\(([0-9.]+)').firstMatch(text)!.group(1)!,
      );
    }

    double capsuleSigma() {
      final text = tester
          .widget<BackdropFilter>(find.byKey(ShellDockBar.capsuleFilterKey))
          .filter
          .toString();
      return double.parse(
        RegExp(r'ImageFilter\.blur\(([0-9.]+)').firstMatch(text)!.group(1)!,
      );
    }

    expect(sigma(), closeTo(3, .01), reason: '静止时读取当前磨砂强度 3');
    expect(capsuleSigma(), closeTo(3, .01));

    final gesture = await tester.startGesture(tester.getCenter(pillFinder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      sigma(),
      closeTo(3 * .34, .05),
      reason: '按到底后在当前 blur=3 的基础上动态降低（约 1.02）',
    );
    expect(capsuleSigma(), lessThan(2), reason: '底层胶囊也要减弱模糊，不能只改叠在上面的水滴');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(sigma(), closeTo(3, .05), reason: '松手后弹回当前设置值 3');
    expect(capsuleSigma(), closeTo(3, .05));
  });

  testWidgets('慢速拖拽：按离落点的距离拉伸，而不是只看速度', (tester) async {
    await pumpShell(tester);

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    final before = tester.getRect(pillFinder);

    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 16));
    // 手指停住：速度会被衰减到 0，但「离页签中心还有距离」仍然应保持拉长。
    await tester.pump(const Duration(milliseconds: 400));
    final held = tester.getRect(pillFinder);
    expect(
      held.width,
      greaterThan(before.width + 4),
      reason: '慢慢拖也要像橡皮筋一样被拉长，不能只是平移',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(pillFinder).width,
      closeTo(before.width, .5),
      reason: '松手后宽度要弹回基准',
    );
  });

  testWidgets('关掉点击弹跳动效：拖拽不拉伸，松手立即吸附', (tester) async {
    await pumpShell(tester);
    await ShellSettingsController.instance.setAppearance(
      const DockAppearance(animateSelection: false),
    );
    await tester.pumpAndSettle();

    final pillFinder = find.descendant(
      of: find.byKey(AppShell.dockKey),
      matching: find.byKey(ShellDockBar.selectionPillKey),
    );
    final before = tester.getRect(pillFinder);

    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final dragging = tester.getRect(pillFinder);
    expect(dragging.width, closeTo(before.width, .5), reason: '关闭动效后不做拉伸形变');
    expect(
      dragging.center.dx,
      greaterThan(before.center.dx + 20),
      reason: '拖动本身仍然跟手',
    );

    await gesture.up();
    await tester.pump();
    final comicCenter = tester.getCenter(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.comic.label),
          )
          .first,
    );
    expect(
      tester.getRect(pillFinder).center.dx,
      closeTo(comicCenter.dx, 1.5),
      reason: '关闭动效后松手直接瞬移到最近页签，不再走弹簧',
    );
  });

  testWidgets('极限外观参数：150pt 高 / 100pt 留白 / -50pt 离底 / 30 磨砂不报错', (
    tester,
  ) async {
    await pumpShell(tester);
    final modules = FloatingModules.instance;
    addTearDown(() => modules.reset(FloatingModule.dock));
    modules.set(
      FloatingModule.dock,
      modules.style(FloatingModule.dock).copyWith(opacity: 1, blur: 30),
    );

    const extreme = DockAppearance(
      horizontalMargin: 100,
      height: 150,
      safeGap: -50,
      borderOpacity: 1,
      shadowOpacity: 1,
      animationMs: 2000,
    );
    await ShellSettingsController.instance.setAppearance(extreme);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    var capsule = tester.getRect(dockCapsule());
    expect(capsule.height, closeTo(150, .01));
    expect(capsule.left, closeTo(100, .01));
    expect(capsule.right, closeTo(width - 100, .01));
    expect(
      capsule.bottom,
      closeTo(height + 16, .01),
      reason: '离底 -50 = 34pt 安全区 - 50 = -16，胶囊要向屏幕外沉 16pt',
    );

    // 另一端：40pt 的紧凑下限 + 满留白。文案用 FittedBox 兜底，不能 overflow。
    // 吸附验证用 -40（-50 时胶囊有 16pt 在屏幕外，点击点会落在屏幕外）。
    await ShellSettingsController.instance.setAppearance(
      extreme.copyWith(height: 40, safeGap: -40, animationMs: 2000),
    );
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: '40pt 高度不能 RenderFlex overflow',
    );

    capsule = tester.getRect(dockCapsule());
    expect(capsule.height, closeTo(40, .01));
    final item = tester.getRect(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(item.height, closeTo(40, .01));

    // 满量程弹簧仍然能吸附，且落定后没有异常。
    await tester.tap(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.comic.label),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getRect(
            find.descendant(
              of: find.byKey(AppShell.dockKey),
              matching: find.byKey(ShellDockBar.selectionPillKey),
            ),
          )
          .height,
      closeTo(32, .01),
      reason: '40pt 高减上下各 4pt，水滴高 32',
    );
  });

  testWidgets('底栏容器更薄 + 圆角椭圆（只收容器，图标文字尺寸不变）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 内容条 64 → 56 → 60 → **54**（第十三次：再收上下内边距，容器更扁平）。
    // 注意这不是胶囊外框的高：外框还要把手势条避让那一段一起画上。
    final item = tester.getRect(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(item.height, closeTo(54, 0.01), reason: '内容条保持统一高度');
    expect(item.height, greaterThanOrEqualTo(44.0), reason: '别压到里面的控件');

    final radius = tester.widget<ClipRRect>(dockCapsule()).borderRadius;
    expect(
      radius,
      BorderRadius.circular(capsule.height / 2),
      reason: '外框要是胶囊 / 椭圆：半径 = 容器高度的一半',
    );

    // 控件尺寸一如既往：选中态的图标与文字都没被缩放。
    final icon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byWidgetPredicate((w) => w is Icon),
          )
          .first,
    );
    expect(icon.size, 20, reason: '底栏图标尺寸不许随容器收窄而变小');
    final label = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.novel.label),
          )
          .first,
    );
    expect(label.style?.fontSize, 12, reason: '全局文字加大一号，底栏容器尺寸保持原样');
  });

  testWidgets('二级页（push 出来的）不留底部白条：内容一路铺到屏幕底边', (tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _SecondaryGlassPage(),
                  ),
                ),
                child: const Text('打开二级页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开二级页'));
    await tester.pumpAndSettle();

    // 用户口径：排行榜这类二级页底部不该多出一条浅色留白。
    // 真因：GlassScaffold 无条件让出底部安全区——壳里那一段正好被悬浮 Dock 盖住
    // （看不见，也是「最后一行不被 Dock 挡住」的实现），二级页底下没有 Dock，
    // 同一段就成了白条。现在只在壳里让（见 shared/widgets/glass_card.dart）。
    final list = tester.getRect(find.byKey(_SecondaryGlassPage.listKey));
    expect(
      list.bottom,
      closeTo(height, 1),
      reason: '二级页的内容要铺到屏幕底边，实测 ${list.bottom}（屏高 $height）',
    );
  });

  testWidgets('壳里的底部安全区仍然让出：宽度正好是 Dock 的脚印（所以看不见）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 量**壳内容区**（页面骨架）拿到的底部内边距：它在壳 Scaffold 的 body 之内，
    // 那里 Flutter 已经把 padding.bottom 换成了「底栏总高」。这一段必须正好等于
    // 悬浮胶囊占的那一段——等于才是「被胶囊盖住、看不见」，不等于就会露白条，
    // 或者让最后一行压到 Dock 底下。
    final pageContext = tester.element(find.byType(GlassScaffold).first);
    final reserved = MediaQuery.paddingOf(pageContext).bottom;
    final dockBand = height - capsule.top;
    expect(
      reserved,
      closeTo(dockBand, 0.01),
      reason:
          '壳里让出的底部安全区（$reserved）必须等于 Dock 占的那一段'
          '（胶囊上沿到屏幕底边 = $dockBand）',
    );
    expect(reserved, greaterThan(bottomInset), reason: '壳里让的是 Dock 脚印，不是系统手势条');
  });

  testWidgets('顶栏容器下沿两个大圆角（贴屏幕顶端的那两个角保持直角）', (tester) async {
    await pumpBoard(tester);

    final clip = tester.widget<ClipRRect>(
      find.descendant(of: homePanel(), matching: find.byType(ClipRRect)).first,
    );
    final radius = clip.borderRadius as BorderRadius;
    expect(radius.topLeft.x, 24, reason: '首页顶栏为悬浮胶囊');
    expect(radius.topRight.x, 24);
    expect(
      radius.bottomLeft.x,
      greaterThanOrEqualTo(16.0),
      reason: '用户口径要「大圆角」：下沿两角至少 16',
    );
    expect(radius.bottomRight, radius.bottomLeft);
  });

  testWidgets('中间内容区自动撑开：页签内容占满顶栏与 Dock 之间的空间', (tester) async {
    await pumpBoard(tester);

    final appBar = tester.getRect(find.text('视频'));
    // 板块页是「内容铺满整屏、顶栏浮在其上」（behindBar）——因此内容区的上下边界
    // 就是屏幕本身：两端移动后中间这块自动变大，不会再被夹出一条死白。
    final content = tester.getRect(find.byType(ExploreView));
    expect(content.top, closeTo(0, 1), reason: '内容铺满整屏（顶栏浮在其上）');
    expect(
      content.bottom,
      closeTo(height, 1),
      reason:
          '内容一路铺到屏幕底边（本用例把板块页单独挂载，树里没有 Dock 壳，'
          '按二级页口径不让底部安全区，实测 ${content.bottom}）',
    );
    // 顶栏下沿到第一条内容（图源条）之间只隔一档常规间距，不是一整条空白。
    final firstRow = tester.getRect(find.text('示例源'));
    final gap = firstRow.top - appBar.bottom;
    expect(gap, greaterThanOrEqualTo(0.0), reason: '图源条不该被顶栏压住（gap=$gap）');
    // 31pt = 列表 12 的顶部内边距 + 源选择卡片自己的内边距 + 文字基线：
    // 都是一档常规间距，不是「一整条空白」（以前这里会出现半个栏高）。
    expect(gap, lessThanOrEqualTo(36.0), reason: '顶栏与第一条内容之间只该留常规间距（实测 $gap）');
  });
}

/// 一个最小的「二级页」：玻璃骨架 + 可量的滚动视图（量它铺到哪儿）。
class _SecondaryGlassPage extends StatelessWidget {
  const _SecondaryGlassPage();

  static const Key listKey = Key('secondary-list');

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '二级页',
      child: ListView(
        key: listKey,
        padding: GlassScaffold.barInset(context)
            .add(const EdgeInsets.fromLTRB(16, 12, 16, 24)),
        children: const <Widget>[SizedBox(height: 2000, child: Text('内容'))],
      ),
    );
  }
}

/// 三套内核都不可用（本用例只看布局）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '${kernel.label} 未接入';
}
