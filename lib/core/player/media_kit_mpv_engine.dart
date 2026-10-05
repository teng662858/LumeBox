import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../util/lume_log.dart';
import 'mpv_engine.dart';

/// [MpvEngine] 的真实实现：media_kit（其内核即 **libmpv**）。
///
/// 从这里往下的东西上层一概不感知：
/// - 渲染：`media_kit_video` 的 `Video` 部件（iOS 走 libmpv 渲染 API + Flutter
///   纹理），并显式关掉它自带的控制栏（`NoVideoControls`）——控制栏归上层；
/// - 状态：订阅 media_kit 的流（位置 / 时长 / 播放 / 缓冲 / 轨道 / 视频参数）
///   拼装成 [MpvEngineSnapshot]；
/// - HUD 原始字段全部来自 libmpv 的轨道与视频参数：
///   `codec`（编码）、`demux-bitrate`（码率，mpv 单位是 bps，这里换算成 kbps）、
///   `demux-fps`（帧率）、`video-params.w/h`（分辨率）、缓冲来自 `buffer` 流。
///
/// 上层不接触任何 mpv 私有属性：需要新参数时在**这一层**取，扩展
/// [MpvEngineSnapshot] 与 [PlayerStats] 即可。
class MediaKitMpvEngine implements MpvEngine, FrameTickCapable {
  /// 私有构造：只接受**已经**建好的 Player。
  ///
  /// 外部只能走 [create]——它保证 media_kit 先初始化、再碰任何 media_kit API。
  MediaKitMpvEngine._(this._player) {
    _video = VideoController(_player);
    _subscribe();
  }

  /// 帧节拍：`time-pos` 每次**最多**更新一帧，因此位置变化就是「新的一帧到了」。
  ///
  /// 为什么不用定时器：定时器在暂停时照样空转取帧（白白拷贝整帧），播放时又可能
  /// 与真实帧错开（同一帧取两次、或跳过一帧）。用位置流当节拍，取帧时刻自然
  /// 跟着画面走——暂停即停，播放时与帧对齐。
  ///
  /// 位置流比目标帧率更密（60fps 视频就是每秒 60 次），但下游
  /// [PipFrameSource] 已有帧率节流，这里不必重复限流。
  @override
  Stream<void> get frameTicks => _player.stream.position.map((_) {});

  /// 创建引擎：**MPV 初始化的第一步就是 media_kit 初始化**。
  ///
  /// 顺序是硬性的：media_kit 的 `Player` / `VideoController` 在未初始化时直接抛
  /// 「MediaKit.ensureInitialized must be called before using any API from
  /// package:media_kit.」（真机实测到的就是这个异常，栈顶在 
  /// `NativeLibrary.path` ← `new NativePlayer`）。因此这里在任何 media_kit API
  /// 之前先初始化（装载 libmpv 原生库），再建 Player 与视频控制器。
  ///
  /// `ensureInitialized` 在 media_kit 1.2.6 是**同步幂等** API（装载原生库），
  /// 因此无需 await；它本身抛错时由启动器按初始化失败处理（超时/异常一律
  /// 丢弃实例并回退 AVPlayer）。
  static MediaKitMpvEngine create({String? title}) {
    // 第一步：初始化 media_kit（幂等）。
    MediaKit.ensureInitialized();
    // 第二步：初始化完成之后才允许创建 Player。
    final player = Player(
      configuration: PlayerConfiguration(
        title: title ?? 'Lume Box',
        // 日志交给宿主日志层：media_kit 自己的控制台输出关掉。
        logLevel: MPVLogLevel.error,
      ),
    );
    return MediaKitMpvEngine._(player);
  }

  final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  void Function(MpvEngineSnapshot snapshot)? _onSnapshot;
  bool _disposed = false;

  /// 最近一次已知状态：media_kit 的流是分片的，这里拼装成完整快照。
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _buffered;
  bool _playing = false;
  bool _buffering = false;
  String? _videoCodec;
  String? _audioCodec;
  double? _videoBitrateKbps;
  double? _audioBitrateKbps;
  double? _fps;
  int? _width;
  int? _height;
  String? _error;

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {
    _onSnapshot = onSnapshot;
    _emit();
  }

  @override
  Future<void> open(MpvMediaRequest request) async {
    if (_disposed) return;
    _resetMediaState();
    try {
      await _player.open(
        Media(request.url, httpHeaders: request.headers),
        play: request.autoplay,
      );
      if (request.speed != 1.0) await _player.setRate(request.speed);
      final startAt = request.startAt;
      if (startAt != null && startAt > Duration.zero) {
        await _player.seek(startAt);
      }
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _fail('打开失败：$error');
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _player.seek(position);
  }

  /// 与 AVPlayer 内核同口径：回到起点并暂停，不卸载媒体。
  ///
  /// （libmpv 的 `stop` 会清空播放列表，那会让随后的 play 无片可播，
  /// 与上层「停止 = 回到起点」的语义不符，因此这里用 seek(0) + pause。）
  @override
  Future<void> stop() async {
    if (_disposed) return;
    await _player.pause();
    await _player.seek(Duration.zero);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_disposed) return;
    try {
      await _player.setRate(speed);
    } catch (error, stackTrace) {
      // 倍速失败不影响播放主链路（与 AVPlayer 内核同口径）。
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    try {
      // media_kit 的音量是 0~100；上层口径是 0~1，在这里换算。
      await _player.setVolume((volume.clamp(0.0, 1.0)) * 100);
    } catch (error, stackTrace) {
      // 音量失败不影响播放主链路（与倍速同口径）。
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<MpvVideoFrame?> captureFrame() async {
    if (_disposed) return null;
    try {
      // format: null → mpv 的 screenshot-raw，返回 BGRA 原始像素（不是编码图片）。
      // 与「截屏存图」是同一个 mpv 命令，但这里只为取帧转发给画中画。
      final raw = await _player.screenshot(format: null);
      if (raw == null || raw.isEmpty) return null;

      final params = _player.state.videoParams;
      final width = params.dw ?? 0;
      final height = params.dh ?? 0;
      if (width <= 0 || height <= 0) return null;

      // mpv 的 screenshot-raw 输出是紧密排列的 BGRA（无行距填充）；
      // 若原生库将来改成带 stride，这里会通过字节数校验暴露出来。
      final expected = width * height * 4;
      if (raw.length < expected) {
        LumeLog.warn(
          '[mpv] 帧尺寸不符（${raw.length} < $expected），跳过本帧',
        );
        return null;
      }
      return MpvVideoFrame(
        pixels: raw.length == expected ? raw : Uint8List.sublistView(raw, 0, expected),
        width: width,
        height: height,
        stride: width * 4,
      );
    } catch (error, stackTrace) {
      // 取帧失败不影响播放（画中画是增强功能）。
      LumeLog.warn('[mpv] 取帧失败: $error');
      LumeLog.error(error, stackTrace);
      return null;
    }
  }

  @override
  Future<void> setSubtitleEnabled(bool enabled) async {
    if (_disposed) return;
    try {
      await _player.setSubtitleTrack(
        enabled ? SubtitleTrack.auto() : SubtitleTrack.no(),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Widget buildView() => Video(
        controller: _video,
        // 控制栏由上层画：内核不自带 UI（换内核上层零改动的前提）。
        controls: NoVideoControls,
        fit: BoxFit.contain,
        fill: Colors.black,
        wakelock: true,
      );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
    _subscriptions.clear();
    _onSnapshot = null;
    try {
      // media_kit_video 的平台控制器由这里显式释放；它可能还没建好，
      // 因此等一下就绪、超时就跳过（下面释放 Player 也会收回视频输出）。
      final controller = await _video.platform.future
          .timeout(const Duration(seconds: 1));
      controller.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    try {
      await _player.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  // ------------------------------------------------------------------ 内部

  void _subscribe() {
    final streams = _player.stream;
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      streams.position.listen((value) {
        _position = value;
        _emit();
      }),
      streams.duration.listen((value) {
        _duration = value;
        _emit();
      }),
      streams.playing.listen((value) {
        _playing = value;
        _emit();
      }),
      streams.buffering.listen((value) {
        _buffering = value;
        _emit();
      }),
      streams.buffer.listen((value) {
        _buffered = value;
        _emit();
      }),
      streams.videoParams.listen((value) {
        _width = value.w;
        _height = value.h;
        _emit();
      }),
      streams.tracks.listen(_applyTracks),
      streams.error.listen((value) {
        _fail(value);
      }),
    ]);
  }

  /// HUD 参数来自 libmpv 的轨道列表：编码 / 帧率 / 码率（bps → kbps）。
  void _applyTracks(Tracks tracks) {
    final video = tracks.video.isEmpty ? null : tracks.video.first;
    final audio = tracks.audio.isEmpty ? null : tracks.audio.first;
    _videoCodec = video?.codec;
    _audioCodec = audio?.codec;
    _fps = video?.fps;
    _videoBitrateKbps = toKbps(video?.bitrate);
    _audioBitrateKbps = toKbps(audio?.bitrate);
    // 分辨率以 videoParams 为准；它还没到时报轨道的 demux 值兜底。
    if (_width == null || _width == 0) _width = video?.w;
    if (_height == null || _height == 0) _height = video?.h;
    _emit();
  }

  /// mpv 的 `demux-bitrate` 单位是 bps；HUD 统一用 kbps。
  ///
  /// 公开给测试用：这是内核与外层之间唯一的单位约定，写错了 HUD 会整片失真。
  @visibleForTesting
  static double? toKbps(int? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return null;
    return bitsPerSecond / 1000;
  }

  void _resetMediaState() {
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = null;
    _playing = false;
    _buffering = false;
    _videoCodec = null;
    _audioCodec = null;
    _videoBitrateKbps = null;
    _audioBitrateKbps = null;
    _fps = null;
    _width = null;
    _height = null;
    _error = null;
    _emit();
  }

  void _fail(String message) {
    _error = message;
    LumeLog.warn('[mpv] $message');
    _emit();
  }

  void _emit() {
    final listener = _onSnapshot;
    if (listener == null || _disposed) return;
    listener(
      MpvEngineSnapshot(
        position: _position,
        duration: _duration,
        buffered: _buffered,
        playing: _playing,
        buffering: _buffering,
        videoCodec: _videoCodec,
        audioCodec: _audioCodec,
        videoBitrateKbps: _videoBitrateKbps,
        audioBitrateKbps: _audioBitrateKbps,
        fps: _fps,
        width: _width,
        height: _height,
        error: _error,
      ),
    );
  }
}
