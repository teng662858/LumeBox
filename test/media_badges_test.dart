import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/shared/widgets/media_badges.dart';
import 'package:lume_box/features/settings/media_badge_settings_page.dart';

void main() {
  setUp(() {
    AppPreferences.instance.mediaBadges = {};
  });
  test('未知规格省略，不把裁剪视频猜成标准分辨率', () {
    expect(MediaBadgeData.fromStats(PlayerStats.empty), isEmpty);
    expect(
      MediaBadgeData.fromStats(const PlayerStats(width: 1920, height: 800)),
      ['800P'],
    );
    expect(MediaBadgeData.fromMap({'title': '4K Dolby Vision'}), isEmpty);
  });
  testWidgets('卡片只显示两个且位置与总开关即时生效', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaBadges(
          values: ['4K', 'HDR10', 'HEVC'],
          location: 'card',
          limit: 2,
        ),
      ),
    );
    expect(find.text('HEVC'), findsNothing);
    expect(find.text('4K'), findsOneWidget);
    MediaBadgeSettings.instance.set('card', false);
    await tester.pump();
    expect(find.text('4K'), findsNothing);
    MediaBadgeSettings.instance.set('card', true);
    MediaBadgeSettings.instance.set('enabled', false);
    await tester.pump();
    expect(find.text('4K'), findsNothing);
  });
  testWidgets('按类别关闭并去重，播放器仅保留关键规格', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaBadges(
          values: ['4K', '1080P', 'HDR10', 'HEVC', 'Atmos', '5.1'],
          location: 'player',
        ),
      ),
    );
    expect(find.text('1080P'), findsNothing);
    expect(find.text('HEVC'), findsNothing);
    expect(find.text('Atmos'), findsOneWidget);
    MediaBadgeSettings.instance.set('kind.dynamicRange', false);
    await tester.pump();
    expect(find.text('HDR10'), findsNothing);
    MediaBadgeSettings.instance.setStyle('text');
    await tester.pump();
    expect(find.text('4K · Atmos'), findsOneWidget);
  });
  testWidgets('设置开关与图形样式实时预览', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MediaBadgeSettingsPage()));
    expect(find.text('启用媒体徽章'), findsOneWidget);
    MediaBadgeSettings.instance.setStyle('graphic');
    await tester.pump();
    expect(find.byIcon(Icons.hd_outlined), findsWidgets);
    expect(find.text('图文徽章'), findsOneWidget);
  });
}
