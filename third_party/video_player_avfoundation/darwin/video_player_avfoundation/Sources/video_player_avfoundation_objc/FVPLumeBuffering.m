// Lume Box 本地补丁（见本包根目录 PATCHES.md）：
// 把宿主写入的播放缓冲参数应用到 video_player 建的 AVPlayer 上。

#import "FVPLumeBuffering.h"

@implementation FVPLumeBuffering

+ (void)applyToPlayer:(AVPlayer *)player {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  // 宿主没配置过：完全不碰，保持上游默认行为。
  if (![defaults boolForKey:@"lumebox.buffering.applied"]) {
    return;
  }

  // 前向缓冲时长：> 0 才写（0 表示「交给 AVFoundation 自动决定」）。
  NSNumber *forward = [defaults objectForKey:@"lumebox.buffering.forwardBufferSeconds"];
  if (forward != nil && forward.doubleValue > 0) {
    player.currentItem.preferredForwardBufferDuration = forward.doubleValue;
  }

  // 是否等缓冲填够再播：关掉它，AVPlayer 一拿到可播数据就起播。
  NSNumber *minimizeStalling = [defaults objectForKey:@"lumebox.buffering.minimizeStalling"];
  if (minimizeStalling != nil) {
    player.automaticallyWaitsToMinimizeStalling = minimizeStalling.boolValue;
  }
}

@end
