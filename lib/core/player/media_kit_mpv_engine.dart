import 'playback_presentation.dart';

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../util/lume_log.dart';
import 'buffering.dart';
import 'highest_hls.dart';
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
    implements
        FastSeekEngine,
        MpvEngine,
        EnginePropertyCapable,
        TrackCapable,
        PresentationEngine {
  /// 私有构造：只接受**已经**建好的 Player。
  ///
  /// 外部只能走 [create]——它保证 media_kit 先初始化、再碰任何 media_kit API。
  MediaKitMpvEngine._(this._player, {bool emulatorSurfacePreview = false})
    : _emulatorSurfacePreview = emulatorSurfacePreview {
    _video = VideoController(
      _player,
      configuration: emulatorSurfacePreview
          ? const VideoControllerConfiguration(
              vo: 'mediacodec_embed',
              hwdec: 'mediacodec',
            )
          : const VideoControllerConfiguration(),
    );
    _subscribe();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sampleDownloadSpeed();
      unawaited(_readPresentationStatus());
    });
  }

  // Position reports are not decode-frame callbacks. PiP must use its bounded
  // capture timer rather than a low-frequency progress stream.

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
  static MediaKitMpvEngine create({
    String? title,
    bool emulatorSurfacePreview = false,
  }) {
    // 第一步：初始化 media_kit（幂等）。
    MediaKit.ensureInitialized();
    // 第二步：初始化完成之后才允许创建 Player。
    final player = Player(
      configuration: PlayerConfiguration(
        title: title ?? 'Lume Box',
        libass: true,
        // 日志交给宿主日志层：media_kit 自己的控制台输出关掉。
        logLevel: MPVLogLevel.error,
      ),
    );
    return MediaKitMpvEngine._(
      player,
      emulatorSurfacePreview: emulatorSurfacePreview,
    );
  }

  final Player _player;
  final bool _emulatorSurfacePreview;

  /// Read-only metadata for the opt-in reference recognizer. The original
  /// player's controls, filters and rendering configuration are unchanged.
  Future<Map<String, Object?>> readIntroMetadata() async {
    final platform = _player.platform;
    if (_disposed || platform is! NativePlayer) return {};
    Future<String?> read(String key) async {
      try {
        return await platform
            .getProperty(key)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        return null;
      }
    }

    final count = (int.tryParse(await read('chapter-list/count') ?? '') ?? 0)
        .clamp(0, 512);
    final chapters = <Map<String, Object?>>[];
    for (var i = 0; i < count && !_disposed; i++) {
      final seconds = double.tryParse(await read('chapter-list/$i/time') ?? '');
      if (seconds == null || !seconds.isFinite) continue;
      chapters.add({
        'title': await read('chapter-list/$i/title') ?? '',
        'startMs': (seconds * 1000).round(),
      });
    }
    final tags = <Map<String, Object?>>[];
    double? seconds(String? value) {
      if (value == null || value.trim().isEmpty) return null;
      var result = 0.0;
      for (final part in value.split(':')) {
        final number = double.tryParse(part);
        if (number == null || !number.isFinite || number < 0) return null;
        result = result * 60 + number;
      }
      return result;
    }

    for (final prefix in ['OP', 'ED', 'INTRO', 'OUTRO', 'RECAP']) {
      final start = seconds(await read('metadata/by-key/${prefix}_START'));
      final end = seconds(await read('metadata/by-key/${prefix}_END'));
      if (start != null && end != null) {
        tags.add({
          'title': prefix,
          'startMs': (start * 1000).round(),
          'endMs': (end * 1000).round(),
        });
      }
    }
    return {'chapters': chapters, 'mkvTags': tags};
  }

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
  Timer? _speedTimer;
  final _highestHls = HighestHls();
  bool _networkMedia = false;
  double? _downloadBytesPerSecond;

  /// `hr-seek` 属性写入与真正 seek 是两段异步操作；松手的精确跳转到来后，
  /// 仍在写 `hr-seek=no` 的旧快 seek 必须作废，不能晚到覆盖新落点。
  int _seekGeneration = 0;

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {
    _onSnapshot = onSnapshot;
    _emit();
  }

  @override
  Future<void> open(MpvMediaRequest request) async {
    if (_disposed) return;
    _seekGeneration++;
    final uri = await _highestHls.resolve(
      Uri.parse(request.url),
      request.headers,
      presentation: _presentation.copyWith(hdrEnabled: false),
    );
    if (_disposed) {
      await _highestHls.close();
      return;
    }
    _pendingAudioPreference = true;
    _appliedPresentation.clear();
    _rejectedPresentation.clear();
    _resetMediaState();
    _networkMedia = [
      'http',
      'https',
    ].contains(Uri.tryParse(request.url)?.scheme);
    try {
      // 缓冲属性要在起播**之前**写进去（cache / 预读时长在打开媒体时读一次）。
      await _applyBufferingProperties();
      // Standard libavformat HLS/AES key handling remains in the native engine.
      // Fixed-length quoting preserves the comma inside the HTTP status list.
      await _setProperties({
        'demuxer-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,'
            'reconnect_on_http_error=%7%429,5xx,reconnect_delay_max=7,seg_max_retry=3',
      });
      await _player.open(
        Media(uri.toString(), httpHeaders: request.headers),
        play: request.autoplay,
      );
      if (request.speed != 1.0) await _player.setRate(request.speed);
      final startAt = request.startAt;
      if (startAt != null && startAt > Duration.zero) {
        await _player.seek(startAt);
      }
      // 字幕状态也要在起播后补挂一次（媒体换了，轨道与延迟都得重设）。
      await _applySubtitleState();
      await applyPresentation(_presentation);
      await _preferAudio();
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
    if (_appliedBuffering == _bufferingConfig) return;
    final properties = MpvProperties.buffering(_bufferingConfig);
    final accepted = await _setProperties(properties);
    if (accepted == properties.length) _appliedBuffering = _bufferingConfig;
    LumeLog.info('[mpv] 缓冲参数已写入 $accepted/${properties.length} 项');
  }

  /// 起播缓冲参数（由上层 [setBuffering] 写入；`open()` 时统一应用）。
  ///
  /// 命名带 Config 后缀：本类已有一个 `_buffering` 是**播放状态**（是否正在缓冲），
  /// 两者含义完全不同，不能同名。
  BufferingConfig _bufferingConfig = BufferingConfig.defaults;
  BufferingConfig? _appliedBuffering;

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
    // Explicit development-only opt-in from android_player_preview.dart.
    // Physical-device and shipping factories always keep their normal path.
    if (_emulatorSurfacePreview) {
      await _setProperties({'hwdec': 'mediacodec'});
      return;
    }
    if (_hardwareDecoding == enabled) return;
    _hardwareDecoding = enabled;
    // hwdec 是 libmpv 的**解码链初始化期**属性：这里写进去，对随后打开的媒体生效
    // （正在播的这一集要等切集后才换解码链——libmpv 的既有口径，不是本层的取舍）。
    final accepted = await _setProperties(
      MpvProperties.hardwareDecoding(enabled),
    );
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
    final tracks = _player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    return <PlayerTrack>[
      for (var index = 0; index < tracks.length; index++)
        PlayerTrack(
          id: tracks[index].id,
          label: _trackLabel(
            tracks[index].title,
            tracks[index].language,
            tracks[index].codec,
            '音轨',
            index,
          ),
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
    final tracks = _player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    return <PlayerTrack>[
      for (var index = 0; index < tracks.length; index++)
        PlayerTrack(
          id: tracks[index].id,
          label: _trackLabel(
            tracks[index].title,
            tracks[index].language,
            tracks[index].codec,
            '字幕',
            index,
          ),
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
    if (lang != null && lang.isNotEmpty && lang != 'und') {
      return '$prefix ${lang.toUpperCase()}';
    }
    final code = codec?.trim();
    if (code != null && code.isNotEmpty) return '$prefix ${code.toUpperCase()}';
    return '$prefix ${index + 1}';
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    if (_disposed) return;
    _pendingAudioPreference = false;
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
      final scheme = Uri.tryParse(path)?.scheme;
      final uri = ['http', 'https', 'file'].contains(scheme)
          ? path
          : Uri.file(path).toString();
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
    await _setProperties({
      'sub-scale': '${style.fontScale}',
      'sub-font-size': '32',
      'sub-color': '#${style.colorArgb.toRadixString(16).padLeft(8, '0')}',
      'sub-border-size': '${style.outlineWidth}',
      'sub-back-color':
          '#${(style.backgroundOpacity * 255).round().toRadixString(16).padLeft(2, '0')}000000',
      'sub-shadow-offset': '${style.shadowStrength * 2.5}',
      'sub-pos': '${(100 - style.offsetY * 20).clamp(0, 100)}',
      'sub-font': style.fontFamily.isEmpty ? 'sans-serif' : style.fontFamily,
    });
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
    final generation = ++_seekGeneration;
    // open() only queues loadfile. Network metadata may still be pending, and
    // libmpv silently ignores a seek issued before the file is ready.
    if (_duration <= Duration.zero) {
      _pendingSeek = position;
      return;
    }
    _pendingSeek = null;
    await _setHrSeek(true);
    if (generation != _seekGeneration) return;
    await _player.seek(position);
  }

  /// 拖动预览：mpv 的 hr-seek=no 直接跳关键帧，网络流上快一个数量级。
  @override
  Future<void> seekFast(Duration position) async {
    if (_disposed) return;
    final generation = ++_seekGeneration;
    if (_duration <= Duration.zero) {
      _pendingSeek = position;
      return;
    }
    _pendingSeek = null;
    await _setHrSeek(false);
    if (generation != _seekGeneration) return;
    await _player.seek(position);
  }

  /// media_kit 初始化时把 `hr-seek` 写死成 yes（精确 seek），
  /// 这里按调用方需要切换；写的都是运行时属性，失败只记日志。
  Future<void> _setHrSeek(bool exact) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('hr-seek', exact ? 'yes' : 'no');
      }
    } catch (error) {
      LumeLog.warn('[mpv] 切换 hr-seek 失败：$error');
    }
  }

  Duration? _pendingSeek;

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
      final width = params.w ?? 0;
      final height = params.h ?? 0;
      if (width <= 0 || height <= 0) return null;

      // Raw screenshots retain mpv's aligned row pitch, unlike encoded images.
      if (raw.length % height != 0) return null;
      final stride = raw.length ~/ height;
      if (stride < width * 4) return null;
      return MpvVideoFrame(
        pixels: raw,
        width: width,
        height: height,
        stride: stride,
      );
    } catch (error, stackTrace) {
      // 取帧失败不影响播放（画中画是增强功能）。
      LumeLog.warn('[mpv] 取帧失败: $error');
      LumeLog.error(error, stackTrace);
      return null;
    }
  }

  PlaybackPresentation _presentation = const PlaybackPresentation();
  final _presentationStatus = ValueNotifier<List<String>>(const ['显示：SDR 纹理']);
  @override
  ValueListenable<List<String>> get presentationStatus => _presentationStatus;
  final Map<String, String> _appliedPresentation = {};
  final Set<String> _rejectedPresentation = {};
  @override
  Future<void> applyPresentation(PlaybackPresentation settings) async {
    final audioChanged = _presentation.dolbyAudio != settings.dolbyAudio;
    final subtitleModeChanged =
        _presentation.originalSubtitleStyle != settings.originalSubtitleStyle;
    _presentation = settings;
    final properties = {
      ...settings.mpvProperties,
      'sub-visibility': _subtitlesEnabled && settings.originalSubtitleStyle
          ? 'yes'
          : 'no',
    };
    for (final entry in properties.entries) {
      if (_appliedPresentation[entry.key] == entry.value) continue;
      if (await setEngineProperty(entry.key, entry.value)) {
        _appliedPresentation[entry.key] = entry.value;
        _rejectedPresentation.remove(entry.key);
      } else {
        _rejectedPresentation.add(entry.key);
      }
    }
    if (subtitleModeChanged && !_disposed) _styleRevision.value++;
    if (audioChanged) {
      _pendingAudioPreference = true;
      await _preferAudio();
    }
    await _readPresentationStatus();
  }

  bool _pendingAudioPreference = true;
  Future<void> _preferAudio() async {
    if (_disposed || !_pendingAudioPreference) return;
    final tracks = _player.state.tracks.audio.where(
      (t) => t.id != 'auto' && t.id != 'no',
    );
    final preferred = tracks.where((t) {
      final codec = t.codec?.toLowerCase() ?? '';
      return ['ac3', 'eac3', 'ac4', 'truehd'].contains(codec) ==
          _presentation.dolbyAudio;
    }).firstOrNull;
    if (tracks.isEmpty) return;
    _pendingAudioPreference = false;
    if (preferred != null) await _player.setAudioTrack(preferred);
  }

  bool _readingPresentation = false;
  Future<void> _readPresentationStatus() async {
    if (_disposed || _readingPresentation) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _readingPresentation = true;
    try {
      Future<String?> read(String key) async {
        try {
          return await platform
              .getProperty(key)
              .timeout(const Duration(seconds: 1));
        } catch (_) {
          return null;
        }
      }

      final gamma = await read('video-params/gamma');
      final primaries = await read('video-params/primaries');
      final audio = await read('audio-codec-name');
      final channels = await read('audio-params/channel-count');
      if (_disposed) return;
      final range = gamma == 'pq'
          ? 'HDR（PQ）'
          : gamma == 'hlg'
          ? 'HLG'
          : gamma == null || gamma.isEmpty
          ? '待识别'
          : 'SDR';
      _presentationStatus.value = [
        '片源：$range${primaries == null ? '' : ' · $primaries'}',
        '显示：SDR 纹理；HDR 内容使用色调映射',
        if (audio != null && audio.isNotEmpty)
          '音轨：$audio${channels == null ? '' : ' · $channels 声道'}（不代表 Atmos 已输出）',
        _presentation.enhances
            ? '画质增强：${_presentation.preset.label}${_rejectedPresentation.isEmpty ? '' : '（部分参数未被内核接受）'}'
            : '画质增强：关闭',
        if (_rejectedPresentation.isNotEmpty)
          '未生效参数：${_rejectedPresentation.join(' / ')}',
        _presentation.originalSubtitleStyle
            ? '字幕：libass 原始样式'
            : '字幕：统一文字样式（ASS 特效已关闭）',
      ];
    } finally {
      _readingPresentation = false;
    }
  }

  @override
  Future<void> setSubtitleEnabled(bool enabled) async {
    if (_disposed) return;
    _subtitlesEnabled = enabled;
    await _setProperties({
      'sub-visibility': enabled && _presentation.originalSubtitleStyle
          ? 'yes'
          : 'no',
    });
  }

  @override
  Widget buildView() => ValueListenableBuilder<int>(
    valueListenable: _styleRevision,
    builder: (context, revision, _) => Stack(
      fit: StackFit.passthrough,
      children: [
        Video(
          key: ValueKey<int>(revision),
          controller: _video,
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
          controls: NoVideoControls,
          fit: BoxFit.contain,
          fill: Colors.black,
          wakelock: true,
        ),
        if (!_presentation.originalSubtitleStyle)
          Positioned.fill(
            child: IgnorePointer(
              child: SubtitleView(
                controller: _video,
                configuration: _subtitleConfiguration(),
              ),
            ),
          ),
      ],
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
    final backgroundAlpha = (style.backgroundOpacity.clamp(0.0, 1.0) * 255)
        .round();
    // 阴影强度 → 单向柔和投影（与四向描边叠加；强度 0 时不加）。
    final shadow = style.shadowStrength.clamp(0.0, 1.0);
    final fontFamily = style.fontFamily.trim();
    return SubtitleViewConfiguration(
      visible: _subtitlesEnabled,
      textScaler: TextScaler.noScaling,
      // 垂直偏移：改字幕层到底边的距离。正偏移 = 离底边更远（视觉上移）。
      padding: EdgeInsets.only(
        bottom: (24 + style.offsetY.clamp(-1.0, 1.0) * 120).clamp(0, 160),
      ),
      style: TextStyle(
        height: 1.4,
        fontSize: (base) + 1,
        letterSpacing: 0.0,
        wordSpacing: 0.0,
        color: Color(style.colorArgb),
        fontWeight: FontWeight.w600,
        fontFamily: fontFamily.isEmpty ? null : fontFamily,
        backgroundColor: Color(backgroundAlpha << 24),
        shadows: <Shadow>[
          if (shadow > 0)
            Shadow(
              color: Color(0xFF000000).withValues(alpha: 0.55 * shadow),
              offset: Offset(shadow * 2.5, shadow * 2.5),
              blurRadius: shadow * 6,
            ),
          if (outline > 0) ...<Shadow>[
            Shadow(color: const Color(0xFF000000), offset: Offset(-outline, 0)),
            Shadow(color: const Color(0xFF000000), offset: Offset(outline, 0)),
            Shadow(color: const Color(0xFF000000), offset: Offset(0, -outline)),
            Shadow(color: const Color(0xFF000000), offset: Offset(0, outline)),
          ],
        ],
      ),
    );
  }

  /// 释放播放器的等待上限（安全阀，见 [dispose]）。
  static const Duration disposeTimeout = Duration(seconds: 10);

  @override
  Future<void> dispose() async {
    await _highestHls.close();
    if (_disposed) return;
    _disposed = true;
    _presentationStatus.dispose();
    _speedTimer?.cancel();
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
    _subscriptions.clear();
    _onSnapshot = null;
    // 视频输出的收尾**只能由 media_kit 自己按它的顺序做**，这一层不许插手：
    //
    // iOS 上的视频输出就是 libmpv 的 render context，它挂在 `Player.dispose()`
    // 的 release 链上——Player 销毁时先等视频控制器就绪，再调
    // `VideoOutputManager.Dispose` 释放原生渲染上下文，**最后**（延迟 5 秒）才
    // `mpv_terminate_destroy`。libmpv 对这条顺序零容忍：`mp_destroy_client` 里
    // 一旦发现 render context 还在，直接 abort：
    //   `Broken API use: mpv_render_context_free() not called.`
    // ——真机两次复现的 SIGABRT 就是这个（mp_destroy_client →
    // mp_clients_destroy.cold.1 → abort，都发生在「播放中切内核 / 退出播放页」）。
    //
    // 曾经的写法是在这里先 `await _video.platform.future` 再 `controller.dispose()`
    // （想着「先把视频输出收掉更稳」）。那是**基类**的 dispose：它只关掉 id / rect
    // 两个 ValueNotifier，原生释放仍在 `_dispose()`（由 Player 的 release 链调用）。
    // 而 Debug 构建里 `ValueNotifier.dispose` 二次调用会抛（"A ValueNotifier
    // was used after being disposed"），异常被 release 链吞掉 →
    // `VideoOutputManager.Dispose` 再也不被调用 → 原生渲染上下文永远活着 →
    // 5 秒后 terminate 命中上面那条 abort。release 构建里那次调用虽然不抛，
    // 但它本身没有任何释放作用——删掉它两种构建都回到唯一正确的顺序。
    try {
      // 超时只是安全阀：不阻塞「切内核 / 退出播放页」的交互。即使这里超时，
      // media_kit 的 release 链也会在后台按顺序跑完，上面那条时序保证不依赖
      // 我们等多久。
      await _player.dispose().timeout(disposeTimeout);
    } catch (error, stackTrace) {
      LumeLog.warn('[mpv] 释放播放器未在预算内完成（media_kit 会自行收尾）：$error');
      LumeLog.error(error, stackTrace);
    }
  }

  // ------------------------------------------------------------------ 内部

  void _sampleDownloadSpeed() {
    if (_disposed || !_networkMedia) return;
    final platform = _player.platform;
    if (platform is! NativePlayer || platform.ctx == nullptr) return;
    final name = 'cache-speed'.toNativeUtf8();
    try {
      final value = platform.mpv.mpv_get_property_string(
        platform.ctx,
        name.cast<Int8>(),
      );
      if (value == nullptr) {
        _downloadBytesPerSecond = null;
        return;
      }
      try {
        final speed = double.tryParse(value.cast<Utf8>().toDartString());
        _downloadBytesPerSecond = speed != null && speed.isFinite && speed >= 0
            ? speed
            : null;
      } finally {
        platform.mpv.mpv_free(value.cast());
      }
      _emit();
    } catch (_) {
      _downloadBytesPerSecond = null;
    } finally {
      malloc.free(name);
    }
  }

  void _subscribe() {
    final streams = _player.stream;
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      streams.position.listen((value) {
        _position = value;
        _emit();
      }),
      streams.duration.listen((value) {
        _duration = value;
        final pending = _pendingSeek;
        if (value > Duration.zero && pending != null) {
          _pendingSeek = null;
          unawaited(
            _player.seek(pending).catchError((Object error, StackTrace stack) {
              LumeLog.error(error, stack);
            }),
          );
        }
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
      streams.track.listen((_) => _applyTracks(_player.state.tracks)),
      streams.error.listen((value) {
        _fail(value);
      }),
    ]);
  }

  /// HUD 参数来自 libmpv 的轨道列表：编码 / 帧率 / 码率（bps → kbps）。
  void _applyTracks(Tracks tracks) {
    if (_pendingAudioPreference) unawaited(_preferAudio());
    final video = tracks.video.isEmpty ? null : tracks.video.first;
    final audio =
        tracks.audio
            .where((t) => t.id == _player.state.track.audio.id)
            .firstOrNull ??
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').firstOrNull;
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

  /// media_kit buffer is a timestamp (demuxer-cache-time), not a duration ahead.
  @visibleForTesting
  static Duration? bufferedAhead(Duration? end, Duration position) {
    if (end == null) return null;
    final ahead = end - position;
    return ahead > Duration.zero ? ahead : Duration.zero;
  }

  void _resetMediaState() {
    _pendingSeek = null;
    _downloadBytesPerSecond = null;
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
        buffered: bufferedAhead(_buffered, _position),
        playing: _playing,
        buffering: _buffering,
        videoCodec: _videoCodec,
        audioCodec: _audioCodec,
        videoBitrateKbps: _videoBitrateKbps,
        audioBitrateKbps: _audioBitrateKbps,
        downloadBytesPerSecond: _downloadBytesPerSecond,
        fps: _fps,
        width: _width,
        height: _height,
        error: _error,
      ),
    );
  }
}
