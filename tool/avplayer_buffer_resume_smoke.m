// Exercise the production resume policy using AVFoundation test doubles.
#import <AVFoundation/AVFoundation.h>
#import "FVPLumeBuffering.h"
#include <math.h>

@interface TimingAsset : AVMutableComposition
@property(nonatomic) AVKeyValueStatus timingStatus;
@property(nonatomic) NSUInteger durationReads;
@end
@implementation TimingAsset
- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)error {
  return self.timingStatus;
}
- (CMTime)duration {
  NSAssert(self.timingStatus == AVKeyValueStatusLoaded, @"unloaded duration must never be read");
  self.durationReads++;
  return CMTimeMake(42000, 1000);
}
@end

@interface ResumeItem : AVPlayerItem
@property(nonatomic) AVPlayerItemStatus testStatus;
@property(nonatomic, copy) NSArray<NSValue *> *testRanges;
@property(nonatomic) BOOL fastForward;
@property(nonatomic) BOOL slowForward;
@property(nonatomic) CMTime testDuration;
@property(nonatomic, strong) TimingAsset *timingAsset;
@end

@implementation ResumeItem
- (AVPlayerItemStatus)status { return self.testStatus; }
- (NSArray<NSValue *> *)loadedTimeRanges { return self.testRanges; }
- (BOOL)canPlayFastForward { return self.fastForward; }
- (BOOL)canPlaySlowForward { return self.slowForward; }
- (CMTime)duration { return self.testDuration; }
- (AVAsset *)asset { return self.timingAsset ?: [super asset]; }
@end

@interface ResumePlayer : AVPlayer
@property(nonatomic, strong) ResumeItem *testItem;
@property(nonatomic) CMTime testPosition;
@property(nonatomic) float testRate;
@property(nonatomic) NSUInteger resumes;
@end

@implementation ResumePlayer
- (AVPlayerItem *)currentItem { return self.testItem; }
- (CMTime)currentTime { return self.testPosition; }
- (float)rate { return self.testRate; }
- (void)playImmediatelyAtRate:(float)rate {
  self.resumes++;
  self.testRate = rate;
}
@end

static NSValue *Range(double start, double seconds) {
  return [NSValue valueWithCMTimeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(start, 1000),
                                                     CMTimeMakeWithSeconds(seconds, 1000))];
}

static void Check(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    ResumeItem *item = [[ResumeItem alloc] initWithAsset:[AVMutableComposition composition]];
    TimingAsset *timing = [[TimingAsset alloc] init];
    item.timingAsset = timing;
    item.testDuration = CMTimeMake(8000, 1000);
    Check(CMTimeGetSeconds([FVPLumeBuffering knownDurationForItem:item]) == 8,
          @"ready item timing never fetches asset metadata");
    item.testDuration = kCMTimeIndefinite;
    for (NSNumber *status in @[@(AVKeyValueStatusUnknown), @(AVKeyValueStatusLoading),
                               @(AVKeyValueStatusFailed), @(AVKeyValueStatusCancelled)]) {
      timing.timingStatus = status.integerValue;
      Check(CMTimeGetSeconds([FVPLumeBuffering knownDurationForItem:item]) == 0,
            @"unloaded or unavailable asset timing returns immediately");
    }
    Check(timing.durationReads == 0, @"no synchronous asset duration reads");
    timing.timingStatus = AVKeyValueStatusLoaded;
    Check(CMTimeGetSeconds([FVPLumeBuffering knownDurationForItem:item]) == 42,
          @"indefinite item can use already loaded asset timing");
    Check(CMTimeGetSeconds([FVPLumeBuffering knownDurationForItem:nil]) == 0,
          @"released item has no duration");
    item.timingAsset = nil;
    item.testStatus = AVPlayerItemStatusReadyToPlay;
    ResumePlayer *player = [[ResumePlayer alloc] init];
    player.testItem = item;
    player.testPosition = CMTimeMakeWithSeconds(10, 1000);
    player.automaticallyWaitsToMinimizeStalling = NO;

    // Reproduce underrun: native rate is zero and fresh data covers the playhead,
    // regardless of whether playbackLikelyToKeepUp has changed to YES.
    item.testRanges = @[Range(0, 30)];
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1.5],
          @"buffered underrun resumes in the same AVPlayer");
    Check(player.resumes == 1 && player.testRate == 1.5, @"preserves requested speed");
    Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1.5],
          @"new buffer events do not restart an already running player");
    player.testRate = 0;
    Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:NO rate:1],
          @"explicit pause or an outstanding seek prevents recovery");
    player.automaticallyWaitsToMinimizeStalling = YES;
    Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
          @"automatic-wait mode keeps its native recovery policy");
    player.automaticallyWaitsToMinimizeStalling = NO;

    for (NSArray<NSValue *> *ranges in @[@[], @[Range(0, 5)], @[Range(30, 60)],
                                       @[Range(0, 5), Range(30, 60)], @[Range(10, 0.1)]]) {
      item.testRanges = ranges;
      Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
            @"empty, old, disjoint or tiny reserves cannot resume");
    }
    item.testRanges = @[Range(10, 0.25)];
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
          @"small playable reserve resumes without filling 300 seconds");
    player.testRate = 0;
    item.testRanges = @[Range(0, 30)];
    for (NSNumber *status in @[@(AVPlayerItemStatusUnknown), @(AVPlayerItemStatusFailed)]) {
      item.testStatus = status.integerValue;
      Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
            @"not-ready and failed items never resume");
    }
    item.testStatus = AVPlayerItemStatusReadyToPlay;
    player.testPosition = kCMTimeIndefinite;
    Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
          @"unknown playhead cannot use a buffered range");
    player.testPosition = CMTimeMakeWithSeconds(10, 1000);
    for (NSNumber *rate in @[@0, @-1, @(NAN), @(INFINITY)]) {
      Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:rate.floatValue],
            @"invalid or non-forward rates never resume");
    }
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:3] &&
              player.testRate == 2, @"fast-forward respects native capability");
    player.testRate = 0;
    item.fastForward = YES;
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:3] &&
              player.testRate == 3, @"supported fast-forward keeps its speed");
    player.testRate = 0;
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:0.5] &&
              player.testRate == 1, @"slow-forward respects native capability");
    player.testRate = 0;
    item.slowForward = YES;
    Check([FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:0.5] &&
              player.testRate == 0.5, @"supported slow-forward keeps its speed");
    player.testRate = 0;
    player.testItem = nil;
    Check(![FVPLumeBuffering resumePlayerIfBuffered:player wantsPlay:YES rate:1],
          @"disposed/replaced item cannot resume");
    puts("AVPlayer buffered resume policy checks passed");
  }
  return 0;
}
