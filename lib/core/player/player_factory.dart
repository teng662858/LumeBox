import 'dart:io';

import 'abstract_player.dart';
import 'av_player.dart';
import 'player_settings.dart';

/// 播放器工厂：三套内核（AVPlayer / MPV / MDK）的唯一选择点。
///
/// 现状：只有 AVPlayer 这一套可用（iOS，由 video_player 插件驱动）；MPV / MDK
/// 尚未接入（没有原生库）。工厂如实报告可用性，设置页据此把未接入的内核标成
/// 不可选并给出原因——不假装可切换。
class PlayerFactory {
  PlayerFactory._();

  /// 当前平台是否有可用的播放内核（视频板块的平台门）。
  static bool get isSupported => isAvailable(PlayerKernel.avplayer);

  /// 内核是否可用。
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
        PlayerKernel.avplayer => Platform.isIOS,
        // MPV / MDK 内核未接入：没有原生库，先如实报告不可用。
        PlayerKernel.mpv => false,
        PlayerKernel.mdk => false,
      };

  /// 内核不可用的原因；可用时为 null（设置页直接展示这段文案）。
  static String? unavailableReason(PlayerKernel kernel) {
    if (isAvailable(kernel)) return null;
    if (kernel == PlayerKernel.avplayer) {
      return '当前平台不提供 AVPlayer（Android / Windows 仅骨架）';
    }
    return '${kernel.label} 内核尚未接入';
  }

  /// 按所选内核创建播放器；内核不可用时返回 null（调用方按现状降级为骨架）。
  static AbstractPlayer? create({
    PlayerKernel kernel = PlayerKernel.avplayer,
  }) =>
      isAvailable(kernel) ? AvPlayer() : null;
}

/// 内核目录端口：设置页依赖的最小能力集。
///
/// 页面不直接问平台，而是问目录；测试注入替身后，非 iOS 平台也能完整驱动
/// 「可选 / 不可选 + 原因」这套交互。
abstract interface class PlayerKernelCatalog {
  bool isAvailable(PlayerKernel kernel);

  String? unavailableReason(PlayerKernel kernel);
}

/// 平台目录：默认实现，按真实平台能力回答。
class PlatformPlayerKernelCatalog implements PlayerKernelCatalog {
  const PlatformPlayerKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => PlayerFactory.isAvailable(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      PlayerFactory.unavailableReason(kernel);
}
