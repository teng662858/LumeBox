import 'dart:io';

import 'abstract_player.dart';
import 'av_player.dart';
import 'mdk_engine.dart';
import 'media_kit_mpv_engine.dart';
import 'mpv_player.dart';
import 'player_settings.dart';

/// 播放器工厂：三套内核（AVPlayer / MPV / MDK）的唯一选择点。
///
/// 现状：iOS 上三套**都可用**——AVPlayer（video_player 驱动）、MPV（libmpv，
/// media_kit 提供）与 **MDK**（libmdk，由 `fvp` 提供原生库与纹理渲染）。
/// 三者各有自己的解码链（系统 / libmpv / libmdk），因此「某台设备上某个内核
/// 放不动（例如硬解 HEVC 花屏）」时还有别的选择——这正是留三套的意义。
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

  /// MDK 本次运行是否已被判定初始化失败（与 MPV 同一套熔断口径）。
  static bool get mdkInitFailed => _mdkInitFailed;
  static bool _mdkInitFailed = false;

  static void markMdkInitFailed() => _mdkInitFailed = true;

  static void clearMdkInitFailure() => _mdkInitFailed = false;

  /// 内核是否可用。
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
        // iOS 是主力平台：AVPlayer 与 MPV 都已接入（MPV 的原生库随 iOS 打包）。
        PlayerKernel.avplayer => Platform.isIOS,
        // MPV 初始化失败过：本次运行不再提供（逃生入口仍可切回 AVPlayer）。
        PlayerKernel.mpv => Platform.isIOS && !_mpvInitFailed,
        // MDK：原生库（libmdk）随 fvp 打包进 iOS；初始化失败过则本次不再提供。
        PlayerKernel.mdk => Platform.isIOS && !_mdkInitFailed,
      };

  /// 该内核能不能携带**逐媒体的请求头**（防盗链用的 Referer / UA）。
  ///
  /// - AVPlayer：能（`video_player` 的 `httpHeaders`）；
  /// - MPV：能（media_kit 的 `httpHeaders`）；
  /// - MDK：能（libmdk 的 `avio.headers` 属性，格式按 fvp 自身用法，
  ///   见 `MdkEngine.headersText`）——早期版本这里返回 false（当时以为 fvp
  ///   没有写通道），现在三条通路都有，因此不再有「因为带不了请求头而换内核」
  ///   的降级；保留这个查询是为了让降级逻辑在**将来某个内核又带不了**时仍然成立。
  static bool supportsMediaHeaders(PlayerKernel kernel) => switch (kernel) {
        PlayerKernel.avplayer => true,
        PlayerKernel.mpv => true,
        PlayerKernel.mdk => true,
      };

  /// 内核不可用的原因；可用时为 null（设置页直接展示这段文案）。
  static String? unavailableReason(PlayerKernel kernel) {
    if (isAvailable(kernel)) return null;
    if (kernel == PlayerKernel.mdk && _mdkInitFailed) {
      return 'MDK 初始化失败（本次运行已自动回退 AVPlayer）';
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
      // MDK：libmdk 绑定（fvp）挡在 MdkEngine 后面，上层只认 AbstractPlayer。
      PlayerKernel.mdk => MdkEngine.create(),
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
