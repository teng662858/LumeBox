import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'player_settings.dart';

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
/// Phase1 只提供 AVPlayer 实现；MPV / MDK 延后开发，不在本层内集成。
abstract class AbstractPlayer {
  /// 当前状态。UI 通过 [snapshot] 订阅，无需自行轮询。
  ValueListenable<PlayerSnapshot> get snapshot;

  Future<void> load(PlayerMedia media);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> stop();

  /// 应用播放设置（内核自行消费它支持的部分）。
  ///
  /// 约定：设置逐项按内核能力生效，内核不支持的项安静忽略——页面不做
  /// 「某内核不支持某项」的分支；能力差异记录在 Phase3 播放器文档里。
  /// 可在加载前后任意时刻调用：实现方自行缓存未就绪的设置。
  Future<void> applySettings(PlayerSettings settings);

  /// 供 UI 嵌入的渲染面。
  Widget buildView();

  Future<void> dispose();
}
