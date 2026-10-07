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
import 'package:lume_box/features/video/player_settings_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 字幕完善（字号 / 颜色 / 描边 / 延迟）与硬件解码开关（文档要求）。
///
/// 文档的原始要求：「外挂字幕（srt/ass），字幕轨道切换、字幕字号/颜色/描边，
/// 字幕延迟调节，和弹幕参数面板分开」+「播放器增加硬件解码开关，部分设备硬解
/// HEVC 失败时可以切软解」。
///
/// 本文件验的是**设置模型与落库**这两层（引擎消费能力另见
/// `mpv_player_test` 与 `MpvEngine` 的接口说明）。其中「延迟与硬解当前只记录
/// 不生效」这条是如实标注的边界，用例把它钉住，避免将来被误读成已实现。
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
    root = Directory.systemTemp.createTempSync('lume_box_subtitle');
    mockPathProvider(root.path);
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    mockPathProvider(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('设置模型', () {
    test('默认值：字幕开、标准字号、白色、细描边、零延迟、硬解开', () {
      const settings = PlayerSettings();
      expect(settings.subtitlesEnabled, isTrue);
      expect(settings.subtitleSize, SubtitleSize.standard);
      expect(settings.subtitleColor, SubtitleColor.white);
      expect(settings.subtitleOutline, SubtitleOutline.thin);
      expect(settings.subtitleDelay, Duration.zero);
      expect(settings.hardwareDecoding, isTrue, reason: '硬解是默认（省电且流畅）');
    });

    test('字号档位含「特大」（文档要求可调）', () {
      expect(
        SubtitleSize.values.map((size) => size.id),
        containsAll(<String>['small', 'standard', 'large', 'huge']),
      );
      expect(SubtitleSize.huge.scale, greaterThan(SubtitleSize.large.scale));
    });

    test('颜色档位带 ARGB 值，且都是不透明色', () {
      for (final color in SubtitleColor.values) {
        expect(color.argb & 0xFF000000, 0xFF000000,
            reason: '字幕颜色必须不透明（半透明字幕压在画面上读不清）');
      }
    });

    test('描边档位含「无」（有些用户就是不喜欢描边）', () {
      expect(SubtitleOutline.none.width, 0);
      expect(SubtitleOutline.thick.width, greaterThan(SubtitleOutline.thin.width));
    });

    test('延迟归一：越界夹到 ±10 秒', () {
      expect(
        PlayerSettings.normalizeSubtitleDelay(const Duration(seconds: 30)),
        const Duration(seconds: 10),
      );
      expect(
        PlayerSettings.normalizeSubtitleDelay(const Duration(seconds: -30)),
        const Duration(seconds: -10),
      );
      expect(
        PlayerSettings.normalizeSubtitleDelay(const Duration(seconds: 3)),
        const Duration(seconds: 3),
      );
      expect(PlayerSettings.normalizeSubtitleDelay(null), Duration.zero);
    });

    test('延迟归一：归到 0.1 秒（滑杆精度）', () {
      expect(
        PlayerSettings.normalizeSubtitleDelay(
          const Duration(milliseconds: 1234),
        ),
        const Duration(milliseconds: 1200),
      );
      expect(
        PlayerSettings.normalizeSubtitleDelay(
          const Duration(milliseconds: -1234),
        ),
        const Duration(milliseconds: -1200),
      );
    });

    test('copyWith 保留未提及的字段', () {
      final base = const PlayerSettings(hardwareDecoding: false).copyWith(
        subtitleColor: SubtitleColor.yellow,
        subtitleOutline: SubtitleOutline.thick,
        subtitleDelay: const Duration(seconds: 2),
      );
      final next = base.copyWith(subtitleSize: SubtitleSize.huge);
      expect(next.subtitleSize, SubtitleSize.huge);
      expect(next.subtitleColor, SubtitleColor.yellow, reason: '没提的字段不动');
      expect(next.subtitleOutline, SubtitleOutline.thick);
      expect(next.subtitleDelay, const Duration(seconds: 2));
      expect(next.hardwareDecoding, isFalse);
    });

    test('相等性覆盖新增字段（改任一项都不再相等）', () {
      const base = PlayerSettings();
      expect(base.copyWith(subtitleColor: SubtitleColor.cyan), isNot(base));
      expect(base.copyWith(subtitleOutline: SubtitleOutline.none), isNot(base));
      expect(
        base.copyWith(subtitleDelay: const Duration(seconds: 1)),
        isNot(base),
      );
      expect(base.copyWith(hardwareDecoding: false), isNot(base));
      expect(base.copyWith(), base);
    });

    test('枚举 fromId 对未知值回退默认', () {
      expect(SubtitleColor.fromId('nope'), SubtitleColor.white);
      expect(SubtitleOutline.fromId('nope'), SubtitleOutline.thin);
      expect(SubtitleSize.fromId('nope'), SubtitleSize.standard);
      expect(SubtitleSize.fromId('huge'), SubtitleSize.huge);
    });
  });

  group('落库往返', () {
    test('全部新字段写进板块库并读回', () {
      final store = VideoPlayerSettingsStore(ReadingLibrary.find(Section.video)!);
      store.save(
        const PlayerSettings(hardwareDecoding: false).copyWith(
          subtitlesEnabled: true,
          subtitleSize: SubtitleSize.huge,
          subtitleColor: SubtitleColor.yellow,
          subtitleOutline: SubtitleOutline.thick,
          subtitleDelay: const Duration(milliseconds: 2500),
        ),
      );

      final loaded = store.load();
      expect(loaded.subtitleSize, SubtitleSize.huge);
      expect(loaded.subtitleColor, SubtitleColor.yellow);
      expect(loaded.subtitleOutline, SubtitleOutline.thick);
      expect(loaded.subtitleDelay, const Duration(milliseconds: 2500));
      expect(loaded.hardwareDecoding, isFalse);
    });

    test('负延迟也能落库（提前字幕）', () {
      final store = VideoPlayerSettingsStore(ReadingLibrary.find(Section.video)!);
      store.save(
        const PlayerSettings().copyWith(
          subtitleDelay: const Duration(seconds: -3),
        ),
      );
      expect(store.load().subtitleDelay, const Duration(seconds: -3));
    });

    test('旧库（缺新键）读回默认值，不让播放起不来', () {
      final store = VideoPlayerSettingsStore(ReadingLibrary.find(Section.video)!);
      // 旧版本只写过内核 / 倍速 / 开关 / 字号。
      final library = ReadingLibrary.find(Section.video)!;
      library.setSetting(VideoPlayerSettingsStore.keyKernel, 'mpv');
      library.setSetting(VideoPlayerSettingsStore.keySpeed, '1.50');

      final loaded = store.load();
      expect(loaded.kernel, PlayerKernel.mpv);
      expect(loaded.speed, 1.5);
      // 新字段回默认。
      expect(loaded.subtitleColor, SubtitleColor.white);
      expect(loaded.subtitleOutline, SubtitleOutline.thin);
      expect(loaded.subtitleDelay, Duration.zero);
      expect(loaded.hardwareDecoding, isTrue);
    });

    test('库里存了脏延迟值：归一后仍然可用', () {
      final library = ReadingLibrary.find(Section.video)!;
      library.setSetting(VideoPlayerSettingsStore.keySubtitleDelay, 'abc');
      final store = VideoPlayerSettingsStore(library);
      expect(store.load().subtitleDelay, Duration.zero);

      library.setSetting(VideoPlayerSettingsStore.keySubtitleDelay, '99999999');
      expect(
        store.load().subtitleDelay,
        const Duration(seconds: 10),
        reason: '越界值夹到上限，而不是拒绝加载',
      );
    });
  });

  group('设置页', () {
    Future<void> pumpPage(WidgetTester tester, {PlayerSettings? initial}) async {
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: PlayerSettingsPage(
            settings: initial ?? const PlayerSettings(),
            catalog: const _AllAvailableCatalog(),
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('字幕区展示字号 / 颜色 / 描边 / 延迟四项', (tester) async {
      await pumpPage(tester);

      // 字号（四个档位）
      expect(find.text('小'), findsOneWidget);
      expect(find.text('标准'), findsOneWidget);
      expect(find.text('大'), findsOneWidget);
      expect(find.text('特大'), findsOneWidget);

      // 颜色
      expect(find.text('颜色'), findsOneWidget);
      expect(find.text('白色'), findsOneWidget);
      expect(find.text('黄色'), findsOneWidget);

      // 描边
      expect(find.text('描边'), findsOneWidget);
      expect(find.text('无'), findsOneWidget);
      expect(find.text('细'), findsOneWidget);
      expect(find.text('粗'), findsOneWidget);

      // 底色（新增：压在亮画面上也能读）。分组说明里也提到「底色」，因此按值找。
      expect(find.textContaining('底色 45%'), findsOneWidget);

      // 延迟（滑杆 + 当前值）。字幕与音频各有一条延迟，因此是两条。
      expect(find.textContaining('延迟 0s'), findsWidgets);
    });

    testWidgets('解码区：支持的内核给开关，不支持的给「不支持」入口', (tester) async {
      // MPV（libmpv 的 hwdec 属性通道已打通）→ 真开关。
      await pumpPage(
        tester,
        initial: const PlayerSettings(kernel: PlayerKernel.mpv),
      );
      expect(find.text('解码'), findsOneWidget);
      expect(find.text('硬件解码'), findsOneWidget);
      expect(find.textContaining('优先硬解'), findsOneWidget);

      // AVPlayer（插件不暴露解码配置）→ 控件照旧在，但点了弹统一提示。
      await pumpPage(tester);
      expect(find.text('硬件解码'), findsOneWidget);
      expect(find.text('不支持'), findsOneWidget);
      expect(
        find.textContaining('没有切换解码链的通道'),
        findsOneWidget,
        reason: '如实说明边界，并指向可换的内核',
      );
    });

    testWidgets('切换颜色真的回调出去', (tester) async {
      PlayerSettings? changed;
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: PlayerSettingsPage(
            // 字幕样式（字号 / 颜色 / 描边 / 底色）只有 MPV 有通道；
            // AVPlayer 上这些控件照旧显示，但点了弹统一提示。
            settings: const PlayerSettings(kernel: PlayerKernel.mpv),
            catalog: const _AllAvailableCatalog(),
            onChanged: (next) => changed = next,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('黄色'));
      await tester.pumpAndSettle();
      expect(changed?.subtitleColor, SubtitleColor.yellow);
    });

    testWidgets('关闭硬件解码真的回调出去', (tester) async {
      PlayerSettings? changed;
      await tester.binding.setSurfaceSize(const Size(900, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: PlayerSettingsPage(
            // 硬解开关只有 MPV 真的能切（AVPlayer 上是「不支持」入口）。
            settings: const PlayerSettings(kernel: PlayerKernel.mpv),
            catalog: const _AllAvailableCatalog(),
            onChanged: (next) => changed = next,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 硬件解码是页面上的最后一个开关。
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(changed?.hardwareDecoding, isFalse);
    });

    testWidgets('字幕关闭时颜色 / 描边 / 延迟不可交互', (tester) async {
      await pumpPage(
        tester,
        initial: const PlayerSettings(subtitlesEnabled: false),
      );

      final chips = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .toList(growable: false);
      // 字号 / 颜色 / 描边三组芯片在字幕关闭时全部 onSelected 为 null。
      final subtitleChips = chips.where((chip) {
        final label = (chip.label as Text).data ?? '';
        return <String>['小', '标准', '大', '特大', '白色', '黄色', '无', '细', '粗']
            .contains(label);
      }).toList();
      expect(subtitleChips, isNotEmpty);
      for (final chip in subtitleChips) {
        expect(chip.onSelected, isNull, reason: '字幕关了，字幕样式不该还能改');
      }
    });
  });
}

class _AllAvailableCatalog implements PlayerKernelCatalog {
  const _AllAvailableCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => kernel != PlayerKernel.mdk;

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}
