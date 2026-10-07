import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/video/player_kernel_picker.dart';
import 'package:lume_box/features/video/player_kernel_section.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 播放内核逃生入口（全局设置页内嵌区块）的验证：
/// 视频页卡死时也能在这里当场把内核切回 AVPlayer，且与视频板块共用同一份列表。
///
/// 非 iOS 平台上平台目录会说「仅骨架」，因此交互用例注入可用性替身——
/// 生产行为由 [PlayerKernelSection] 自己按平台目录判断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  void mockPathProvider(String? path) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? path : null,
    );
  }

  setUp(() async {
    PlayerFactory.clearMpvInitFailure();
    root = Directory.systemTemp.createTempSync('lume_box_kernel_section');
    mockPathProvider(root.path);
    await SectionScope.open(Section.video);
  });

  tearDown(() async {
    PlayerFactory.clearMpvInitFailure();
    ReadingLibrary.disposeAll();
    await SectionScope.closeAll();
    mockPathProvider(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 只挂逃生区块本身（交互用例；目录可控）。
  Future<void> pumpSection(
    WidgetTester tester, {
    Set<PlayerKernel> available = const <PlayerKernel>{
      PlayerKernel.avplayer,
      PlayerKernel.mpv,
    },
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlayerKernelSection(catalog: _FakeCatalog(available)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页内嵌逃生入口：与视频板块共用同一份内核列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        // 非 iOS 平台设置页是骨架；这里注入可用性以便断言内嵌区块。
        home: const SettingsPage(runtimeAvailable: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('播放器内核 · 故障逃生入口'), findsOneWidget);
    expect(
      find.byType(PlayerKernelPicker),
      findsOneWidget,
      reason: '两处必须是同一个组件（列表长得一模一样）',
    );
    for (final kernel in PlayerKernel.values) {
      expect(find.text(kernel.label), findsOneWidget);
    }
  });

  testWidgets('逃生切换：只改内核并写回视频板块的库；字幕不动，倍速按内核各记一份', (tester) async {
    final store = await VideoPlayerSettingsStore.open();
    store.save(
      const PlayerSettings(subtitlesEnabled: false).copyWith(speed: 1.5),
    );
    store.close();

    await pumpSection(tester);
    await tester.tap(find.text('MPV'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已切换到 MPV'), findsOneWidget);

    final probe = await VideoPlayerSettingsStore.open();
    final saved = probe.load();
    expect(saved.kernel, PlayerKernel.mpv, reason: '内核必须落库');
    expect(saved.subtitlesEnabled, isFalse, reason: '逃生入口不碰字幕（它是全局的）');
    // 倍速按内核分别记住：逃生入口不碰倍速，因此 AVPlayer 那一格仍是 1.5；
    // 当前内核（MPV）读自己的那一格（默认 1.0）。
    expect(
      saved.copyWith(kernel: PlayerKernel.avplayer).speed,
      1.5,
      reason: '原内核的倍速没被逃生切换动过',
    );
    expect(saved.speed, PlayerSettings.defaultSpeed);
  });

  testWidgets('逃生场景：库里的 MPV 不可用时，能在这里切回 AVPlayer', (tester) async {
    final store = await VideoPlayerSettingsStore.open();
    store.save(const PlayerSettings(kernel: PlayerKernel.mpv));
    store.close();

    await pumpSection(
      tester,
      available: const <PlayerKernel>{PlayerKernel.avplayer},
    );

    // 不可用原因照常展示（文案由可用性目录给出）。
    expect(find.text('MPV 内核尚未接入'), findsOneWidget);

    await tester.tap(find.text('AVPlayer'));
    await tester.pumpAndSettle();

    final probe = await VideoPlayerSettingsStore.open();
    expect(
      probe.load().kernel,
      PlayerKernel.avplayer,
      reason: '逃生入口必须能把内核切回来',
    );
  });

  testWidgets('库打不开：给出可读提示而不是白屏', (tester) async {
    await SectionScope.closeAll();
    ReadingLibrary.disposeAll();
    mockPathProvider(null);

    await pumpSection(tester);

    expect(find.text('播放器设置库不可用'), findsOneWidget);
  });
}

/// 内核可用性替身（与视频板块用例同一口径）。
class _FakeCatalog implements PlayerKernelCatalog {
  _FakeCatalog(this.available);

  final Set<PlayerKernel> available;

  @override
  bool isAvailable(PlayerKernel kernel) => available.contains(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}
