import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'buffering.dart';
import 'player_capabilities.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// 播放器要打开的媒体。
class PlayerMedia {
  const PlayerMedia({required this.uri, this.headers, this.title});

  /// 本地文件与网络地址统一用 URI 表达。
  final Uri uri;

  final Map<String, String>? headers;

  final String? title;

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';
}

/// 播放器对外暴露的只读状态快照。
@immutable
class PlayerSnapshot {
  const PlayerSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final String? error;
}

/// 播放器抽象层。
///
/// 三套实现：AVPlayer（video_player 驱动）、MPV（libmpv / media_kit 驱动）与
/// MDK（libmdk / fvp 驱动）。
///
/// ## 能力差异的唯一表达：能力矩阵 + 统一提示
///
/// 用户点名的约束：**每一个可用内核都要有整套控制能力**——控件不随内核变化显隐，
/// 差异只体现在「点下去之后是生效还是提示」。落地方式是三层：
///
/// 1. [capabilities] 声明本内核支持哪些项（拿不到的能力如实标 false）；
/// 2. 每项能力都有对应的内核方法（音轨 / 字幕轨 / 外挂字幕 / 延迟…），
///    不支持的实现**安静地什么都不做**，不抛异常、不假装成功；
/// 3. 页面按 [PlayerCapabilities] 决定「调用」还是「弹
///    [PlayerCapabilities.unsupportedMessage]」，因此从不在 UI 上写
///    `switch (kernel)`。
///
/// 所有方法都给了默认实现（默认 = 不支持），新内核只需覆盖它真能做的部分，
/// 不必为了「接口齐全」写一堆空方法再各自解释。
abstract class AbstractPlayer {
  /// 当前状态。UI 通过 [snapshot] 订阅，无需自行轮询。
  ValueListenable<PlayerSnapshot> get snapshot;

  /// HUD 参数（编码格式 / 码率 / 帧率 / 缓冲状态 / 分辨率）。
  ///
  /// **每个内核自己填**自己拿得到的字段，拿不到的留空；上层只渲染
  /// [PlayerStats.chips]，不认识任何内核私有 API——换内核时 HUD 一行不用改。
  ValueListenable<PlayerStats> get stats;

  /// 内核能力矩阵：只影响「点了之后是生效还是提示」，不影响按钮显隐。
  ///
  /// 默认「什么都不支持」：这样替身与将来的新内核都必须显式声明能力，
  /// 而不是默默继承一个乐观的默认值。
  PlayerCapabilities get capabilities => PlayerCapabilities.none;

  Future<void> load(PlayerMedia media);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> stop();

  /// 设置音量（0.0~1.0）。手势调音量走这里。
  ///
  /// 各内核的实现方式不同（AVPlayer 设 player.volume；MPV 设 libmpv 的 volume
  /// 属性），但口径统一为 0..1 的线性值。内核不支持时安静忽略。
  Future<void> setVolume(double volume);

  /// 应用播放设置（内核自行消费它支持的部分）。
  ///
  /// 约定：设置逐项按内核能力生效，内核不支持的项安静忽略——页面不做
  /// 「某内核不支持某项」的分支；差异由 [capabilities] 表达，并由设置面板据它
  /// 给出「点了提示」还是「真的调下去」。可在加载前后任意时刻调用。
  Future<void> applySettings(PlayerSettings settings);

  /// 应用起播缓冲参数（[BufferingConfig]，来自模块设置里的「前向缓冲」）。
  ///
  /// 与 [applySettings] 分开的理由是**时机**：缓冲属性必须在打开媒体**之前**
  /// 落定（libmpv 是打开文件时读一次；AVPlayer 是建播放器时读一次），因此调用方
  /// 一律在 [load] 之前调用它。内核没有缓冲参数写通道时安静忽略（默认实现）——
  /// 与其余能力同一口径：不假装已生效，也不抛错打断起播。
  Future<void> setBuffering(BufferingConfig config) async {}

  // ------------------------------------------------------------ 音频 / 字幕

  /// 可选的音轨列表（当前选中的那条带 `selected: true`）。
  ///
  /// 拿不到时返回空表——「素材里只有一条音轨」与「内核不支持列轨道」是两回事，
  /// 前者由点击后的提示区分（见页面）。
  Future<List<PlayerTrack>> audioTracks() async => const <PlayerTrack>[];

  /// 切换音轨（[PlayerTrack.id] 原样回传）。
  Future<void> selectAudioTrack(String id) async {}

  /// 可选的字幕轨道列表（含外挂字幕）。
  Future<List<PlayerTrack>> subtitleTracks() async => const <PlayerTrack>[];

  /// 切换字幕轨；[id] 为 null 表示「关闭字幕」。
  Future<void> selectSubtitleTrack(String? id) async {}

  /// 加载外挂字幕文件（本地路径）。
  ///
  /// 成功返回 true；内核没有这条通路时返回 false（页面据此弹统一提示）。
  Future<bool> loadSubtitleFile(String path) async => false;

  /// 音频延迟（正值表示音频延后）。内核没有写通道时安静忽略。
  Future<void> setAudioDelay(Duration delay) async {}

  /// 供 UI 嵌入的渲染面。
  Widget buildView();

  Future<void> dispose();
}
