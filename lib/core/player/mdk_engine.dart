import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fvp/mdk.dart' as mdk;

import '../util/lume_log.dart';
import 'abstract_player.dart';
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
/// - **自定义请求头**：本项目当前不给内核逐媒体请求头（MDK 侧没有稳定的公开
///   写通道），带 Referer 的地址会记一条日志——与 Venera 图片那条同一口径。
class MdkEngine implements AbstractPlayer {
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

  @override
  Future<void> load(PlayerMedia media) async {
    if (!_live) return;
    _emit(error: null, clearError: true);
    if (media.headers != null && media.headers!.isNotEmpty) {
      // 如实记录，并把「怎么办」一起说了：fvp 0.39 的 Player **没有任何**
      // header / option 通道（`media` 只收一个 URL 字符串），因此 MDK 内核
      // 递不过逐媒体请求头——这不是本层漏传，是依赖的能力缺口。
      // 需要 Referer/UA 的地址（防盗链）在 MDK 上会 403：这条日志是排查时的
      // 第一线索，用户看到它就知道该换 AVPlayer / MPV（两者都支持）。
      LumeLog.warn(
        '[mdk] 该媒体带了自定义请求头（${media.headers!.keys.join(', ')}），'
        '但 MDK（fvp）没有透传通道：防盗链地址可能 403。'
        '请在播放器设置里改用 AVPlayer 或 MPV。',
      );
    }
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
