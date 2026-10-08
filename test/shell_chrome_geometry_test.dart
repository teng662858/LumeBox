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

  testWidgets('顶部导航贴近状态栏：整条顶栏 = 状态区 + 工具栏 44 + 页签 44', (tester) async {
    await pumpBoard(tester);

    final appBar = tester.getRect(find.byType(AppBar));
    // 用户口径 6：外框**向上顶**——整条上移一档（让出来的状态栏那一段被屏幕裁掉），
    // 所以 top 是负的、玻璃依然铺满状态栏区域。
    expect(appBar.top, closeTo(-kLumeTopInsetTrim, 0.01),
        reason: '顶栏要向上顶一档：外框贴近屏幕顶端，只让内容避让状态栏');

    final chromeHeight =
        trimmedTopInset(statusInset) + kLumeToolbarHeight + BoardTabHeader.height;
    expect(
      appBar.bottom,
      closeTo(chromeHeight, 2),
      reason: '顶栏下沿应为「避让后的状态栏 + 工具栏 + 页签条」=$chromeHeight，'
          '实测 ${appBar.bottom}（比状态栏原值高出一档才对）',
    );
    expect(appBar.bottom, lessThan(statusInset + kLumeToolbarHeight + BoardTabHeader.height - 1),
        reason: '必须比「完整安全区」那一版更高：这一档就是向上顶的幅度');
    // 容器收窄（用户口径第三次反馈）：工具栏与页签条都比上一版更薄，
    // 但**不能薄到压住控件**——右上角图标盒 34 是硬下限。
    // 34 是硬下限：右上角图标盒就是 34（再矮 AppBar 会把它压到 32 = 缩放控件）。
    expect(kLumeToolbarHeight, greaterThanOrEqualTo(34.0));
    expect(kLumeToolbarHeight, lessThanOrEqualTo(38.0), reason: '收窄但别过冲');
    expect(BoardTabHeader.height, greaterThanOrEqualTo(36.0));
    expect(BoardTabHeader.height, lessThanOrEqualTo(40.0));

    // 页签条确实在顶栏里（书架 / 探索）。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(TabBar)),
      findsOneWidget,
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

  testWidgets('底部 Dock 贴在屏幕底边上方一档（对齐参考图的位置）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 用户口径第七次：**保留一小段悬浮留白**——上一版怼死屏幕底边「改过头了」，
    // 要的是「缩短空隙、不消除空隙」。
    final gap = height - capsule.bottom;
    expect(
      gap,
      inInclusiveRange(6.0, 14.0),
      reason: '胶囊要悬浮在屏幕底边之上（约 8pt），实测 $gap',
    );
    expect(capsule.left, closeTo(12, 0.01), reason: '左右悬浮留白仍是 12');

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
    expect(item.height, lessThanOrEqualTo(58.0), reason: '内容条还是老高度（64）');
    expect(item.height, greaterThanOrEqualTo(48.0), reason: '别压到里面的控件');

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
    final content = tester.getRect(find.byType(BoardTabs));
    expect(content.top, closeTo(0, 1), reason: '内容铺满整屏（顶栏浮在其上）');
    expect(
      content.bottom,
      closeTo(height - bottomInset, 1),
      reason: '内容一直铺到**底部安全区**（板块页没有 Dock 时就是安全区边界，实测 ${content.bottom}）',
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

/// 三套内核都不可用（本用例只看布局）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '${kernel.label} 未接入';
}
