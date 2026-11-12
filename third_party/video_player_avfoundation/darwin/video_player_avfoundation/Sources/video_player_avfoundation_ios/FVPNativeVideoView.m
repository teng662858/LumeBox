// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "../video_player_avfoundation_objc/include/video_player_avfoundation_objc/FVPNativeVideoView.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface FVPWeakPlayerLayer : NSObject
@property(nonatomic, weak) AVPlayerLayer *layer;
@end
@implementation FVPWeakPlayerLayer
@end

static char inlineLayerKey;

@interface FVPPlayerView : UIView
@end

@implementation FVPPlayerView
+ (Class)layerClass {
  return [AVPlayerLayer class];
}

- (void)setPlayer:(AVPlayer *)player {
  [(AVPlayerLayer *)[self layer] setPlayer:player];
}
@end

@interface FVPNativeVideoView ()
@property(nonatomic) FVPPlayerView *playerView;
@end

@implementation FVPNativeVideoView
- (instancetype)initWithPlayer:(AVPlayer *)player {
  if (self = [super init]) {
    _playerView = [[FVPPlayerView alloc] init];
    _playerView.userInteractionEnabled = NO;
    [_playerView setPlayer:player];
    FVPWeakPlayerLayer *reference = [[FVPWeakPlayerLayer alloc] init];
    reference.layer = (AVPlayerLayer *)_playerView.layer;
    objc_setAssociatedObject(player, &inlineLayerKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return self;
}

+ (AVPlayerLayer *)layerForPlayer:(AVPlayer *)player {
  FVPWeakPlayerLayer *reference = objc_getAssociatedObject(player, &inlineLayerKey);
  return reference.layer;
}

- (FVPPlayerView *)view {
  return self.playerView;
}
@end
