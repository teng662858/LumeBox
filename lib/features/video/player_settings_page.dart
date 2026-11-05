import 'intro_settings_page.dart';

import 'package:flutter/material.dart';

import '../../core/player/playback_orientation.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../shared/widgets/glass_card.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_sources_page.dart';
import 'player_settings_sheet.dart';
import '../media/audio_player_page.dart';
import '../settings/experience_settings_card.dart';
import '../settings/settings_ui.dart';

/// 播放器设置页（全局设置 Tab → 播放器设置）。
///
/// **与播放页的设置弹窗共用同一个面板**（[PlayerSettingsSheet] 的正文）：
/// 两处不各写一套，免得同一项在两处长得不一样、或者改了一边忘一边。
///
/// 受控页面：设置从 [settings] 进来，改动经 [onChanged] 出去（由宿主写库并立即
/// 应用到正在播放的内核）。
class PlayerSettingsPage extends StatefulWidget {
  const PlayerSettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.catalog = const PlatformPlayerKernelCatalog(),
    this.danmaku,
    this.onDanmakuChanged,
    this.focusCategory,
  });
  final String? focusCategory;

  /// 弹幕设置（与播放页的弹幕面板同一份数据；为空时不显示弹幕一节）。
  ///
  /// 由宿主从**视频板块的库**里读出来传进来——用户口径：全局设置里也要能改弹幕。
  final DanmakuSettings? danmaku;

  /// 弹幕设置变更回调（宿主写库）。
  final ValueChanged<DanmakuSettings>? onDanmakuChanged;

  /// 进入页面时的当前设置。
  final PlayerSettings settings;

  /// 设置变更回调：每改一项调用一次，参数是完整的下一份设置。
  final ValueChanged<PlayerSettings> onChanged;

  /// 内核可用性目录。
  final PlayerKernelCatalog catalog;

  @override
  State<PlayerSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<PlayerSettingsPage> {
  late String selected = widget.focusCategory ?? 'playback';
  static const _categories = <(String, String, String, IconData)>[
    ('playback', '播放与选集', '播放速度、画质与选集偏好', Icons.play_circle_outline),
    ('intro', '片头片尾', '跳过片头片尾与同剧记忆', Icons.skip_next_outlined),
    ('picture', '画面与显示', '缩放、画面比例与方向', Icons.aspect_ratio),
    ('audio', '声音与字幕', '字幕样式、音轨与延迟', Icons.subtitles_outlined),
    ('danmaku', '弹幕与匹配', '弹幕样式、屏蔽与服务', Icons.chat_bubble_outline),
    ('controls', '手势与外观', '控制栏样式与手势灵敏度', Icons.touch_app_outlined),
    (
      'advanced',
      '内核与网络',
      '播放内核、解码和网络选项',
      Icons.settings_input_component_outlined,
    ),
  ];

  Widget _categoryBody(BuildContext context, String id) => ListView(
    key: PageStorageKey('player-settings-$id'),
    padding: const EdgeInsets.all(16),
    children: [
      if (id == 'playback') ...[
        const BackgroundPlaybackSetting(),
        const SizedBox(height: 16),
      ],
      PlayerSettingsSheet(
        key: ValueKey(id),
        categoryOnly: id,
        settings: widget.settings,
        capabilities: PlayerCapabilities.of(widget.settings.kernel),
        catalog: widget.catalog,
        onChanged: widget.onChanged,
        orientation: PlaybackOrientationController.instance.orientation,
        onOrientationChanged: PlaybackOrientationController.instance.apply,
        danmaku: widget.danmaku,
        onDanmakuChanged: widget.onDanmakuChanged,
        embedded: true,
        danmakuControls: ListTile(
          leading: const Icon(Icons.comment_outlined),
          title: const Text('弹幕服务'),
          subtitle: const Text('内置本机服务 · 弹弹play 开放平台 · 自定义服务器'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showSettingsDetail(context, const DanmakuSourcesPage()),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.video,
    settingsSurface: true,
    title: '播放器设置',
    child: Column(
      children: [
        SettingsTabBar(
          selected: selected,
          tabs: [
            for (final entry in _categories) (entry.$1, entry.$2),
            ('audioPlayer', '音频播放器'),
          ],
          onSelected: (id) => setState(() => selected = id),
        ),
        Expanded(
          child: selected == 'intro'
              ? const IntroSettingsPage(embedded: true)
              : selected == 'audioPlayer'
              ? const AudioPlaybackSettingsPage(embedded: true)
              : _categoryBody(context, selected),
        ),
      ],
    ),
  );
}
