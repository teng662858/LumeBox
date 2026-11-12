import 'dart:io';

import 'abstract_player.dart';
import 'player_settings.dart';

/// Native video kernel catalog. Playback sessions are created by Swift through
/// NativeVideoBridge; Dart never constructs a decoder or a Flutter video view.
/// Legacy enum values are retained only to migrate saved preferences.
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

  /// MDK 本次运行是否已被判定初始化失败（与 MPV 同一套熔断口径）。
  static bool get mdkInitFailed => _mdkInitFailed;
  static bool _mdkInitFailed = false;

  static void markMdkInitFailed() => _mdkInitFailed = true;

  static void clearMdkInitFailure() => _mdkInitFailed = false;

  /// 内核是否可用。
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
    // iOS 是主力平台：AVPlayer 与 MPV 都已接入（MPV 的原生库随 iOS 打包）。
    PlayerKernel.avplayer => Platform.isIOS,
    PlayerKernel.aether => false,
    // MPV 初始化失败过：本次运行不再提供（逃生入口仍可切回 AVPlayer）。
    PlayerKernel.mpv => Platform.isIOS && !_mpvInitFailed,
    // Removed kernel; its enum value remains for preference migration.
    PlayerKernel.mdk => false,
  };

  /// Both native engines accept per-media headers without changing the URL.
  static bool supportsMediaHeaders(PlayerKernel kernel) => switch (kernel) {
    PlayerKernel.avplayer => true,
    PlayerKernel.aether => true,
    PlayerKernel.mpv => true,
    PlayerKernel.mdk => true,
  };

  /// 内核不可用的原因；可用时为 null（设置页直接展示这段文案）。
  static String? unavailableReason(PlayerKernel kernel) {
    if (kernel == PlayerKernel.aether || kernel == PlayerKernel.mdk) {
      return '旧内核已移除，请使用原生系统播放器或 MPV';
    }
    if (isAvailable(kernel)) return null;
    if (kernel == PlayerKernel.mdk && _mdkInitFailed) {
      return 'MDK 初始化失败（本次运行已自动回退 AVPlayer）';
    }
    if (kernel == PlayerKernel.mpv && _mpvInitFailed) {
      return 'MPV 初始化失败（本次运行已自动回退 AVPlayer）';
    }
    return '${kernel.label} 内核当前仅在 iOS 提供（Android / Windows 仅骨架）';
  }

  /// Compatibility hook for old launch ports and injected test doubles.
  /// Production video routes open NativeVideoBridge instead.
  static AbstractPlayer? create({
    PlayerKernel kernel = PlayerKernel.avplayer,
  }) => null;
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
