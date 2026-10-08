import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/board_tabs.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_source_manager.dart';

/// 顶栏 / 底栏的纵向位置（用户口径）：
/// 1. 顶部导航（标题 + 图标 + 页签）整条贴近状态栏，只留一小段安全边距——
///    不许「往下陷」；
/// 2. 底部 Dock 下沿落在 iOS 标准底部安全距离上（安全区 + 0 余量）；
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
    controller = ShellDockController();
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
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
      .descendant(of: find.byKey(AppShell.dockKey), matching: find.byType(ClipRRect))
      .first;

  /// 挂一个**真实板块页**（视频：标题 + 右上角图标 + 书架/探索页签）。
  Future<void> pumpBoard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
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
              SourceDescriptor(id: 'a', name: '示例源', version: '1.0', enabled: true),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('顶部导航贴近状态栏：外框贴上移一档、内部内容避让状态栏', (tester) async {
    await pumpBoard(tester);

    final appBar = tester.getRect(find.byType(AppBar));
    // 用户口径 6：外框**向上顶**——整条上移一档（让出来的状态栏那一段被屏幕裁掉），
    // 所以 top 是负的、玻璃依然铺满状态栏区域。
    expect(appBar.top, closeTo(-kLumeTopInsetTrim, 0.01),
        reason: '顶栏要向上顶一档：外框贴近屏幕顶端，只让内容避让状态栏');

    // 视频页现在**没有页签条**（用户口径：删掉「浏览」，内容直接顶上去），
    // 因此这里量的是「避让后的状态栏 + 工具栏」；页签条的常量单独钉在下面。
    final chromeHeight = trimmedTopInset(statusInset) + kLumeToolbarHeight;
    expect(
      appBar.bottom,
      closeTo(chromeHeight, 2),
      reason: '顶栏下沿应为「避让后的状态栏 + 工具栏」=$chromeHeight，'
          '实测 ${appBar.bottom}（比状态栏原值高出一档才对）',
    );
    expect(
      appBar.bottom,
      lessThan(statusInset + kLumeToolbarHeight + BoardTabHeader.height - 1),
      reason: '必须比「完整安全区 + 页签条」那一版更高：这一档就是向上顶的幅度',
    );
    // 容器收窄（用户口径第三次反馈）：工具栏与页签条都比上一版更薄，
    // 但**不能薄到压住控件**——右上角图标盒 34 是硬下限。
    // 34 是硬下限：右上角图标盒就是 34（再矮 AppBar 会把它压到 32 = 缩放控件）。
    expect(kLumeToolbarHeight, greaterThanOrEqualTo(34.0));
    expect(kLumeToolbarHeight, lessThanOrEqualTo(38.0), reason: '收窄但别过冲');
    expect(BoardTabHeader.height, greaterThanOrEqualTo(36.0));
    expect(BoardTabHeader.height, lessThanOrEqualTo(40.0));

    // 视频页顶部**不再有**页签条（书架 / 探索那种只出现在小说 / 漫画页）。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(TabBar)),
      findsNothing,
      reason: '用户口径：删掉视频页顶部的「浏览」页签条，内容直接顶上去',
    );
    expect(kLumeToolbarHeight, lessThanOrEqualTo(44.0));
    expect(BoardTabHeader.height, lessThanOrEqualTo(44.0));
  });

  testWidgets('右上角图标仍按 42 的触达尺寸排布（只移容器、不缩控件）', (tester) async {
    await pumpBoard(tester);

    final icons = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(IconButton),
    );
    expect(icons, findsWidgets, reason: '顶栏应有一排图标按钮');
    for (final element in icons.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      // IconButtonTheme 里 minimumSize 是 42，但 `visualDensity: compact` 会把
      // 布局盒折到 34（这是既有口径，本轮没动过）——这里守住它，防止「为了让
      // 顶栏更矮」把图标本身压小。
      expect(
        rect.height,
        greaterThanOrEqualTo(34.0 - 0.01),
        reason: '图标按钮高度被压到 ${rect.height}，违反「不缩放控件」',
      );
      // 内容避让状态栏：icon 盒仍落在状态栏下沿之下（上移的是容器，不是内容压顶）。
      expect(
        rect.top,
        greaterThanOrEqualTo(statusInset - kLumeTopInsetTrim - 1),
        reason: '图标不能压到状态栏时间/电量（实测 ${rect.top}）',
      );
      expect(
        rect.top + rect.height,
        lessThanOrEqualTo(statusInset - kLumeTopInsetTrim + kLumeToolbarHeight + 1),
        reason: '图标仍要在工具栏之内',
      );
    }
  });

  testWidgets('底部 Dock 悬浮在屏幕底边之上 + 左右大幅收窄（用户口径第十一次）',
      (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 用户口径第七次：**保留一小段悬浮留白**——上一版怼死屏幕底边「改过头了」。
    // 第十一次：整体**再往上抬一小段**（6 → 12），别贴死屏幕底边。
    final gap = height - capsule.bottom;
    expect(
      gap,
      inInclusiveRange(10.0, 16.0),
      reason: '胶囊要悬浮在屏幕底边之上（约 12pt），实测 $gap',
    );
    // 用户口径第十一次：左右两侧**大幅收窄**，缩短悬浮背景的总宽度——胶囊按
    // 「最大宽度 320、居中」摆放，440pt 的屏幕上两侧各留 (440-320)/2 = 60。
    expect(capsule.width, closeTo(320, 0.01), reason: '胶囊总宽度要收到 320');
    expect(
      capsule.left,
      closeTo((width - 320) / 2, 0.01),
      reason: '胶囊居中：左侧留白 =（屏宽 − 最大宽度）÷ 2',
    );

    // 收窄容器**不许收窄点击区域**：五项平分之后每项仍要够手指点（≥44）。
    final items = find
        .descendant(of: find.byKey(AppShell.dockKey), matching: find.byType(InkWell))
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
      find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text(Section.novel.label),
      ).first,
    );
    expect(
      height - item.bottom,
      greaterThanOrEqualTo(inset),
      reason: '胶囊里的文字要避开系统手势条（至少离底边 ${inset}pt，'
          '实测 ${height - item.bottom}）',
    );
  });

  testWidgets('底栏容器更薄 + 圆角椭圆（只收容器，图标文字尺寸不变）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // **内容那一条**的高度收窄（用户口径第三次）：64 → 56。注意不是胶囊外框的高
    // ——外框现在还要把「手势条避让」那一段一起画上（用户口径 6：外框贴屏幕底边，
    // 内容往上缩），所以外框比内容条高。
    final item = tester.getRect(
      find
          .descendant(of: find.byKey(AppShell.dockKey), matching: find.byType(InkWell))
          .first,
    );
    // 内容条 64 → 56 → 48：只收留白；下限 44 是留给「图标 20 + 间距 3 + 文字 15」的。
    expect(item.height, lessThanOrEqualTo(50.0), reason: '内容条还没收窄（应 ≤48）');
    expect(item.height, greaterThanOrEqualTo(44.0), reason: '别压到里面的控件');

    final radius = tester.widget<ClipRRect>(dockCapsule()).borderRadius;
    expect(
      radius,
      BorderRadius.circular(capsule.height / 2),
      reason: '外框要是胶囊 / 椭圆：半径 = 容器高度的一半',
    );

    // 控件尺寸一如既往：选中态的图标与文字都没被缩放。
    final icon = tester.widget<Icon>(
      find.descendant(of: find.byKey(AppShell.dockKey), matching: find.byType(Icon)).first,
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
    expect(label.style?.fontSize, 11, reason: '底栏文字尺寸不许随容器收窄而变小');
  });

  testWidgets('二级页（push 出来的）不留底部白条：内容一路铺到屏幕底边', (tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
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

  testWidgets('壳里的底部安全区仍然让出：宽度正好是 Dock 的脚印（所以看不见）',
      (tester) async {
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
      reason: '壳里让出的底部安全区（$reserved）必须等于 Dock 占的那一段'
          '（胶囊上沿到屏幕底边 = $dockBand）',
    );
    expect(reserved, greaterThan(bottomInset), reason: '壳里让的是 Dock 脚印，不是系统手势条');
  });

  testWidgets('顶栏容器下沿两个大圆角（贴屏幕顶端的那两个角保持直角）', (tester) async {
    await pumpBoard(tester);

    final clip = tester.widget<ClipRRect>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(ClipRRect))
          .first,
    );
    final radius = clip.borderRadius as BorderRadius;
    expect(radius.topLeft.x, 0, reason: '上沿贴着屏幕顶端，保持直角');
    expect(radius.topRight.x, 0);
    expect(
      radius.bottomLeft.x,
      greaterThanOrEqualTo(16.0),
      reason: '用户口径要「大圆角」：下沿两角至少 16',
    );
    expect(radius.bottomRight, radius.bottomLeft);
  });

  testWidgets('中间内容区自动撑开：页签内容占满顶栏与 Dock 之间的空间', (tester) async {
    await pumpBoard(tester);

    final appBar = tester.getRect(find.byType(AppBar));
    // 板块页是「内容铺满整屏、顶栏浮在其上」（behindBar）——因此内容区的上下边界
    // 就是屏幕本身：两端移动后中间这块自动变大，不会再被夹出一条死白。
    final content = tester.getRect(find.byType(ExploreView));
    expect(content.top, closeTo(0, 1), reason: '内容铺满整屏（顶栏浮在其上）');
    expect(
      content.bottom,
      closeTo(height, 1),
      reason: '内容一路铺到屏幕底边（本用例把板块页单独挂载，树里没有 Dock 壳，'
          '按二级页口径不让底部安全区，实测 ${content.bottom}）',
    );
    // 顶栏下沿到第一条内容（图源条）之间只隔一档常规间距，不是一整条空白。
    final firstRow = tester.getRect(find.text('示例源'));
    final gap = firstRow.top - appBar.bottom;
    expect(
      gap,
      greaterThanOrEqualTo(0.0),
      reason: '图源条不该被顶栏压住（gap=$gap）',
    );
    // 31pt = 列表 12 的顶部内边距 + 源选择卡片自己的内边距 + 文字基线：
    // 都是一档常规间距，不是「一整条空白」（以前这里会出现半个栏高）。
    expect(
      gap,
      lessThanOrEqualTo(36.0),
      reason: '顶栏与第一条内容之间只该留常规间距（实测 $gap）',
    );
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
        padding: GlassScaffold.barInset(context).add(
          const EdgeInsets.fromLTRB(16, 12, 16, 24),
        ),
        children: const <Widget>[
          SizedBox(height: 2000, child: Text('内容')),
        ],
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
