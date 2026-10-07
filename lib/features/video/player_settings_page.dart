import 'package:flutter/material.dart';

import '../../core/player/playback_orientation.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../shared/widgets/glass_card.dart';
import 'player_settings_sheet.dart';

/// 播放器设置页（全局设置 Tab → 播放器设置）。
///
/// **与播放页的设置弹窗共用同一个面板**（[PlayerSettingsSheet] 的正文）：
/// 两处不各写一套，免得同一项在两处长得不一样、或者改了一边忘一边。
///
/// 受控页面：设置从 [settings] 进来，改动经 [onChanged] 出去（由宿主写库并立即
/// 应用到正在播放的内核）。
class PlayerSettingsPage extends StatelessWidget {
  const PlayerSettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.catalog = const PlatformPlayerKernelCatalog(),
  });

  /// 进入页面时的当前设置。
  final PlayerSettings settings;

  /// 设置变更回调：每改一项调用一次，参数是完整的下一份设置。
  final ValueChanged<PlayerSettings> onChanged;

  /// 内核可用性目录。
  final PlayerKernelCatalog catalog;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '播放器设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          PlayerSettingsSheet(
            settings: settings,
            // 全局页没有播放器实例：按「设置里选的内核」查同一张能力表。
            capabilities: PlayerCapabilities.of(settings.kernel),
            catalog: catalog,
            onChanged: onChanged,
            // 方向锁定是应用级偏好（与设置页的「横屏播放」同一份），
            // 这里直接读写控制器，不必再由宿主转一手。
            orientation: PlaybackOrientationController.instance.orientation,
            onOrientationChanged: PlaybackOrientationController.instance.apply,
            embedded: true,
          ),
        ],
      ),
    );
  }
}
