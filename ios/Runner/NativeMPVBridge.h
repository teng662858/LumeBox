#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns one libmpv core. Control, rendering and UIKit use separate serial queues.
@interface NativeMPVBridge : NSObject
- (instancetype)initWithOptions:(NSDictionary *)options
                          state:(void (^)(NSDictionary *))state
                          frame:(void (^)(CMSampleBufferRef))frame;
- (void)openURL:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers
      position:(double)position;
- (void)setProperty:(NSString *)name value:(NSString *)value;
- (void)command:(NSArray<NSString *> *)arguments;
- (void)setRenderingEnabled:(BOOL)enabled;
- (void)dispose:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
