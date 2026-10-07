import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../util/lume_log.dart';
import 'buffering.dart';
import 'mpv_engine.dart';
import 'player_capabilities.dart';

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
///
/// ## 属性写通道（[EnginePropertyCapable]）
///
/// libmpv 的 `cache` / `hwdec` / `sub-delay` 这类能力只有属性通道。media_kit
/// 的高层 API 不开放它，但它的 `NativePlayer` 把 **FFI 绑定实例（`mpv`）与 mpv
/// 句柄（`ctx`）做成了公开字段**，libmpv 的客户端 API 又是线程安全的，
/// 因此这一层可以直接调用 `mpv_set_property_string`——不 fork、不反射、不猜。
class MediaKitMpvEngine
    implements MpvEngine, FrameTickCapable, EnginePropertyCapable, TrackCapable {
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
      // 缓冲属性要在起播**之前**写进去（cache / 预读时长在打开媒体时读一次）。
      await _applyBufferingProperties();
      await _player.open(
        Media(request.url, httpHeaders: request.headers),
        play: request.autoplay,
      );
      if (request.speed != 1.0) await _player.setRate(request.speed);
      final startAt = request.startAt;
      if (startAt != null && startAt > Duration.zero) {
        await _player.seek(startAt);
      }
      // 字幕状态也要在起播后补挂一次（媒体换了，轨道与延迟都得重设）。
      await _applySubtitleState();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _fail('打开失败：$error');
    }
  }

  /// 写一批 libmpv 属性，返回**被内核接受**的属性个数（映射与计数口径见
  /// [writeEngineProperties]）。
  Future<int> _setProperties(Map<String, String> properties) =>
      writeEngineProperties(this, properties);

  /// 起播缓冲参数（见 [BufferingConfig]）。
  ///
  /// 写入的几项都是 libmpv 的**公开属性**（`MpvProperties.buffering` 定死名字与
  /// 单位）：`cache`（网络流缓存开关）、`cache-pause-initial`（不等缓存填满就起播）、
  /// `demuxer-readahead-secs` 与两个缓存上限（先攒多少数据）。
  /// 写不进去只记日志，不影响播放。
  Future<void> _applyBufferingProperties() async {
    final properties = MpvProperties.buffering(_bufferingConfig);
    final accepted = await _setProperties(properties);
    LumeLog.info('[mpv] 缓冲参数已写入 $accepted/${properties.length} 项');
  }

  /// 起播缓冲参数（由上层 [setBuffering] 写入；`open()` 时统一应用）。
  ///
  /// 命名带 Config 后缀：本类已有一个 `_buffering` 是**播放状态**（是否正在缓冲），
  /// 两者含义完全不同，不能同名。
  BufferingConfig _bufferingConfig = BufferingConfig.defaults;

  @override
  Future<void> setBuffering(BufferingConfig config) async {
    if (_disposed) return;
    final changed = config != _bufferingConfig;
    _bufferingConfig = config;
    // 没变就不重复写：`open()` 之前还会统一应用一次，值相同的那次是多余的。
    if (!changed) return;
    // 已经打开媒体时也写一遍：这几项属性在播放中改对**下一个**文件生效，
    // 因此不会打断正在播的画面（下一集 / 下次起播就会用上新值）。
    await _applyBufferingProperties();
  }

  /// 引擎属性写通道（libmpv 的 `mpv_set_property_string`）。
  ///
  /// 通道来源：media_kit 的 `NativePlayer` **公开**暴露了 FFI 绑定实例
  /// （`mpv`）与 mpv 句柄（`ctx`）两个字段，libmpv 的客户端 API 又是线程安全的，
  /// 因此这里可以直接写属性——不需要 fork，也不需要反射猜测。
  ///
  /// 返回值语义：true = libmpv 接受了这次写入（`MPV_ERROR_SUCCESS`）；
  /// false = 通道不可用（非原生内核 / 未初始化 / 已释放）或属性不被接受。
  @override
  Future<bool> setEngineProperty(String name, String value) async {
    if (_disposed) return false;
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      LumeLog.warn('[mpv] 当前平台后端不是原生播放器，属性 $name 写不进去');
      return false;
    }
    try {
      // 句柄在初始化完成后才有值；同一次等待里把「未初始化」也挡掉。
      await platform.waitForPlayerInitialization;
    } catch (error) {
      LumeLog.warn('[mpv] 播放器未就绪，属性 $name 写不进去：$error');
      return false;
    }
    if (_disposed) return false;
    final ctx = platform.ctx;
    if (ctx == nullptr) {
      LumeLog.warn('[mpv] mpv 句柄不可用，属性 $name 写不进去');
      return false;
    }

    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      final code = platform.mpv.mpv_set_property_string(
        ctx,
        namePtr.cast<Int8>(),
        valuePtr.cast<Int8>(),
      );
      if (code < 0) {
        LumeLog.warn('[mpv] 属性 $name=$value 未被内核接受（错误码 $code）');
        return false;
      }
      return true;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[mpv] 写属性 $name 失败：$error');
      return false;
    } finally {
      malloc.free(namePtr);
      malloc.free(valuePtr);
    }
  }

  /// 硬件解码开关的最近一次写入值；null = 还没写过。
  ///
  /// 保留它是为了「值没变就不重复写属性」——hwdec 是解码链初始化期属性，
  /// 每次设置变更都重写一遍可能让 libmpv 重载当前文件的解码链。
  bool? _hardwareDecoding;

  /// 字幕延迟（由上层 [setSubtitleDelay] 写入；每次打开媒体补挂一次）。
  Duration _subtitleDelay = Duration.zero;

  /// 字幕开关（由上层 [setSubtitleEnabled] 写入，open 时应用）。
  bool _subtitlesEnabled = true;

  /// 字幕样式（由上层 [setSubtitleStyle] 写入，渲染面消费）。
  SubtitleStyle _subtitleStyle = SubtitleStyle.defaults;

  @override
  Future<void> setHardwareDecoding(bool enabled) async {
    if (_disposed) return;
    if (_hardwareDecoding == enabled) return;
    _hardwareDecoding = enabled;
    // hwdec 是 libmpv 的**解码链初始化期**属性：这里写进去，对随后打开的媒体生效
    // （正在播的这一集要等切集后才换解码链——libmpv 的既有口径，不是本层的取舍）。
    final accepted = await _setProperties(MpvProperties.hardwareDecoding(enabled));
    if (accepted == 0) {
      LumeLog.warn('[mpv] 硬解开关（${enabled ? '开' : '关'}）未能写入内核');
    }
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    if (_disposed) return;
    _subtitleDelay = delay;
    await _writeSubtitleDelay(delay);
  }

  // ------------------------------------------------------------ 轨道读写

  /// 可选音轨（media_kit 的轨道列表里已经带标题 / 语言 / 默认标记）。
  @override
  Future<List<PlayerTrack>> audioTracks() async {
    if (_disposed) return const <PlayerTrack>[];
    final selected = _player.state.track.audio.id;
    final tracks = _player.state.tracks.audio;
    return <PlayerTrack>[
      for (var index = 0; index < tracks.length; index++)
        PlayerTrack(
          id: tracks[index].id,
          label: _trackLabel(tracks[index].title, tracks[index].language,
              tracks[index].codec, '音轨', index),
          language: tracks[index].language,
          selected: tracks[index].id == selected,
        ),
    ];
  }

  /// 可选字幕轨（含外挂字幕：媒体里加载过的外挂轨也会出现在这里）。
  @override
  Future<List<PlayerTrack>> subtitleTracks() async {
    if (_disposed) return const <PlayerTrack>[];
    final selected = _player.state.track.subtitle.id;
    final tracks = _player.state.tracks.subtitle;
    return <PlayerTrack>[
      for (var index = 0; index < tracks.length; index++)
        PlayerTrack(
          id: tracks[index].id,
          label: _trackLabel(tracks[index].title, tracks[index].language,
              tracks[index].codec, '字幕', index),
          language: tracks[index].language,
          selected: tracks[index].id == selected,
        ),
    ];
  }

  /// 轨道展示名：内核给了标题就用标题，否则语言，再否则「音轨 1」这类兜底。
  static String _trackLabel(
    String? title,
    String? language,
    String? codec,
    String prefix,
    int index,
  ) {
    final name = title?.trim();
    if (name != null && name.isNotEmpty) return name;
    final lang = language?.trim();
    if (lang != null && lang.isNotEmpty && lang != 'und') return '$prefix ${lang.toUpperCase()}';
    final code = codec?.trim();
    if (code != null && code.isNotEmpty) return '$prefix ${code.toUpperCase()}';
    return '$prefix ${index + 1}';
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    if (_disposed) return;
    try {
      await _player.setAudioTrack(AudioTrack(id, null, null));
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[mpv] 切音轨失败（$id）：$error');
    }
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    if (_disposed) return;
    try {
      await _player.setSubtitleTrack(
        id == null ? SubtitleTrack.no() : SubtitleTrack(id, null, null),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[mpv] 切字幕轨失败（$id）：$error');
    }
  }

  /// 外挂字幕：media_kit 的 `SubtitleTrack.uri` 支持本地文件（SRT / ASS / VTT）。
  @override
  Future<bool> loadSubtitleFile(String path) async {
    if (_disposed) return false;
    try {
      final uri = path.startsWith('file:') ? path : Uri.file(path).toString();
      await _player.setSubtitleTrack(SubtitleTrack.uri(uri));
      LumeLog.info('[mpv] 已加载外挂字幕：$path');
      return true;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[mpv] 加载外挂字幕失败：$error');
      return false;
    }
  }

  /// 音频延迟（libmpv 的 `audio-delay`，单位秒）。
  @override
  Future<void> setAudioDelay(Duration delay) async {
    if (_disposed) return;
    if (_audioDelay == delay) return;
    _audioDelay = delay;
    final accepted = await _setProperties(MpvProperties.audioDelay(delay));
    if (accepted == 0) {
      LumeLog.warn('[mpv] 音频延迟（${delay.inMilliseconds}ms）未能写入内核');
    }
  }

  /// 音频延迟的最近一次写入值（null = 还没写过）。
  Duration? _audioDelay;

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    if (_disposed) return;
    _subtitleStyle = style;
    // 样式由 buildView 的 SubtitleViewConfiguration 消费；这里换掉值并让
    // 渲染面重建（_styleRevision 变化触发上层 rebuild）。
    _styleRevision.value++;
  }

  /// 字幕样式版本：变化即通知渲染面重建（`Video` 是 const 构造，靠 key 换新）。
  final ValueNotifier<int> _styleRevision = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get subtitleStyleRevision => _styleRevision;

  /// 起播后补挂字幕状态（开关 + 延迟）。
  ///
  /// 延迟每换一次媒体都要补挂：`sub-delay` 是**每个文件**的播放属性，换集之后
  /// 不重写就回到 0（用户会以为「延迟设置丢了」）。
  Future<void> _applySubtitleState() async {
    await setSubtitleEnabled(_subtitlesEnabled);
    await _writeSubtitleDelay(_subtitleDelay);
  }

  /// 写 libmpv 的 `sub-delay`（单位**秒**，可负；见 [MpvProperties.subtitleDelay]）。
  Future<void> _writeSubtitleDelay(Duration delay) async {
    final accepted = await _setProperties(MpvProperties.subtitleDelay(delay));
    if (accepted == 0) {
      LumeLog.warn('[mpv] 字幕延迟（${delay.inMilliseconds}ms）未能写入内核');
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
    _subtitlesEnabled = enabled;
    try {
      await _player.setSubtitleTrack(
        enabled ? SubtitleTrack.auto() : SubtitleTrack.no(),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Widget buildView() => ValueListenableBuilder<int>(
        valueListenable: _styleRevision,
        builder: (context, revision, _) => Video(
          key: ValueKey<int>(revision),
          controller: _video,
          // 控制栏由上层画：内核不自带 UI（换内核上层零改动的前提）。
          controls: NoVideoControls,
          fit: BoxFit.contain,
          fill: Colors.black,
          wakelock: true,
          // 字幕样式：media_kit 的字幕层是 Flutter Widget，收一个完整 TextStyle，
          // 因此字号 / 颜色 / 描边都真实生效（描边用多层阴影模拟）。
          subtitleViewConfiguration: _subtitleConfiguration(),
        ),
      );

  /// 把 [SubtitleStyle] 翻成 media_kit 的字幕样式。
  ///
  /// 描边实现：Flutter 的 TextStyle 没有 stroke，用四向阴影模拟——
  /// 这是 Flutter 生态里的通行做法，效果与描边一致（压在亮画面上也能读）。
  SubtitleViewConfiguration _subtitleConfiguration() {
    final style = _subtitleStyle;
    final base = 32.0 * style.fontScale;
    final outline = style.outlineWidth;
    // 底色：把「不透明度」翻成 ARGB 的 alpha 通道（0 = 完全透明，不画底色）。
    final backgroundAlpha =
        (style.backgroundOpacity.clamp(0.0, 1.0) * 255).round();
    return SubtitleViewConfiguration(
      visible: _subtitlesEnabled,
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        height: 1.4,
        fontSize: base,
        letterSpacing: 0.0,
        wordSpacing: 0.0,
        color: Color(style.colorArgb),
        fontWeight: FontWeight.w600,
        backgroundColor: Color(backgroundAlpha << 24),
        shadows: outline <= 0
            ? const <Shadow>[]
            : <Shadow>[
                Shadow(
                  color: const Color(0xFF000000),
                  offset: Offset(-outline, 0),
                ),
                Shadow(
                  color: const Color(0xFF000000),
                  offset: Offset(outline, 0),
                ),
                Shadow(
                  color: const Color(0xFF000000),
                  offset: Offset(0, -outline),
                ),
                Shadow(
                  color: const Color(0xFF000000),
                  offset: Offset(0, outline),
                ),
              ],
      ),
    );
  }

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
