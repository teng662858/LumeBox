import 'dart:io';

import 'abstract_player.dart';
import 'av_player.dart';
import 'media_kit_mpv_engine.dart';
import 'mpv_player.dart';
import 'player_settings.dart';

/// 播放器工厂：三套内核（AVPlayer / MPV / MDK）的唯一选择点。
///
/// 现状（Phase1）：iOS 上 AVPlayer（video_player 驱动）与 **MPV**（libmpv，
/// 由 media_kit 提供原生库与渲染）都可用；MDK 只预留接口——没有原生库，
/// 工厂如实报告不可用并给出原因，不假装可切换。
///
/// 平台边界：Android / Windows 仍只保留骨架（Phase1 优先 iOS），因此除 iOS
/// 之外的平台统一报告「仅骨架」。
class PlayerFactory {
  PlayerFactory._();

  /// 当前平台是否有可用的播放内核（视频板块的平台门）。
  static bool get isSupported => isAvailable(PlayerKernel.avplayer);

  /// 内核是否可用。
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
        // iOS 是主力平台：AVPlayer 与 MPV 都已接入（MPV 的原生库随 iOS 打包）。
        PlayerKernel.avplayer => Platform.isIOS,
        PlayerKernel.mpv => Platform.isIOS,
        // MDK 只预留接口：没有原生库，如实报告不可用（Phase1 不实现）。
        PlayerKernel.mdk => false,
      };

  /// 内核不可用的原因；可用时为 null（设置页直接展示这段文案）。
  static String? unavailableReason(PlayerKernel kernel) {
    if (isAvailable(kernel)) return null;
    if (kernel == PlayerKernel.mdk) {
      return 'MDK 内核只预留接口（Phase1 未实现）';
    }
    return '${kernel.label} 内核当前仅在 iOS 提供（Android / Windows 仅骨架）';
  }

  /// 按所选内核创建播放器；内核不可用时返回 null（调用方按现状降级为骨架）。
  static AbstractPlayer? create({
    PlayerKernel kernel = PlayerKernel.avplayer,
  }) {
    if (!isAvailable(kernel)) return null;
    return switch (kernel) {
      PlayerKernel.avplayer => AvPlayer(),
      // MPV：libmpv（media_kit）绑定挡在端口后面，上层只认 AbstractPlayer。
      PlayerKernel.mpv => MpvPlayer(
          engine: MediaKitMpvEngine(title: 'Lume Box'),
          engineLabel: kernel.label,
        ),
      // MDK：只预留接口（上面的可用性判断已拦住，这里保持显式）。
      PlayerKernel.mdk => null,
    };
  }
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
