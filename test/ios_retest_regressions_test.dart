import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/reading/explore_view.dart';

import 'support/fake_source_manager.dart';

/// iOS 复测（2026-10-12）查实的几处缺陷的回归用例。
///
/// 每条用例都对着一次**真机 / 模拟器的实测现象**写，不是照着实现反推的：
/// - 漫画导入订阅后探索页报「Bad state: This database has already been closed」；
/// - 弹幕开关关掉后重开视频又变回「开」；
/// - 点「测速」之后什么都没有（失败与「还没测」共用同一个占位文案）；
/// - MPV 内核销毁播放器必崩（SIGABRT，mp_destroy_client）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_ios_retest');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    // 阅读库在**真实时钟**里先打开：testWidgets 的 fake-async 里等不到真实 IO。
    await ReadingLibrary.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 按固定帧数推进（不用 `pumpAndSettle`：页面里只要有转圈动画它就永远等不到
  /// 「无新帧」，而这里要的只是「让异步链路跑完几轮」）。
  Future<void> advance(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  // ------------------------------------------------------------------ P1-2

  group('图源板块：探索页与板块级注册表的资源归属', () {
    Future<FakeSourceManager> pumpComicBoard(WidgetTester tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'demo-comic',
            name: '示例漫画源',
            version: '1.0.0',
            enabled: true,
          ),
        ],
      );
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: ComicPage(runtimeAvailable: true, manager: manager),
        ),
      );
      await advance(tester);
      return manager;
    }

    testWidgets('图源变更后探索页**原地**刷新：不换 Key 重挂', (tester) async {
      await pumpComicBoard(tester);
      expect(find.byType(ExploreView), findsOneWidget, reason: '板块把探索页挂上了');
      final before = tester.state(find.byType(ExploreView));

      // 「源管理」返回 = 走一遍宿主的 `_onSourcesChanged()`（图源变更代数 +1）。
      // 曾经的写法用 `ValueKey(revision)` 重挂探索页：新实例的首次解析会同步拿到
      // 旧的板块注册表，同一帧末尾旧实例 dispose 把它连同数据库一起关掉，新实例
      // 在飞的那条读就报「数据库已关闭」（真机在漫画导入订阅后复现）。
      await tester.tap(find.byKey(const ValueKey('open-source-picker')));
      await advance(tester);
      await tester.tap(find.byTooltip('源管理'));
      await advance(tester);
      expect(find.widgetWithText(AppBar, '漫画 · 源管理'), findsOneWidget);

      await tester.pageBack();
      await advance(tester);
      await tester.tap(find.byTooltip('关闭'));
      await advance(tester);

      final after = tester.state(find.byType(ExploreView));
      expect(
        identical(before, after),
        isTrue,
        reason: '探索页必须原地刷新；重挂会与旧实例的 dispose 抢同一份板块注册表',
      );
      expect(find.byType(ExploreView), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('板块页卸载：探索页不关掉板块级的图源管理器', (tester) async {
      final manager = await pumpComicBoard(tester);

      // 卸载整个板块页：探索页退出时**只归还借用**，不 close——它一 close 就是
      // 关掉整个板块的图源库，书架 / 详情 / 播放页随后都会报「库已关闭」。
      await tester.pumpWidget(const SizedBox.shrink());
      await advance(tester);

      expect(manager.closed, isFalse, reason: '板块共享的图源管理器由板块页收尾（与阅读库同一条纪律）');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ------------------------------------------------------------------ P2-4

  // ------------------------------------------------------------------ O-3

  // ------------------------------------------------------------------ P0-1
}

/// 内核目录替身：只回答「有哪些内核可用」。

/// 静默播放器：只让页面有「就绪」的落点，不产生任何快照。

/// 回一份「太短」的探测响应：与「站点拒绝 / 回错误页」在测速里是同一个结论
/// （读不到有效数据 → 没有读数）。
