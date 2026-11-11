// Lume Box 本地补丁（见本包根目录 PATCHES.md）：
// 把宿主写入的播放缓冲参数应用到 video_player 建的 AVPlayer 上。

#import "FVPLumeBuffering.h"
#include <math.h>

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

+ (BOOL)resumePlayerIfBuffered:(AVPlayer *)player wantsPlay:(BOOL)wantsPlay rate:(float)rate {
  AVPlayerItem *item = player.currentItem;
  if (!wantsPlay || player.automaticallyWaitsToMinimizeStalling || player.rate != 0 ||
      item.status != AVPlayerItemStatusReadyToPlay || !isfinite(rate) || rate <= 0) {
    return NO;
  }
  CMTime position = player.currentTime;
  if (!CMTIME_IS_NUMERIC(position)) return NO;
  // Never count a remote/disjoint buffered range as playable at this position.
  // A small reserve prevents repeated restarts on tiny partial downloads.
  for (NSValue *value in item.loadedTimeRanges) {
    CMTimeRange range = value.CMTimeRangeValue;
    CMTime end = CMTimeRangeGetEnd(range);
    if (!CMTIME_IS_NUMERIC(range.start) || !CMTIME_IS_NUMERIC(end) ||
        CMTimeCompare(range.start, position) > 0 ||
        CMTimeGetSeconds(CMTimeSubtract(end, position)) < 0.25) {
      continue;
    }
    // Match the speed limits applied by FVPVideoPlayer.updateRate.
    if (rate > 2 && !item.canPlayFastForward) rate = 2;
    if (rate < 1 && !item.canPlaySlowForward) rate = 1;
    [player playImmediatelyAtRate:rate];
    return YES;
  }
  return NO;
}

@end
