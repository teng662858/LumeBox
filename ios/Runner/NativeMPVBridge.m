#import "NativeMPVBridge.h"
#import "../../third_party/mpv_headers/client.h"
#import "../../third_party/mpv_headers/render_gl.h"
#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>

static void *NativeMPVProc(void *context, const char *name);

static id NativeMPVNode(mpv_node *node) {
  switch (node->format) {
    case MPV_FORMAT_STRING: return node->u.string ? @(node->u.string) : @"";
    case MPV_FORMAT_FLAG: return @(node->u.flag != 0);
    case MPV_FORMAT_INT64: return @(node->u.int64);
    case MPV_FORMAT_DOUBLE: return isfinite(node->u.double_) ? @(node->u.double_) : @0;
    case MPV_FORMAT_NODE_ARRAY: {
      NSMutableArray *array = [NSMutableArray array];
      for (int i = 0; i < node->u.list->num; i++) [array addObject:NativeMPVNode(&node->u.list->values[i])];
      return array;
    }
    case MPV_FORMAT_NODE_MAP: {
      NSMutableDictionary *map = [NSMutableDictionary dictionary];
      for (int i = 0; i < node->u.list->num; i++) map[@(node->u.list->keys[i])] = NativeMPVNode(&node->u.list->values[i]);
      return map;
    }
    default: return [NSNull null];
  }
}

@implementation NativeMPVBridge {
  dispatch_queue_t _control, _render;
  dispatch_source_t _poll, _frames;
  mpv_handle *_mpv;
  mpv_render_context *_renderer;
  EAGLContext *_gl;
  CVOpenGLESTextureCacheRef _textureCache;
  CVPixelBufferPoolRef _pool;
  int _width, _height, _poolWidth, _poolHeight;
  BOOL _software, _ready, _fileLoaded, _ended;
  atomic_bool _closing, _framePending, _renderEnabled, _initialized;
  atomic_uintptr_t _publishedCore;
  NSString *_error;
  NSDictionary *_pendingMedia;
  void (^_state)(NSDictionary *);
  void (^_frame)(CMSampleBufferRef);
}

- (instancetype)initWithOptions:(NSDictionary *)options state:(void (^)(NSDictionary *))state frame:(void (^)(CMSampleBufferRef))frame {
  if (!(self = [super init])) return nil;
  _state = [state copy]; _frame = [frame copy];
  atomic_init(&_closing, false); atomic_init(&_framePending, false); atomic_init(&_renderEnabled, true);
  atomic_init(&_initialized, false);
  atomic_init(&_publishedCore, 0);
  _control = dispatch_queue_create("com.lumebox.native.mpv.control", DISPATCH_QUEUE_SERIAL);
  _render = dispatch_queue_create("com.lumebox.native.mpv.render", DISPATCH_QUEUE_SERIAL);
  _software = TARGET_OS_SIMULATOR;
  dispatch_async(_control, ^{
    if (atomic_load(&self->_closing)) return;
    self->_mpv = mpv_create();
    if (!self->_mpv) { [self fail:@"MPV 创建失败"]; return; }
    NSDictionary *settings = @{@"vo": @"libmpv", @"terminal": @"no", @"input-default-bindings": @"no",
      @"input-vo-keyboard": @"no", @"osc": @"no", @"idle": @"yes", @"keep-open": @"yes", @"pause": @"yes",
      @"hwdec": [options[@"hardwareDecoding"] isEqual:@NO] ? @"no" : (self->_software ? @"videotoolbox-copy" : @"videotoolbox"),
      @"network-timeout": @"15", @"cache": @"yes", @"cache-pause-initial": @"no", @"cache-pause-wait": @"0.5",
      @"demuxer-max-bytes": @"268435456", @"demuxer-max-back-bytes": @"33554432",
      @"demuxer-readahead-secs": @"120", @"ytdl": @"no", @"audio-display": @"no"};
    for (NSString *key in settings) mpv_set_option_string(self->_mpv, key.UTF8String, [settings[key] UTF8String]);
    double seconds = [options[@"forwardBufferSeconds"] doubleValue];
    if (isfinite(seconds) && seconds > 0) {
      mpv_set_option_string(self->_mpv, "demuxer-readahead-secs", [[NSString stringWithFormat:@"%.0f", MIN(86400, seconds)] UTF8String]);
    }
    int64_t bytes = [options[@"maxBufferBytes"] longLongValue];
    if (bytes > 0) {
      bytes = MAX(32LL * 1024 * 1024, MIN(1024LL * 1024 * 1024, bytes));
      mpv_set_option_string(self->_mpv, "demuxer-max-bytes", [[NSString stringWithFormat:@"%lld", (long long)bytes] UTF8String]);
    }
    if ([options[@"headlessAudio"] boolValue]) mpv_set_option_string(self->_mpv, "ao", "null");
    if ([options[@"subtitlesEnabled"] isEqual:@NO]) mpv_set_option_string(self->_mpv, "sid", "no");
    int status = mpv_initialize(self->_mpv);
    if (status < 0) { [self fail:@(mpv_error_string(status))]; return; }
    atomic_store(&self->_initialized, true);
    dispatch_async(self->_render, ^{ [self createRenderer]; });
  });
  return self;
}

- (void)fail:(NSString *)message {
  dispatch_async(_control, ^{
    if (atomic_load(&self->_closing)) return;
    self->_error = message;
    [self emit:@{@"error": message, @"buffering": @NO}];
  });
}
- (void)emit:(NSDictionary *)snapshot {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!atomic_load(&self->_closing) && self->_state) self->_state(snapshot);
  });
}
- (void)createRenderer {
  if (atomic_load(&_closing) || !atomic_load(&_renderEnabled) || !atomic_load(&_initialized) || _renderer) return;
  const char *api = _software ? MPV_RENDER_API_TYPE_SW : MPV_RENDER_API_TYPE_OPENGL;
  mpv_opengl_init_params gl = {.get_proc_address = NativeMPVProc};
  if (!_software) {
    _gl = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_gl || ![EAGLContext setCurrentContext:_gl]) { [self fail:@"MPV 无法创建原生图形上下文"]; return; }
    if (CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _gl, NULL, &_textureCache) != kCVReturnSuccess) {
      [self fail:@"MPV 无法创建视频纹理缓存"]; return;
    }
  }
  mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, (void *)api},
    {_software ? MPV_RENDER_PARAM_INVALID : MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl}, {0}};
  int code = mpv_render_context_create(&_renderer, _mpv, params);
  [EAGLContext setCurrentContext:nil];
  if (code < 0) { [self fail:@(mpv_error_string(code))]; return; }
  __weak NativeMPVBridge *weak = self;
  _frames = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _render);
  dispatch_source_set_timer(_frames, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC * 2);
  dispatch_source_set_event_handler(_frames, ^{ [weak renderFrame]; });
  dispatch_resume(_frames);
  dispatch_async(_control, ^{
    if (atomic_load(&self->_closing)) return;
    self->_ready = YES;
    atomic_store(&self->_publishedCore, (uintptr_t)self->_mpv);
    self->_poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_control);
    dispatch_source_set_timer(self->_poll, DISPATCH_TIME_NOW, NSEC_PER_MSEC * 250, NSEC_PER_MSEC * 20);
    dispatch_source_set_event_handler(self->_poll, ^{ [weak poll]; });
    dispatch_resume(self->_poll);
    if (self->_pendingMedia) [self openPending];
  });
}
static void *NativeMPVProc(void *context, const char *name) { return dlsym(RTLD_DEFAULT, name); }

- (id)property:(const char *)name {
  mpv_node node = {0};
  if (!_mpv || mpv_get_property(_mpv, name, MPV_FORMAT_NODE, &node) < 0) return nil;
  id value = NativeMPVNode(&node); mpv_free_node_contents(&node); return value;
}
- (double)number:(const char *)name {
  id value = [self property:name]; return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
}
- (void)poll {
  if (atomic_load(&_closing) || !_mpv) return;
  for (int i = 0; i < 100; i++) {
    mpv_event *event = mpv_wait_event(_mpv, 0);
    if (!event || event->event_id == MPV_EVENT_NONE) break;
    if (event->event_id == MPV_EVENT_FILE_LOADED) _fileLoaded = YES;
    if (event->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *end = event->data;
      if (end->reason == MPV_END_FILE_REASON_ERROR) [self fail:@(mpv_error_string(end->error))];
      if (end->reason == MPV_END_FILE_REASON_EOF) _ended = YES;
    }
  }
  int width = (int)[self number:"width"], height = (int)[self number:"height"];
  if (width > 0 && height > 0) {
    double scale = MIN(1., 1920. / MAX(width, height));
    int w = MAX(2, ((int)(width * scale) / 2) * 2), h = MAX(2, ((int)(height * scale) / 2) * 2);
    dispatch_async(_render, ^{ self->_width = w; self->_height = h; });
  }
  // With keep-open, seeking back from EOF resumes the same loaded file.
  // Retain the END_FILE notification only when the property is unavailable.
  id eof = [self property:"eof-reached"];
  if ([eof isKindOfClass:NSNumber.class]) _ended = [eof boolValue];
  BOOL paused = [self number:"pause"] != 0, buffering = [self number:"paused-for-cache"] != 0 || !_fileLoaded;
  NSMutableDictionary *snapshot = [@{@"position": @([self number:"time-pos"]), @"duration": @([self number:"duration"]),
    @"playing": @(!paused && !_ended && _fileLoaded), @"buffering": @(buffering), @"ready": @(_fileLoaded),
    @"ended": @(_ended), @"width": @(width), @"height": @(height),
    @"buffered": @([self number:"demuxer-cache-duration"]), @"tracks": [self property:"track-list"] ?: @[]} mutableCopy];
  if (_error) snapshot[@"error"] = _error;
  [self emit:snapshot];
}
- (void)openURL:(NSString *)url headers:(NSDictionary<NSString *,NSString *> *)headers position:(double)position {
  dispatch_async(_control, ^{
    if (atomic_load(&self->_closing)) return;
    self->_pendingMedia = @{@"url": url, @"headers": headers, @"position": @(MAX(0, position))};
    if (self->_ready) [self openPending];
  });
}
- (void)openPending {
  NSDictionary *media = _pendingMedia; _pendingMedia = nil;
  _fileLoaded = NO; _ended = NO; _error = nil;
  NSMutableArray *headers = [NSMutableArray array];
  for (NSString *key in media[@"headers"]) {
    NSString *value = media[@"headers"][key];
    if ([key rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound ||
        [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) continue;
    // Use a typed node array: string-list text parsing changes commas and
    // backslashes in signed cookies, so it cannot preserve exact headers.
    NSString *line = [NSString stringWithFormat:@"%@: %@", key, value];
    [headers addObject:line];
  }
  mpv_node *values = calloc(MAX(1, headers.count), sizeof(mpv_node));
  for (NSUInteger i = 0; i < headers.count; i++) {
    values[i].format = MPV_FORMAT_STRING;
    values[i].u.string = (char *)[headers[i] UTF8String];
  }
  mpv_node_list list = {.num = (int)headers.count, .values = values};
  mpv_node node = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
  int result = mpv_set_property(_mpv, "http-header-fields", MPV_FORMAT_NODE, &node);
  free(values);
  if (result < 0) { [self fail:@(mpv_error_string(result))]; return; }
  [self send:@[@"loadfile", media[@"url"], @"replace"]];
}
- (void)send:(NSArray<NSString *> *)arguments {
  if (!_mpv) return;
  const char **args = calloc(arguments.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < arguments.count; i++) args[i] = arguments[i].UTF8String;
  int status = mpv_command_async(_mpv, 0, args); free(args);
  if (status < 0) [self fail:@(mpv_error_string(status))];
}
- (void)command:(NSArray<NSString *> *)arguments {
  dispatch_async(_control, ^{ if (!atomic_load(&self->_closing)) [self send:arguments]; });
}
- (void)setProperty:(NSString *)name value:(NSString *)value {
  [self command:@[@"set", name, value]];
}
- (void)setRenderingEnabled:(BOOL)enabled {
  atomic_store(&_renderEnabled, enabled);
  // Called while resigning active, before UIKit enters the background. Drain
  // the final GPU submission; no media/control queue is waited on here.
  if (!enabled && !_software) dispatch_sync(_render, ^{});
  if (enabled) dispatch_async(_render, ^{ [self createRenderer]; });
}

- (void)renderFrame {
  if (atomic_load(&_closing) || !atomic_load(&_renderEnabled) || atomic_load(&_framePending) || !_renderer || _width <= 0 || _height <= 0) return;
  if (!_software) [EAGLContext setCurrentContext:_gl];
  uint64_t flags = mpv_render_context_update(_renderer);
  if (!(flags & MPV_RENDER_UPDATE_FRAME)) { [EAGLContext setCurrentContext:nil]; return; }
  if (!_pool || _poolWidth != _width || _poolHeight != _height) {
    if (_pool) CVPixelBufferPoolRelease(_pool); _pool = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey: @(_width), (id)kCVPixelBufferHeightKey: @(_height),
      (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
    _poolWidth = _width; _poolHeight = _height;
  }
  CVPixelBufferRef buffer = NULL;
  NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @6};
  if (!_pool || CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool, (__bridge CFDictionaryRef)limit, &buffer) != kCVReturnSuccess) {
    [EAGLContext setCurrentContext:nil]; return;
  }
  if (_software) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    int size[] = {_width, _height}; size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    mpv_render_param params[] = {{MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, "bgr0"},
      {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, CVPixelBufferGetBaseAddress(buffer)}, {0}};
    mpv_render_context_render(_renderer, params);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
  } else {
    CVOpenGLESTextureRef texture = NULL;
    CVReturn result = CVOpenGLESTextureCacheCreateTextureFromImage(NULL, _textureCache, buffer, NULL, GL_TEXTURE_2D,
      GL_RGBA, _width, _height, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
    if (result != kCVReturnSuccess || !texture) { CVPixelBufferRelease(buffer); [EAGLContext setCurrentContext:nil]; return; }
    GLuint fbo; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(texture), 0);
    // This FBO writes directly into a top-row-first CVPixelBuffer, consumed by
    // AVSampleBufferDisplayLayer. It is not an on-screen GL default framebuffer.
    // Flipping here inverts only the device OpenGL path (simulator uses SW).
    mpv_opengl_fbo target = {.fbo = (int)fbo, .w = _width, .h = _height}; int flip = 0;
    int blockForTargetTime = 0;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &blockForTargetTime}, {0}};
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) mpv_render_context_render(_renderer, params);
    glFinish(); glBindFramebuffer(GL_FRAMEBUFFER, 0); glDeleteFramebuffers(1, &fbo); CFRelease(texture);
    CVOpenGLESTextureCacheFlush(_textureCache, 0); [EAGLContext setCurrentContext:nil];
  }
  CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
  CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &format);
  CMSampleTimingInfo timing = {.duration = kCMTimeInvalid, .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600), .decodeTimeStamp = kCMTimeInvalid};
  if (format) CMSampleBufferCreateReadyWithImageBuffer(NULL, buffer, format, &timing, &sample);
  if (format) CFRelease(format); CVPixelBufferRelease(buffer);
  if (!sample) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (attachments && CFArrayGetCount(attachments)) CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  atomic_store(&_framePending, true);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!atomic_load(&self->_closing) && self->_frame) self->_frame(sample);
    CFRelease(sample); atomic_store(&self->_framePending, false);
  });
}
- (void)dispose:(void (^)(void))completion {
  if (atomic_exchange(&_closing, true)) { dispatch_async(dispatch_get_main_queue(), completion); return; }
  // Submit cancellation before teardown queues can be delayed by property IO.
  // The published core remains alive until the cleanup scheduled below runs.
  mpv_handle *core = (mpv_handle *)atomic_exchange(&_publishedCore, 0);
  if (core) {
    const char *pause[] = {"set", "pause", "yes", NULL};
    mpv_command_async(core, 0, pause);
  }
  dispatch_async(_control, ^{
    if (self->_poll) { dispatch_source_cancel(self->_poll); self->_poll = nil; }
    dispatch_async(self->_render, ^{
      if (self->_frames) { dispatch_source_cancel(self->_frames); self->_frames = nil; }
      if (!self->_software) [EAGLContext setCurrentContext:self->_gl];
      if (self->_renderer) { mpv_render_context_free(self->_renderer); self->_renderer = NULL; }
      if (self->_textureCache) { CFRelease(self->_textureCache); self->_textureCache = NULL; }
      if (self->_pool) { CVPixelBufferPoolRelease(self->_pool); self->_pool = NULL; }
      [EAGLContext setCurrentContext:nil]; self->_gl = nil;
      dispatch_async(self->_control, ^{
        if (self->_mpv) { mpv_terminate_destroy(self->_mpv); self->_mpv = NULL; }
        dispatch_async(dispatch_get_main_queue(), ^{ self->_state = nil; self->_frame = nil; completion(); });
      });
    });
  });
}
@end
