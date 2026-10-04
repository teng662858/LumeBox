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

  /// MPV 初始化超时（任务书：8 秒）。
  ///
  /// 超时即判定初始化失败：丢弃刚建的实例、回退 AVPlayer，并在本次运行内熔断
  /// MPV——绝不让用户卡在「进视频页就卡死」的状态里。
  static const Duration mpvInitTimeout = Duration(seconds: 8);

  /// MPV 本次运行是否已被判定初始化失败（熔断开关）。
  ///
  /// 熔断只在内存里，不写持久化配置：重启 App 会再给 MPV 一次机会，
  /// 而失败的那次绝不会把 MPV 写进库（见 `video_page` 的落库口径）。
  static bool get mpvInitFailed => _mpvInitFailed;
  static bool _mpvInitFailed = false;

  /// 标记 MPV 初始化失败（由 [PlayerKernelLauncher] 在丢弃实例时调用）。
  static void markMpvInitFailed() => _mpvInitFailed = true;

  /// 清除熔断标记（测试用；也给「用户手动重试」留一个入口）。
  static void clearMpvInitFailure() => _mpvInitFailed = false;

  /// 内核是否可用。
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
        // iOS 是主力平台：AVPlayer 与 MPV 都已接入（MPV 的原生库随 iOS 打包）。
        PlayerKernel.avplayer => Platform.isIOS,
        // MPV 初始化失败过：本次运行不再提供（逃生入口仍可切回 AVPlayer）。
        PlayerKernel.mpv => Platform.isIOS && !_mpvInitFailed,
        // MDK 只预留接口：没有原生库，如实报告不可用（Phase1 不实现）。
        PlayerKernel.mdk => false,
      };

  /// 内核不可用的原因；可用时为 null（设置页直接展示这段文案）。
  static String? unavailableReason(PlayerKernel kernel) {
    if (isAvailable(kernel)) return null;
    if (kernel == PlayerKernel.mdk) {
      return 'MDK 内核只预留接口（Phase1 未实现）';
    }
    if (kernel == PlayerKernel.mpv && _mpvInitFailed) {
      return 'MPV 初始化失败（本次运行已自动回退 AVPlayer）';
    }
    return '${kernel.label} 内核当前仅在 iOS 提供（Android / Windows 仅骨架）';
  }

  /// 按所选内核创建播放器；内核不可用时返回 null（调用方按现状降级为骨架）。
  ///
  /// **同步创建，必须经 [PlayerKernelLauncher] 调用**：那里负责把创建挪出
  /// UI 同步路径、加 8 秒超时、超时/抛错时丢弃实例并回退 AVPlayer。
  /// 直接在这里 new 播放器就等于把原生库装载放回主线程，会重现卡死。
  static AbstractPlayer? create({
    PlayerKernel kernel = PlayerKernel.avplayer,
  }) {
    if (!isAvailable(kernel)) return null;
    return switch (kernel) {
      PlayerKernel.avplayer => AvPlayer(),
      // MPV：libmpv（media_kit）绑定挡在端口后面，上层只认 AbstractPlayer。
      PlayerKernel.mpv => MpvPlayer(
          engine: MediaKitMpvEngine.create(title: 'Lume Box'),
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
