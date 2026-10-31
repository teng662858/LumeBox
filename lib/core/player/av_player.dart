import 'av_presentation_channel.dart';
import 'text_subtitles.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'buffering.dart';
import 'download_speed.dart';
import 'highest_hls.dart';
import 'player_capabilities.dart';
import 'player_error.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// 基于 AVPlayer 的播放器实现。
///
/// iOS 上 video_player 由 AVPlayer 驱动，符合 Phase1「优先 AVPlayer 实现原型」。
///
/// 播放设置消费情况（[applySettings]）：
/// - 倍速：真实生效（`setPlaybackSpeed`），加载完成后自动补挂；
/// - 字幕开关与字号：本内核基于 video_player 插件，插件按系统样式渲染自带字幕、
///   不暴露样式接口，因此暂不消费（缺口与落点记录在 Phase3 播放器文档里）。
///
/// 缓冲参数（[BufferingConfig]）：AVPlayer 的 `preferredForwardBufferDuration` /
/// `automaticallyWaitsToMinimizeStalling` **只存在于原生对象上**，Dart 侧写不到，
/// 因此这里走原生通道（`lumebox/buffering`）先写一次，再由 vendored 的
/// video_player_avfoundation 在建播放器时应用——详见 `third_party/
/// video_player_avfoundation/PATCHES.md`。写入只做一次：原生侧的参数一旦落定就
/// 对之后创建的每个播放器生效（[setBuffering] 改了参数则重写一次）。
class AvPlayer extends AbstractPlayer implements PresentationEngine {
  final _presentationStatus = ValueNotifier<List<String>>(const ['正在读取播放信息']);
  @override
  ValueListenable<List<String>> get presentationStatus => _presentationStatus;
  TextSubtitles? _externalSubtitles;
  String? _externalLabel;
  bool _externalSelected = false;
  bool _subtitleSuppressed = false;
  List<String> _nativeStatus = const [];
  AvPlayer({BufferingBackend? buffering})
    : _buffering = buffering ?? createPlatformBufferingBackend();

  /// 缓冲参数的原生写通道（测试可注入替身）。
  final BufferingBackend _buffering;

  /// 待写入的缓冲参数（[setBuffering] 可在装载前改，见 [_applyBufferingOnce]）。
  BufferingConfig _config = BufferingConfig.defaults;

  /// 是否已经把缓冲参数写进原生侧（只写一次，后续起播省掉通道往返）。
  bool _bufferingWritten = false;
  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(),
  );

  /// HUD 参数：video_player 只暴露分辨率 / 缓冲 / 缓冲中，
  /// 编码、帧率、码率它拿不到——留空由 HUD 自动省略（不编造）。
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    const PlayerStats(engineLabel: 'AVPlayer'),
  );

  VideoPlayerController? _controller;
  int _loadGeneration = 0;

  /// 最新一次跳转代次。容差写入与 video_player.seekTo 分属两个异步通道：
  /// 松手的精确 seek 到来后，仍在等容差写入的旧快 seek 必须作废，不能晚到覆盖。
  int _seekGeneration = 0;
  PlayerMedia? _retryMedia;
  Timer? _retryTimer;
  int _networkRetries = 0;
  bool _recoveringNetwork = false;
  bool _retryAllowed = true;
  bool _wantsPlay = false;
  static bool retryableNetworkError(String message) =>
      !RegExp(
        r'403|401|404|410|DRM|decrypt|certificate|证书|验证码',
        caseSensitive: false,
      ).hasMatch(message) &&
      RegExp(
        r'429|50[0234]|-1001|-1005|-1009|timed? ?out|network connection|connection (lost|reset)|网络连接|连接中断',
        caseSensitive: false,
      ).hasMatch(message);

  Completer<void>? _loadCancelled;

  // video_player is pinned; this ID resolves its existing native AVPlayer.
  // ignore: invalid_use_of_visible_for_testing_member
  int? get nativePlayerId => _controller?.playerId;
  Timer? _ticker;
  final _highestHls = HighestHls();
  final _downloadSampler = DownloadSpeedSampler();
  final _downloadClock = Stopwatch();
  double? _downloadBytesPerSecond;
  bool _readingNetwork = false;
  bool _networkMedia = false;
  Duration _lastNetworkPoll = Duration.zero;
  bool _disposed = false;

  /// 最近一次应用的设置；加载完成后补挂到新控制器上。
  PlayerSettings _settings = const PlayerSettings();

  /// 当前音量（0..1）；加载完成后补挂到新控制器上。
  double _volume = 1.0;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  /// 能力矩阵：见 [PlayerCapabilities.of] 的唯一声明处（AVPlayer 那一栏）。
  @override
  PlayerCapabilities get capabilities => _externalSelected
      ? const PlayerCapabilities(
          audioTracks: true,
          subtitleTracks: true,
          externalSubtitle: true,
          subtitleStyle: true,
          subtitleDelay: true,
          backgroundAudio: true,
          nowPlaying: true,
          bufferingParams: true,
        )
      : PlayerCapabilities.of(PlayerKernel.avplayer);

  /// 可选音轨（video_player 在 iOS 上支持；不支持时如实返回空表）。
  @override
  Future<List<PlayerTrack>> audioTracks() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const <PlayerTrack>[];
    }
    if (!controller.isAudioTrackSupportAvailable()) {
      return const <PlayerTrack>[];
    }
    try {
      final tracks = await controller.getAudioTracks();
      return <PlayerTrack>[
        for (final track in tracks)
          PlayerTrack(
            id: track.id,
            label: _trackLabel(track.label, track.language, track.codec),
            language: track.language,
            selected: track.isSelected,
          ),
      ];
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return const <PlayerTrack>[];
    }
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.selectAudioTrack(id);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[avplayer] 切音轨失败（$id）：$error');
    }
  }

  /// 轨道展示名：标题 → 语言 → 编码 → 「音轨 N」兜底（与 MPV 侧同一套口径）。
  static String _trackLabel(String? label, String? language, String? codec) {
    final name = label?.trim();
    if (name != null && name.isNotEmpty) return name;
    final lang = language?.trim();
    if (lang != null && lang.isNotEmpty && lang != 'und') {
      return '音轨 ${lang.toUpperCase()}';
    }
    final code = codec?.trim();
    if (code != null && code.isNotEmpty) return '音轨 ${code.toUpperCase()}';
    return '音轨';
  }

  @override
  Future<void> load(PlayerMedia media) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _networkRetries = 0;
    _retryMedia = media;
    _retryAllowed = true;
    await _loadMedia(media);
  }

  Future<void> _loadMedia(PlayerMedia media) async {
    if (_disposed) return;
    if (_loadCancelled?.isCompleted == false) {
      _loadCancelled!.complete();
    }
    final cancelled = Completer<void>();
    _loadCancelled = cancelled;
    final generation = ++_loadGeneration;
    _seekGeneration++;
    _externalSubtitles = null;
    _externalLabel = null;
    _externalSelected = false;
    _subtitleSuppressed = false;
    _nativeStatus = const [];
    final uri = await _highestHls.resolve(
      media.uri,
      media.headers,
      presentation: _settings.presentation,
    );
    if (_disposed) {
      await _highestHls.close();
      return;
    }
    if (generation != _loadGeneration) return;
    // 缓冲参数要先落到原生侧：插件正是在下面的 initialize() 里建 AVPlayer，
    // 晚一步写就只对下一次起播生效（那正是「第一次起播慢」的那一次）。
    await _applyBufferingOnce();
    // seek 容差存在进程级 UserDefaults；拖动被中断时可能留在 400ms / -1。
    // 每次换集、换地址、重开都归零，不能只在播放器实例第一次装载时做。
    await _setSeekTolerance(Duration.zero);
    if (_disposed) return;
    if (generation != _loadGeneration) return;
    await _releaseController();
    if (_disposed || generation != _loadGeneration) return;
    final controller = media.isNetwork
        ? VideoPlayerController.networkUrl(
            uri,
            httpHeaders: media.headers ?? const <String, String>{},
            viewType: _settings.presentation.wantsHdr
                ? VideoViewType.platformView
                : VideoViewType.textureView,
            // 后台音频继续播放：切到后台时画面停、声音不停（用户在听内容）。
            // `allowBackgroundPlayback` 是插件暴露的唯一后台开关，它顺带把
            // 音画会话设成播放类，与另一条原生通道（锁屏控制）配合工作。
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          )
        : VideoPlayerController.file(
            File.fromUri(media.uri),
            viewType: _settings.presentation.wantsHdr
                ? VideoViewType.platformView
                : VideoViewType.textureView,
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          );
    _controller = controller;
    _networkMedia = media.isNetwork;
    _downloadClock
      ..reset()
      ..start();
    controller.addListener(_sync);
    try {
      await Future.any<void>([controller.initialize(), cancelled.future]);
      if (_disposed ||
          generation != _loadGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      await _applySpeed();
      await _configurePresentation();
      await controller.setVolume(_volume);
      if (_disposed ||
          generation != _loadGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _sync();
        unawaited(_sampleNetwork(controller));
        unawaited(_refreshPresentation());
      });
      _sync();
    } catch (error, stackTrace) {
      if (_disposed ||
          generation != _loadGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      LumeLog.error(error, stackTrace);
      if (_retryTimer == null && !_recoveringNetwork) {
        _emit(_snapshot.value, error: PlayerErrorText.describe(error));
      }
    }
  }

  /// 起播缓冲参数（见 [BufferingConfig]）：值变了就把「已写入」标记清掉，
  /// 下一次装载前重写一遍原生通道（原生侧只按最后一次写入建播放器）。
  @override
  Future<void> setBuffering(BufferingConfig config) async {
    if (config == _config) return;
    _config = config;
    _bufferingWritten = false;
    final id = nativePlayerId;
    if (Platform.isIOS &&
        id != null &&
        _controller?.value.isInitialized == true) {
      await AvNetworkStatistics.applyBuffering(
        id,
        config.forwardBuffer.inMicroseconds / Duration.microsecondsPerSecond,
        config.minimizeStalling,
      );
    }
  }

  /// 把缓冲参数写进原生侧（只写一次；失败只记日志，不打断起播）。
  Future<void> _applyBufferingOnce() async {
    if (_bufferingWritten) return;
    _bufferingWritten = true;
    try {
      await _buffering.apply(_config);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[avplayer] 写缓冲参数失败，本次按系统默认缓冲策略播放');
    }
  }

  @override
  Future<void> play() async {
    _retryAllowed = true;
    _wantsPlay = true;
    if (_retryTimer != null) return;
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    _retryAllowed = false;
    _wantsPlay = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _controller?.pause();
  }

  /// 拖动预览用的容差：AVPlayer 在这个范围内可直接落到关键帧，
  /// 不必从上一个关键帧解码到目标帧（长 GOP 剧集里这一步最慢）。
  static const Duration fastSeekTolerance = Duration(milliseconds: 400);

  @override
  Future<void> seek(Duration position) async {
    final generation = ++_seekGeneration;
    // 松手/系统跳转用精确 seek（容差归零，恢复上游行为）。
    await _setSeekTolerance(Duration.zero);
    if (generation != _seekGeneration) return;
    await _controller?.seekTo(position);
  }

  /// 吸附到前一关键帧（实验开关）：写 -1 作哨兵，原生侧翻成 ±∞/0。
  bool _snapToKeyframe = false;

  @override
  void setFastSeekSnapToKeyframe(bool value) => _snapToKeyframe = value;

  @override
  Future<void> seekFast(Duration position) async {
    final generation = ++_seekGeneration;
    await _setSeekTolerance(
      _snapToKeyframe ? const Duration(milliseconds: -1) : fastSeekTolerance,
    );
    if (generation != _seekGeneration) return;
    await _controller?.seekTo(position);
  }

  Future<void> _setSeekTolerance(Duration tolerance) async {
    try {
      await _buffering.applySeekTolerance(tolerance);
    } catch (error, stackTrace) {
      LumeLog.warn('[avplayer] 写 seek 容差失败：$error');
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    _wantsPlay = false;
    _retryAllowed = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryMedia = null;
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    await controller.seekTo(Duration.zero);
    _sync();
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0);
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setVolume(_volume);
    } catch (error, stackTrace) {
      // 音量失败不影响播放主链路。
      LumeLog.error(error, stackTrace);
    }
  }

  /// 当前音量（0..1）。
  double get volume => _volume;

  @override
  Future<void> applySettings(PlayerSettings settings) {
    final operation = _settingsQueue.then((_) => _applySettingsNow(settings));
    _settingsQueue = operation.catchError((Object error, StackTrace stack) {
      LumeLog.error(error, stack);
    });
    return operation;
  }

  Future<void> _settingsQueue = Future.value();
  Future<void> _applySettingsNow(PlayerSettings settings) async {
    if (_disposed) return;
    final old = _settings;
    _settings = settings;
    if (!old.subtitlesEnabled && settings.subtitlesEnabled) {
      _subtitleSuppressed = false;
    }
    if (old.presentation.wantsHdr != settings.presentation.wantsHdr &&
        _controller?.value.isInitialized == true &&
        _retryMedia != null) {
      final position = _snapshot.value.position;
      final playing = _snapshot.value.playing;
      final subtitles = _externalSubtitles;
      final label = _externalLabel;
      final external = _externalSelected;
      final suppressed = _subtitleSuppressed;
      final media = _retryMedia!;
      final audio = (await audioTracks()).where((t) => t.selected).firstOrNull;
      final subtitle = (await subtitleTracks())
          .where((t) => t.selected)
          .firstOrNull;
      await _loadMedia(media);
      _externalSubtitles = subtitles;
      _externalLabel = label;
      _externalSelected = external;
      _subtitleSuppressed = suppressed;
      if (_disposed || !identical(media, _retryMedia)) return;
      if (audio != null &&
          old.presentation.dolbyAudio == settings.presentation.dolbyAudio) {
        final tracks = await audioTracks();
        final match = tracks
            .where(
              (t) => t.label == audio.label && t.language == audio.language,
            )
            .firstOrNull;
        if (match != null) await selectAudioTrack(match.id);
      }
      if (subtitle != null && !external) {
        final tracks = await subtitleTracks();
        final match = tracks
            .where(
              (t) =>
                  t.label == subtitle.label && t.language == subtitle.language,
            )
            .firstOrNull;
        if (match != null) await selectSubtitleTrack(match.id);
      }
      await seek(position);
      if (playing) await play();
    }
    await _applySpeed();
    await _configurePresentation(
      selectAudio:
          old.presentation.dolbyAudio != settings.presentation.dolbyAudio,
    );
  }

  /// 把倍速挂到当前控制器；控制器未就绪时静默跳过（加载完成后会补挂）。
  Future<void> _applySpeed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setPlaybackSpeed(_settings.speed);
    } catch (error, stackTrace) {
      // 倍速失败不影响播放主链路：记录后继续。
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<void> applyPresentation(PlaybackPresentation settings) =>
      applySettings(_settings.copyWith(presentation: settings));

  Future<void> _configurePresentation({bool selectAudio = true}) async {
    if (!Platform.isIOS || _controller?.value.isInitialized != true) return;
    await AvPresentationChannel.invoke<Object?>(nativePlayerId, 'configure', {
      'dolbyAudio': _settings.presentation.dolbyAudio,
      'selectAudio': selectAudio,
      'subtitlesEnabled':
          _settings.subtitlesEnabled &&
          !_externalSelected &&
          !_subtitleSuppressed,
      'originalStyle': _settings.presentation.originalSubtitleStyle,
      'fontSize': 24 * _settings.subtitleSize.scale,
      'color': _settings.subtitleColor.argb,
      'font': _settings.subtitleFont,
      'background': _settings.subtitleBackground,
    });
    await _refreshPresentation();
  }

  bool _readingPresentation = false;
  Future<void> _refreshPresentation() async {
    if (_disposed || !Platform.isIOS || _readingPresentation) return;
    _readingPresentation = true;
    final id = nativePlayerId;
    try {
      final result = await AvPresentationChannel.invoke<List<Object?>>(
        id,
        'status',
      );
      if (_disposed || id != nativePlayerId) return;
      if (result != null) _nativeStatus = result.whereType<String>().toList();
      _presentationStatus.value = [
        ..._nativeStatus,
        _settings.presentation.wantsHdr
            ? '显示：原生 AVPlayerLayer；HDR 实际输出需设备验证'
            : '显示：SDR 兼容纹理',
        if (_settings.presentation.enhancementEnabled) '画质增强：当前内核不支持，请切换 MPV',
        if (_externalSelected) '字幕：$_externalLabel（外挂）',
      ];
    } finally {
      _readingPresentation = false;
    }
  }

  @override
  Future<List<PlayerTrack>> subtitleTracks() async {
    final result = await AvPresentationChannel.invoke<List<Object?>>(
      nativePlayerId,
      'subtitleTracks',
    );
    return [
      for (final value in result ?? const [])
        if (value is Map)
          PlayerTrack(
            id: '${value['id']}',
            label: '${value['label']}',
            language: value['language'] as String?,
            selected: !_externalSelected && value['selected'] == true,
          ),
      if (_externalLabel != null)
        PlayerTrack(
          id: 'external',
          label: _externalLabel!,
          selected: _externalSelected,
        ),
    ];
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    _externalSelected = id == 'external';
    _subtitleSuppressed = id == null;
    await AvPresentationChannel.invoke<Object?>(
      nativePlayerId,
      'selectSubtitle',
      {'id': _externalSelected ? null : id},
    );
    await _refreshPresentation();
  }

  @override
  Future<bool> loadSubtitleFile(String path) async {
    try {
      final document = await TextSubtitles.load(path);
      if (document == null || _disposed) return false;
      _externalSubtitles = document;
      _externalLabel = Uri.tryParse(path)?.pathSegments.lastOrNull ?? '外挂字幕';
      await selectSubtitleTrack('external');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget buildView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: Text('Lume Box'));
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(controller),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final text = _externalSelected && _settings.subtitlesEnabled
                  ? _externalSubtitles?.at(
                          value.position - _settings.subtitleDelay,
                        ) ??
                        ''
                  : '';
              if (text.isEmpty) return const SizedBox.shrink();
              return IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      (24 + _settings.subtitleOffsetY * 120).clamp(0, 160),
                    ),
                    child: Text(
                      text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24 * _settings.subtitleSize.scale,
                        color: Color(_settings.subtitleColor.argb),
                        fontFamily: _settings.subtitleFont.isEmpty
                            ? null
                            : _settings.subtitleFont,
                        backgroundColor: Color(
                          (_settings.subtitleBackground * 255).round() << 24,
                        ),
                        shadows: [
                          for (final offset in [
                            const Offset(-1, 0),
                            const Offset(1, 0),
                            const Offset(0, -1),
                            const Offset(0, 1),
                          ])
                            Shadow(
                              color: const Color(0xff000000),
                              offset: offset * _settings.subtitleOutline.width,
                            ),
                          if (_settings.subtitleShadow > 0)
                            Shadow(
                              color: const Color(0xff000000),
                              blurRadius: _settings.subtitleShadow * 6,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryMedia = null;
    if (_loadCancelled?.isCompleted == false) {
      _loadCancelled!.complete();
    }
    await _highestHls.close();
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    await _releaseController();
    _presentationStatus.dispose();
    _snapshot.dispose();
    _stats.dispose();
  }

  Future<void> _releaseController() async {
    _ticker?.cancel();
    _ticker = null;
    final controller = _controller;
    _controller = null;
    _downloadClock.stop();
    _downloadSampler.reset();
    _downloadBytesPerSecond = null;
    _lastNetworkPoll = Duration.zero;
    if (controller == null) return;
    controller.removeListener(_sync);
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  Future<void> _sampleNetwork(VideoPlayerController controller) async {
    if (_disposed ||
        !_networkMedia ||
        !Platform.isIOS ||
        _readingNetwork ||
        !identical(controller, _controller) ||
        _downloadClock.elapsed - _lastNetworkPoll <
            const Duration(seconds: 1)) {
      return;
    }
    _readingNetwork = true;
    _lastNetworkPoll = _downloadClock.elapsed;
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final bytes = await AvNetworkStatistics.readBytes(controller.playerId);
      if (_disposed || !identical(controller, _controller)) return;
      _downloadBytesPerSecond = _downloadSampler.sample(
        bytes,
        _downloadClock.elapsed,
      );
      _sync();
    } finally {
      _readingNetwork = false;
    }
  }

  void _sync() {
    final controller = _controller;
    if (controller == null || _disposed) return;
    final value = controller.value;
    if (value.hasError &&
        _retryAllowed &&
        _retryMedia?.isNetwork == true &&
        !_recoveringNetwork &&
        _retryTimer == null &&
        _networkRetries < 3 &&
        retryableNetworkError(value.errorDescription ?? '')) {
      final media = _retryMedia!;
      final position = _snapshot.value.position;
      // 首次失败时尚未进入 playing；恢复后遵循用户的播放意图。
      final generation = _loadGeneration;
      _retryTimer = Timer(Duration(seconds: 1 << _networkRetries++), () async {
        _retryTimer = null;
        if (_disposed ||
            generation != _loadGeneration ||
            !identical(media, _retryMedia)) {
          return;
        }
        _recoveringNetwork = true;
        try {
          await _loadMedia(media);
          if (_disposed || !identical(media, _retryMedia)) return;
          await seek(position);
          if (_wantsPlay && _retryAllowed) await play();
        } finally {
          _recoveringNetwork = false;
          if (!_disposed && identical(media, _retryMedia)) _sync();
        }
      });
    }
    final retrying = _retryTimer != null || _recoveringNetwork;
    if (value.hasError && !retrying && _snapshot.value.error == null) {
      // Preserve the native reason; the UI below receives a short translation.
      LumeLog.warn('[avplayer] 播放失败: ${value.errorDescription}');
    }
    _emit(
      PlayerSnapshot(
        position: value.position,
        duration: value.duration,
        playing: value.isPlaying,
        buffering: value.isBuffering || retrying,
        error: value.hasError && !retrying
            ? PlayerErrorText.describe(value.errorDescription)
            : null,
      ),
    );
    _stats.value = PlayerStats(
      engineLabel: 'AVPlayer',
      width: value.size.width > 0 ? value.size.width.round() : null,
      height: value.size.height > 0 ? value.size.height.round() : null,
      buffered: _bufferedAhead(value),
      buffering: value.isBuffering,
      downloadBytesPerSecond: _downloadBytesPerSecond,
    );
  }

  /// 缓冲状态：当前位置**前方**已缓冲的时长（取最远的一段）。
  static Duration? _bufferedAhead(VideoPlayerValue value) {
    Duration? ahead;
    for (final range in value.buffered) {
      if (range.end <= value.position) continue;
      final span = range.end - value.position;
      if (ahead == null || span > ahead) ahead = span;
    }
    return ahead;
  }

  void _emit(PlayerSnapshot next, {String? error}) {
    if (_disposed) return;
    _snapshot.value = error == null
        ? next
        : PlayerSnapshot(
            position: next.position,
            duration: next.duration,
            playing: false,
            buffering: false,
            error: error,
          );
  }
}
