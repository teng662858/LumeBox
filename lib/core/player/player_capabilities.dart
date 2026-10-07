import 'package:flutter/foundation.dart';

import 'player_settings.dart';

/// 播放器内核能力矩阵。
///
/// ## 这张表决定什么、不决定什么
///
/// **只决定「点下去之后是生效还是提示」，绝不决定按钮显隐。**
/// 用户点名的约束：每一个可用内核都要有整套控制能力，不允许「A 内核有这个按钮、
/// 切到 B 内核按钮就消失」——同一套控制栏 + 同一组设置入口，内核差异只体现在
/// 点击后的提示上（[unsupportedMessage]），而不是控件的存在与否。
///
/// 因此这里的每一项都对应「点下去会发生什么」：
/// - `true`  → 真的下发到内核（能不能生效由素材本身决定，例如没有第二条音轨时
///   菜单里就是空的，那是**素材**没有，不是内核不支持）；
/// - `false` → 弹统一提示，告诉用户换个内核（例如 AVPlayer 没有字幕样式通道）。
///
/// ## 为什么不做成三份独立的能力枚举
///
/// 上层只认这一个形状：UI 不需要 `switch (kernel)` 的写法，加内核时只改内核
/// 自己的 `capabilities` 一处，控制栏与设置面板一行都不用动。
@immutable
class PlayerCapabilities {
  const PlayerCapabilities({
    this.audioTracks = false,
    this.subtitleTracks = false,
    this.externalSubtitle = false,
    this.subtitleStyle = false,
    this.subtitleDelay = false,
    this.audioDelay = false,
    this.hardwareDecoding = false,
    this.backgroundAudio = false,
    this.nowPlaying = false,
    this.bufferingParams = false,
  });

  /// 多音轨选择（内置音轨切换）。
  final bool audioTracks;

  /// 内置字幕轨道切换。
  final bool subtitleTracks;

  /// 外挂字幕（从本地文件加载）。
  final bool externalSubtitle;

  /// 字幕样式（字号 / 颜色 / 描边 / 背景透明度）。
  final bool subtitleStyle;

  /// 字幕时间偏移（sub-delay）。
  final bool subtitleDelay;

  /// 音频延迟（音画不同步时的补偿）。
  final bool audioDelay;

  /// 硬件 / 软件解码切换。
  final bool hardwareDecoding;

  /// 后台音频继续播放。
  final bool backgroundAudio;

  /// 锁屏 / 控制中心的媒体控制器（播放条 / 暂停 / 切集）。
  final bool nowPlaying;

  /// 起播缓冲参数（B 项）。
  final bool bufferingParams;

  /// 点击不支持的功能时的统一提示（用户点名的口径，原文照用）。
  static const String unsupportedMessage = '当前播放器内核不支持该功能，请切换其它播放器';

  /// 基础控制（播放 / 暂停 / 停止 / 进度 / 倍速 / 手势 / 缩放 / 旋转 / 锁屏 /
  /// 画中画开关）**由 UI 层实现**，三套内核都支持，因此不在这里列出——
  /// 列出来的都是「必须内核配合」的项。
  static const PlayerCapabilities none = PlayerCapabilities();

  /// 三套内核的能力矩阵：**全项目唯一的声明处**。
  ///
  /// 各内核的 `capabilities` getter 都返回这里的表，因此不存在「实现里一份、
  /// 文档里一份」的漂移；没有播放器实例的地方（全局设置页）也能查到某个内核的
  /// 支持面。
  ///
  /// 逐项依据（都核对过依赖源码 / 官方文档，不是猜的）：
  /// - **AVPlayer**（video_player 2.14 + video_player_avfoundation 2.12）：
  ///   音轨选择可用（插件 `isAudioTrackSupportAvailable() == true`）；
  ///   字幕由系统样式渲染，轨道 / 样式 / 延迟都无接口；硬解无通道；
  ///   后台音频走 `allowBackgroundPlayback`；缓冲参数走本项目原生通道；
  /// - **MPV**（media_kit 1.2.6 / libmpv）：轨道、外挂字幕、字幕样式（Flutter
  ///   字幕层）、延迟（`sub-delay` / `audio-delay`）、硬解（`hwdec`）、缓冲参数
  ///   全部有通路；
  /// - **MDK**（fvp 0.39 / libmdk）：轨道与外挂字幕可用；字幕延迟可写
  ///   （`sub-delay`）；字幕是内嵌渲染（样式改不了）；音频延迟与解码链切换
  ///   没有可查证的属性名——**不猜**，如实标不支持。
  static PlayerCapabilities of(PlayerKernel kernel) => switch (kernel) {
        PlayerKernel.avplayer => const PlayerCapabilities(
            audioTracks: true,
            backgroundAudio: true,
            nowPlaying: true,
            bufferingParams: true,
          ),
        PlayerKernel.mpv => const PlayerCapabilities(
            audioTracks: true,
            subtitleTracks: true,
            externalSubtitle: true,
            subtitleStyle: true,
            subtitleDelay: true,
            audioDelay: true,
            hardwareDecoding: true,
            backgroundAudio: true,
            nowPlaying: true,
            bufferingParams: true,
          ),
        PlayerKernel.mdk => const PlayerCapabilities(
            audioTracks: true,
            subtitleTracks: true,
            externalSubtitle: true,
            subtitleDelay: true,
            backgroundAudio: true,
            nowPlaying: true,
          ),
      };

  @override
  bool operator ==(Object other) =>
      other is PlayerCapabilities &&
      other.audioTracks == audioTracks &&
      other.subtitleTracks == subtitleTracks &&
      other.externalSubtitle == externalSubtitle &&
      other.subtitleStyle == subtitleStyle &&
      other.subtitleDelay == subtitleDelay &&
      other.audioDelay == audioDelay &&
      other.hardwareDecoding == hardwareDecoding &&
      other.backgroundAudio == backgroundAudio &&
      other.nowPlaying == nowPlaying &&
      other.bufferingParams == bufferingParams;

  @override
  int get hashCode => Object.hash(
        audioTracks,
        subtitleTracks,
        externalSubtitle,
        subtitleStyle,
        subtitleDelay,
        audioDelay,
        hardwareDecoding,
        backgroundAudio,
        nowPlaying,
        bufferingParams,
      );

  @override
  String toString() => 'PlayerCapabilities('
      '${<String>[
        if (audioTracks) '音轨',
        if (subtitleTracks) '字幕轨',
        if (externalSubtitle) '外挂字幕',
        if (subtitleStyle) '字幕样式',
        if (subtitleDelay) '字幕延迟',
        if (audioDelay) '音频延迟',
        if (hardwareDecoding) '硬解',
        if (backgroundAudio) '后台音频',
        if (nowPlaying) '锁屏控制',
        if (bufferingParams) '缓冲参数',
      ].join('/')})';
}

/// 一条可选音轨 / 字幕轨（内核无关的统一形状）。
///
/// 三套内核的原始形状差别很大（libmpv 的轨道 id 是字符串、MDK 是下标、AVPlayer
/// 是 "0/1/2" 这样的序号），这里统一成「id + 展示名 + 语言 + 是否默认」。
@immutable
class PlayerTrack {
  const PlayerTrack({
    required this.id,
    required this.label,
    this.language,
    this.selected = false,
  });

  /// 内核侧的轨道标识（原样回传给内核）。
  final String id;

  /// 展示名（内核没给标题时用「音轨 1」这类兜底文案）。
  final String label;

  /// 语言标签（可能为空）。
  final String? language;

  /// 是否是当前选中的那条。
  final bool selected;

  @override
  bool operator ==(Object other) =>
      other is PlayerTrack &&
      other.id == id &&
      other.label == label &&
      other.language == language &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(id, label, language, selected);

  @override
  String toString() => 'PlayerTrack($id, $label${language == null ? '' : '/$language'}, '
      '${selected ? '选中' : '未选'})';
}
