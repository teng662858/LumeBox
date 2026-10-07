import 'package:flutter/material.dart';

import '../../core/player/playback_orientation.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 设置页的「播放」分组：横屏播放（用户要求）。
///
/// 它与播放器里的「方向锁定」是**同一份偏好**（[PlaybackOrientationController]）：
/// 这里是个两态开关（开 = 强制横屏），播放器里给了完整三档（自动 / 强制横屏 /
/// 强制竖屏）——用户在播放页想临时换一下，不必跑回设置里来。
///
/// 为什么开关只有两态：竖屏短剧的默认行为（竖屏全屏）就是「关」的样子，
/// 开关的语义是「我要一律横屏」；要强制竖屏是更少见的一档，放在播放器里。
class PlaybackSettingsGroup extends StatelessWidget {
  const PlaybackSettingsGroup({super.key, this.showTitle = true});

  /// 是否自带分组标题（嵌进设置页的更大分组时传 false）。
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final controller = PlaybackOrientationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
            '播放',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textSecondary,
            ),
          ),
        ),
        GlassCard(
          radius: 14,
          padding: EdgeInsets.zero,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.stay_current_landscape,
                    size: 22,
                    color: LumeTheme.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '横屏播放',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          controller.orientation.isLandscape
                              ? '已开启：全屏播放一律横屏'
                              : '关闭时按视频比例自动判断：竖屏短剧竖屏全屏、'
                                  '普通横片横屏全屏；播放器里还能强制竖屏',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: LumeTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: controller.orientation.isLandscape,
                    // 打开 = 强制横屏；关闭 = 回到「按视频比例自动判断」。
                    onChanged: (value) => controller.apply(
                      value
                          ? PlaybackOrientation.landscape
                          : PlaybackOrientation.auto,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
