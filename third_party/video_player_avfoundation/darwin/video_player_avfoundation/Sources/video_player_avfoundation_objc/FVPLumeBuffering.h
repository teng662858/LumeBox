// Lume Box 本地补丁（见本包根目录 PATCHES.md）：
// 把宿主写入的播放缓冲参数应用到 video_player 建的 AVPlayer 上。

@import AVFoundation;

NS_ASSUME_NONNULL_BEGIN

/// 缓冲参数的应用点。
///
/// 宿主（Lume Box 的 `ios/Runner/BufferingController.swift`）把参数写进
/// `UserDefaults`；这里在**每个 AVPlayer 创建时**读一次并应用。
/// 宿主没有配置过时（`lumebox.buffering.applied` 不存在）**什么都不做**，
/// 与上游行为完全一致。
@interface FVPLumeBuffering : NSObject

/// 把当前缓冲参数应用到刚创建好的播放器。
+ (void)applyToPlayer:(AVPlayer *)player;

@end

NS_ASSUME_NONNULL_END
