import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/player_settings_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

/// 播放器设置页的验证：内核选择（未接入项不可选并给出原因）、倍速档位、
/// 字幕开关与字号。页面是受控组件，断言落在「回调收到了什么设置」上。
void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required PlayerSettings settings,
    required PlayerKernelCatalog catalog,
    required ValueChanged<PlayerSettings> onChanged,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: PlayerSettingsPage(
          settings: settings,
          catalog: catalog,
          onChanged: onChanged,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('内核：当前项打勾；未接入项不可选并显示原因', (tester) async {
    PlayerSettings? changed;
    await pumpPage(
      tester,
      settings: const PlayerSettings(),
      catalog: _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
      onChanged: (next) => changed = next,
    );

    expect(find.text('AVPlayer'), findsOneWidget);
    expect(find.text('MPV 内核尚未接入'), findsOneWidget);
    expect(find.text('MDK 内核尚未接入'), findsOneWidget);
    // 只有当前内核打勾。
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // 未接入的内核点击无效。
    await tester.tap(find.text('MDK'));
    await tester.pumpAndSettle();
    expect(changed, isNull);
  });

  testWidgets('内核切换：点击可用内核回调新设置', (tester) async {
    PlayerSettings? changed;
    await pumpPage(
      tester,
      settings: const PlayerSettings(),
      catalog: _FakeCatalog(<PlayerKernel>{
        PlayerKernel.avplayer,
        PlayerKernel.mpv,
      }),
      onChanged: (next) => changed = next,
    );

    await tester.tap(find.text('MPV'));
    await tester.pumpAndSettle();

    expect(changed?.kernel, PlayerKernel.mpv);
    // 页面本地状态同步更新：勾选移到 MPV 那一行。
    Finder checkOn(String label) => find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(GlassCard),
          ),
          matching: find.byIcon(Icons.check_circle),
        );
    expect(checkOn('MPV'), findsOneWidget);
    expect(checkOn('AVPlayer'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('倍速：档位点击回调，选中态跟随', (tester) async {
    PlayerSettings? changed;
    await pumpPage(
      tester,
      settings: const PlayerSettings().copyWith(speed: 1.0),
      catalog: _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
      onChanged: (next) => changed = next,
    );

    // 档位是 0.25~4.0 步长 0.25（滑杆给全档位，芯片给常用预设）。
    expect(PlayerSettings.minSpeed, 0.25);
    expect(PlayerSettings.maxSpeed, 4.0);
    for (final label in <String>['0.5x', '1x', '2x', '3x']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    expect(
      find.widgetWithText(ChoiceChip, '1.5x'),
      findsWidgets,
      reason: '1.5x 在倍速与画面缩放里都有（同一个数字档）',
    );
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1x')).selected,
      isTrue,
    );

    // 点「2x」而不是「1.5x」：画面缩放里也有一个「1.5x」档，标签会重名；
    // 2x 只在倍速里出现，按标签就能唯一定位。
    await tester.tap(find.widgetWithText(ChoiceChip, '2x'));
    await tester.pumpAndSettle();

    expect(changed?.speed, 2.0);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '2x')).selected,
      isTrue,
    );
  });

  testWidgets('字幕：开关与字号写入设置', (tester) async {
    PlayerSettings? changed;
    await pumpPage(
      tester,
      // 字号 / 颜色 / 描边只有 MPV 有通道：换成 AVPlayer 时这些控件照旧显示，
      // 但点了会弹统一提示（见另一条用例），因此这里用 MPV 验「真的写进去」。
      settings: const PlayerSettings(kernel: PlayerKernel.mpv),
      catalog: _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
      onChanged: (next) => changed = next,
    );

    expect(find.text('显示字幕'), findsOneWidget);

    // 开着字幕时先改字号。
    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();
    expect(changed?.subtitleSize, SubtitleSize.large);

    // 再关字幕：改动基于本地最新状态，字号保持上一次的选择。
    // 页面上有两个开关（字幕 / 硬件解码），因此按「显示字幕」那一行定位。
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('显示字幕'),
          matching: find.byType(Row),
        ),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(changed?.subtitlesEnabled, isFalse);
    expect(changed?.subtitleSize, SubtitleSize.large);
  });

  testWidgets('字幕关闭时字号不可选', (tester) async {
    PlayerSettings? changed;
    await pumpPage(
      tester,
      settings: const PlayerSettings(subtitlesEnabled: false),
      catalog: _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
      onChanged: (next) => changed = next,
    );

    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();
    expect(changed, isNull);
  });
}

class _FakeCatalog implements PlayerKernelCatalog {
  const _FakeCatalog(this.available);

  final Set<PlayerKernel> available;

  @override
  bool isAvailable(PlayerKernel kernel) => available.contains(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}
