import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/lume_log.dart';

/// 起播缓冲参数（待办清单「视频播放启动慢」的 B 项）。
///
/// 问题：**拿到播放地址之后**到出画面之间，AVPlayer 会先按系统策略把前向缓冲
/// 填到一定程度才开始播放。网络慢 / 图源 CDN 抖动时，这一等就是几十秒到一两
/// 分钟（真机实测），而同一地址在电脑上立刻能播。
///
/// 这些参数**只存在于原生播放器对象上**，Dart 侧拿不到：
/// - AVPlayer：`AVPlayerItem.preferredForwardBufferDuration` 与
///   `AVPlayer.automaticallyWaitsToMinimizeStalling`；`video_player` 的
///   `VideoPlayerOptions` 只暴露 `mixWithOthers` / `allowBackgroundPlayback`
///   （已核对 2.14.1 的源码）；
/// - MPV：libmpv 的 `cache` / `demuxer-*` 属性（media_kit 的高层 API 不开放）；
/// - MDK：libmdk 的 `avio.*` 属性（fvp 只给了 `setProperty` 这一条通道）。
///
/// 因此本文件定义**一个统一的参数对象 + 一个原生写通道**：符合平台条件时写
/// 原生参数，不符合时如实降级（[UnsupportedBufferingBackend]），绝不假装已生效。
@immutable
class BufferingConfig {
  const BufferingConfig({
    this.forwardBuffer = Duration.zero,
    this.minimizeStalling = false,
    this.readAhead = const Duration(seconds: 15),
    this.maxBufferBytes = 64 * 1024 * 1024,
    this.maxBackBufferBytes = 16 * 1024 * 1024,
  });

  /// 默认参数：以「尽快出画面」为准，而不是把缓冲填满再播。
  ///
  /// 取值理由：
  /// - [forwardBuffer] = 0（AVFoundation 的「自动」）—— 交给系统按网络状况决定；
  ///   写死一个大值只会让起播更晚；
  /// - [minimizeStalling] = false —— 这是「等缓冲」最直接的开关：关掉后 AVPlayer
  ///   一拿到可播数据就起播，而不是先攒够缓冲；
  /// - 缓存上限给的是**中等值**（64MB 前向 / 16MB 回退）：长片连续播放足够用，
  ///   又不会像默认那样先把大块数据拉满再开始。
  static const BufferingConfig defaults = BufferingConfig();

  /// 由「前向缓冲」设置（模块设置里的秒数）派生一份参数。
  ///
  /// 为什么要有这条派生：那个滑杆此前只把值存进库，**没有任何内核消费它**
  /// （真机上「调了没反应」）。用户口径是一个设置，因此这里映射到两套内核
  /// **等价的那一项**：
  /// - AVPlayer：`preferredForwardBufferDuration`（[forwardBuffer]）；
  /// - MPV：`demuxer-readahead-secs`（[readAhead]）。
  ///
  /// [forwardBuffer] 为 0 / 负 = 交给内核自动决定，与 [defaults] 完全一致。
  /// **[minimizeStalling] 永远保持 false**：它是「不为了填缓冲而推迟起播」的
  /// 底线（见 [defaults] 的说明），前向缓冲只决定播放中预读多少，不许变成
  /// 起播前的一次等待。
  factory BufferingConfig.forForwardBuffer(Duration forwardBuffer) {
    if (forwardBuffer <= Duration.zero) return defaults;
    return BufferingConfig(
      forwardBuffer: forwardBuffer,
      readAhead: forwardBuffer,
    );
  }

  /// 前向缓冲时长；[Duration.zero] 表示交给内核自动决定。
  final Duration forwardBuffer;

  /// 是否让内核「等缓冲填够再播」（true = 等，false = 尽快起播）。
  final bool minimizeStalling;

  /// 前向解复用缓存时长（MPV 的 `demuxer-readahead-secs`）。
  final Duration readAhead;

  /// 前向解复用缓存上限（字节，MPV 的 `demuxer-max-bytes`）。
  final int maxBufferBytes;

  /// 回退（已播过）缓存上限（字节，MPV 的 `demuxer-max-back-bytes`）。
  final int maxBackBufferBytes;

  /// MPV 属性写法：字符串值 + 单位已在属性名里约定。
  Map<String, String> get mpvProperties => <String, String>{
        // 网络流开启缓存（本地文件由 libmpv 自行忽略）。
        'cache': 'yes',
        // 不要「等缓存填满再起播」——这是 mpv 侧的同一个开关。
        'cache-pause-initial': 'no',
        'demuxer-readahead-secs': '${readAhead.inSeconds}',
        'demuxer-max-bytes': '$maxBufferBytes',
        'demuxer-max-back-bytes': '$maxBackBufferBytes',
      };

  /// 通道参数（原生侧只需要这两项：它拿不到 Dart 的 Duration / 字节单位）。
  Map<String, Object?> toChannelArguments() => <String, Object?>{
        'forwardBufferSeconds': forwardBuffer.inMilliseconds / 1000.0,
        'minimizeStalling': minimizeStalling,
      };

  @override
  bool operator ==(Object other) =>
      other is BufferingConfig &&
      other.forwardBuffer == forwardBuffer &&
      other.minimizeStalling == minimizeStalling &&
      other.readAhead == readAhead &&
      other.maxBufferBytes == maxBufferBytes &&
      other.maxBackBufferBytes == maxBackBufferBytes;

  @override
  int get hashCode => Object.hash(
        forwardBuffer,
        minimizeStalling,
        readAhead,
        maxBufferBytes,
        maxBackBufferBytes,
      );

  @override
  String toString() => 'BufferingConfig(前向缓冲 ${forwardBuffer.inMilliseconds}ms, '
      '等待缓冲 ${minimizeStalling ? '是' : '否'}, '
      '预读 ${readAhead.inSeconds}s, 前向 $maxBufferBytes B, 回退 $maxBackBufferBytes B)';
}

/// 缓冲参数的原生写通道端口。
///
/// 与画中画 / 亮度 / 语音同一套做法：能力做成端口，平台不支持时如实返回 false，
/// 由调用方降级——调用方（各内核）不认识 UserDefaults、AVPlayer 或渠道名。
abstract interface class BufferingBackend {
  /// 平台是否提供原生写通道。
  Future<bool> isSupported();

  /// 应用缓冲参数（[BufferingConfig]）。失败只记日志，绝不打断播放。
  Future<void> apply(BufferingConfig config);
}

/// 没有原生写通道的后端（非 iOS，或原生侧未接入）。
class UnsupportedBufferingBackend implements BufferingBackend {
  const UnsupportedBufferingBackend();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> apply(BufferingConfig config) async {}
}

/// 方法通道 `lumebox/buffering`：
/// - `isSupported` → `bool`；
/// - `apply` → 参数见 [BufferingConfig.toChannelArguments]。
///
/// 原生未接入时 `isSupported` 把 MissingPluginException 如实降级为 false
/// （与 `MethodChannelBrightnessBackend` 同一口径）。
class MethodChannelBufferingBackend implements BufferingBackend {
  MethodChannelBufferingBackend({MethodChannel? methodChannel})
      : _methods = methodChannel ?? const MethodChannel(channelName);

  static const String channelName = 'lumebox/buffering';

  final MethodChannel _methods;

  /// 最近一次成功应用的原生开关：避免每次起播都往原生往返一次。
  bool _channelKnown = false;

  @override
  Future<bool> isSupported() async {
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
  }

  @override
  Future<void> apply(BufferingConfig config) async {
    try {
      await _methods.invokeMethod<void>('apply', config.toChannelArguments());
      _channelKnown = true;
    } on MissingPluginException {
      // 原生未接入：调用方已按 isSupported 走过降级路径，这里静默。
    } catch (error, stackTrace) {
      // 缓冲参数失败不该影响播放：记一条日志就好。
      LumeLog.warn('[buffering] 应用缓冲参数失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 是否已经成功写过一次（原生侧会持久保存这份配置）。
  ///
  /// 原生参数一旦写入就一直生效，因此内核**只需要在第一次起播前写一次**；
  /// 这个标记让第二次起播省掉一次通道往返。
  bool get channelKnown => _channelKnown;
}

/// 按平台选择缓冲参数后端：iOS 走原生，其余平台如实降级。
BufferingBackend createPlatformBufferingBackend() => Platform.isIOS
    ? MethodChannelBufferingBackend()
    : const UnsupportedBufferingBackend();
