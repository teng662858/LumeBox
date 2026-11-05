import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/playback_glass.dart';
import 'package:lume_box/features/video/player_settings_panel.dart';

void main() {
  final frame = find.byKey(const ValueKey('danmaku-panel-frame'));
  final openers = <String, Future<void> Function(BuildContext)>{
    '画质、倍速和内核菜单': (context) async => showPlaybackMenu<void>(
      context: context,
      glass: false,
      builder: (_) => const Text('内容'),
    ),
    '弹幕匹配': (context) async => showDanmakuPanel<void>(
      context: context,
      builder: (_) => const Text('内容'),
    ),
    '二级设置': (context) async => showPlayerSettingsPanel<void>(
      context: context,
      builder: (_) => const Text('内容'),
    ),
    '链接输入': (context) async => showPlayerDialog<void>(
      context: context,
      builder: (_) =>
          const AlertDialog(title: Text('字幕链接'), content: TextField()),
    ),
    '外挂字幕选择': (context) async => showPlayerDialog<void>(
      context: context,
      builder: (_) =>
          const SimpleDialog(title: Text('导入外挂字幕'), children: [Text('选择本地文件')]),
    ),
  };
  for (final entry in openers.entries) {
    testWidgets('${entry.key}与选集相同位置尺寸，旋转和键盘后仍贴边', (tester) async {
      tester.view.physicalSize = const Size(932, 430);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(right: 44, bottom: 24);
      tester.view.padding = const FakeViewPadding(right: 44, bottom: 24);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => entry.value(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final initialRect = tester.getRect(frame);
      expect(initialRect.left, closeTo(932 * .6, .01));
      expect(initialRect.top, 0);
      expect(initialRect.right, 932);
      expect(initialRect.height, 430);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      final keyboardRect = tester.getRect(frame);
      expect(keyboardRect.right, 932);
      expect(keyboardRect.width, closeTo(932 * .4, .01));
      expect(keyboardRect.bottom, lessThanOrEqualTo(250));
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(430, 932);
      await tester.pumpAndSettle();
      expect(tester.getSize(frame).width, lessThanOrEqualTo(430));
      tester.view.physicalSize = const Size(932, 430);
      await tester.pumpAndSettle();
      expect(tester.getRect(frame).right, 932);
      expect(tester.getSize(frame).height, 430);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('竖屏嵌套输入忽略父层清除的键盘 inset，操作按钮仍在键盘上方', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: DanmakuPanelFrame(
                maxPortraitHeight: 280,
                child: Column(
                  children: [
                    const TextField(),
                    const Spacer(),
                    TextButton(onPressed: () {}, child: const Text('确认输入')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.byKey(const ValueKey('danmaku-panel-frame')),
    );
    expect(rect.bottom, lessThanOrEqualTo(544));
    expect(rect.height, lessThanOrEqualTo(280));
    expect(tester.getRect(find.text('确认输入')).bottom, lessThan(544));
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套设置输入弹窗仍占物理屏幕四成，确认只关闭输入层', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPlayerSettingsPanel<void>(
                context: context,
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () async {
                      result = await showPlayerDialog<String>(
                        context: context,
                        onlyInPlayer: true,
                        builder: (context) => AlertDialog(
                          title: const Text('关键词屏蔽'),
                          content: const TextField(),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, 'saved'),
                              child: const Text('应用'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Text('编辑屏蔽词'),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑屏蔽词'));
    await tester.pumpAndSettle();
    expect(frame, findsNWidgets(2));
    expect(tester.getRect(frame.last).right, 932);
    expect(tester.getSize(frame.last).width, closeTo(932 * .4, .01));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(frame, findsOneWidget);
    expect(find.text('编辑屏蔽词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏抽屉内容贴物理右边缘，右侧安全区不再推离卡片', (tester) async {
    // iOS 横屏把左右两侧安全区报成同一数值，这里用 44 模拟灵动岛机型：
    // 抽屉玻璃贴边，内容也必须贴边，只有顶部/底部仍让出系统安全区。
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(right: 44, bottom: 24);
    tester.view.padding = const FakeViewPadding(right: 44, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DanmakuPanelFrame(
            child: SizedBox.expand(key: ValueKey('panel-content')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final content = tester.getRect(find.byKey(const ValueKey('panel-content')));
    expect(content.left, closeTo(932 * .6, .01));
    expect(content.right, closeTo(932, .01));
    expect(content.top, 0);
    expect(content.bottom, closeTo(430 - 24, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局设置调用共用输入组件仍使用普通对话框', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPlayerDialog<void>(
                context: context,
                onlyInPlayer: true,
                builder: (_) => const AlertDialog(title: Text('关键词屏蔽')),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(frame, findsNothing);
  });
}
