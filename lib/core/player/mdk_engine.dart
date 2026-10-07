import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fvp/mdk.dart' as mdk;

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'player_capabilities.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// MDK 内核（[libmdk](https://github.com/wang-bin/mdk-sdk)），Flutter 侧由 `fvp` 提供。
///
/// 与另外两套内核的分工：AVPlayer 走系统解码链、MPV 由 media_kit 驱动；
/// MDK 自带 FFmpeg 解封装 + 硬件解码（VideoToolbox）与 Metal 渲染，
/// 因此在**硬解 HEVC / 杜比视界**这类场景上和另外两套是不同的实现路径——
/// 这正是留第三套内核的意义（某台设备上某一个内核放不动时还有别的选择）。
///
/// ## 渲染面由本引擎自己给（[buildView]）
///
/// fvp 的 [mdk.Player] 是「纹理型」的：`updateTexture()` 拿到一个 textureId，
/// 由 Flutter 侧 `Texture` 贴上去。页面只认 [AbstractPlayer.buildView]，
/// 因此这里换纹理、页面一行都不用改（与 AVPlayer / MPV 同一口径）。
///
/// ## 如实声明（不做「假装支持」）
///
/// - **字幕**：MDK 的字幕是**内嵌渲染**的（由 libmdk 画进画面），字号 / 颜色 /
///   描边无法像 MPV 那样由 Flutter 侧的字幕组件接管；延迟通过 libmdk 的
///   `sub-delay` 属性可写，因此**只有延迟这一项真的生效**。
/// - **逐媒体请求头**：走 libmdk 的 `avio.headers` 属性（fvp 自己的
///   video_player 后端就是这么传的：`'Key: Value\r\n'` 形式）。必须在
///   `prepare()` **之前**写进去——fvp 的 `media` 只收一个 URL 字符串，没有
///   headers 参数，属性通道是唯一入口。
/// - **缓冲大小类参数**：libmdk 没有可查证的缓冲大小属性名（`Player.setProperty`
///   的属性表没有权威文档），因此这里**不写猜测的属性名**，只写 fvp 源码里
///   实际在用、语义明确的网络重连两项（`avio.reconnect` /
///   `avio.reconnect_delay_max`）——它们解决的是「起播/播放中连接被掐断后
///   要重新握手」这一类卡顿，与缓冲策略是两回事，如实分开说。
class MdkEngine extends AbstractPlayer {
  MdkEngine._(this._player);

  /// 创建引擎。原生库不可用时抛 [StateError]（由工厂转成可读提示）。
  static MdkEngine create() {
    final player = mdk.Player();
    final engine = MdkEngine._(player);
    engine._attach();
    return engine;
  }

  final mdk.Player _player;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  final ValueNotifier<PlayerStats> _stats =
      ValueNotifier<PlayerStats>(PlayerStats.empty);

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  /// 位置 / 缓冲的刷新节拍。
  ///
  /// fvp 没有「位置变化」事件（`position` 是同步查询），因此这里用轻量轮询；
  /// 400ms 足够让进度条顺滑，又不至于让 UI 每帧都重建。
  Timer? _ticker;

  bool _disposed = false;

  /// 纹理是否已经创建（[buildView] 用它决定贴不贴 `Texture`）。
  int? _textureId;

  /// 最近一次准备的媒体时长（毫秒）。fvp 的 `position` 是 int 毫秒。
  Duration _duration = Duration.zero;

  /// 字幕状态（MDK 只能写延迟，见类文档）。
  bool _subtitlesEnabled = true;
  Duration _subtitleDelay = Duration.zero;

  double _volume = 1.0;
  double _speed = 1.0;

  /// 标记「正在收尾」：dispose 之后不再写 notifier。
  bool get _live => !_disposed;

  void _attach() {
    _subscriptions.add(
      _player.onStateChanged.listen((change) {
        if (!_live) return;
        final playing = change.newValue == mdk.PlaybackState.playing;
        _emit(playing: playing, buffering: change.newValue == mdk.PlaybackState.running);
      }),
    );
    _subscriptions.add(
      _player.onMediaStatus.listen((change) {
        if (!_live) return;
        // MDK 的媒体状态是**位标记**（用 test() 判位，不是等值比较）。
        // 缓冲中 → 页面转圈；缓冲完成 → 收起转圈。
        if (change.newValue.test(mdk.MediaStatus.buffering)) {
          _emit(buffering: true);
        } else if (change.newValue.test(mdk.MediaStatus.buffered)) {
          _emit(buffering: false);
        }
      }),
    );
    _subscriptions.add(
      _player.onEvent.listen((event) {
        if (!_live) return;
        // MDK 的事件里既有真错误（解码 / 网络），也有可恢复的告警；
        // 只在非 0 错误码时把它当错误报给页面，其余写日志留痕。
        if (event.error != 0) {
          LumeLog.warn('[mdk] 事件（${event.category}）: ${event.detail}');
          _emit(error: '${event.category}: ${event.detail}');
        }
      }),
    );
  }

  void _emit({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    String? error,
    bool clearError = false,
  }) {
    if (!_live) return;
    final current = _snapshot.value;
    _snapshot.value = PlayerSnapshot(
      position: position ?? current.position,
      duration: duration ?? current.duration,
      playing: playing ?? current.playing,
      buffering: buffering ?? current.buffering,
      error: clearError ? null : (error ?? current.error),
    );
  }

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  /// 能力矩阵：见 [PlayerCapabilities.of] 的唯一声明处（MDK 那一栏）。
  @override
  PlayerCapabilities get capabilities => PlayerCapabilities.of(PlayerKernel.mdk);

  /// 可选音轨：列表来自 libmdk 的媒体信息，选中项从当前激活轨道反查。
  @override
  Future<List<PlayerTrack>> audioTracks() async {
    if (!_live) return const <PlayerTrack>[];
    final streams = _player.mediaInfo.audio ?? const <mdk.AudioStreamInfo>[];
    final active = _player.activeAudioTracks;
    return <PlayerTrack>[
      for (final stream in streams)
        PlayerTrack(
          id: '${stream.index}',
          label: _trackLabel(stream, '音轨', streams.indexOf(stream)),
          language: _metadata(stream.metadata, 'language'),
          // MDK 的隐式约定：空列表 = 自动（第一条），因此「没有显式选择」时
          // 第一条算选中——与播放器实际行为一致。
          selected: active.isEmpty
              ? stream.index == streams.first.index
              : active.contains(stream.index),
        ),
    ];
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    if (!_live) return;
    final index = int.tryParse(id);
    if (index == null) return;
    try {
      _player.activeAudioTracks = <int>[index];
    } catch (error) {
      LumeLog.warn('[mdk] 切音轨失败（$id）：$error');
    }
  }

  /// 可选字幕轨（含用 [loadSubtitleFile] 加进来的外挂轨）。
  @override
  Future<List<PlayerTrack>> subtitleTracks() async {
    if (!_live) return const <PlayerTrack>[];
    final streams =
        _player.mediaInfo.subtitle ?? const <mdk.SubtitleStreamInfo>[];
    final active = _player.activeSubtitleTracks;
    return <PlayerTrack>[
      for (final stream in streams)
        PlayerTrack(
          id: '${stream.index}',
          label: _trackLabel(stream, '字幕', streams.indexOf(stream)),
          language: _metadata(stream.metadata, 'language'),
          selected: active.isEmpty
              ? stream.index == streams.first.index
              : active.contains(stream.index),
        ),
    ];
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    if (!_live) return;
    try {
      if (id == null) {
        // 空列表 = 不选任何字幕轨（关闭字幕）。
        _player.activeSubtitleTracks = const <int>[];
        return;
      }
      final index = int.tryParse(id);
      if (index == null) return;
      _player.activeSubtitleTracks = <int>[index];
    } catch (error) {
      LumeLog.warn('[mdk] 切字幕轨失败（$id）：$error');
    }
  }

  /// 外挂字幕：fvp 的 `setMedia(uri, MediaType.subtitle)` 支持本地字幕文件。
  @override
  Future<bool> loadSubtitleFile(String path) async {
    if (!_live) return false;
    try {
      final uri = path.startsWith('file:') ? path : Uri.file(path).toString();
      _player.setMedia(uri, mdk.MediaType.subtitle);
      LumeLog.info('[mdk] 已加载外挂字幕：$path');
      return true;
    } catch (error) {
      LumeLog.warn('[mdk] 加载外挂字幕失败：$error');
      return false;
    }
  }

  /// 轨道展示名：元数据标题 → 语言 → 「音轨 1」兜底。
  static String _trackLabel(Object stream, String prefix, int index) {
    final metadata = switch (stream) {
      final mdk.AudioStreamInfo info => info.metadata,
      final mdk.SubtitleStreamInfo info => info.metadata,
      _ => const <String, String>{},
    };
    final title = metadata['title']?.trim();
    if (title != null && title.isNotEmpty) return title;
    final language = _metadata(metadata, 'language');
    if (language != null && language.isNotEmpty && language != 'und') {
      return '$prefix ${language.toUpperCase()}';
    }
    return '$prefix ${index + 1}';
  }

  static String? _metadata(Map<String, String> metadata, String key) {
    for (final entry in metadata.entries) {
      if (entry.key.toLowerCase() == key) {
        final value = entry.value.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  @override
  Future<void> load(PlayerMedia media) async {
    if (!_live) return;
    _emit(error: null, clearError: true);
    _applyNetworkProperties();
    _applyHeaders(media.headers);
    _player.media = media.uri.toString();
    // fvp 要求显式 prepare 才会真正起播（内部会等首个媒体信息到达）。
    await _player.prepare();
    _duration = Duration(milliseconds: _player.mediaInfo.duration);
    _emit(duration: _duration, position: Duration.zero);
    _applySubtitleState();
    _applyRate();
    _applyVolume();
    _startTicker();
  }

  /// 逐媒体请求头（防盗链用的 Referer / UA）→ libmdk 的 `avio.headers`。
  ///
  /// 格式按 fvp 自己的做法：每行 `'Key: Value\r\n'`。没有请求头时**清空**该属性
  /// （否则上一集带的头会跟到下一集，那是另一种「串味」的 403）。
  void _applyHeaders(Map<String, String>? headers) {
    final header = headers == null || headers.isEmpty ? '' : headersText(headers);
    try {
      _player.setProperty('avio.headers', header);
      if (header.isNotEmpty) {
        LumeLog.info('[mdk] 已透传请求头（${headers!.keys.join(', ')}）');
      }
    } catch (error) {
      // 写不进去时如实记一条：地址要 Referer 的话会 403，用户据此换内核。
      LumeLog.warn('[mdk] 写请求头失败（防盗链地址可能 403）：$error');
    }
  }

  /// 逐媒体请求头 → `avio.headers` 的字符串形式。
  ///
  /// 提出来单独做（而不是内联在 [_applyHeaders] 里）是为了**可测**：
  /// 这一段是纯字符串拼装，单测在本机就能钉住格式（真机只需验证 libmdk 收不收）。
  @visibleForTesting
  static String headersText(Map<String, String> headers) {
    final buffer = StringBuffer();
    headers.forEach((key, value) {
      buffer.write('$key: $value\r\n');
    });
    return buffer.toString();
  }

  /// 网络重连属性：连接被掐断时自动重连，避免「起播卡住 / 播一半停住」。
  ///
  /// 属性名取自 fvp 自身的 video_player 后端（`avio.reconnect` /
  /// `avio.reconnect_delay_max`），不是猜的；写失败只记日志。
  void _applyNetworkProperties() {
    if (_networkPropertiesApplied) return;
    _networkPropertiesApplied = true;
    for (final entry in _networkProperties.entries) {
      try {
        _player.setProperty(entry.key, entry.value);
      } catch (error) {
        LumeLog.warn('[mdk] 写 ${entry.key} 失败：$error');
      }
    }
  }

  bool _networkPropertiesApplied = false;

  static const Map<String, String> _networkProperties = <String, String>{
    'avio.reconnect': '1',
    'avio.reconnect_delay_max': '7',
  };

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!_live) return;
      final ms = _player.position;
      final duration = _player.mediaInfo.duration;
      _emit(
        position: Duration(milliseconds: ms < 0 ? 0 : ms),
        duration: duration > 0 ? Duration(milliseconds: duration) : _duration,
      );
    });
  }

  @override
  Future<void> play() async {
    if (!_live) return;
    _player.state = mdk.PlaybackState.playing;
    _emit(playing: true);
  }

  @override
  Future<void> pause() async {
    if (!_live) return;
    _player.state = mdk.PlaybackState.paused;
    _emit(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_live) return;
    await _player.seek(position: position.inMilliseconds);
    _emit(position: position);
  }

  @override
  Future<void> stop() async {
    if (!_live) return;
    // 与 AVPlayer / MPV 同口径：回到起点并暂停，不卸载媒体。
    _player.state = mdk.PlaybackState.paused;
    await _player.seek(position: 0);
    _emit(position: Duration.zero, playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (!_live) return;
    _applyVolume();
  }

  void _applyVolume() {
    // 全静音走 mute：某些设备上 volume=0 仍会有极小底噪。
    _player.mute = _volume <= 0.001;
    _player.volume = _volume;
  }

  void _applyRate() {
    if (!_live) return;
    _player.playbackRate = _speed;
  }

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    _speed = settings.speed;
    _subtitlesEnabled = settings.subtitlesEnabled;
    _subtitleDelay = settings.subtitleDelay;
    if (!_live) return;
    _applyRate();
    _applySubtitleState();
  }

  /// 字幕状态：**只有延迟与开关真的生效**（见类文档）。
  ///
  /// - 开关走 fvp 的字幕轨切换（`setActiveTracks`）；
  /// - 延迟写 libmdk 的 `sub-delay` 属性（毫秒）；
  /// - 字号 / 颜色 / 描边在 MDK 上是内嵌渲染的，这里**如实记一条日志**，
  ///   不假装支持。
  void _applySubtitleState() {
    if (!_live) return;
    try {
      _player.setProperty('sub-delay', '${_subtitleDelay.inMilliseconds}');
    } catch (error) {
      LumeLog.warn('[mdk] 写字幕延迟失败：$error');
    }
    try {
      // 空列表 = 不选任何字幕轨；[-1] = 交给内核自动选（MDK 的默认行为）。
      _player.activeSubtitleTracks = _subtitlesEnabled
          ? const <int>[-1]
          : const <int>[];
    } catch (error) {
      LumeLog.warn('[mdk] 切字幕轨失败：$error');
    }
  }

  @override
  Widget buildView() {
    // 纹理在媒体加载完成时才创建（fvp 的约定：mediaInfo.video 非空才建纹理），
    // 因此这里既要监听 textureId，也要在拿到尺寸后告诉原生侧渲染面大小——
    // 不然画面不会初始化。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.round()
            : 0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight.round()
            : 0;
        _ensureTexture(width, height);
        return ValueListenableBuilder<int?>(
          valueListenable: _player.textureId,
          builder: (context, id, _) {
            if (id == null) return const SizedBox.expand();
            return Texture(textureId: id);
          },
        );
      },
    );
  }

  /// 建纹理 / 跟随尺寸变化更新渲染面。
  Future<void> _ensureTexture(int width, int height) async {
    if (!_live || width <= 0 || height <= 0) return;
    try {
      if (_textureId == null) {
        final id = await _player.updateTexture(width: width, height: height);
        if (id >= 0) _textureId = id;
        return;
      }
      _player.setVideoSurfaceSize(width, height);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[mdk] 创建/更新渲染纹理失败：$error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _player.dispose();
    _snapshot.dispose();
    _stats.dispose();
  }
}
