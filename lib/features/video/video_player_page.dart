import '../reading/poster_card.dart';
import '../reading/section_toolbar.dart';
import 'video_detail_page.dart';
import 'video_resume_match.dart';
import '../reading/search_results_page.dart';

import 'dart:convert';

import '../../core/player/playback_diagnostics.dart';
import 'video_episode_catalog.dart';
import 'player_settings_panel.dart';
import '../../shared/widgets/native_glass_controls.dart';
import 'danmaku/danmaku_panel.dart';
import 'danmaku/danmaku_match_sheet.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'playback_glass.dart';
import 'playback_failure_panel.dart';
import '../../core/session/app_preferences.dart';

import 'dart:io' show Platform;

import '../../core/net/ios_verified_webview.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/buffering.dart';
import '../../core/cache/media_preload.dart';
import '../../core/player/playback_session.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
import '../../core/player/pip_frame_pump.dart';
import '../../core/player/mpv_engine.dart';
import '../../core/player/mpv_player.dart';
import '../../core/player/mdk_engine.dart';
import '../../core/player/av_player.dart';
import '../../core/player/playback_orientation.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../../core/player/player_stats.dart';
import '../../core/player/player_error.dart';
import '../../core/player/skip_marks.dart';
import '../../core/bangumi/bangumi_sync.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/session/module_ui_scale.dart';
import '../../core/session/section_module_settings.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'danmaku/danmaku_models.dart';
import 'danmaku/dandanplay_client.dart';
import 'danmaku/danmaku_sources_page.dart';
import 'danmaku/danmaku_overlay.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_settings_sheet.dart';
import 'player_gestures.dart';
import 'player_hud.dart';
import 'player_layout.dart';
import 'player_waiting_overlay.dart';
import 'player_control_glyph.dart';
import 'playback_source_validator.dart';
import 'playback_quality_preference.dart';
import 'playback_preference_wiring.dart';
import '../../core/player/player_experience_store.dart';
import 'player_kernel_picker.dart';
import 'next_episode_buffer.dart';
import 'player_settings_sheet.dart';
import 'player_source_sheet.dart';
import 'player_speed_meter.dart';
import 'source_playback.dart';
import 'source_web_player_page.dart';
import '../../core/cat/cat_web_parse.dart';
import 'video_play_target.dart';
import 'player_intro_memory.dart';
import 'video_player_settings.dart';
import '../source/waf_webview_page.dart';
import '../../core/intro/intro_controller.dart';
import '../../core/intro/intro_models.dart';
import '../../core/intro/intro_service.dart';
import '../../core/intro/intro_store.dart';
import '../../core/intro/playback_metadata.dart';
import '../../core/player/playback_logs.dart';
import 'intro_episode_sheet.dart';

part 'video_player_intro.dart';

/// 独立播放器页：视频**唯一的**播放入口。
///
/// 为什么是独立页面（真机反馈）：视频板块顶部的「播放」子页签被移除，播放不再
/// 占用板块的页签位——浏览列表点条目即唤起本页，返回就回到浏览。继续观看 /
/// 播放历史 / 追剧日历也都从这里进。
///
/// 页面职责（与旧「播放」页签同一套逻辑，逐条搬过来而不是重写）：
/// - 内核的创建 / 切换 / 失败回退（[PlayerKernelLauncher]：8 秒超时 + 回退 AVPlayer）；
/// - 播放设置落库与即时生效（本板块自己的视频设置库）；
/// - 手势（左亮度 / 右音量 / 横滑进度 / 长按倍速）、HUD、弹幕、画中画；
/// - 进度记忆（集数 + 时间点）与自动连播下一集。
///
/// 底部导航的显隐不需要本页操心：`ShellDockObserver` 在推入非首页路由时自动
/// 隐藏 Dock（播放是沉浸态，返回即恢复）。
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    this.media,
    this.title,
    this.target,
    this.sourceId,
    this.qualities = const <VideoQuality>[],
    this.playerFactory,
    this.catalog,
    this.pipBackend,
    this.brightnessBackend,
    this.sourceManager,
    this.source,
    this.library,
    this.playbackBackend,
    this.speedMeter,
    this.prelaunch,
    this.sourceValidator,
    this.fullscreenOnly = true,
  });

  /// 起播媒体（含防盗链请求头）。
  ///
  /// 为空时页面照常创建播放器，只是**不装载任何媒体**：控制栏右侧「播放源」弹窗里
  /// 的地址留空，用户贴一个地址按「播放这个地址」即可起播（手动地址没有作品身份，
  /// 因此不记进度、不连播）。
  final PlayerMedia? media;
  final bool fullscreenOnly;

  /// 页面标题（作品名）；为空时用「播放」。
  final String? title;

  /// 作品身份：给了就记进度（继续观看 / 历史），不给（手动贴地址）不记。
  final VideoPlayTarget? target;

  /// 图源 id：连播下一集与弹幕要用（页面自己按 id 打开图源，用完即关）。
  final String? sourceId;

  /// 候选清晰度线路（图源给多条时才有）。空 / 单条时画质面板显示真实选项或空态，
  /// **不隐藏按钮**（用户点名：不支持的项点了给提示）。
  final List<VideoQuality> qualities;

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端。为空时按平台选择（iOS 走原生通道，其余平台如实降级）。
  final PipBackend? pipBackend;

  /// 屏幕亮度后端。为空时按平台选择；不支持时亮度手势回退为页面内遮罩。
  final BrightnessBackend? brightnessBackend;

  /// 图源管理端口（连播 / 弹幕按 id 打开图源用）。为空时用正式实现。
  final SourceManager? sourceManager;
  final DataSource? source;

  /// 本板块阅读库（进度与继续观看）；为空时按板块打开正式实现。
  final ReadingLibrary? library;

  /// 播放会话后端（后台音频 + 锁屏控制）。为空时按平台选择。
  final PlaybackSessionBackend? playbackBackend;

  /// 网速表（测试注入用）。为空时用真实现（向播放地址发 Range 探测）。
  final PlaybackSpeedMeter? speedMeter;
  final PlaybackSourceValidator? sourceValidator;

  /// 浏览页在解析播放地址期间**预启动**的内核实例（见 [PlayerPrelaunch]）。
  ///
  /// 有它就省掉一次「进页面才开始建内核」的等待：第一次重建直接接手，内核不匹配
  /// （用户在别处换了内核）或已被用掉时拒绝接手并就地释放。
  final PlayerPrelaunch? prelaunch;

  /// 控制栏紧接画面，保留 12pt 间距。
  static const double controlTopGap = 12;

  /// 控制栏距屏幕底部的留白。比原值 16 收窄：整块控制区（进度条 + 下面所有按钮）
  /// 跟着往下挪（下方还有 SafeArea 让出 home 指示条，不会贴到屏幕边缘）。
  static const double controlBottomGap = 8;

  /// 标准控制栏（非全屏时压在页面下方那块）的定位键。
  ///
  /// 全屏的浮层控制栏里也有同名按钮（设置 / 播放源），因此测试要区分两者时用
  /// 这个键，而不是某个按钮的 tooltip。
  static const Key controlPanelKey = Key('player-control-panel');

  /// 全屏浮层的左右内边距（用户口径）：**顶栏、进度条、底部按钮三处必须一致**，
  /// 三处都读这一个值。
  static const double controlHorizontalPadding = 8;

  /// 进度条行与按钮行之间的固定行距（用户口径：两行给一个固定值）。
  static const double controlRowGap = 0;

  /// 控制栏里图标按钮的统一尺寸（图标 21 / 触达盒至少 44）：顶部与底部、横屏与
  /// 竖屏都用它，尺寸与间距才一致（用户口径：图标尺寸统一、文字图标大小统一）。
  /// 这里是 **100% 档**的基准值，实际取值再乘模块设置里的「控件尺寸」倍率。
  static const double controlIconSize = 21;
  static const double controlBox = 44;

  /// 「播放内核」按钮的图标（用户口径：原来那颗不好看，换一颗）。
  ///
  /// 选 `change_circle_outlined`（双向循环箭头）：一眼读出「切换解码引擎」，
  /// 比原来的 CPU 芯片（memory）更轻；三套内核共用同一颗，不随内核变。
  static const IconData playerKernelIcon = Icons.change_circle_outlined;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  late final PlayerKernelCatalog _catalog =
      widget.catalog ?? const PlatformPlayerKernelCatalog();

  /// 内核启动器：异步创建 + 8 秒超时 + 失败回退 AVPlayer（见 [PlayerKernelLauncher]）。
  late final PlayerKernelLauncher _launcher = PlayerKernelLauncher(
    factory: widget.playerFactory,
  );

  /// 播放会话：后台音频 + 锁屏 / 控制中心的媒体控制器（平台不支持时全为空操作）。
  late final PlaybackSession _playback = PlaybackSession(
    backend: widget.playbackBackend,
  );
  StreamSubscription<PlaybackSessionCommand>? _commandSubscription;

  VideoPlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  AbstractPlayer? _player;
  PipSession? _session;
  PlayerMedia? _media;
  bool _preferredSubtitleApplied = false;
  String? _savedKernelIdentity;
  PlayerKernel? _activeKernel;

  /// 媒体是否已加载成功（画中画的就绪边界检查用它）。
  bool _loaded = false;
  late final PlaybackSourceValidator _sourceValidator =
      widget.sourceValidator ?? PlaybackSourceValidator();
  int _validationRevision = 0;
  PlayerMedia? _validatedMedia;
  Map<String, String> _playbackRequestHeaders = const {};

  /// 正在准备的内核：非空表示「已开始创建、还没交到手上」。
  ///
  /// 它不是 UI 进度条，而是**给用户的交代**——等待期间画面上要写明在等哪个内核
  /// （MPV 首次初始化要装载原生库，几秒是正常的），并始终留着「切回 AVPlayer」
  /// 的出口。
  PlayerKernel? _pendingKernel;

  /// 重建失败的原因（非空即失败态）。失败态必须带出口（重试 / 切回 AVPlayer）。
  String? _rebuildFailure;

  /// 失败的内核：重试时按它重来（而不是按已被回退改写的当前设置）。
  PlayerKernel? _failedKernel;

  /// 重建序号：连续切换内核时只有最后一次重建的结果算数（过期结果丢弃）。
  int _rebuildSeq = 0;

  /// 空闲快照：没有播放器时控制栏仍要用一个可监听的空值渲染（控制栏常在）。
  final ValueNotifier<PlayerSnapshot> _idleSnapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  /// 设置库打不开：设置读写不可用，但播放链路继续（用默认设置）。
  bool _storeFailed = false;

  /// 本板块的阅读库：视频进度与「继续观看」落在它里面。
  ReadingLibrary? _library;

  /// 起播缓冲参数（模块设置里的「前向缓冲」派生，见 [BufferingConfig.forForwardBuffer]）。
  ///
  /// 调库失败或还没读到时就是默认值——与历史行为一致（默认值 = 起播最快那套）。
  BufferingConfig _buffering = BufferingConfig.defaults;

  /// 浏览页预启动的内核实例：**只有第一次重建**能接手（见 [_rebuildPlayer]）。
  PlayerPrelaunch? _prelaunch;
  PlayerMedia? _preparedInitialMedia;

  /// 当前正在播的图源条目：有它才记进度。
  VideoPlayTarget? _target;
  IntroController? _intro;
  PlayerMedia? _introMedia;
  bool _introOpening = false;
  int _introGeneration = 0;

  void _refresh(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// 改「自动连播」并落库（与模块设置页双向同步）。
  Future<void> _setAutoNext(bool value) async {
    setState(() => _settings = _settings.copyWith(autoNext: value));
    try {
      final store = await VideoPlayerSettingsStore.open();
      store.save(_settings);
    } catch (error) {
      LumeLog.warn('[video] 自动连播写库失败：$error');
    }
  }

  /// 连播 / 弹幕用的图源（按 [VideoPlayerPage.sourceId] 打开）。
  DataSource? _source;

  /// 图源管理器的兜底实例（调用方没注入时用板块级管理器）。
  ///
  /// **本页绝不 close 它**：`LumeSources.manager(section)` 的所有方法都转发到
  /// 板块级的图源状态（注册表与库句柄是共享的），关掉一个管理器等于关掉整个板块
  /// 的图源库——浏览页随后再点条目就会报「This database has already been
  /// closed」（真机实测：退出播放后再点别的视频就是这么炸的）。
  SourceManager? _fallbackManager;

  /// 候选清晰度线路 + 当前线路下标（图源给多条时才有）。
  late List<VideoQuality> _qualities = widget.qualities;
  int _qualityIndex = 0;
  bool _switchingQuality = false;
  bool _gestureHelpOffered = false;
  String? _operation;

  /// 锁屏防误触：锁定后手势层与所有控制都不响应，只留一个解锁按钮。
  bool _locked = false;
  bool _unlockVisible = true;
  Timer? _unlockTimer;
  bool _muted = false, _musicMode = false;
  bool _showNetworkSpeed = true;
  double get _effectiveVolume => _muted ? 0 : _gesture.volume;

  /// 全屏（沉浸）模式：顶栏与控制栏收起，点画面切换浮层控制栏。
  late bool _fullscreen = widget.fullscreenOnly;
  final _nextEpisodeBuffer = NextEpisodeBuffer();

  /// 全屏模式下的浮层控制栏是否可见。
  bool _overlayVisible = true;
  bool _panelOpen = false;
  DateTime? _lastScrubSeek;

  /// 拖动中待下发的目标：同一时刻只允许一个快 seek 在路上，只保留最新目标。
  ///
  /// 之前是「每 150ms 直接发一次 seekFast」，既不排队也不取消：松手那一下
  /// 往往还有几次快 seek 在飞，紧接着的精确定位排在它们后面，源端和解码器
  /// 被这一串请求堵住——真机表现就是松手后一直「缓冲中」、网速 0KB/s。
  Duration? _pendingScrubSeek;
  bool _scrubSeekInFlight = false;

  /// 跳转后的停滞看门狗（三个内核共用）：位置不动先重发同一跳转，
  /// 仍不动才换地址重开，避免把用户留在永远转圈的画面里。
  Timer? _seekWatchdog;
  int _seekWatchdogGeneration = 0;
  String? _hint;
  Timer? _hintTimer;
  bool _swipeNextFired = false;

  /// 控制栏自动隐藏的计时器（用户要求：播放中无操作 N 秒收起，点屏幕唤回）。
  Timer? _autoHideTimer;
  bool _accessibleNavigation = false;

  /// 无操作多久收起控制栏（用户口径：3 秒；画面中间那组播放控件不受影响）。
  static const Duration _autoHideDelay = Duration(seconds: 3);

  /// 设置 → 各模块独立设置 → 「控件尺寸」的倍率（真机反馈「显示模式全都没有
  /// 生效」：这套值原来只写库、没有界面读）。控制栏的按钮盒与图标都乘它。
  double? _initialControlScale;
  double get _controlScale =>
      _initialControlScale ??
      ModuleUiScale.instance.controlScale(_library?.section ?? Section.video);

  /// 当前生效的触达盒与图标尺寸（默认 100% 就是上面那两个常量）。
  double get _box => math.max(
    PlayerLayout.tapSize,
    VideoPlayerPage.controlBox * _controlScale,
  );
  double get _iconSize => VideoPlayerPage.controlIconSize * _controlScale;

  /// 方向锁定（用户要求）：自动 / 强制横屏 / 强制竖屏。
  ///
  /// 与全局设置里的「横屏播放」是**同一个值**（[PlaybackOrientationController]）：
  /// 设置页改的是全局默认，这里改的是同一份偏好——两处不会各说各话。
  PlaybackOrientation _orientation = PlaybackOrientation.fallback;

  /// 最近一次真正下发的方向列表：同样的值不重复下发（内核每帧都在报参数，
  /// 没有这道闸就会把同一条平台调用刷爆）。
  List<DeviceOrientation>? _appliedOrientations;

  /// 进度条拖动预览的目标位置（拖动中显示，松手才真 seek）。
  Duration? _previewTarget;
  int _seekRevision = 0;

  /// 进度落盘节流：播放中每 5 秒写一次，暂停 / 切集 / 退出时立即写。
  Timer? _progressTimer;
  static const Duration _progressInterval = Duration(seconds: 5);

  /// 上次落盘的时间点：避免同一秒重复写库。
  Duration _lastSavedPosition = Duration.zero;

  /// 正在自动连播下一集：防止「播完」的多次快照回调触发连播两次。
  bool _advancing = false;

  /// 自动连播开关（默认开：看完一集接着下一集是追剧的常态）。
  // 用户可在控制栏切换（setState 改它），因此不是 final。
  // ignore: prefer_final_fields
  /// 自动连播：**存在视频板块的设置里**（与「各模块独立设置 → 视频设置」同一份
  /// 数据，两边改哪边都同步；以前只活在本页内存里，重进就复位）。
  bool get _autoNext => _settings.autoNext;

  /// 画中画帧转发泵：画中画激活期间按帧率节拍取帧并转发（仅 MPV 内核）。
  PipFramePump? _framePump;
  bool? _pipPlaying;
  Duration? _pipDuration;
  double? _pipRate;
  late final PlaybackSpeedMeter _networkSpeed =
      widget.speedMeter ?? PlaybackSpeedMeter();
  DateTime? _nextSpeedProbe;
  bool _pipPreparing = false;
  bool _inlinePipReady = false;
  bool _preparingInlinePip = false;
  DateTime? _nextInlinePipAttempt;
  bool _backgroundPlaying = false;
  bool _returnedFromBackground = false;
  bool _recoveringPlayback = false;
  bool _rangeFallbackAttempted = false;
  Duration _healthyPosition = Duration.zero;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lifecycle;
    _lifecycle = state;
    final introSnapshot = _player?.snapshot.value;
    if (introSnapshot != null) _syncOriginalIntro(introSnapshot);
    if (state != AppLifecycleState.resumed) _nextEpisodeBuffer.discard();
    _framePump?.setBackground(state != AppLifecycleState.resumed);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _returnedFromBackground = true;
      if (!AppPreferences.instance.backgroundPlayback &&
          _session?.state != PipState.active &&
          _session?.state != PipState.entering &&
          !_pipPreparing) {
        _backgroundPlaying = false;
        unawaited(_player?.pause());
      }
    }
    if (state == AppLifecycleState.inactive &&
        previous == AppLifecycleState.resumed) {
      final snapshot = _player?.snapshot.value;
      _backgroundPlaying = snapshot?.playing ?? false;
      if (snapshot != null && snapshot.error == null) {
        _healthyPosition = snapshot.position;
      }
    }
    if (state == AppLifecycleState.resumed && _returnedFromBackground) {
      _returnedFromBackground = false;
      if (_session?.state == PipState.active) unawaited(_session?.exit());
      unawaited(_restoreInlinePlayback());
    }
  }

  Future<void> _prepareInlinePip() async {
    if (_nextInlinePipAttempt?.isAfter(DateTime.now()) ?? false) return;
    final backend = _session?.backend;
    final engine = _frameEngineOf(_player);
    if (_inlinePipReady ||
        _preparingInlinePip ||
        _pipPreparing ||
        backend is! MethodChannelPipBackend ||
        (engine == null && _player is! AvPlayer)) {
      return;
    }
    _preparingInlinePip = true;
    _nextInlinePipAttempt = DateTime.now().add(const Duration(seconds: 5));
    final player = _player;
    try {
      if (player is AvPlayer) {
        final id = player.nativePlayerId;
        if (id != null) {
          await _syncPipDanmaku();
          await backend.prepareAvPlayer(id);
          if (mounted && identical(player, _player)) _inlinePipReady = true;
        }
        return;
      }
      if (engine == null) return;
      _framePump ??= PipFramePump(
        engine: engine,
        frameSource: backend.frameSource,
        position: () => _player?.snapshot.value.position ?? Duration.zero,
        playing: () => _player?.snapshot.value.playing ?? false,
        playbackRate: () => _settings.speed,
      );
      final ready = await _framePump!.prime().timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );
      if (mounted && identical(player, _player)) _inlinePipReady = ready;
    } catch (error) {
      LumeLog.info('[pip] inline preparation failed: $error');
    } finally {
      _preparingInlinePip = false;
    }
  }

  Future<void> _restoreInlinePlayback({
    bool retry = false,
    Duration? position,
  }) async {
    final player = _player;
    final media = _media;
    if (!mounted || player == null || media == null || _recoveringPlayback) {
      return;
    }
    final snapshot = player.snapshot.value;
    final shouldPlay = retry || _backgroundPlaying;
    _recoveringPlayback = true;
    _suppressProgressSave = true;
    try {
      if (retry || snapshot.error != null) {
        // 跳转卡死的重开要回到**用户想去的位置**，而不是卡住前的旧位置。
        final resumeAt = position ?? _healthyPosition;
        if (_lifecycle == AppLifecycleState.resumed ||
            _session?.state != PipState.active) {
          _stopFrameForwarding();
          final backend = _session?.backend;
          if (backend is MethodChannelPipBackend) await backend.resetFrames();
        }
        final recoveryMedia = retry
            ? await _renewPlaybackAddress(media)
            : media;
        if (!mounted ||
            !identical(player, _player) ||
            !identical(media, _media)) {
          return;
        }
        _cancelSourceValidation();
        _media = recoveryMedia;
        _playbackRequestHeaders = recoveryMedia.headers ?? const {};
        _networkSpeed.reset();
        _nextSpeedProbe = null;
        await player.load(recoveryMedia);
        if (!mounted ||
            !identical(player, _player) ||
            !identical(recoveryMedia, _media)) {
          return;
        }
        if (resumeAt > Duration.zero) await player.seek(resumeAt);
      }
      if (shouldPlay && !player.snapshot.value.playing) await player.play();
      if (!shouldPlay && player.snapshot.value.playing) await player.pause();
      if (mounted) {
        setState(() => _overlayVisible = true);
        await _applyOrientation();
        _scheduleAutoHide();
      }
    } catch (error, stack) {
      LumeLog.error(error, stack);
      if (mounted) _showToast('恢复播放失败，请重试或更换线路');
    } finally {
      _suppressProgressSave = false;
      _recoveringPlayback = false;
    }
  }

  /// 手势进行态（亮度 / 音量 / 进度 / 长按倍速）。
  Future<PlayerMedia> _renewPlaybackAddress(PlayerMedia previous) async {
    final target = _target;
    if (target == null) return previous;
    final source = await _openSource();
    if (source == null) return previous;
    final content = await source
        .content(itemId: target.itemId, chapterId: target.chapterId)
        .timeout(const Duration(seconds: 15));
    if (!mounted || !identical(target, _target)) return previous;
    final qualities = SourcePlayback.contentQualities(content, source: source);
    final label = _qualityIndex < _qualities.length
        ? _qualities[_qualityIndex].label
        : null;
    final selected = qualities
        .where((quality) => quality.label == label)
        .firstOrNull;
    final address = selected?.url ?? SourcePlayback.contentAddress(content);
    if (address == null) throw StateError('源未返回可播放地址');
    _qualities = qualities;
    _qualityIndex = selected == null ? 0 : qualities.indexOf(selected);
    return PlayerMedia(
      uri: address,
      title: previous.title,
      headers: selected != null && selected.headers.isNotEmpty
          ? selected.headers
          : SourcePlayback.contentHeaders(content, source: source),
    );
  }

  /// 手势进行态（亮度 / 音量 / 进度 / 长按倍速）。
  PlayerGestureState _gesture = PlayerGestureState.idle;

  /// 一次手势的起点数据（按下时记录，拖动过程中用它算增量）。
  Duration _gestureStartPosition = Duration.zero;
  double _gestureStartVolume = 1.0;
  double _gestureStartBrightness = 1.0;
  double _gestureStartFraction = 0.5;
  double _gestureSpeedBeforeBoost = 1.0;
  bool _gestureBoosted = false;

  /// 手势层：既是命中区，也用来把全局坐标换算回本层坐标。
  final GlobalKey _gestureLayerKey = GlobalKey();

  /// 手势起点（按下时的触点坐标，全局坐标系）。
  ///
  /// 用「当前位置 − 起点」算总位移，而不是把每帧的 `delta` 累加：拖拽识别器在
  /// 判定成立的那一帧会把之前的位移一起吞掉（slop），逐帧累加会少算一截。
  Offset? _gestureOrigin;

  /// 屏幕亮度（0..1）。
  ///
  /// 平台支持改系统亮度时它就是系统亮度；不支持时退化为「页面内遮罩」的强度。
  double _brightness = 1.0;

  /// 亮度后端（按平台选择或测试注入）。
  late final BrightnessBackend _brightnessBackend =
      widget.brightnessBackend ?? createPlatformBrightnessBackend();

  /// 平台是否支持改系统亮度（探测一次；不支持就走遮罩降级）。
  bool _systemBrightness = false;

  /// 片头 / 片尾标记（用户口径：播放中「记一下」，下次自动跳过）。
  SkipMarks _skipMarks = SkipMarks.none;

  /// 本次播放是否已经处理过片头（只在起播时判一次：用户拖回片头看时不再弹回去）。
  bool _introHandled = false;

  /// 本次播放是否已经处理过片尾（与片头同一条纪律，且是**死循环的守门人**）。
  ///
  /// 片尾的判定源是「位置 ≥ 标记」，而跳片尾恰恰把位置推到标记之后（跳到结尾）
  /// ——没有这个标记，最后一集会在片尾之后**每个快照都重现处理一次**：换集请求
  /// 与 seek 交替，永远停不下来（真机是每帧一次章节列表请求，用例里直接挂死）。
  bool _outroHandled = false;

  /// 弹幕：设置 + 本集弹幕 + 内存缓存（换集时按 itemId/chapterId 取）。
  DanmakuSettings _danmakuSettings = DanmakuSettings.defaults;
  DanmakuTrack _danmaku = DanmakuTrack.empty;
  DanmakuTrack _sourceDanmakuTrack = DanmakuTrack.empty;
  DanmakuTrack _publicDanmakuTrack = DanmakuTrack.empty;
  DanmakuTrack _localDanmakuTrack = DanmakuTrack.empty;
  final DanmakuCache _sourceDanmakuCache = DanmakuCache();
  final DanmakuCache _publicDanmakuCache = DanmakuCache();
  final Set<DandanplayClient> _danmakuClients = {};
  int _danmakuLoadSeq = 0;
  int _publicDanmakuSeq = 0;
  final ValueNotifier<int> _danmakuRevision = ValueNotifier(0);
  void _notifyDanmakuSheet() {
    if (mounted) {
      _danmakuRevision.value++;
      unawaited(_syncPipDanmaku());
    }
  }

  Future<void> _syncPipDanmaku() async {
    final backend = _session?.backend;
    if (backend is! MethodChannelPipBackend) return;
    await backend.updateDanmaku(
      {..._danmakuSettings.toJson(), 'playbackRate': _settings.speed},
      [
        for (final item in _danmaku.items)
          {
            'time': item.time.inMilliseconds,
            'text': item.text,
            'mode': item.mode.id,
            'color': item.color,
            'fontSize': item.fontSize,
          },
      ],
    );
  }

  DanmakuTrack _combinedDanmaku() => DanmakuTrack.parse(
    {
      ..._sourceDanmakuTrack.items,
      ..._publicDanmakuTrack.items,
      ..._localDanmakuTrack.items,
    }.toList(),
  );
  String _publicDanmakuStatus = '等待加载';
  String? _publicDanmakuMatchLabel, _danmakuServiceLabel;
  bool _publicDanmakuLoading = false;
  int _sourceDanmakuCount = 0;
  int _publicDanmakuCount = 0;
  String _danmakuKey(VideoPlayTarget target) =>
      '${target.sourceId}:${target.itemId}';
  String _matchingKey(VideoPlayTarget target, String base) =>
      'video.danmaku.match.$base.${target.sourceId}.${target.itemId}.${target.chapterId}';

  final DanmakuCache _danmakuCache = DanmakuCache();

  /// 用户在**打开的读盘完成之前**就动过弹幕设置。
  ///
  /// 为什么要有这个标记：阅读库是异步打开的（首次进入要建库，真的会慢一截），
  /// 而控制栏在库就绪前就画出来了——这期间用户点弹幕开关会走
  /// [_applyDanmakuSettings]，此刻 [_library] 还是 null、落库一并无从谈起；
  /// 随后读盘回来若直接 setState 覆盖，用户的这次点击就被悄悄抹掉了（真机
  /// 反馈的「弹幕关掉后重开视频又变回开」正是这条路：改没存下、显示值又被
  /// 读盘结果盖回去）。改了就以用户的为准，并把待写值补落到库里。
  bool _danmakuSettingsDirty = false;

  /// 等着补落的弹幕设置（[_applyDanmakuSettings] 在库还没打开时记下）。
  DanmakuSettings? _pendingDanmakuSave;

  /// 本平台是否提供任一播放内核（没有就是骨架占位）。
  bool get _anyKernelAvailable => PlayerKernel.values.any(_catalog.isAvailable);

  /// 设置里选的内核不可用时回退到第一个可用内核（库被改坏也不至于打不开）。
  PlayerKernel get _effectiveKernel {
    if (_catalog.isAvailable(_settings.kernel)) return _settings.kernel;
    return PlayerKernel.values.firstWhere(_catalog.isAvailable);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DanmakuSourcesStore.revision.addListener(_danmakuServiceChanged);
    if (widget.fullscreenOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_applyOrientation());
      });
    }
    // The normal route already owns this local library; read the final scale
    // synchronously before the first control frame, rather than resizing later.
    final layoutLibrary = widget.library ?? ReadingLibrary.find(Section.video);
    if (layoutLibrary != null) {
      _initialControlScale = SectionModuleSettings.load(layoutLibrary)
          .controlScale;
    }

    final media = widget.media;
    _syncQualityIndex(media);
    // 方向偏好：读当前值并订阅变化（设置页改了「横屏播放」当场生效）。
    final orientation = PlaybackOrientationController.instance;
    _orientation = orientation.orientation;
    orientation.addListener(_onOrientationPreferenceChanged);
    // 作品身份由 [_startPlayback] 在起播时落定：这里不预设，否则「换作品前先落盘
    // 上一部进度」那一步会在首次起播时写出一条位置为 0 的空记录。
    _cancelSourceValidation();
    _media = media;
    _networkSpeed.reset();
    _prelaunch = widget.prelaunch;
    if (_anyKernelAvailable) _boot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final accessible = MediaQuery.accessibleNavigationOf(context);
    if (accessible == _accessibleNavigation) return;
    _accessibleNavigation = accessible;
    if (accessible) {
      // VoiceOver 导航需要稳定的控件，不能在聚焦途中把返回键与控制栏移除。
      _cancelAutoHide();
      _unlockTimer?.cancel();
      if (_locked) _unlockVisible = true;
    } else {
      _scheduleAutoHide();
    }
  }

  @override
  void dispose() {
    _rebuildSeq++;
    _library?.settingsRevision.removeListener(_onSharedSettingsChanged);
    DanmakuSourcesStore.revision.removeListener(_danmakuServiceChanged);
    _introGeneration++;
    _episodeImages?.dispose();
    _intro?.dispose();
    _nextEpisodeBuffer.dispose();
    _unlockTimer?.cancel();
    _hintTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _danmakuLoadSeq++;
    for (final client in _danmakuClients) {
      client.close();
    }
    _danmakuClients.clear();
    _danmakuRevision.dispose();
    // 顺序要紧：进度必须**在摘监听、清空 _player 之前**落盘——那两步之后
    // 就读不到播放位置了（记录会静默丢掉）。此刻也不能再 setState。
    _progressTimer?.cancel();
    _progressTimer = null;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    _seekWatchdog?.cancel();
    _seekWatchdog = null;
    _saveProgress(force: true);

    PlaybackOrientationController.instance.removeListener(
      _onOrientationPreferenceChanged,
    );

    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    player?.snapshot.removeListener(_onSnapshotChanged);
    player?.stats.removeListener(_onStatsChanged);
    // 锁屏播放条属于「当前这次播放」：页面退出即收起（听书那套随后可接管）。
    unawaited(_playback.stop());
    // 从全屏直接返回时把方向还原成竖屏（否则整个 App 留在横屏里）。
    if (_fullscreen) {
      unawaited(
        _sendOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]),
      );
    }
    unawaited(_commandSubscription?.cancel());
    // Silence immediately; PiP teardown must never delay or prevent player release.
    _stopFrameForwarding();
    unawaited(() async {
      try {
        await player?.pause().timeout(const Duration(seconds: 2));
      } catch (error, stack) {
        LumeLog.error(error, stack);
      }
      try {
        await player?.stop().timeout(const Duration(seconds: 2));
      } catch (error, stack) {
        LumeLog.error(error, stack);
      }
      try {
        await session?.dispose().timeout(const Duration(seconds: 3));
      } catch (error, stack) {
        LumeLog.error(error, stack);
      }
      final backend = session?.backend;
      try {
        if (backend is MethodChannelPipBackend) {
          await backend.teardownFrames().timeout(const Duration(seconds: 2));
        }
      } catch (error, stack) {
        LumeLog.error(error, stack);
      } finally {
        if (player != null) await _disposeQuietly(player, '退出播放页');
      }
    }());
    // 预启动的实例没人接手（页面没起播就退了 / 内核库打不开）：就地释放，
    // 绝不留下一个还在后台活着、谁也拿不到的播放器。
    final prelaunch = _prelaunch;
    _prelaunch = null;
    if (prelaunch != null) unawaited(prelaunch.discard());
    // **只借不关**：阅读库是板块级共享实例（VideoPage 还会用它打开历史）。
    // 这里关闭会让返回后的视频页拿着一个已关闭的库，历史抽屉静默读到空列表，
    // 必须切一次 Tab 重新打开才恢复（真机 bug）。生命周期归板块页管。
    _idleSnapshot.dispose();
    if (widget.speedMeter == null) _networkSpeed.dispose();
    // 注入进来的网速表由调用方释放。
    _validationRevision++;
    _sourceValidator.cancel();
    super.dispose();
  }

  void _cancelSourceValidation() {
    _validationRevision++;
    _validatedMedia = null;
    _sourceValidator.cancel();
  }

  void _scheduleSourceValidation(PlayerSnapshot snapshot) {
    final media = _media;
    if (!_settings.backgroundSourceValidation ||
        media == null ||
        !media.isNetwork ||
        !snapshot.playing ||
        snapshot.buffering ||
        snapshot.error != null ||
        snapshot.position <= Duration.zero ||
        _lifecycle != AppLifecycleState.resumed ||
        identical(_validatedMedia, media)) {
      return;
    }
    _validatedMedia = media;
    final revision = _validationRevision;
    // Runs only after the player reports progressing playback. No start path awaits it.
    unawaited(() async {
      final message = await _sourceValidator.check(
        media.uri,
        _playbackRequestHeaders,
      );
      if (!mounted ||
          revision != _validationRevision ||
          !identical(_media, media) ||
          !_settings.backgroundSourceValidation ||
          message == null) {
        return;
      }
      _showToast(message);
    }());
  }

  /// 播放状态变化：在「从播放转为非播放」时立即落盘进度，并检查是否播完。
  /// 模块「控件尺寸」变化：控制栏按钮跟着重排一次（设置页改完当场生效）。
  void _onModuleScaleChanged() {
    _initialControlScale = ModuleUiScale.instance.controlScale(Section.video);
    if (mounted) setState(() {});
  }

  void _onSnapshotChanged() {
    _syncPipPlaybackState();
    final snapshot = _player?.snapshot.value;
    if (snapshot != null) _syncOriginalIntro(snapshot);
    final playing = snapshot?.playing ?? false;
    final work = _target;
    if (playing &&
        snapshot?.error == null &&
        work != null &&
        _library != null &&
        _activeKernel != null) {
      final identity = '${work.identity}:${_activeKernel?.name}';
      if (_savedKernelIdentity != identity) {
        _savedKernelIdentity = identity;
        _library!.setSetting(
          'video.kernel.work.${work.identity}',
          _activeKernel!.name,
        );
      }
    }
    if (snapshot != null &&
        snapshot.error == null &&
        !_recoveringPlayback &&
        (_lifecycle == AppLifecycleState.resumed ||
            (playing && snapshot.position > Duration.zero))) {
      _healthyPosition = snapshot.position;
      if (!_gestureHelpOffered &&
          _library != null &&
          playing &&
          !snapshot.buffering &&
          snapshot.position > Duration.zero) {
        _gestureHelpOffered = true;
        if (_library!.setting('video.player.gestureHelpSeen.v1') != 'true') {
          _library!.setSetting('video.player.gestureHelpSeen.v1', 'true');
          scheduleMicrotask(() {
            if (mounted) _showToast('左右滑动调进度，长按临时倍速；设置中可查看手势说明');
          });
        }
      }
      if (_lifecycle == AppLifecycleState.resumed &&
          playing &&
          !snapshot.buffering) {
        unawaited(_prepareInlinePip());
      }
    }
    if (_wasPlaying && !playing && !_suppressProgressSave) {
      _saveProgress(force: true);
    }
    if (playing != _wasPlaying) {
      if (playing) {
        _scheduleAutoHide();
      } else {
        _scheduleAutoHide();
      }
    }
    if (snapshot?.error != null) {
      _cancelAutoHide();
      _logPlaybackFailure(snapshot!);
      final error = snapshot.error!.toLowerCase();
      if (!_rangeFallbackAttempted &&
          _settings.kernel == PlayerKernel.avplayer &&
          _catalog.isAvailable(PlayerKernel.mpv) &&
          (error.contains('-12939') ||
              error.contains('byte range and no content length') ||
              error.contains('服务器不支持分段请求') ||
              error.contains('server is not correctly configured'))) {
        _rangeFallbackAttempted = true;
        // 快照通知期间不能同步释放发出通知的播放器。
        scheduleMicrotask(() async {
          if (!mounted || _settings.kernel != PlayerKernel.avplayer) return;
          _showToast('当前媒体的分段响应与 AVPlayer 不兼容，正在切换 MPV');
          await _applySettings(_settings.copyWith(kernel: PlayerKernel.mpv));
          if (mounted) await _player?.play();
        });
      }
    }
    _wasPlaying = playing;
    if (snapshot != null) {
      // 首帧到了（播放中且不在缓冲）才去排测速：起播抢带宽的事不做（见
      // 片头片尾：每次快照变化判一次（判定本身是纯函数，跳过一次后不再重复）。
      _scheduleSourceValidation(snapshot);
      if (_settings.backgroundSourceValidation &&
          playing &&
          _player?.stats.value.downloadBytesPerSecond == null &&
          !snapshot.buffering &&
          snapshot.position > Duration.zero &&
          _lifecycle == AppLifecycleState.resumed &&
          !(_nextSpeedProbe?.isAfter(DateTime.now()) ?? false)) {
        final media = _media;
        if (media != null && media.isNetwork) {
          _nextSpeedProbe = DateTime.now().add(const Duration(seconds: 30));
          unawaited(
            _networkSpeed.measure(
              media.uri,
              headers: media.headers,
              force: true,
            ),
          );
        }
      }
      final remaining = snapshot.duration - snapshot.position;
      final target = _target;
      final buffered = _player?.stats.value.buffered ?? Duration.zero;
      if (target != null &&
          playing &&
          !snapshot.buffering &&
          snapshot.error == null &&
          !_advancing &&
          MediaPreload.instance.video &&
          _lifecycle == AppLifecycleState.resumed &&
          _session?.state != PipState.active &&
          snapshot.position >= const Duration(seconds: 10) &&
          remaining >= const Duration(seconds: 5) &&
          remaining <=
              Duration(seconds: MediaPreload.instance.triggerSeconds) &&
          buffered >=
              Duration(seconds: _settings.kernel == PlayerKernel.mdk ? 3 : 8)) {
        unawaited(
          _nextEpisodeBuffer.prepare(
            target,
            _settings,
            _openSource,
            widget.playerFactory ??
                ((kernel) => PlayerFactory.create(kernel: kernel)),
          ),
        );
      }
      // Once the unified controller is available it owns skip decisions,
      // including the cancelable countdown and duration-relative ending.
      // 锁屏播放条跟随播放状态（进度在会话内部节流，不必在这里省）。
      unawaited(
        _playback.update(
          position: snapshot.position,
          playing: playing,
          duration: snapshot.duration > Duration.zero
              ? snapshot.duration
              : null,
        ),
      );
      if (_isFinished(snapshot)) _autoAdvance();
    }
  }

  /// 锁屏 / 控制中心的按钮 → 播放器动作。
  ///
  /// 「切集」在这里落地：下一集 = 连播的那一集，上一集 = 前选集（播放超过 5 秒
  /// 时先回到开头——这是主流播放器的既有手感，锁屏误触也不至于跳集）。
  void _onPlaybackCommand(PlaybackSessionCommand command) {
    final player = _player;
    if (player == null) return;
    final target = _target;
    switch (command) {
      case PlaybackSessionCommand.play:
        unawaited(player.play());
      case PlaybackSessionCommand.pause:
        unawaited(player.pause());
      case PlaybackSessionCommand.toggle:
        unawaited(
          player.snapshot.value.playing ? player.pause() : player.play(),
        );
      case PlaybackSessionCommand.next:
        unawaited(_playEpisodeAt((target?.chapterIndex ?? 0) + 1));
      case PlaybackSessionCommand.previous:
        final position = player.snapshot.value.position;
        if (position > const Duration(seconds: 5) || target == null) {
          unawaited(player.seek(Duration.zero));
        } else {
          unawaited(_playEpisodeAt(target.chapterIndex - 1));
        }
    }
  }

  bool _wasPlaying = false;

  /// 正在重建播放器 / 重载媒体：期间**不要**按快照自动落盘。
  ///
  /// 为什么必须抑制：换内核（或换清晰度线路）时会释放旧播放器、装载新的，
  /// 中间必然出现「播放中 → 停下」「位置 → 0」的瞬时快照。若不挡住，
  /// [_onSnapshotChanged] 会把**位置 0** 当成最新进度写进库——真机反馈的
  /// 「切内核后从头播」正是这么来的（记录被自己清掉了）。
  bool _suppressProgressSave = false;
  _ResumePoint? _kernelResume;

  /// 是否已播到结尾（留 1 秒余量：播放器到结尾前会先停下）。
  ///
  /// 时长未知时一律返回 false——宁可不连播，也不在半途跳走。
  static bool _isFinished(PlayerSnapshot snapshot) {
    if (snapshot.duration <= Duration.zero) return false;
    if (snapshot.error != null) return false;
    return snapshot.position >= snapshot.duration - const Duration(seconds: 1);
  }

  Future<void> _boot() async {
    // 两套设置共用视频阅读库：只打开一次，避免冷启动时重复建库。
    final libraryFuture = widget.library == null
        ? ReadingLibrary.open(Section.video)
        : Future.value(widget.library!);
    // 控制栏的「控件尺寸」倍率来自本板块的模块设置：库好了就读一次并订阅变化
    // （设置页改完当场生效；见 [ModuleUiScale] 的说明）。
    ModuleUiScale.instance.addListener(_onModuleScaleChanged);
    unawaited(
      libraryFuture
          .then((library) => ModuleUiScale.instance.ensure(library.section))
          .catchError((Object _) {}),
    );
    final settingsFuture = libraryFuture.then(VideoPlayerSettingsStore.new);
    // 立即订阅错误，防止阅读库仍在打开时出现未处理的异步异常。
    final settingsResult = settingsFuture.then<Object>(
      (store) => store,
      onError: (Object error, StackTrace stack) => error,
    );
    // 阅读库（进度）与播放器设置库分开打开：前者失败不该拦住播放。
    try {
      final library = await libraryFuture;
      if (!mounted) return;
      library.settingsRevision.addListener(_onSharedSettingsChanged);
      final store = DanmakuSettingsStore(library);
      // 用户在库就绪前改过弹幕设置：以他改的那一份为准，并把待写值补落库
      //（读盘结果只用于**没人动过**的情况，见 [_danmakuSettingsDirty]）。
      final loaded = store.load();
      final pending = _pendingDanmakuSave;
      _pendingDanmakuSave = null;
      setState(() {
        _library = library;
        if (!_danmakuSettingsDirty) _danmakuSettings = loaded;
        // 「前向缓冲」在**模块设置**里（与设置页同一份数据），派生成内核参数；
        // 装载前经 setBuffering 交给内核（见 _rebuildPlayer）。
        _buffering = BufferingConfig.forForwardBuffer(
          SectionModuleSettings.load(library).buffer,
        );
      });
      if (pending != null) {
        store.save(pending);
        LumeLog.info('[player] 弹幕设置（库就绪前改的）已补落库');
      }
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 阅读库打不开，本次不记录播放进度');
    }
    try {
      final result = await settingsResult;
      if (result is! VideoPlayerSettingsStore) throw result;
      final store = result;
      if (!mounted) return;
      _store = store;
      _settings = store.load();
      final work = widget.target;
      final rememberedKernel = work == null
          ? null
          : _library?.setting('video.kernel.work.${work.identity}');
      final preferred = PlayerKernel.values
          .where((k) => k.name == rememberedKernel && _catalog.isAvailable(k))
          .firstOrNull;
      if (preferred != null) _settings = _settings.copyWith(kernel: preferred);
      final experience = PlayerExperienceStore.current;
      _muted = experience.flag('muted');
      _musicMode = experience.flag('musicMode');
      _showNetworkSpeed = experience.flag('showNetworkSpeed', true);
      _gesture = _gesture.copyWith(
        volume: experience.number('volume', 1, 0, 1),
      );
      if (mounted) setState(() {});
    } catch (error, stackTrace) {
      // 本板块的库打不开：起不了播放器，页面给出可读提示。
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _storeFailed = true);
      return;
    }
    if (!mounted) return;
    _session = PipSession(
      backend: widget.pipBackend ?? createPlatformPipBackend(),
      canEnter: () =>
          _loaded && _player != null && _player!.snapshot.value.error == null,
      onEvent: _onPipEvent,
    );
    _commandSubscription = _playback.commands.listen(_onPlaybackCommand);
    // 亮度探测**不挡在创建内核前面**：它是两次平台通道往返，与「建播放器」
    // 毫无依赖（结果只服务亮度手势）。此前串行等待等于让起播白等两个往返。
    unawaited(_probeBrightness());
    // Initial media is loaded by _startPlayback after quality selection and
    // target identity are ready. Loading it here too resets the surface twice.
    await _rebuildPlayer(loadCurrentMedia: false);
    // 内核就绪后再把媒体交出去（有媒体、且播放器真的在手上时）。
    //
    // 播放器起不来时**不**走这一步：失败态已经有带出口的说明卡，再弹一条
    // 「还在准备」既不准确，又会用 SnackBar 盖住控制栏——真机上就是「点哪都没
    // 反应」（实测：发起播的 SnackBar 压在控制栏上，设置 / 全屏都点不到）。
    final media = widget.media;
    if (media != null && _player != null) {
      final selected = PlaybackQualityPreference.select(_qualities, _settings);
      final initial = selected == null
          ? media
          : PlayerMedia(
              uri: selected.url,
              title: media.title,
              headers: selected.headers.isEmpty
                  ? media.headers
                  : selected.headers,
            );
      _syncQualityIndex(initial);
      await _startPlaybackSafely(initial, target: widget.target);
    }
  }

  /// 探测系统亮度能力，并把当前值对齐到亮度手势的起点。
  ///
  /// 它是**发出去就不管**的（见 [_boot]）：拿不到结论时手势走「页面内遮罩」的
  /// 降级路径，不该因此让起播失败——所以这里自己吞掉异常，只记日志。
  Future<void> _probeBrightness() async {
    try {
      final supported = await _brightnessBackend.isSupported();
      final current = supported
          ? await _brightnessBackend.currentBrightness()
          : null;
      if (!mounted) return;
      setState(() {
        _systemBrightness = supported;
        if (current != null) _brightness = current;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 亮度能力探测失败，本次手势走页面内遮罩');
    }
  }

  /// 按当前设置创建播放器，并把媒体与播放位置接回去。
  ///
  /// 三条硬约束（沿用旧实现，见每次修复的注释）：
  /// 1. **一定收敛到终态**：无论成功、回退、失败还是中途抛错，函数退出时页面
  ///    要么拿着一个播放器，要么拿着一条带出口的失败说明——不会停在「转圈」上；
  /// 2. **实例不泄漏**：任何路径下建出来但没被采用的播放器都要 dispose；
  /// 3. **落库失败不拖垮播放**：写设置库失败只记日志并提示。
  Future<void> _rebuildPlayer({bool loadCurrentMedia = true}) async {
    _nextEpisodeBuffer.discard();
    final seq = ++_rebuildSeq;
    if (_session?.state == PipState.active ||
        _session?.state == PipState.entering) {
      await _session?.exit();
      if (!mounted || seq != _rebuildSeq) return;
    }
    _stopFrameForwarding();
    final backend = _session?.backend;
    if (backend is MethodChannelPipBackend) await backend.resetFrames();
    if (!mounted || seq != _rebuildSeq) return;
    // 先落盘：此刻旧播放器还活着，位置是准的。随后整个重建期间抑制自动落盘
    //（见 [_suppressProgressSave]）。
    _saveProgress(force: true);
    final previous = _player;
    final resume =
        previous != null && previous.snapshot.value.position > Duration.zero
        ? _ResumePoint.of(previous)
        : _kernelResume;
    _kernelResume = resume;
    _suppressProgressSave = true;
    _player = null;
    if (previous != null) {
      // 摘的必须是**当初挂上去的那个**回调（[onSnapshotChanged]）。
      previous.snapshot.removeListener(_onSnapshotChanged);
      previous.stats.removeListener(_onStatsChanged);
      await _disposeQuietly(previous, '切换内核时释放旧播放器');
    }

    final kernel = _effectiveKernel;
    if (mounted) {
      setState(() {
        _player = null;
        _loaded = false;
        _pendingKernel = kernel;
        _rebuildFailure = null;
      });
    }

    PlayerLaunch? launch;
    try {
      // 浏览页预启动的实例：**只有第一次重建**能接手（此后 _prelaunch 已清空）。
      // 内核不匹配（用户在别处换了内核 / 目录已熔断）就拒绝接手并就地释放——
      // 宁可少省一次等待，也不让两个内核实例同时活着。
      final prelaunch = _prelaunch;
      _prelaunch = null;
      if (prelaunch != null) {
        if (prelaunch.kernel == kernel) {
          launch = await prelaunch.take();
          if (launch != null &&
              widget.media != null &&
              prelaunch.hasPreparedMedia(widget.media!)) {
            _preparedInitialMedia = widget.media;
          }
        } else {
          unawaited(prelaunch.discard());
        }
      }
      launch ??= await _launcher.launch(kernel);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      launch = null;
    }

    // 过期重建：用户又切了内核，本次结果作废（实例必须释放）。
    if (seq != _rebuildSeq) {
      final stale = launch?.player;
      if (stale != null) await _disposeQuietly(stale, '过期重建结果');
      return;
    }
    if (!mounted) {
      _suppressProgressSave = false;
      final orphan = launch?.player;
      if (orphan != null) await _disposeQuietly(orphan, '页面已退出');
      return;
    }

    if (launch == null) {
      _suppressProgressSave = false;
      setState(() {
        _player = null;
        _pendingKernel = null;
        _failedKernel = kernel;
        _rebuildFailure =
            '${kernel.label} 无法启动'
            '${PlayerFactory.unavailableReason(kernel) == null ? '' : '（${PlayerFactory.unavailableReason(kernel)}）'}';
      });
      return;
    }

    if (launch.didFallback) {
      // 回退：设置改成实际生效的内核并提示；**失败的内核绝不写进配置**。
      _settings = _settings.copyWith(kernel: launch.kernel);
      _failedKernel = launch.fallbackFrom;
      _showToast(launch.message);
    } else {
      _failedKernel = null;
    }

    final player = launch.player;
    _activeKernel = launch.kernel;
    try {
      _store?.save(_settings);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 播放器设置写库失败，本次仍按已生效的内核播放');
    }
    setState(() {
      _player = player;
      _loaded = false;
      _pendingKernel = null;
      _rebuildFailure = null;
    });
    // 换内核 / 换集：上一轮拖动留下的落点与看门狗都要作废。
    _pendingScrubSeek = null;
    _lastScrubSeek = null;
    _seekWatchdog?.cancel();
    _seekWatchdog = null;
    _seekWatchdogGeneration++;
    player.snapshot.addListener(_onSnapshotChanged);
    // 分辨率参数也算全屏方向的输入（「自动」档要按宽高比判断，见 [_onStatsChanged]）。
    player.stats.addListener(_onStatsChanged);
    _onStatsChanged();

    try {
      // 缓冲参数要先于装载落定（见 [AbstractPlayer.setBuffering]）：模块设置里的
      // 「前向缓冲」就是经这里真正生效的（0 = 交给内核自动决定）。
      await player.setBuffering(_buffering);
      if (!mounted || !identical(player, _player)) return;
      await player.applySettings(_settings);
      player.setFastSeekSnapToKeyframe(_settings.fastSeekSnap);
      if (!mounted || !identical(player, _player)) return;
      await player.setVolume(_effectiveVolume);
      final media = _media;
      if (media != null && loadCurrentMedia) await _loadMedia(media);
      if (!mounted || !identical(player, _player)) return;
      if (resume != null && !resume.isAtStart) {
        await player.seek(resume.position);
        if (resume.playing && mounted && identical(player, _player)) {
          await player.play();
        }
      }
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (mounted && seq == _rebuildSeq) {
        setState(() => _rebuildFailure = '播放器已就绪，但接续上次播放失败：$error');
      }
    } finally {
      if (seq == _rebuildSeq) {
        _suppressProgressSave = false;
        _kernelResume = null;
      }
    }
  }

  /// 释放一个不再使用的播放器：失败只记日志，绝不打断重建链路。
  Future<void> _disposeQuietly(AbstractPlayer player, String reason) async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 释放播放器失败（$reason）');
    }
  }

  /// 重试：按失败的那个内核再来一次（先解除熔断，否则重试仍会被拦下）。
  Future<void> _retryFailedKernel() async {
    final kernel = _failedKernel;
    if (kernel != null && kernel != PlayerKernel.avplayer) {
      PlayerFactory.clearMpvInitFailure();
      if (_settings.kernel != kernel) {
        _settings = _settings.copyWith(kernel: kernel);
      }
    }
    await _rebuildPlayer();
  }

  /// 切回 AVPlayer：失败态与等待态都留着的出口。
  Future<void> _switchToAvPlayer() async {
    if (_settings.kernel == PlayerKernel.avplayer) {
      await _rebuildPlayer();
      return;
    }
    await _applySettings(_settings.copyWith(kernel: PlayerKernel.avplayer));
  }

  /// 重试打不开的设置库。
  Future<void> _retryBoot() async {
    setState(() => _storeFailed = false);
    await _boot();
  }

  Future<void> _loadMedia(
    PlayerMedia media, {
    bool alreadyLoaded = false,
  }) async {
    PlaybackDiagnostics.record(
      'media-load',
      source: _target?.sourceId,
      kernel: _settings.kernel.name,
      uri: media.uri,
    );
    final loadWatch = Stopwatch()..start();
    _nextEpisodeBuffer.discard();
    // 浏览器 UA：片源/会话自带的 User-Agent 优先，否则补上全局偏好。
    final requestMedia = PlaybackPreferenceWiring.applyUserAgent(
      media,
      PlayerExperienceStore.current,
    );
    _preferredSubtitleApplied = false;
    final player = _player;
    if (player == null) return;
    if (_session?.state != PipState.active) {
      _stopFrameForwarding();
      final backend = _session?.backend;
      if (backend is MethodChannelPipBackend) await backend.resetFrames();
    }
    if (!mounted || !identical(player, _player)) return;
    _cancelSourceValidation();
    _media = media;
    _networkSpeed.reset();
    _nextSpeedProbe = null;
    if (mounted) setState(() => _loaded = false);
    _playbackRequestHeaders = requestMedia.headers ?? const {};
    if (!alreadyLoaded) {
      final headers = Platform.isIOS && _target != null
          ? await IosVerifiedWebView.resourceHeaders(
              media.uri.toString(),
              requestMedia.headers ?? const {},
            )
          : requestMedia.headers;
      if (!mounted ||
          !identical(player, _player) ||
          !identical(media, _media)) {
        return;
      }
      _playbackRequestHeaders = headers ?? const {};
      try {
        await player.load(
          PlayerMedia(uri: media.uri, title: media.title, headers: headers),
        );
      } catch (error) {
        PlaybackDiagnostics.record(
          'media-failed',
          source: _target?.sourceId,
          kernel: _settings.kernel.name,
          uri: media.uri,
          elapsedMs: loadWatch.elapsedMilliseconds,
          error: '$error',
        );
        rethrow;
      }
    }
    if (!mounted || !identical(player, _player) || !identical(media, _media)) {
      return;
    }
    // 起播那几秒里同一个 CDN 域名上多一条 256KB 探测，就是和首帧缓冲抢带宽。
    if (!mounted) return;
    PlaybackDiagnostics.record(
      'media-ready',
      source: _target?.sourceId,
      kernel: _settings.kernel.name,
      uri: media.uri,
      elapsedMs: loadWatch.elapsedMilliseconds,
      error: player.snapshot.value.error,
    );
    setState(() => _loaded = player.snapshot.value.error == null);
  }

  /// 设置变更：落库并立即生效；换内核走重建，其余项直接应用到当前内核。
  Future<void> _applySettings(PlayerSettings next) async {
    final subtitlePreferenceChanged =
        next.presentation.subtitleLanguage !=
            _settings.presentation.subtitleLanguage ||
        next.presentation.rememberSubtitle !=
            _settings.presentation.rememberSubtitle;
    if (subtitlePreferenceChanged) _preferredSubtitleApplied = false;
    final kernelChanged = next.kernel != _settings.kernel;
    _nextEpisodeBuffer.discard();
    if (!mounted) return;
    if (next.backgroundSourceValidation !=
        _settings.backgroundSourceValidation) {
      _cancelSourceValidation();
    }
    if (!next.backgroundSourceValidation) {
      _networkSpeed.reset();
      _nextSpeedProbe = null;
    }
    setState(() => _settings = next);
    if (next.backgroundSourceValidation && _player != null) {
      _scheduleSourceValidation(_player!.snapshot.value);
    }
    // 关掉自动隐藏：立刻取消计时并让控制栏显形。
    if (next.autoHideControls) {
      _scheduleAutoHide();
    } else {
      _cancelAutoHide();
    }
    if (kernelChanged) {
      await _rebuildPlayer();
    } else {
      _store?.save(next);
      await _player?.applySettings(next);
      _player?.setFastSeekSnapToKeyframe(next.fastSeekSnap);
      if (subtitlePreferenceChanged) unawaited(_applyPreferredSubtitle());
    }
  }

  /// 可读提示（不冒泡异常）。
  ///
  /// 播放页不再用 SnackBar 黑条：它在视频上是一条通栏黑带，换集这种高频提示
  /// 一闪就是整屏打断。改成画面顶部的半透明胶囊，1.6 秒淡出，新提示顶掉旧的。
  void _showToast(String? message) {
    if (message == null || !mounted) return;
    _hintTimer?.cancel();
    setState(() => _hint = message);
    _hintTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  /// 顶部轻提示胶囊：不拦手势，最多两行。
  Widget _buildHintPill() {
    final hint = _hint;
    if (hint == null) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xCC1C1C1E),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0x33FFFFFF), width: .5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: Color(0xFFF6F6F6),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 起播链路

  /// 起播时把「当前线路」对齐到实际地址（图源给的默认地址可能是某一条线路）。
  void _syncQualityIndex(PlayerMedia? media) {
    final uri = media?.uri;
    if (uri == null || _qualities.isEmpty) return;
    final index = _qualities.indexWhere((quality) => quality.url == uri);
    if (index >= 0) _qualityIndex = index;
  }

  /// 切换清晰度线路：**保留当前位置与播放状态**重新装载那一条地址。
  ///
  /// 为什么重新装载而不是「同一条流切码率」：图源的「多清晰度」是**多个独立
  /// 地址**（不是 HLS 的多码率变体），播放器只能换地址重开——因此这里把当前
  /// 位置接回去，用户感知不到「重新开始」。
  Future<void> _selectQuality(int index) async {
    if (_switchingQuality || _advancing) throw StateError('正在切换，请稍后重试');
    if (index < 0 || index >= _qualities.length) {
      throw RangeError.index(index, _qualities);
    }
    if (index == _qualityIndex &&
        _player?.snapshot.value.error == null &&
        _media?.uri == _qualities[index].url) {
      _nextEpisodeBuffer.discard();
      _settings = _settings.copyWith(
        manualQualityLabel: _qualities[index].label,
      );
      _store?.save(_settings);
      return;
    }
    final player = _player;
    if (player == null) throw StateError('播放器尚未就绪');
    final snapshot = player.snapshot.value;
    final previousMedia = _media;
    final quality = _qualities[index];
    _nextEpisodeBuffer.discard();
    _saveProgress(force: true);
    _suppressProgressSave = true;
    setState(() {
      _switchingQuality = true;
      _operation = '正在切换至 ${quality.label}';
    });
    try {
      await _loadMedia(
        PlayerMedia(
          uri: quality.url,
          title: _media?.title,
          headers: quality.headers.isEmpty ? _media?.headers : quality.headers,
        ),
      );
      if (!mounted) return;
      final active = _player;
      if (active == null || active.snapshot.value.error != null) {
        throw StateError('画质切换失败');
      }
      if (snapshot.position > Duration.zero) {
        await active.seek(snapshot.position);
      }
      if (snapshot.playing) {
        await active.play();
      } else {
        await active.pause();
      }
      if (!mounted) return;
      setState(() => _qualityIndex = index);
      _settings = _settings.copyWith(manualQualityLabel: quality.label);
      _store?.save(_settings);
      unawaited(_applyPreferredSubtitle());
      _showToast('已切换到 ${quality.label}，继续当前进度');
    } catch (_) {
      if (mounted) setState(() => _media = previousMedia);
      rethrow;
    } finally {
      _suppressProgressSave = false;
      _switchingQuality = false;
      if (mounted) setState(() => _operation = null);
    }
  }

  /// 播放弹窗共享同一套紧凑面板与玻璃材质。
  Future<T?> _playbackMenu<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    Color? backgroundColor,
    bool isScrollControlled = false,
    bool useSafeArea = false,
    bool edgeDrawer = true,
  }) async {
    _panelOpen = true;
    if (mounted) setState(() {});
    try {
      return await showPlaybackMenu<T>(
        context: context,
        builder: builder,
        edgeDrawer: edgeDrawer,
        glass: _settings.playbackGlass,
        backgroundColor: backgroundColor,
        isScrollControlled: isScrollControlled,
        useSafeArea: useSafeArea,
      );
    } finally {
      _panelOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openQualityMenu() =>
      _openSourceSheet(initialTab: PlayerSourceTab.quality);

  /// 起播的**异常安全**入口：内核的 load 抛错时不让异常冒到 initState 的异步
  /// 路径上（那会变成「页面还在、错误没人管」），而是如实说一次并保留出口
  /// （画面仍在、「播放源」与设置入口仍在，用户可重试、换内核或改地址）。
  Future<void> _startPlaybackSafely(
    PlayerMedia media, {
    VideoPlayTarget? target,
    AbstractPlayer? preparedPlayer,
  }) async {
    try {
      await _startPlayback(
        media,
        target: target,
        preparedPlayer: preparedPlayer,
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _showToast('起播失败：$error');
    }
  }

  /// 交给播放器：先按需切换内核（防盗链降级），再装载、恢复进度、起连播与弹幕。
  Future<void> _startPlayback(
    PlayerMedia media, {
    VideoPlayTarget? target,
    AbstractPlayer? preparedPlayer,
    Duration? resumePosition,
  }) async {
    if (_player == null) {
      _showToast(_anyKernelAvailable ? '播放器还在准备，请稍后再试' : '本平台不提供播放内核');
      return;
    }
    if (!mounted) return;

    // 防盗链降级：图源给了**逐媒体请求头**，而当前内核带不了时改用能带的内核
    // （当前三套内核都能带，这里保留为安全网：将来某个内核退化时仍然成立）。
    final headers = media.headers;
    if (headers != null && headers.isNotEmpty) {
      final fallback = _headerCapableKernel();
      if (fallback != _settings.kernel) {
        _showToast(
          '该图源带防盗链请求头，${_settings.kernel.label} 内核带不了，'
          '已改用 ${fallback.label}',
        );
        await _applySettings(_settings.copyWith(kernel: fallback));
        if (!mounted) return;
      }
    }

    // 换作品 / 换集前先把上一部的进度落盘（首次起播没有「上一部」，跳过——
    // 否则会写一条位置 0 的空记录，让「继续观看」里凭空多出一部没看过的片子）。
    if (_target != null) _saveProgress(force: true);
    if (preparedPlayer != null && !await _adoptPreparedPlayer(preparedPlayer)) {
      return;
    }
    // 换作品 / 换集：重新读这套片头片尾标记，并允许片头**与片尾**再判一次
    //（片尾那条同样必须复位：换集就是为了让新一集还能走到它自己的片尾）。
    _introHandled = false;
    _outroHandled = false;
    _loadSkipMarks(target);
    _introGeneration++;
    _introOpening = false;
    _intro?.cancel();
    _introMedia = null;
    _healthyPosition = Duration.zero;
    _target = target;
    _syncQualityIndex(media);
    _suppressProgressSave = true;
    try {
      final preparedInitial = _preparedInitialMedia;
      _preparedInitialMedia = null;
      await _loadMedia(
        media,
        alreadyLoaded:
            preparedPlayer != null ||
            (preparedInitial != null &&
                preparedInitial.uri == media.uri &&
                mapEquals(preparedInitial.headers, media.headers)),
      );
      if (!mounted || !identical(media, _media)) return;
      if (resumePosition != null && resumePosition > Duration.zero) {
        await _player?.seek(resumePosition);
      } else {
        await _restoreProgress();
      }
    } finally {
      _suppressProgressSave = false;
    }
    _startProgressTicker();
    unawaited(_loadDanmaku(target));
    // 打开视频即自动播放（用户要求）：装载与续播定位都做完之后再发 play，
    // 免得播放器在 seek 之前就开跑、位置被拉回开头。
    if (_player != null && mounted) {
      await _player!.setVolume(_effectiveVolume);
      await _player!.play();
      unawaited(_applyPreferredSubtitle());
    }
  }

  /// 能携带逐媒体请求头的内核；当前内核就能带、或没有别的可用内核时原样返回。
  PlayerKernel _headerCapableKernel() {
    if (PlayerFactory.supportsMediaHeaders(_settings.kernel)) {
      return _settings.kernel;
    }
    for (final kernel in <PlayerKernel>[
      PlayerKernel.mpv,
      PlayerKernel.avplayer,
    ]) {
      if (_catalog.isAvailable(kernel)) return kernel;
    }
    return _settings.kernel;
  }

  Future<bool> _adoptPreparedPlayer(AbstractPlayer player) async {
    // Configure before transferring ownership, so a failed setting update leaves
    // the currently playing instance and its listeners intact.
    try {
      await player.setBuffering(_buffering);
      await player.applySettings(_settings);
      await player.setVolume(_effectiveVolume);
    } catch (_) {
      await player.dispose();
      rethrow;
    }
    if (!mounted) {
      await player.dispose();
      return false;
    }
    final previous = _player;
    previous?.snapshot.removeListener(_onSnapshotChanged);
    previous?.stats.removeListener(_onStatsChanged);
    _stopFrameForwarding();
    _inlinePipReady = false;
    _nextInlinePipAttempt = null;
    _suppressProgressSave = true;
    try {
      setState(() {
        _player = player;
        _activeKernel = _settings.kernel;
      });
      player.snapshot.addListener(_onSnapshotChanged);
      player.stats.addListener(_onStatsChanged);
    } finally {
      _suppressProgressSave = false;
    }
    if (previous != null) {
      unawaited(() async {
        try {
          await previous.pause();
          await previous.dispose();
        } catch (error) {
          LumeLog.info('[player] 切集释放旧内核失败：$error');
        }
      }());
    }
    return true;
  }

  /// 自动连播下一集。
  ///
  /// 只有「从图源条目起播、且还有下一集」时才连播；手动贴地址没有剧集列表。
  Future<void> _autoAdvance() async {
    if (!_autoNext || _advancing) return;
    final target = _target;
    if (target == null) return;
    await _playEpisodeAt(target.chapterIndex + 1, auto: true);
  }

  /// 播放同一作品的第 [index] 集（越界即返回；[auto] 区分自动连播与手动切集）。
  ///
  /// 自动连播、锁屏「下一集 / 上一集」都走这里：一处判越界与取地址，避免三份
  /// 各写一遍（写三遍就会有三套越界口径）。
  Future<bool> _playEpisodeAt(int index, {bool auto = false}) async {
    if (_advancing || _switchingQuality) return false;
    final target = _target;
    final previousMedia = _media;
    final previousQualities = _qualities;
    final previousQualityIndex = _qualityIndex;
    final source = await _openSource();
    if (!mounted || _advancing || _switchingQuality) return false;
    if (target == null || source == null) {
      if (!auto) _showToast('手动贴地址播放时没有剧集列表');
      return false;
    }

    setState(() {
      _advancing = true;
      _operation = '正在获取播放地址';
    });
    try {
      final prepared = _session?.state == PipState.active
          ? null
          : _nextEpisodeBuffer.take(target, index, _settings.kernel);
      final List<SourceChapter>? chapters;
      try {
        chapters = prepared == null
            ? VideoEpisodeCatalog.forChapter(
                await VideoEpisodeCatalog.load(source, target.itemId),
                target.chapterId,
              )
            : null;
      } on SourceException {
        return false;
      }
      if (index < 0 || (chapters != null && index >= chapters.length)) {
        // 越界：自动连播时安静停下（没下一集了），手动切集时如实说一句。
        if (!auto) {
          _showToast(index < 0 ? '已经是第一集' : '已经是最后一集');
        }
        return false;
      }
      final next = prepared?.chapter ?? chapters![index];

      final content =
          prepared?.content ??
          await source.content(itemId: target.itemId, chapterId: next.id);
      final qualities = SourcePlayback.contentQualities(
        content,
        source: source,
      );
      final chosen = PlaybackQualityPreference.select(qualities, _settings);
      final address = chosen?.url ?? SourcePlayback.contentAddress(content);
      if (address == null || !mounted) return false;

      // 换集时线路也可能完全不同：把这一集的候选线路一起换掉。
      setState(() {
        _qualities = qualities;
        _qualityIndex = 0;
      });
      await _startPlayback(
        PlayerMedia(
          uri: address,
          title: '${target.title} · ${next.title}',
          // Reuse the existing verified headers for the selected address.
          headers:
              chosen?.headers ??
              SourcePlayback.contentHeaders(content, source: source),
        ),
        preparedPlayer: prepared?.player,
        target: VideoPlayTarget(
          sourceId: target.sourceId,
          itemId: target.itemId,
          title: target.title,
          cover: target.cover,
          chapterIndex: index,
          chapterId: next.id,
          chapterTitle: next.title,
        ),
      );
      if (!mounted) return false;
      if (_player?.snapshot.value.error != null) {
        setState(() {
          _target = target;
          _media = previousMedia;
          _qualities = previousQualities;
          _qualityIndex = previousQualityIndex;
        });
        return false;
      }
      if (auto) _showToast('已自动播放：${next.title}');
      return true;
    } on CatWebParseRequired catch (request) {
      if (request.webPlayer && !auto && mounted) {
        await _player?.pause();
        if (mounted) await showSourceWebPlayer(context, request);
      } else if (request.webPlayer && mounted) {
        _showToast('下一集需要网页播放，请手动选择');
      }
      return false;
    } on SourceException {
      // 连播失败不打扰：用户没主动要求跳集，安静停在当前状态即可。
      return false;
    } catch (_) {
      if (mounted) {
        setState(() {
          _target = target;
          _media = previousMedia;
          _qualities = previousQualities;
          _qualityIndex = previousQualityIndex;
        });
        if (!auto) _showToast('切集失败，请重试');
      }
      return false;
    } finally {
      _advancing = false;
      if (mounted) setState(() => _operation = null);
    }
  }

  /// 打开当前作品的图源（连播 / 弹幕用）。
  ///
  /// 管理器**只借不关**（见 [_fallbackManager] 的说明）：注入进来的由调用方管，
  /// 兜底的那个是板块级共享实例，关它会顺手关掉浏览页在用的图源库。
  Future<DataSource?> _openSource() async {
    final existing = _source;
    if (existing != null) return existing;
    final sourceId = _target?.sourceId ?? widget.sourceId;
    if (sourceId == null) return null;
    final provided = widget.source;
    if (provided != null &&
        provided.id == sourceId &&
        provided.section == Section.video) {
      return _source = provided;
    }
    final manager =
        widget.sourceManager ??
        (_fallbackManager ??= LumeSources.manager(Section.video));
    try {
      final source = await manager.open(sourceId);
      if (source == null) return null;
      _source = source;
      return source;
    } on SourceException catch (error) {
      LumeLog.info('[player] 图源不可用（连播 / 弹幕降级）：${error.message}');
      return null;
    }
  }

  /// 加载本集弹幕：先查内存缓存，再问图源契约（`danmaku({id, chapterId})`）。
  ///
  /// 弹幕是**可选能力**：图源没实现、网络失败、格式不符都只是「这集没弹幕」，
  /// 绝不能影响播放——因此全程静默降级，只记日志。
  Future<void> _loadDanmaku(
    VideoPlayTarget? target, {
    bool force = false,
  }) async {
    final seq = ++_danmakuLoadSeq;
    final publicSeq = ++_publicDanmakuSeq;
    for (final client in _danmakuClients) {
      client.close();
    }
    _danmakuClients.clear();
    _sourceDanmakuTrack = DanmakuTrack.empty;
    _publicDanmakuTrack = DanmakuTrack.empty;
    _localDanmakuTrack = target == null
        ? DanmakuTrack.empty
        : (_danmakuCache.get(_danmakuKey(target), target.chapterId) ??
              DanmakuTrack.empty);
    if (mounted) {
      setState(() {
        _danmaku = _combinedDanmaku();
        _sourceDanmakuCount = 0;
        _publicDanmakuCount = 0;
        _publicDanmakuStatus = target == null
            ? '从源条目播放后可匹配本集弹幕'
            : '正在匹配当前作品和集数…';
        _publicDanmakuLoading = target != null;
        _publicDanmakuMatchLabel = null;
      });
    }
    _notifyDanmakuSheet();
    if (target == null) return;
    bool current() =>
        mounted &&
        seq == _danmakuLoadSeq &&
        (_target?.isSameEpisode(target) ?? false);
    bool publicCurrent() => current() && publicSeq == _publicDanmakuSeq;
    await Future.wait<void>([
      () async {
        try {
          var track = force
              ? null
              : _sourceDanmakuCache.get(_danmakuKey(target), target.chapterId);
          if (track == null) {
            final source = await _openSource();
            if (source is! DanmakuCapable) return;
            track = DanmakuTrack.parse(
              await (source as DanmakuCapable).danmaku(
                itemId: target.itemId,
                chapterId: target.chapterId,
              ),
            );
          }
          if (!current()) return;
          _sourceDanmakuCache.put(_danmakuKey(target), target.chapterId, track);
          setState(() {
            _sourceDanmakuTrack = track!;
            _sourceDanmakuCount = track.length;
            _danmaku = _combinedDanmaku();
          });
        } catch (_) {
          LumeLog.info('[player] 源未提供本集弹幕');
        } finally {
          if (current()) _notifyDanmakuSheet();
        }
      }(),
      () async {
        DandanplayClient? client;
        try {
          final config = await DandanplayCredentials.load();
          if (!publicCurrent()) return;
          _danmakuServiceLabel = config.builtin
              ? '内置本机服务'
              : config.official
              ? '弹弹play 官方'
              : Uri.parse(config.baseUrl).host;
          if (config.official && !config.configured) {
            setState(() => _publicDanmakuStatus = '官方服务尚未配置凭证');
            return;
          }
          final cacheKey = '${config.baseUrl}:${_danmakuKey(target)}';
          var track = force
              ? null
              : _publicDanmakuCache.get(cacheKey, target.chapterId);
          if (track == null) {
            client = DandanplayClient(credentials: config);
            _danmakuClients.add(client);
            final key = _matchingKey(target, config.baseUrl);
            var id = _library?.setting(key);
            final savedLabel = _library?.setting('$key.label');
            if (id?.isEmpty == true ||
                savedLabel == null ||
                savedLabel.isEmpty ||
                config.builtin) {
              id = null;
            }
            // Compatible servers may allocate transient episode IDs. After a
            // restart, resolve a stale saved association through search again.
            if (id != null) {
              try {
                track = await client.comments(id);
                if (track.isEmpty) {
                  track = null;
                  id = null;
                }
              } catch (_) {
                id = null;
              }
              if (!publicCurrent()) return;
            }
            DandanplayEpisode? match;
            var matches = const <DandanplayEpisode>[];
            if (id == null) {
              final number = DandanplayClient.episodeNumber(
                target.chapterTitle,
                chapterIndex: target.chapterIndex,
              );
              matches = await client.search(target.title, episode: number);
              match = DandanplayClient.exactMatch(
                matches,
                target.title,
                episode: number,
              );
              id = match?.id;
              if (!publicCurrent()) return;
              if (id == null) {
                // 同名同集有多个来源时 exactMatch 会故意返回 null；
                // 自动匹配按候选队列逐个试，取第一个有弹幕的。
                for (final candidate in DandanplayClient.candidates(
                  matches,
                  target.title,
                  episode: number,
                )) {
                  DanmakuTrack candidateTrack;
                  try {
                    candidateTrack = await client.comments(candidate.id);
                  } catch (error) {
                    LumeLog.warn('[danmaku] 候选加载失败，继续同集其他来源：$error');
                    continue;
                  }
                  if (!publicCurrent()) return;
                  if (candidateTrack.isEmpty) continue;
                  match = candidate;
                  id = candidate.id;
                  track = candidateTrack;
                  break;
                }
                if (id == null) {
                  setState(
                    () => _publicDanmakuStatus = matches.isEmpty
                        ? '${config.official ? '官方弹幕库' : '此服务'}未找到“${target.title}”第$number集，可手动匹配或更换服务'
                        : '同名、同集条目均未加载到弹幕，请手动匹配或更换服务',
                  );
                  return;
                }
              }
            }
            track ??= await client.comments(id);
            // 官方 TMDB 补充条目有时只有 episodeId、没有任何弹幕；如果同一作品
            // 在原生目录里还有候选，自动换一个候选再取一次，避免“官方永远 0 条”。
            if (track.isEmpty && match != null && config.official) {
              for (final candidate in DandanplayClient.alternatives(
                matches,
                match,
              )) {
                DanmakuTrack retry;
                try {
                  retry = await client.comments(candidate.id);
                } catch (_) {
                  continue;
                }
                if (!publicCurrent()) return;
                if (retry.isEmpty) continue;
                track = retry;
                match = candidate;
                id = candidate.id;
                break;
              }
            }
            if (!publicCurrent()) return;
            final resolvedTrack = track;
            final resolvedId = id;
            if (resolvedTrack == null || resolvedId == null) return;
            if (!resolvedTrack.isEmpty) {
              final label = match == null
                  ? savedLabel!
                  : '${match.title} · ${match.episode}';
              _library?.setSetting(key, resolvedId);
              _library?.setSetting('$key.label', label);
              _publicDanmakuMatchLabel = label;
            }
          } else {
            _publicDanmakuMatchLabel = _library?.setting(
              '${_matchingKey(target, config.baseUrl)}.label',
            );
          }
          final resolvedTrack = track;
          if (resolvedTrack == null) return;
          if (!publicCurrent()) return;
          if (!resolvedTrack.isEmpty) {
            _publicDanmakuCache.put(cacheKey, target.chapterId, resolvedTrack);
          }
          setState(() {
            _publicDanmakuTrack = resolvedTrack;
            _publicDanmakuCount = resolvedTrack.length;
            _publicDanmakuStatus = resolvedTrack.isEmpty
                ? (config.builtin
                      ? '内置服务该集返回 0 条；如果开了 VPN/代理，请关闭后重新加载本集'
                      : '本服务该集返回 0 条弹幕，可重新匹配或更换服务')
                : '公共库已加载 ${resolvedTrack.length} 条';
            _danmaku = _combinedDanmaku();
          });
        } catch (error) {
          if (publicCurrent()) {
            setState(
              () =>
                  _publicDanmakuStatus = DandanplayClient.describeError(error),
            );
          }
        } finally {
          client?.close();
          _danmakuClients.remove(client);
          if (publicCurrent()) {
            setState(() => _publicDanmakuLoading = false);
            _notifyDanmakuSheet();
          }
        }
      }(),
    ]);
  }

  void _danmakuServiceChanged() {
    if (mounted) unawaited(_loadDanmaku(_target, force: true));
  }

  Future<void> _configureDanmakuService([BuildContext? panelContext]) async {
    try {
      if (!mounted) return;
      if (panelContext != null) {
        await Navigator.of(panelContext).push(
          MaterialPageRoute<void>(builder: (_) => const DanmakuSourcesPage()),
        );
      } else {
        await showPlayerSettingsPanel<void>(
          context: context,
          builder: (_) => const DanmakuSourcesPage(),
        );
      }
    } catch (error) {
      if (mounted) _showToast(DandanplayClient.describeError(error));
    }
  }

  Future<void> _matchPublicDanmaku() async {
    final target = _target;
    if (target == null) {
      _showToast('请先从源条目播放视频');
      return;
    }
    final publicSeq = ++_publicDanmakuSeq;
    final previousStatus = _publicDanmakuStatus;
    var applied = false;
    setState(() {
      _publicDanmakuLoading = false;
      _publicDanmakuStatus = '正在手动匹配本集…';
    });
    _notifyDanmakuSheet();
    DandanplayClient? client;
    try {
      final config = await DandanplayCredentials.load();
      if (!mounted ||
          publicSeq != _publicDanmakuSeq ||
          !(_target?.isSameEpisode(target) ?? false)) {
        return;
      }
      client = DandanplayClient(credentials: config);
      _danmakuClients.add(client);
      final selected = await showDanmakuPanel<DanmakuMatchSelection>(
        context: context,
        builder: (sheetContext) => DanmakuMatchSheet(
          client: client!,
          title: target.title,
          episode: DandanplayClient.episodeNumber(
            target.chapterTitle,
            chapterIndex: target.chapterIndex,
          ),
          serviceLabel: config.builtin
              ? '内置本机服务'
              : config.official
              ? '弹弹play 官方'
              : Uri.parse(config.baseUrl).host,
          onChangeService: () {
            Navigator.pop(sheetContext);
            unawaited(_configureDanmakuService());
          },
        ),
      );
      if (selected == null ||
          selected.track.isEmpty ||
          !mounted ||
          publicSeq != _publicDanmakuSeq ||
          !(_target?.isSameEpisode(target) ?? false)) {
        return;
      }
      final item = selected.episode;
      final track = selected.track;
      final label = '${item.title} · ${item.episode}';
      _library?.setSetting(_matchingKey(target, config.baseUrl), item.id);
      _library?.setSetting(
        '${_matchingKey(target, config.baseUrl)}.label',
        label,
      );
      _publicDanmakuCache.put(
        '${config.baseUrl}:${_danmakuKey(target)}',
        target.chapterId,
        track,
      );
      _publicDanmakuTrack = track;
      _applyDanmakuSettings(_danmakuSettings.copyWith(enabled: true));
      applied = true;
      setState(() {
        _publicDanmakuMatchLabel = label;
        _danmaku = _combinedDanmaku();
        _publicDanmakuCount = track.length;
        _publicDanmakuStatus = '已加载 ${track.length} 条公共弹幕';
      });
      _notifyDanmakuSheet();
      _showToast('已加载 ${track.length} 条公共弹幕');
    } catch (error) {
      if (mounted &&
          publicSeq == _publicDanmakuSeq &&
          (_target?.isSameEpisode(target) ?? false)) {
        _showToast(DandanplayClient.describeError(error));
      }
    } finally {
      client?.close();
      _danmakuClients.remove(client);
      if (!applied &&
          mounted &&
          publicSeq == _publicDanmakuSeq &&
          (_target?.isSameEpisode(target) ?? false)) {
        setState(() => _publicDanmakuStatus = previousStatus);
        _notifyDanmakuSheet();
      }
    }
  }

  Future<void> _clearDanmakuMatch() async {
    final target = _target;
    if (target == null) return;
    final config = await DandanplayCredentials.load();
    if (!mounted || !(_target?.isSameEpisode(target) ?? false)) return;
    _publicDanmakuSeq++;
    _library?.setSetting(_matchingKey(target, config.baseUrl), '');
    _library?.setSetting('${_matchingKey(target, config.baseUrl)}.label', '');
    _publicDanmakuCache.clear();
    setState(() {
      _publicDanmakuMatchLabel = null;
      _publicDanmakuLoading = false;
      _publicDanmakuTrack = DanmakuTrack.empty;
      _publicDanmakuCount = 0;
      _publicDanmakuStatus = '本集关联已清除，请重新匹配';
      _danmaku = _combinedDanmaku();
    });
    _notifyDanmakuSheet();
  }

  /// 打开弹幕设置面板。
  Future<void> _openDanmakuSettings() async {
    _cancelAutoHide();
    await showPlayerSettingsPanel<void>(
      context: context,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _danmakuRevision,
        builder: (panelContext, revision, child) => DanmakuSettingsSheet(
          settings: _danmakuSettings,
          danmakuCount: _danmaku.length,
          status: _publicDanmakuStatus,
          sourceCount: _sourceDanmakuCount,
          publicCount: _publicDanmakuCount,
          loading: _publicDanmakuLoading,
          videoTitle: _target?.title,
          episodeTitle: _target?.chapterTitle,
          serviceLabel: _danmakuServiceLabel,
          matchLabel: _publicDanmakuMatchLabel,
          onClearMatch: _clearDanmakuMatch,
          onMatch: _matchPublicDanmaku,
          onConfigureService: () => _configureDanmakuService(panelContext),
          onReload: () => _loadDanmaku(_target, force: true),
          onChanged: _applyDanmakuSettings,
        ),
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  /// 从库里恢复上次的时间点：同一集就续播，换了集就从头。
  Future<void> _restoreProgress() async {
    final target = _target;
    final player = _player;
    final library = _library;
    if (target == null || player == null || library == null) return;

    final saved = library.videoEpisodeProgress(
      target.itemId,
      target.chapterId,
      sourceId: target.sourceId,
    );
    if (saved == null) return;
    if (saved.position <= Duration.zero) return;
    // 已播完的不自动跳回结尾（用户重看时从头开始更自然）。
    if (saved.isFinished) return;

    await player.seek(saved.position);
    if (!mounted) return;
    _lastSavedPosition = saved.position;
    _showToast('已从上次位置继续：${_format(saved.position)}');
  }

  /// 播放中定期落盘：只在播放且有目标时写，节流到 [_progressInterval]。
  void _startProgressTicker() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_progressInterval, (_) {
      final snapshot = _player?.snapshot.value;
      if (snapshot == null || !snapshot.playing) return;
      _saveProgress();
    });
  }

  /// 读这套作品的片头片尾标记（按 itemId 存，同一部剧共用一个）。
  void _loadSkipMarks(VideoPlayTarget? target) {
    final library = _library;
    if (library == null || target == null) {
      _skipMarks = SkipMarks.none;
      return;
    }
    _skipMarks = SkipMarksStore(library).load(target.identity);
  }

  /// 记片头 / 记片尾（用户口径：播到那个位置点一下，下次自动跳过）。
  void _markSkip({required bool intro}) {
    final target = _target;
    final library = _library;
    final snapshot = _player?.snapshot.value;
    if (target == null || library == null || snapshot == null) {
      _showToast('从源条目起播才能记片头片尾（当前播放没有作品身份）');
      return;
    }
    final position = snapshot.position;
    if (position <= Duration.zero) {
      _showToast('先播到片头结束 / 片尾开始的位置再记');
      return;
    }
    final next = intro
        ? _skipMarks.copyWith(intro: position)
        : _skipMarks.copyWith(outro: position);
    SkipMarksStore(library).save(target.identity, next);
    unawaited(
      rememberPlayerSkip(
        target,
        next,
        snapshot.duration,
        intro: intro,
        controller: _intro,
      ).catchError((Object error) => LumeLog.warn('同剧跳过记忆保存失败：$error')),
    );
    setState(() => _skipMarks = next);
    _introHandled = !intro && _introducedAlready;
    // 「记片尾」记的就是**当前位置**：当场算作已处理，这一集不会被立刻跳走
    //（用户还要看完这一段）。下次起播 / 换集重新判定，到时照跳。
    if (!intro) _outroHandled = true;
    _showToast(
      intro
          ? '已记片头：${_format(position)}（下次从这里开始播）'
          : '已记片尾：${_format(position)}（到时自动跳下一集）',
    );
  }

  /// 清掉这套作品的片头片尾标记。
  void _clearSkipMarks() {
    final target = _target;
    final library = _library;
    if (target == null || library == null) return;
    SkipMarksStore(library).clear(target.identity);
    unawaited(
      rememberPlayerSkip(
        target,
        SkipMarks.none,
        _player?.snapshot.value.duration ?? Duration.zero,
      ).catchError((Object error) => LumeLog.warn('同剧跳过记忆清除失败：$error')),
    );
    setState(() => _skipMarks = SkipMarks.none);
    _showToast('已清除片头片尾标记');
  }

  /// 片尾区间：剩余时间进到这里就算「在片尾」，快捷按钮随之变成「记片尾」。
  ///
  /// 取「2 分钟」与「总时长 8%」里**较大**的那个：十几分钟的短剧最后两分钟就能记，
  /// 一小时上下的长片也不会在还剩十来分钟时就把按钮切成片尾（那样片头就没法记了）。
  static const Duration _outroWindowMin = Duration(minutes: 2);
  static const double _outroWindowFraction = 0.08;

  bool _inOutroRegion(PlayerSnapshot snapshot) {
    final total = snapshot.duration;
    if (total <= Duration.zero) return false;
    final scaled = total * _outroWindowFraction;
    final window = scaled > _outroWindowMin ? scaled : _outroWindowMin;
    return total - snapshot.position <= window;
  }

  /// 快捷按钮的文案（用户口径：片头显示「记片头」，走到片尾显示「记片尾」）。
  String _skipQuickLabel(PlayerSnapshot snapshot) =>
      _inOutroRegion(snapshot) ? '记片尾' : '记片头';

  /// 快捷按钮的提示：把「这一下记的是哪一头、长按能清」说清楚。
  String _skipQuickTooltip(PlayerSnapshot snapshot) =>
      '${_skipQuickLabel(snapshot)}（长按清除标记）';

  /// 快捷按钮按下去：按当前所处的区间记对应的一头。
  void _markSkipFromQuick(PlayerSnapshot snapshot) =>
      _markSkip(intro: !_inOutroRegion(snapshot));

  /// 长按快捷按钮清标记；没记过时如实说明，别让长按像没反应。
  void _clearSkipMarksFromQuick() {
    if (_skipMarks.isEmpty) {
      _showToast('还没有记过片头片尾');
      return;
    }
    _clearSkipMarks();
  }

  /// 快捷智能「记片头 / 记片尾」（用户口径：就放在播放页控制栏上）。
  ///
  /// 文案随播放位置切换，不再需要用户自己判断「现在该记哪一头」；两个入口
  /// （全屏浮层与竖屏控制栏）读同一份判定，行为不会各说各话。
  Widget _skipQuickButton() => ValueListenableBuilder<PlayerSnapshot>(
    valueListenable: _player?.snapshot ?? _idleSnapshot,
    builder: (context, snapshot, _) => Tooltip(
      message: _skipQuickTooltip(snapshot),
      child: TextButton(
        onPressed: () => _intro?.prompt != null
            ? _originalSkipNow()
            : _markSkipFromQuick(snapshot),
        onLongPress: _clearSkipMarksFromQuick,
        style: TextButton.styleFrom(
          minimumSize: const Size(56, 40),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          foregroundColor: _fullscreen ? Colors.white : LumeTheme.accent,
        ),
        child: Text(
          _skipQuickLabel(snapshot),
          style: TextStyle(
            fontSize: LumeTypography.bodySize + 1,
            fontWeight: FontWeight.w600,
            shadows: _fullscreen ? _controlShadows : null,
          ),
        ),
      ),
    ),
  );

  /// 起播时是否已经走过片头（用来判断「记片尾」后要不要重新判片头）。
  bool get _introducedAlready {
    final snapshot = _player?.snapshot.value;
    final intro = _skipMarks.intro;
    if (snapshot == null || intro == null) return false;
    return snapshot.position >= intro;
  }

  /// 每次快照变化时判一次：该跳片头就跳、到片尾就进下一集。
  ///
  /// 只在「从源条目起播」且这一集有标记时生效；手动贴地址没有作品身份，不跳。
  void _maybeSkip(SkipMarks marks, Duration position, Duration duration) {
    final target = _target;
    final player = _player;
    if (target == null || player == null) return;
    final outcome = SkipDecision.resolve(
      marks: marks,
      position: position,
      duration: duration,
      introEnabled: true,
      outroEnabled: true,
      introHandled: _introHandled,
      outroHandled: _outroHandled,
      hasNext: _autoNext && target.chapterIndex >= 0,
    );
    // 片尾只处理一次：位置已经越过片尾标记就等于「这一集的片尾已经管过了」，
    // 任何一次动作之后都不能再判（否则跳到结尾 / 换集失败之后位置仍在标记之后，
    // 每个快照都会再来一轮——见 SkipDecision 的第 2 条边界）。
    if (outcome.action != SkipAction.none &&
        marks.outro != null &&
        position >= marks.outro!) {
      _outroHandled = true;
    }
    switch (outcome.action) {
      case SkipAction.none:
        return;
      case SkipAction.seek:
        final to = outcome.position!;
        _introHandled = true;
        unawaited(player.seek(to));
        _showToast(
          to >= duration && duration > Duration.zero ? '已跳过片尾' : '已跳过片头',
        );
      case SkipAction.advance:
        _introHandled = true;
        // 有没有下一集要**问过才知道**（单集作品 / 最后一集都没有），
        // 因此先试着换集：换成了才说「进入下一集」，换不成跳到结尾。
        unawaited(_skipOutroTo(target, duration));
    }
  }

  /// 片尾到点：有下一集就连播，没有就跳到结尾（用户口径：片尾「到点自动跳」）。
  ///
  /// 以前这里直接判「有下一集」（只按 `_autoNext` 猜），单集作品的片尾于是**什么
  /// 都没发生**——越界换集被静默吃掉，用户等不到「跳到结尾」。
  Future<void> _skipOutroTo(VideoPlayTarget target, Duration duration) async {
    final switched = await _playEpisodeAt(target.chapterIndex + 1, auto: true);
    if (switched) {
      _showToast('已跳过片尾，进入下一集');
      return;
    }
    final player = _player;
    if (player == null || !mounted) return;
    if (duration > Duration.zero) await player.seek(duration);
    _showToast('已跳过片尾');
  }

  /// 保存当前播放进度（集数 + 时间点）。
  ///
  /// [force] 为 true 时忽略节流（暂停、切集、退出这些「状态改变」的时刻必须写准）。
  void _saveProgress({bool force = false}) {
    if (_suppressProgressSave) return;
    final target = _target;
    final library = _library;
    final snapshot = _player?.snapshot.value;
    if (target == null || library == null || snapshot == null) return;
    if (library.setting('history.incognito') == 'true') return;
    if (snapshot.error != null) return;

    final position = snapshot.position;
    if (position <= Duration.zero &&
        (!_loaded || snapshot.duration <= Duration.zero)) {
      final saved = library.videoProgress(
        target.itemId,
        sourceId: target.sourceId,
      );
      if (saved?.chapterIndex == target.chapterIndex &&
          saved!.position > Duration.zero) {
        return;
      }
    }
    // 刚开播还没走表、或位置没动过，不必写库（省掉大量无意义的写）。
    if (!force &&
        (position - _lastSavedPosition).abs() < const Duration(seconds: 2)) {
      return;
    }
    if (position <= Duration.zero && !force) return;

    _lastSavedPosition = position;
    // **只写历史**：播放不是收藏。这里若调 shelve()，其 upsert 会把
    // favorite 置 1，播放记录就会跑进收藏页（真机 bug）。
    library.recordHistoryItem(
      sourceId: target.sourceId,
      itemId: target.itemId,
      title: target.title,
      cover: target.cover,
      chapterCount: 0,
    );
    final progress = VideoProgress(
      sourceId: target.sourceId,
      section: library.section,
      itemId: target.itemId,
      chapterIndex: target.chapterIndex,
      chapterId: target.chapterId,
      chapterTitle: target.chapterTitle,
      updatedAt: DateTime.now(),
      position: position,
      duration: snapshot.duration,
    );
    library.saveProgress(progress);
    // 绑定了 Bangumi 的作品：按集数同步「看到第几集」。失败只记日志，
    // 同步服务内部会吞掉异常，不影响播放与本地进度。
    unawaited(BangumiSyncService.instance.afterProgress(library, progress));
  }

  // ---------------------------------------------------------------- 画中画

  Future<void> _togglePip() async {
    if (_player?.snapshot.value.error != null) {
      _showToast('请先重试播放，再开启画中画');
      return;
    }
    if (_pipPreparing) return;
    _pipPreparing = true;
    try {
      final session = _session;
      if (session == null) return;

      if (session.state != PipState.active) {
        final player = _player;
        if (player == null) return;
        await player.play();
        _backgroundPlaying = true;
        final nativeBackend = session.backend;
        if (nativeBackend is MethodChannelPipBackend) {
          await _syncPipDanmaku();
          await nativeBackend.updatePlaybackState(
            playing: true,
            duration: player.snapshot.value.duration,
            playbackRate: _settings.speed,
          );
          if (player is AvPlayer) {
            final id = player.nativePlayerId;
            if (id == null) {
              _showToast('请等播放画面就绪');
              return;
            }
            await _syncPipDanmaku();
            await nativeBackend.prepareAvPlayer(id);
          } else {
            final engine = _frameEngineOf(player);
            if (engine == null) {
              _showToast('当前内核无法提供画中画视频帧');
              return;
            }
            _framePump ??= PipFramePump(
              engine: engine,
              frameSource: nativeBackend.frameSource,
              position: () => _player?.snapshot.value.position ?? Duration.zero,
              playing: () => _player?.snapshot.value.playing ?? false,
              playbackRate: () => _settings.speed,
            );
            final ready = await _framePump!.prime().timeout(
              const Duration(seconds: 3),
              onTimeout: () => false,
            );
            if (!mounted) return;
            if (!ready) {
              _stopFrameForwarding();
              _showToast('画中画视频帧未就绪，请等画面出现后重试');
              return;
            }
            // Keep supplying frames while iOS checks readiness, not only after entered.
            _framePump!.start();
          }
        }
      }
      final outcome = session.state == PipState.active
          ? await session.exit()
          : await session.enter();
      if (!mounted) return;
      final rejection = outcome.rejection;
      if (rejection != null) {
        _stopFrameForwarding();
        _showToast(rejection);
      }
    } catch (error) {
      _stopFrameForwarding();
      _showToast('画中画准备失败：$error');
    } finally {
      _pipPreparing = false;
    }
  }

  /// 画中画事件回调：原生失败给可读提示；进入 / 退出时开关帧转发。
  void _onPipEvent(PipEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case PipEventKind.play:
        _backgroundPlaying = true;
        if (_player?.snapshot.value.error != null) {
          unawaited(_restoreInlinePlayback(retry: true));
        } else {
          unawaited(_player?.play());
        }
      case PipEventKind.pause:
        _backgroundPlaying = false;
        unawaited(_player?.pause());
      case PipEventKind.skip:
        unawaited(
          _seekBy(
            Duration(milliseconds: int.tryParse(event.message ?? '') ?? 0),
          ),
        );
      case PipEventKind.failed:
        _stopFrameForwarding();
        _showToast(event.message ?? '画中画失败');
      case PipEventKind.entered:
        _backgroundPlaying = true;
        unawaited(_player?.play());
        _startFrameForwarding();
      case PipEventKind.exited:
        _stopFrameForwarding();
        if (_lifecycle == AppLifecycleState.resumed) {
          unawaited(_restoreInlinePlayback());
        }
      case PipEventKind.restored:
        unawaited(_restoreInlinePlayback());
    }
    final snapshot = _player?.snapshot.value;
    if (snapshot != null) _syncOriginalIntro(snapshot);
  }

  /// 开始帧转发（仅 MPV 内核需要：AVPlayer 走原生 `AVPlayerLayer` 通路）。
  void _startFrameForwarding() {
    final player = _player;
    final backend = _session?.backend;
    final engine = _frameEngineOf(player);
    if (player == null || backend is! MethodChannelPipBackend) {
      LumeLog.info('[player] 当前内核不需要帧转发（或画中画后端非原生）');
      return;
    }
    if (engine == null) {
      LumeLog.info('[pip] 系统播放器由原生 AVPlayerLayer 提供画面');
      return;
    }
    _framePump ??= PipFramePump(
      engine: engine,
      frameSource: backend.frameSource,
      position: () => _player?.snapshot.value.position ?? Duration.zero,
      playing: () => _player?.snapshot.value.playing ?? false,
      playbackRate: () => _settings.speed,
    );
    _framePump!.start();
    _framePump!.setBackground(_lifecycle != AppLifecycleState.resumed);
  }

  void _stopFrameForwarding() {
    _framePump?.stop();
    _framePump = null;
    _inlinePipReady = false;
  }

  void _syncPipPlaybackState() {
    final backend = _session?.backend;
    final snapshot = _player?.snapshot.value;
    if (backend is! MethodChannelPipBackend || snapshot == null) return;
    final playing =
        snapshot.playing ||
        _pipPreparing ||
        _session?.state == PipState.entering;
    if (_pipPlaying == playing &&
        _pipDuration == snapshot.duration &&
        _pipRate == _settings.speed) {
      return;
    }
    _pipPlaying = playing;
    _pipRate = _settings.speed;
    _pipDuration = snapshot.duration;
    unawaited(
      backend.updatePlaybackState(
        playing: playing,
        duration: snapshot.duration,
        playbackRate: _settings.speed,
      ),
    );
  }

  void _toggleDanmaku() {
    final enabled = !_danmakuSettings.enabled;
    _applyDanmakuSettings(_danmakuSettings.copyWith(enabled: enabled));
    if (enabled && _danmaku.isEmpty) _showToast('本集暂无弹幕，可以发送本机弹幕');
  }

  /// 取播放器背后的 MPV 引擎（非 MPV 内核返回 null）。
  VideoFrameCapture? _frameEngineOf(AbstractPlayer? player) {
    if (player is MpvPlayer) return player.engine;
    if (player is MdkEngine) return player;
    return null;
  }

  // ------------------------------------------------------------------ 手势

  /// 手势层：透明触摸面 + 手势提示浮层。
  Widget _buildGestureLayer(Size size) {
    final gestures = _settings.gestures.enabled;
    return GestureDetector(
      key: _gestureLayerKey,
      behavior: HitTestBehavior.opaque,
      // 单击切换控制栏：不注册双击，保证单击立即响应（双击在左右侧区单独识��）。
      onTap: _fullscreen ? _toggleOverlayByTap : null,
      onLongPressStart: !gestures || !_settings.gestures.boost
          ? null
          : (_) => _onLongPressStart(),
      onLongPressEnd: gestures ? (_) => _endBoost() : null,
      onLongPressCancel: gestures ? _endBoost : null,
      onPanDown: gestures ? (details) => _onGestureDown(details, size) : null,
      onPanStart: gestures ? (details) => _onGestureStart(details, size) : null,
      onPanUpdate: gestures
          ? (details) => _onGestureUpdate(details, size)
          : null,
      onPanEnd: gestures ? _onGestureEnd : null,
      onPanCancel: gestures
          ? () {
              _endBoost();
              setState(() => _gesture = PlayerGestureState.idle);
            }
          : null,
      child: _gesture.active
          ? _GestureHint(
              state: _gesture,
              brightness: _brightness,
              startPosition: _gestureStartPosition,
              baseSpeed: _gestureSpeedBeforeBoost,
              boostSpeed: _settings.gestures.boostMultiplier
                  .clamp(_settings.speed, 4.0)
                  .toDouble(),
            )
          : const SizedBox.expand(),
    );
  }

  void _onGestureStart(DragStartDetails details, Size size) {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;
    _cancelAutoHide();
    _gestureOrigin ??= details.globalPosition;
    _gestureStartPosition = snapshot.position;
    _gestureStartVolume = _gesture.volume;
    _gestureStartBrightness = _brightness;
    final local = _localPositionOf(_gestureOrigin!, size);
    _gestureStartFraction = size.width <= 0 ? 0.5 : local.dx / size.width;
  }

  void _onGestureDown(DragDownDetails details, Size size) {
    _swipeNextFired = false;
    _gestureOrigin = details.globalPosition;
    _gestureStartFraction = size.width <= 0
        ? 0.5
        : details.localPosition.dx / size.width;
  }

  /// 把全局坐标换算成手势层内的局部坐标。
  Offset _localPositionOf(Offset global, Size size) {
    final box = _gestureLayerKey.currentContext?.findRenderObject();
    if (box is RenderBox) {
      return box.globalToLocal(global);
    }
    return global;
  }

  void _onGestureUpdate(DragUpdateDetails details, Size size) {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;

    final origin = _gestureOrigin ?? details.globalPosition;
    final current = _localPositionOf(details.globalPosition, size);
    final start = _localPositionOf(origin, size);
    final totalDx = current.dx - start.dx;
    final totalDy = current.dy - start.dy;

    // 竖屏短剧：画面中间带的上滑切下一集（开关打开时才拦截；两侧仍是亮度/音量）。
    // 必须在意图判定之前吃掉竖直位移，否则第一次 update 就会被判成音量手势。
    final middleSwipe =
        _settings.swipeUpNext &&
        size.height > size.width &&
        _gestureStartFraction > .34 &&
        _gestureStartFraction < .66 &&
        totalDy.abs() > totalDx.abs();
    if (middleSwipe) {
      if (!_swipeNextFired && totalDy < -72) {
        _swipeNextFired = true;
        _endBoost();
        final current = _target;
        if (current != null && !_advancing) {
          unawaited(_playEpisodeAt(current.chapterIndex + 1));
        }
      }
      return;
    }

    // 已判定的意图优先：中途不换功能（换功能最让人恼火）。
    var intent = _gesture.intent;
    if (intent == PlayerGestureIntent.none) {
      intent = PlayerGesturePolicy.intentFor(
        dx: totalDx,
        dy: totalDy,
        startFraction: _gestureStartFraction,
      );
      if (intent == PlayerGestureIntent.seek) {
        if (snapshot.duration <= Duration.zero) return;
        _gestureStartPosition = snapshot.position;
      }
    }
    final gestures = _settings.gestures;
    if (!gestures.enabled ||
        intent == PlayerGestureIntent.brightness && !gestures.brightness ||
        intent == PlayerGestureIntent.volume && !gestures.volume ||
        intent == PlayerGestureIntent.seek && !gestures.seek) {
      return;
    }
    if (intent == PlayerGestureIntent.none) return;

    switch (intent) {
      case PlayerGestureIntent.brightness:
        final next = PlayerGesturePolicy.applyVerticalDelta(
          startValue: _gestureStartBrightness,
          dy: totalDy,
          height: size.height,
          // 手势灵敏度是用户设置（播放器设置里可调）。
          sensitivity: _settings.gestureSensitivity,
        );
        setState(() {
          _brightness = next;
          _gesture = _gesture.copyWith(
            intent: intent,
            brightness: next,
            active: true,
          );
        });
        if (_systemBrightness) {
          unawaited(_brightnessBackend.setBrightness(next));
        }
      case PlayerGestureIntent.volume:
        final next = PlayerGesturePolicy.applyVerticalDelta(
          startValue: _gestureStartVolume,
          dy: totalDy,
          height: size.height,
          sensitivity: _settings.gestureSensitivity,
        );
        setState(() {
          _gesture = _gesture.copyWith(
            intent: intent,
            volume: next,
            active: true,
          );
        });
        _muted = false;
        unawaited(player.setVolume(next));
      case PlayerGestureIntent.seek:
        final target = PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: _gestureStartPosition,
          duration: snapshot.duration,
          dx: totalDx,
          width: size.width,
          window: Duration(seconds: _settings.gestures.seekSeconds),
        );
        _scrubSeekThrottled(target);
        setState(() {
          _gesture = _gesture.copyWith(
            intent: intent,
            seekTarget: target,
            active: true,
          );
        });
      case PlayerGestureIntent.none:
      case PlayerGestureIntent.boost:
        break;
    }
  }

  /// 手势结束：调进度的手势在这里才真正 seek（拖动中不反复 seek）。
  void _onGestureEnd(DragEndDetails details) {
    final player = _player;
    final target = _gesture.seekTarget;
    if (player != null && target != null) {
      unawaited(_seekGesture(player, target));
    }
    _endBoost();
    _scheduleAutoHide();
    _savePlaybackPreferences();
    _gestureOrigin = null;
    setState(
      () => _gesture = PlayerGestureState.idle.copyWith(
        volume: _gesture.volume,
        brightness: _brightness,
      ),
    );
  }

  /// 拖动中节流快 seek：每 150ms 一次，画面跟着手指走；松手再精确 seek。
  ///
  /// 串行 + 只保留最新目标：拖动时目标是连续变化的，中间那些落点没有一个是
  /// 用户要的，排队发出去只会让源端连开一路又一路 Range 请求。
  void _scrubSeekThrottled(Duration target) {
    final player = _player;
    if (player == null) return;
    _pendingScrubSeek = target;
    final now = DateTime.now();
    final last = _lastScrubSeek;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastScrubSeek = now;
    unawaited(_drainScrubSeeks(player));
  }

  Future<void> _drainScrubSeeks(AbstractPlayer player) async {
    if (_scrubSeekInFlight) return;
    _scrubSeekInFlight = true;
    try {
      while (mounted && identical(player, _player)) {
        final target = _pendingScrubSeek;
        if (target == null) break;
        _pendingScrubSeek = null;
        try {
          // 挂死的快 seek 不能把后来的跳转堵在后面：超时即放行下一次。
          await player.seekFast(target).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          LumeLog.warn('[player] 拖动快 seek 超时：${target.inMilliseconds}ms');
        } catch (error, stack) {
          LumeLog.error(error, stack);
        }
      }
    } finally {
      _scrubSeekInFlight = false;
      // 关闸和下一次 onChanged 恰好交错时，最新目标可能在 finally 前才写入；
      // 再看一眼，避免它没有后续手势事件来唤醒而静默丢失。
      if (_pendingScrubSeek != null && mounted && identical(player, _player)) {
        unawaited(_drainScrubSeeks(player));
      }
    }
  }

  /// 松手 / 按钮 / 手势跳转共用：精确 seek + 等一次位置确认。
  ///
  /// 内核的 seek 可能一直不返回（AVPlayer 的 seekToTime 完成回调在源端卡住时
  /// 就不来），所以这段必须自带超时——否则调用方一直挂在 await 上，
  /// 拖动预览文字和「缓冲中」就一起留着不动了。
  Future<bool> _seekAndConfirm(AbstractPlayer player, Duration target) async {
    // 新一轮跳转作废上一轮看门狗：不然上一个落点的超时会来复查这次跳转。
    _seekWatchdog?.cancel();
    _seekWatchdogGeneration++;
    final acknowledged = Completer<bool>();
    void checkPosition() {
      if (!acknowledged.isCompleted &&
          (player.snapshot.value.position - target).abs() <=
              const Duration(seconds: 1)) {
        acknowledged.complete(true);
      }
    }

    player.snapshot.addListener(checkPosition);
    try {
      final returned = await player
          .seek(target)
          .then((_) => true)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              LumeLog.warn(
                '[player] ${_settings.kernel.label} 跳转未返回：'
                '${target.inMilliseconds}ms',
              );
              return false;
            },
          );
      checkPosition();
      if (acknowledged.isCompleted) return true;
      // seek 自己都没回来时不再多挂 800ms；预览立刻收尾，由看门狗恢复。
      if (!returned) return false;
      return await acknowledged.future.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => false,
      );
    } finally {
      player.snapshot.removeListener(checkPosition);
    }
  }

  /// 跳转后停滞的看门狗：6 秒内位置没动就重发一次同一跳转，
  /// 再 6 秒还不动就换地址重开并回到目标位置（三个内核都走这条路）。
  void _armSeekWatchdog(
    AbstractPlayer player,
    Duration target, {
    bool retried = false,
  }) {
    _seekWatchdog?.cancel();
    final generation = ++_seekWatchdogGeneration;
    final anchor = player.snapshot.value.position;
    _seekWatchdog = Timer(const Duration(seconds: 6), () {
      if (!mounted ||
          generation != _seekWatchdogGeneration ||
          !identical(player, _player)) {
        return;
      }
      final snapshot = player.snapshot.value;
      final stalled =
          snapshot.buffering &&
          snapshot.error == null &&
          (snapshot.position - anchor).abs() <= const Duration(seconds: 1);
      if (!stalled) return;
      LumeLog.warn(
        '[player] ${_settings.kernel.label} 跳转后无进展：'
        '${anchor.inMilliseconds}ms → ${target.inMilliseconds}ms'
        '${retried ? '（重发过）' : ''}',
      );
      if (retried) {
        unawaited(_restoreInlinePlayback(retry: true, position: target));
        return;
      }
      unawaited(
        _seekAndConfirm(player, target).then((ok) {
          if (!ok) _armSeekWatchdog(player, target, retried: true);
        }),
      );
    });
  }

  Future<void> _seekGesture(AbstractPlayer player, Duration target) async {
    try {
      final ok = await _seekAndConfirm(player, target);
      if (!ok) _armSeekWatchdog(player, target);
    } catch (_) {
      if (mounted) _showToast('跳转失败，请重试');
    }
  }

  /// 长按：临时倍速。
  void _onLongPressStart() {
    final player = _player;
    if (player == null) return;
    _cancelAutoHide();
    _gestureSpeedBeforeBoost = _settings.speed;
    if (!_settings.gestures.enabled || !_settings.gestures.boost) return;
    final boosted = _settings.gestures.boostMultiplier
        .clamp(_settings.speed, 4.0)
        .toDouble();
    _gestureBoosted = true;
    setState(() {
      _gesture = _gesture.copyWith(
        intent: PlayerGestureIntent.boost,
        boosting: true,
        active: true,
      );
    });
    unawaited(player.applySettings(_settings.copyWith(speed: boosted)));
  }

  /// 松手：恢复原倍速。
  void _endBoost() {
    if (!_gestureBoosted) return;
    _gestureBoosted = false;
    if (mounted) {
      setState(
        () => _gesture = PlayerGestureState.idle.copyWith(
          volume: _gesture.volume,
          brightness: _brightness,
        ),
      );
    }
    _scheduleAutoHide();
    final player = _player;
    if (player == null) return;
    unawaited(
      player.applySettings(_settings.copyWith(speed: _gestureSpeedBeforeBoost)),
    );
  }

  // ------------------------------------------------------------------ 设置入口

  /// 当前生效的能力矩阵：有播放器就问它，没有就按「设置里选的（或回退后的）
  /// 内核」查同一张表——两种情况给出的是同一份声明。
  PlayerCapabilities get _capabilities =>
      _player?.capabilities ?? PlayerCapabilities.of(_effectiveKernel);

  /// 打开设置弹窗（所有功能入口都在这里）。
  Future<void> _openSettings() async {
    _cancelAutoHide();
    await showPlayerSettingsSheet(
      context: context,
      settings: _settings,
      capabilities: _capabilities,
      catalog: _catalog,
      onChanged: _applySettings,
      onUnsupported: _showToast,
      onPickAudioTrack: _pickAudioTrack,
      onPickSubtitleTrack: _pickSubtitleTrack,
      onPickSubtitleFile: _pickSubtitleFile,
      // 方向锁定：值来自应用级偏好（与全局设置的「横屏播放」同一份）。
      orientation: _orientation,
      onOrientationChanged: PlaybackOrientationController.instance.apply,
      // 弹幕设置也收进同一份设置弹窗（用户点名：所有功能入口都固定在这里）；
      // 控制栏那颗 tune 仍保留为快捷入口。
      danmaku: _danmakuSettings,
      onDanmakuChanged: _applyDanmakuSettings,
      introControls: _buildPlaybackSettings('intro'),
      extraControls: _buildPlaybackSettings('playback'),
      audioControls: _buildPlaybackSettings('audio'),
      connectionControls: _buildPlaybackSettings('connection'),
      danmakuControls: ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('弹幕显示与匹配'),
        subtitle: const Text('显示样式、来源匹配与屏蔽词'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          Navigator.of(context).pop();
          await _openDanmakuSettings();
        },
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  Future<void> _showGestureHelp() async {
    _cancelAutoHide();
    await showPlayerDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放手势'),
        content: const SingleChildScrollView(
          child: Text(
            '左右滑动：调整播放进度\n左侧上下滑：调整亮度\n右侧上下滑：调整音量\n长按画面：临时倍速，松手恢复\n\n左右互换、换集和灵敏度以「手势与外观」设置为准。锁定后仅解锁按钮可操作。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  Widget _buildPlaybackSettings(String group) => StatefulBuilder(
    builder: (context, update) {
      final buffer = _buffering.forwardBuffer.inSeconds;
      final supported = _player?.capabilities.bufferingParams ?? false;
      return GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (group == 'connection' && _player is PresentationEngine)
              Builder(
                builder: (context) {
                  final engine = _player! as PresentationEngine;
                  return ValueListenableBuilder<List<String>>(
                    valueListenable: engine.presentationStatus,
                    builder: (context, lines, _) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        lines.join('\n'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  );
                },
              ),
            if (group == 'intro') _skipQuickButton(),
            if (group == 'intro')
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const LumeIcon(
                  Icons.skip_next,
                  slot: 'video_player_page.1',
                ),
                title: const Text('片头片尾与同剧记忆'),
                subtitle: const Text('记一次，后续各集自动沿用；无需作品 ID'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _openOriginalIntro();
                },
              ),
            if (group == 'playback') ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('画质'),
                subtitle: const Text('切换当前片源提供的清晰度'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openQualityMenu());
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('选集与线路'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openSourceSheet());
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('画中画'),
                subtitle: const Text('文字叠加字幕不会自动进入系统画中画'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_togglePip());
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('查看手势说明'),
                trailing: const Icon(Icons.touch_app_outlined),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_showGestureHelp());
                },
              ),
            ],
            if (group == 'audio') ...[
              SwitchListTile(
                title: const Text('静音'),
                value: _muted,
                onChanged: (value) {
                  setState(() => _muted = value);
                  update(() {});
                  _savePlaybackPreferences();
                  unawaited(_player?.setVolume(_effectiveVolume));
                },
              ),
              SwitchListTile(
                title: const Text('音乐模式'),
                subtitle: const Text('隐藏画面，保留音频和播放控制'),
                value: _musicMode,
                onChanged: (value) {
                  setState(() => _musicMode = value);
                  update(() {});
                  _savePlaybackPreferences();
                },
              ),
              Text('音量 ${(_gesture.volume * 100).round()}%'),
              NativeGlassSlider(
                value: _gesture.volume,
                min: 0,
                max: 1,
                onChanged: _player == null
                    ? null
                    : (value) {
                        setState(
                          () => _gesture = _gesture.copyWith(volume: value),
                        );
                        update(() {});
                        _muted = false;
                        _savePlaybackPreferences();
                        unawaited(_player!.setVolume(value));
                      },
              ),
            ],
            if (group == 'connection') ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示播放速率'),
                subtitle: const Text('在全屏进度条右上方显示传输速率'),
                value: _showNetworkSpeed,
                onChanged: (value) {
                  setState(() => _showNetworkSpeed = value);
                  update(() {});
                  _savePlaybackPreferences();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放信息'),
                subtitle: Text(
                  [
                    '内核：${_effectiveKernel.label}',
                    ...?_player?.stats.value.chips,
                  ].join(' · '),
                ),
                trailing: IconButton(
                  tooltip: '复制地址',
                  icon: const Icon(Icons.copy),
                  onPressed: _media == null
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: _media!.uri.toString()),
                          );
                          if (mounted) _showToast('已复制播放地址');
                        },
                ),
              ),

              Text(
                supported
                    ? '前向缓冲 ${buffer == 0 ? '自动' : '$buffer 秒'}'
                    : '当前内核未提供缓冲参数',
              ),
              NativeGlassSlider(
                value: buffer.toDouble().clamp(
                  0,
                  SectionModuleSettings.maxBufferSeconds.toDouble(),
                ),
                min: 0,
                max: SectionModuleSettings.maxBufferSeconds.toDouble(),
                divisions: SectionModuleSettings.maxBufferSeconds,
                onChanged: !supported
                    ? null
                    : (value) {
                        final seconds = value.round();
                        setState(
                          () => _buffering = BufferingConfig.forForwardBuffer(
                            Duration(seconds: seconds),
                          ),
                        );
                        update(() {});
                        final library = _library;
                        if (library != null) {
                          SectionModuleSettings.load(library)
                              .copyWith(bufferSeconds: seconds)
                              .save(library);
                        }
                        unawaited(_player?.setBuffering(_buffering));
                      },
              ),
            ],
            if (group == 'playback')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动连播'),
                value: _autoNext,
                onChanged: (value) {
                  _setAutoNext(value);
                  update(() {});
                },
              ),
          ],
        ),
      );
    },
  );

  /// 弹幕设置变更：上屏 + 落库（与「弹幕设置」弹窗同一套落库口径）。
  ///
  /// 落库是**必达**的：库还没打开（[_boot] 的读盘没回来）就先记下待写值，
  /// 读完盘立刻补写——绝不静默丢掉用户这一次点击（见 [_danmakuSettingsDirty]）。
  void _applyDanmakuSettings(DanmakuSettings next) {
    _danmakuSettingsDirty = true;
    setState(() => _danmakuSettings = next.clamped());
    _notifyDanmakuSheet();
    final library = _library;
    if (library == null) {
      _pendingDanmakuSave = next;
      return;
    }
    DanmakuSettingsStore(library).save(next);
  }

  void _onSharedSettingsChanged() {
    final library = _library;
    if (!mounted ||
        library == null ||
        library.lastSettingKey != DanmakuSettings.settingKey) {
      return;
    }
    final next = DanmakuSettingsStore(library).load();
    if (next == _danmakuSettings) return;
    setState(() => _danmakuSettings = next);
    _notifyDanmakuSheet();
  }

  /// 不支持的项：统一提示（用户点名的口径）。
  void _unsupported() => _showToast(PlayerCapabilities.unsupportedMessage);

  // ------------------------------------------------------------ 音轨 / 字幕

  /// 选音轨：列表来自内核；**一条都没有时如实说「这条视频没有可选音轨」**，
  /// 与「内核不支持」区分开（后者在设置面板里就被提示拦下了）。
  Future<void> _pickAudioTrack() async {
    final player = _player;
    if (player == null) {
      _unsupported();
      return;
    }
    final tracks = await player.audioTracks();
    if (!mounted) return;
    if (tracks.isEmpty) {
      _showToast('这条视频没有可选音轨');
      return;
    }
    final selected = await _playbackMenu<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _TrackSheet(title: '选择音轨', tracks: tracks),
    );
    if (selected == null || !mounted) return;
    await player.selectAudioTrack(selected);
    if (mounted) _showToast('已切换音轨');
  }

  String? get _subtitleMemoryKey {
    final target = _target ?? widget.target;
    return target == null ? null : 'video.subtitle.work.${target.identity}';
  }

  /// 按设置里的“字幕语言”自动选一次字幕；用户手动选过就不再覆盖。
  Future<void> _applyPreferredSubtitle() async {
    if (_preferredSubtitleApplied || !_settings.subtitlesEnabled) return;
    var preference = _settings.presentation.subtitleLanguage;
    Map? remembered;
    final memoryKey = _subtitleMemoryKey;
    if (_settings.presentation.rememberSubtitle && memoryKey != null) {
      try {
        final raw = jsonDecode(_library?.setting(memoryKey) ?? 'null');
        if (raw is Map) remembered = raw;
      } catch (_) {}
      if (remembered?['off'] == true) preference = 'off';
    }
    if (preference == 'source' && remembered == null) {
      preference = PlayerExperienceStore.current.subtitleLanguage;
    }
    if (preference == 'source' && remembered == null) {
      _preferredSubtitleApplied = true;
      return;
    }
    final player = _player;
    if (player == null) return;
    if (preference == 'off') {
      _preferredSubtitleApplied = true;
      await player.selectSubtitleTrack(null);
      return;
    }
    // 起播瞬间部分内核还没填好轨道列表；给几次短重试，避免设置“没生效”。
    var tracks = const <PlayerTrack>[];
    for (var attempt = 0; attempt < 4; attempt++) {
      tracks = await player.subtitleTracks();
      if (tracks.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted || !identical(player, _player)) return;
    }
    if (!mounted || !identical(player, _player)) return;
    _preferredSubtitleApplied = true;
    final rememberedTrack = remembered == null
        ? null
        : tracks
              .where(
                (t) =>
                    (remembered!['language'] is String &&
                        (remembered['language'] as String).isNotEmpty &&
                        t.language == remembered['language']) ||
                    t.label == remembered['label'],
              )
              .firstOrNull;
    final id =
        rememberedTrack?.id ??
        PlaybackPreferenceWiring.chooseSubtitleTrack(tracks, preference);
    if (id == null) return;
    if (!_settings.subtitlesEnabled) {
      _settings = _settings.copyWith(subtitlesEnabled: true);
      _store?.save(_settings);
    }
    await player.selectSubtitleTrack(id);
  }

  /// 选字幕轨（含「关闭字幕」）。
  Future<void> _pickSubtitleTrack() async {
    final player = _player;
    if (player == null) {
      _unsupported();
      return;
    }
    final tracks = await player.subtitleTracks();
    if (!mounted) return;
    if (tracks.isEmpty) {
      _showToast('这条视频没有内置字幕轨（可以试试「外挂字幕」）');
      return;
    }
    final selected = await _playbackMenu<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _TrackSheet(title: '选择字幕轨', tracks: tracks, allowOff: true),
    );
    if (selected == null || !mounted) return;
    _preferredSubtitleApplied = true;
    final off = selected == _TrackSheet.offId;
    if (!off && !_settings.subtitlesEnabled) {
      await _applySettings(_settings.copyWith(subtitlesEnabled: true));
    }
    await player.selectSubtitleTrack(off ? null : selected);
    final key = _subtitleMemoryKey;
    if (_settings.presentation.rememberSubtitle && key != null) {
      final track = tracks.where((t) => t.id == selected).firstOrNull;
      _library?.setSetting(
        key,
        jsonEncode({
          'off': off,
          'language': track?.language,
          'label': track?.label,
        }),
      );
    }
    if (mounted) _showToast('已切换字幕轨');
  }

  /// 外挂字幕：挑一个本地字幕文件交给内核。
  ///
  /// 加载成功**顺带把字幕总开关打开**：用户刚选了字幕文件，结果画面里什么都没有
  /// 会以为是坏的。
  Future<void> _pickSubtitleFile() async {
    final player = _player;
    if (player == null) {
      _unsupported();
      return;
    }
    final source = await showPlayerDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导入外挂字幕'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'file'),
            child: const Text('选择本地文件'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'url'),
            child: const Text('从字幕链接导入'),
          ),
        ],
      ),
    );
    if (!mounted || source == null) return;
    if (source == 'url') {
      await _pickSubtitleUrl(player);
      return;
    }
    final file = await openFile(acceptedTypeGroups: _subtitleTypes);
    if (file == null || !mounted) return;
    _preferredSubtitleApplied = true;
    final ok = await player.loadSubtitleFile(file.path);
    if (!mounted) return;
    if (!ok) {
      _showToast('字幕导入失败：AVPlayer 支持 SRT / VTT，ASS 请使用 MPV');
      return;
    }
    if (!_settings.subtitlesEnabled) {
      await _applySettings(_settings.copyWith(subtitlesEnabled: true));
    }
    if (mounted) {
      setState(() {});
      _showToast('已加载字幕：${file.name}');
    }
  }

  Future<void> _pickSubtitleUrl(AbstractPlayer player) async {
    final controller = TextEditingController();
    final value = await showPlayerDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字幕链接'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…/subtitle.srt'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    // The dialog's route may still be animating out; its field owns the controller until then.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (!mounted || value == null) return;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _showToast('请输入有效的 HTTP(S) 字幕链接');
      return;
    }
    _preferredSubtitleApplied = true;
    bool loaded;
    try {
      loaded = await player.loadSubtitleFile(value);
    } catch (_) {
      loaded = false;
    }
    if (!mounted || !identical(player, _player)) return;
    if (!loaded) {
      _showToast('字幕导入失败：AVPlayer 支持 SRT / VTT，ASS 请使用 MPV');
      return;
    }
    await _applySettings(_settings.copyWith(subtitlesEnabled: true));
    if (mounted) {
      setState(() {});
      _showToast('已导入字幕链接');
    }
  }

  /// 字幕文件类型（iOS 走系统文档选择器，这里按扩展名过滤）。
  static const List<XTypeGroup> _subtitleTypes = <XTypeGroup>[
    XTypeGroup(
      label: '字幕文件',
      extensions: <String>['srt', 'ass', 'ssa', 'vtt', 'sub'],
    ),
  ];

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      // 返回的**那一刻**就落盘：dispose 要等退场动画跑完，用户会在这之前
      // 点右上角历史（真机现象：不切一次 Tab 就看不到刚播的那条）。
      if (didPop) _saveProgress(force: true);
    },
    child: ModuleGlassScope(
      module: GlassModule.video,
      child: _legacyBuild(context),
    ),
  );
  Widget _legacyBuild(BuildContext context) {
    final body = _anyKernelAvailable ? _buildBody() : const _VideoSkeleton();
    // 全屏（沉浸）模式：整页只剩画面 + 浮层控制栏——顶栏与标准控制栏都收起。
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildImmersive(body),
      );
    }
    return GlassScaffold(
      effectModule: GlassModule.video,
      title: widget.title ?? _target?.title ?? '播放',
      behindBar: true,
      child: Padding(padding: GlassScaffold.barInset(context), child: body),
    );
  }

  Widget _buildBody() {
    final player = _player;
    // 控制栏**任何状态下都在**：它是「播放器设置」这个入口的家，不能因为
    // 播放器还没准备好就整块消失。两处例外，都是有意的：
    // - 锁屏：防误触就是要挡住这些；
    // - 全屏：标准控制栏换成压在画面上的浮层（点画面切换显隐）。
    if (_locked || _fullscreen) {
      return Stack(
        children: [
          Positioned.fill(child: _buildStage(player)),
          if (_locked)
            Positioned.fill(
              child: GestureDetector(
                key: const Key('locked-player-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: _showUnlock,
              ),
            ),
          if (_locked && _unlockVisible)
            SafeArea(
              child: Align(
                alignment: _fullscreen
                    ? Alignment.centerLeft
                    : Alignment.topRight,
                child: _buildUnlockButton(),
              ),
            ),
        ],
      );
    }
    // Stable video/control slots: decoded dimensions only affect the picture
    // inside the stage, never the control panel's geometry.
    return Column(
      children: [
        Expanded(child: _buildStage(player)),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .32,
          ),
          child: SingleChildScrollView(child: _buildControlPanel(player)),
        ),
      ],
    );
  }

  // --------------------------------------------------------- 控制栏自动隐藏

  /// 重排自动隐藏：每次有操作（点按钮 / 唤出控制栏 / 状态变化）都重新计时。
  ///
  /// 全屏闲置三秒淡出，暂停时同样生效；锁定、报错与无障碍导航保留操作出口。
  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    if (!_fullscreen || _locked || _previewTarget != null) return;
    if (_accessibleNavigation) return;
    if (!_settings.autoHideControls) return;
    if (_player?.snapshot.value.error != null) {
      return;
    }
    _autoHideTimer = Timer(_autoHideDelay, () {
      if (!mounted || !_fullscreen || _locked) return;
      if (_accessibleNavigation) return;
      if (_player?.snapshot.value.error != null) {
        return;
      }
      setState(() => _overlayVisible = false);
    });
  }

  /// 单击画面：显示时立即收起，收起时唤出并重新计时。
  void _toggleOverlayByTap() {
    if (!_fullscreen || _locked) return;
    if (_overlayVisible) {
      _autoHideTimer?.cancel();
      setState(() => _overlayVisible = false);
      return;
    }
    setState(() => _overlayVisible = true);
    _scheduleAutoHide();
  }

  /// 双击左侧后退 10 秒 / 双击右侧前进 10 秒。
  Future<void> _seekBySide(int direction) async {
    final player = _player;
    if (player == null) return;
    final snapshot = player.snapshot.value;
    final total = snapshot.duration;
    if (total <= Duration.zero) return;
    const delta = Duration(seconds: 10);
    var target = direction < 0
        ? snapshot.position - delta
        : snapshot.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    _cancelAutoHide();
    try {
      await player.seek(target);
      if (mounted) {
        _showToast(PlayerLayout.seekDelta(snapshot.position, target));
      }
    } catch (_) {
      if (mounted) _showToast('跳转失败，请重试');
    }
  }

  /// 取消自动隐藏并让控制栏保持可见。
  void _cancelAutoHide({bool show = true}) {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    if (show && mounted && !_overlayVisible) {
      setState(() => _overlayVisible = true);
    }
  }

  /// 切换全屏：**按视频宽高比自动选方向**，方向锁定可以覆盖（用户要求）。
  ///
  /// 方向交给 `SystemChrome.setPreferredOrientations`：竖屏短剧进全屏即竖屏全屏
  /// （9:16 正好铺满手机屏）；普通横片照旧横屏全屏（左右两个方向都收，用户横握
  /// 哪边都行）。页面 dispose 时也会还原一次——否则从全屏直接返回会把整个 App
  /// 留在横屏里。
  void _setFullscreen(bool value) {
    if (widget.fullscreenOnly && !value) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _fullscreen = value;
      _overlayVisible = true;
    });
    // 进全屏后开始计时；退出全屏立刻停表（普通页面那套控制栏是固定元素）。
    if (value) {
      _scheduleAutoHide();
    } else {
      _cancelAutoHide();
    }
    unawaited(_applyOrientation());
  }

  /// 方向偏好被改（设置页的「横屏播放」或本页设置弹窗的「方向锁定」）。
  void _onOrientationPreferenceChanged() {
    final next = PlaybackOrientationController.instance.orientation;
    if (next == _orientation) return;
    if (mounted) {
      setState(() => _orientation = next);
    } else {
      _orientation = next;
    }
    // 已经全屏的话当场换方向；普通页面本来就只有竖屏一种可能，不必下发。
    if (_fullscreen) unawaited(_applyOrientation());
  }

  /// 视频参数变化：分辨率变化要重新取景；全屏中还要按宽高比重算方向。
  ///
  /// 起播瞬间还没有分辨率参数，此时画面是「原样放」的（取景框算不出来）；参数到了
  /// 这里补一次——竖屏短剧不会被一直按横屏摆着，全屏方向也不会留在兜底的横屏里。
  void _onStatsChanged() {
    if (!mounted) return;
    final stats = _player?.stats.value;
    final sizeKey = '${stats?.width}x${stats?.height}';
    if (sizeKey != _lastVideoSize) {
      setState(() => _lastVideoSize = sizeKey);
    }
    if (!_fullscreen) return;
    if (_orientation != PlaybackOrientation.auto) return;
    unawaited(_applyOrientation());
  }

  /// 最近一次用于取景的宽高（`宽x高`）；用来判断分辨率有没有变。
  String? _lastVideoSize;

  /// 按当前全屏状态 + 方向锁定算出该下发的方向。
  List<DeviceOrientation> _preferredOrientations() {
    // 普通页面播放（不进全屏）：资源浏览与阅读都是竖屏语境，保持竖屏。
    if (!_fullscreen) {
      return const <DeviceOrientation>[DeviceOrientation.portraitUp];
    }
    switch (_orientation) {
      case PlaybackOrientation.landscape:
        return const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      case PlaybackOrientation.portrait:
        return const <DeviceOrientation>[DeviceOrientation.portraitUp];
      case PlaybackOrientation.auto:
        // Unknown dimensions retain the entry direction instead of briefly
        // forcing a portrait short into landscape before metadata arrives.
        return !_hasVideoDimensions || _isPortraitVideo
            ? const <DeviceOrientation>[DeviceOrientation.portraitUp]
            : const <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ];
    }
  }

  PlayerStats? get _orientationStats {
    final stats = _player?.stats.value;
    if ((stats?.width ?? 0) > 0 && (stats?.height ?? 0) > 0) return stats;
    if (_media?.uri == widget.media?.uri) {
      return widget.prelaunch?.preparedStats;
    }
    return null;
  }

  bool get _hasVideoDimensions =>
      (_orientationStats?.width ?? 0) > 0 &&
      (_orientationStats?.height ?? 0) > 0;

  /// 当前视频是不是竖屏（宽 < 高）；入场可使用详情页预加载的实测尺寸。
  bool get _isPortraitVideo {
    final stats = _orientationStats;
    final width = stats?.width;
    final height = stats?.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return false;
    }
    return width < height;
  }

  /// 应用当前该用的方向（同样的值不重复下发，见 [_appliedOrientations]）。
  Future<void> _applyOrientation() =>
      _sendOrientations(_preferredOrientations());

  /// 真正下发方向；桌面 / 测试环境没有方向概念，失败只记日志、不影响播放。
  Future<void> _sendOrientations(List<DeviceOrientation> orientations) async {
    if (listEquals(orientations, _appliedOrientations)) return;
    _appliedOrientations = orientations;
    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (error) {
      LumeLog.info('[player] 设置屏幕方向失败（当前平台可能不支持）：$error');
    }
  }

  /// 全屏模式的布局：画面铺满 + 浮层控制栏（点画面切换显隐）。
  Widget _buildImmersive(Widget body) {
    final media = MediaQuery.sizeOf(context);
    final portrait = media.height > media.width;
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _overlayVisible && !_locked ? 1 : 0,
              duration: PlayerLayout.motion(context, 200),
              child: const DecoratedBox(
                key: Key('fullscreen-control-gradient'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Colors.transparent,
                      Colors.transparent,
                      Color(0xB3000000),
                    ],
                    stops: [0, .28, .62, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_overlayVisible || _locked,
            child: AnimatedSwitcher(
              key: const Key('fullscreen-controls'),
              duration: PlayerLayout.motion(context, 200),
              child: !_overlayVisible || _locked
                  ? const SizedBox.shrink()
                  : SafeArea(
                      key: const Key('fullscreen-visible-controls'),
                      child: Stack(
                        children: [
                          // 竖屏时两个圆钮从画面中线挪到进度条上方，避免压住竖屏短剧的人物。
                          if (portrait) ...[
                            Positioned(
                              left: VideoPlayerPage.controlHorizontalPadding,
                              // 用户口径：放在屏幕下方三分之一处。
                              bottom: media.height / 3,
                              child: _topIcon(
                                icon: Icons.lock_open,
                                tooltip: '锁定（防误触）',
                                onPressed: () {
                                  _cancelAutoHide();
                                  _setLocked();
                                },
                              ),
                            ),
                            Positioned(
                              right: VideoPlayerPage.controlHorizontalPadding,
                              bottom: media.height / 3,
                              child: _topIcon(
                                icon: Icons.screen_rotation_alt,
                                tooltip: '横竖屏切换',
                                onPressed: () {
                                  _cycleOrientation();
                                  _scheduleAutoHide();
                                },
                              ),
                            ),
                          ] else ...[
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left:
                                      VideoPlayerPage.controlHorizontalPadding,
                                ),
                                child: _topIcon(
                                  icon: Icons.lock_open,
                                  tooltip: '锁定（防误触）',
                                  onPressed: () {
                                    _cancelAutoHide();
                                    _setLocked();
                                  },
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  right:
                                      VideoPlayerPage.controlHorizontalPadding,
                                ),
                                child: _topIcon(
                                  icon: Icons.screen_rotation_alt,
                                  tooltip: '横竖屏切换',
                                  onPressed: () {
                                    _cycleOrientation();
                                    _scheduleAutoHide();
                                  },
                                ),
                              ),
                            ),
                          ],
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _buildImmersiveTopBar(),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: _buildFloatingControls(),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  void _savePlaybackPreferences() {
    final library = _library;
    if (library == null) return;
    PlayerExperienceStore.forLibrary(library).update({
      'volume': _gesture.volume,
      'muted': _muted,
      'musicMode': _musicMode,
      'showNetworkSpeed': _showNetworkSpeed,
    });
  }

  void _setLocked() {
    _cancelAutoHide();
    setState(() => _locked = true);
    _showUnlock();
  }

  void _showUnlock() {
    _unlockTimer?.cancel();
    setState(() => _unlockVisible = true);
    if (_accessibleNavigation) return;
    _unlockTimer = Timer(_autoHideDelay, () {
      if (mounted && _locked) setState(() => _unlockVisible = false);
    });
  }

  Widget _buildUnlockButton() => Padding(
    padding: const EdgeInsets.only(
      left: VideoPlayerPage.controlHorizontalPadding,
    ),
    child: _topIcon(
      icon: Icons.lock,
      tooltip: '解除锁定',
      onPressed: () {
        setState(() {
          _locked = false;
          _unlockTimer?.cancel();
          _overlayVisible = true;
        });
        _scheduleAutoHide();
      },
    ),
  );

  // 只给文字和图标投影，避免安全区内的面板背景形成矩形边界。
  static const _controlShadows = <Shadow>[
    Shadow(color: Color(0x59000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// 顶部保留返回、片名与媒体选项，低频操作收进更多。
  Widget _buildImmersiveTopBar() => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 580;
      final title = _target?.title ?? widget.title ?? _media?.title ?? '播放';
      final episode = _target?.chapterTitle.trim();
      Widget caption(PlayerStats stats) {
        final parts = <String>[
          if (episode != null &&
              episode.isNotEmpty &&
              episode != '播放' &&
              episode != title)
            episode,
          if (stats.resolutionText != null) stats.resolutionText!,
        ];
        if (parts.isEmpty) return const SizedBox.shrink();
        return Text(
          parts.join(' · '),
          key: const Key('fullscreen-media-caption'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: LumeTypography.captionSize,
            fontWeight: FontWeight.w600,
            color: Color(0xFFE4E4E4),
            shadows: _controlShadows,
          ),
        );
      }

      return Padding(
        key: const Key('fullscreen-topbar'),
        // 行距收窄：状态行与片名块之间不留松缝，片名整体上移。
        padding: const EdgeInsets.symmetric(
          horizontal: VideoPlayerPage.controlHorizontalPadding,
          vertical: 2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PlayerClock(showBattery: !_panelOpen),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _topIcon(
                  icon: Icons.arrow_back_ios_new,
                  tooltip: '退出全屏',
                  onPressed: () => _setFullscreen(false),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: LumeTypography.titleSize,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF8F8F8),
                          shadows: _controlShadows,
                        ),
                      ),
                      if (_player == null)
                        caption(PlayerStats.empty)
                      else
                        ValueListenableBuilder<PlayerStats>(
                          valueListenable: _player!.stats,
                          builder: (context, stats, _) => caption(stats),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (!narrow) _buildPipButton(),
                const SizedBox(width: 4),
                _topIcon(
                  icon: Icons.more_horiz,
                  tooltip: '播放器设置',
                  onPressed: _openSettings,
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Future<void> _openKernelPicker() async {
    _cancelAutoHide();
    final selected = await _playbackMenu<PlayerKernel>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '播放内核',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: LumeTypography.pageTitleSize,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const LumeIcon(
                      Icons.close,
                      slot: 'video_player_page.2',
                    ),
                  ),
                ],
              ),
              PlayerKernelPicker(
                selected: _settings.kernel,
                catalog: _catalog,
                onChanged: (kernel) => Navigator.pop(context, kernel),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (selected != null && selected != _settings.kernel) {
      await _applySettings(_settings.copyWith(kernel: selected));
    }
    _scheduleAutoHide();
  }

  /// 顶栏上的紧凑图标按钮（白字 + 投影，压在画面上也看得清）。
  Widget _topIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    if (_fullscreen) {
      return Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 32,
          height: 36,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: PlayerControlGlyph(
              icon,
              size: _iconSize,
              color: onPressed == null
                  ? const Color(0x99F8F8F8)
                  : const Color(0xFFF8F8F8),
            ),
          ),
        ),
      );
    }
    return IconButton(
      iconSize: _iconSize,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(minWidth: _box, minHeight: _box),
      padding: EdgeInsets.zero,
      color: highlighted ? Colors.white : Colors.white70,
      tooltip: tooltip,
      icon: _fullscreen
          ? PlayerControlGlyph(icon, size: _iconSize)
          : LumeIcon(icon, slot: 'video_player_page.3', variant: true),
      onPressed: onPressed,
    );
  }

  void _cycleOrientation() {
    final modes = PlaybackOrientation.values;
    final next = modes[(modes.indexOf(_orientation) + 1) % modes.length];
    PlaybackOrientationController.instance.apply(next);
    _showToast('屏幕方向：${next.label}');
  }

  Future<void> _showSpeedPicker() async {
    _cancelAutoHide();
    final speed = await _playbackMenu<double>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '播放速度',
                  style: TextStyle(
                    fontSize: LumeTypography.pageTitleSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final value in PlayerSettings.speeds)
                      ChoiceChip(
                        label: Text('${value}x'),
                        selected: value == _settings.speed,
                        onSelected: (_) => Navigator.pop(context, value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (speed != null) await _applySettings(_settings.copyWith(speed: speed));
    _scheduleAutoHide();
  }

  /// 全屏浮层控制栏：进度 + 主要控制 + 次级控制（退出全屏与设置都在里面）。
  Widget _buildFloatingControls() {
    return PlaybackGlass(
      enabled: _settings.playbackGlass,
      dark: true,
      child: Listener(
        onPointerDown: (_) => _scheduleAutoHide(),
        child: Padding(
          // 底部留白 6（用户口径：整块往下移，靠近屏幕底边）。再往下就是安全区
          // （home 指示条）本身留的位，按钮压不进去也不用压进去。
          padding: const EdgeInsets.fromLTRB(
            VideoPlayerPage.controlHorizontalPadding,
            4,
            VideoPlayerPage.controlHorizontalPadding,
            2,
          ),
          child: ValueListenableBuilder<PlayerSnapshot>(
            valueListenable: _player?.snapshot ?? _idleSnapshot,
            builder: (context, snapshot, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_showNetworkSpeed && _player != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: PlayerStatsInline(
                        key: const Key('fullscreen-network-speed'),
                        stats: _player!.stats,
                        networkKbps: _networkSpeed.kbps,
                        showResolution: false,
                        dimmed: true,
                      ),
                    ),
                  ),
                _buildProgress(snapshot),
                // 两行（进度条行 / 按钮行）固定行距（用户口径）。
                const SizedBox(height: VideoPlayerPage.controlRowGap),
                _buildFloatingSplitControls(snapshot),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 左侧播放与下集，右侧文字入口依次为弹幕、倍速、选集。
  bool _compactFullscreenControls(double width) =>
      width < 580 ||
      width < _box * 6 + 96 ||
      MediaQuery.textScalerOf(context).scale(1) > 1.4;

  Widget _buildFloatingSplitControls(PlayerSnapshot snapshot) => LayoutBuilder(
    builder: (context, constraints) {
      final target = _target;
      final compact = _compactFullscreenControls(constraints.maxWidth);
      Widget action(
        String label,
        String tooltip,
        IconData icon,
        VoidCallback? callback, {
        bool forceText = false,
        double? width,
        VoidCallback? onLongPress,
      }) => Tooltip(
        message: tooltip,
        child: SizedBox(
          width: width ?? _box,
          height: _box,
          child: TextButton(
            onPressed: callback,
            onLongPress: onLongPress,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              foregroundColor: const Color(0xFFF8F8F8),
              disabledForegroundColor: const Color(0x99F8F8F8),
            ),
            child:
                forceText || _settings.controlStyle == PlayerControlStyle.text
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        shadows: _controlShadows,
                      ),
                    ),
                  )
                : PlayerControlGlyph(
                    icon,
                    size: _iconSize,
                    color: callback == null
                        ? const Color(0x99F8F8F8)
                        : const Color(0xFFF8F8F8),
                  ),
          ),
        ),
      );
      final playing = snapshot.playing && snapshot.error == null;
      return Row(
        key: const Key('fullscreen-actions'),
        children: [
          action(
            playing ? '暂停' : '播放',
            playing ? '暂停' : '播放',
            playing ? Icons.pause : Icons.play_arrow,
            _player == null
                ? null
                : () => unawaited(playing ? _player!.pause() : _player!.play()),
          ),
          if (!compact) ...[
            const SizedBox(width: 4),
            action(
              '下集',
              '下一集',
              Icons.skip_next,
              target == null || _advancing
                  ? null
                  : () => _playEpisodeAt(target.chapterIndex + 1),
            ),
          ],
          const Spacer(),
          Semantics(
            toggled: _danmakuSettings.enabled,
            child: action(
              '弹幕',
              _danmakuSettings.enabled ? '弹幕：开' : '弹幕：关',
              Icons.forum_outlined,
              _openDanmakuSettings,
              forceText: true,
            ),
          ),
          const SizedBox(width: 4),
          action(
            '${_settings.speed}×',
            '播放速度（${_settings.speed}x）',
            Icons.speed,
            _showSpeedPicker,
            forceText: true,
            onLongPress: _settings.speed == 1
                ? null
                : () => unawaited(_applySettings(_settings.copyWith(speed: 1))),
          ),
          const SizedBox(width: 4),
          action(
            '选集',
            '线路 / 选集',
            Icons.grid_view_rounded,
            _openSourceSheet,
            forceText: true,
          ),
        ],
      );
    },
  );

  /// 竖屏（直屏）控制栏那一排（用户口径：**文字与图标对齐、大小统一**）。
  ///
  /// 文字按钮与图标按钮走同一个 [VideoPlayerPage.controlBox] 触达盒、同一个 13 号字，
  /// 因此一排看上去是等高等宽的方块，而不是「文字比图标大一号」。
  List<Widget> _essentialActions() => <Widget>[
    _actionLabel('选集', '线路 / 选集', _openSourceSheet),
    _skipQuickButton(),
    _actionLabel('片头尾', '片头片尾设置', _openOriginalIntro),
    if (_media != null) _actionLabel('画质', '清晰度', _openQualityMenu),
    _actionLabel(
      '弹',
      _danmakuSettings.enabled ? '弹幕：开' : '弹幕：关',
      _openDanmakuSettings,
      onLongPress: _toggleDanmaku,
      highlighted: _danmakuSettings.enabled,
    ),
    _buildPipButton(),
    // 播放内核：与全屏那颗同一图标（用户口径：换个好看的图标）。
    _compactIcon(
      icon: VideoPlayerPage.playerKernelIcon,
      tooltip: '播放内核',
      onPressed: _openKernelPicker,
    ),
    _compactIcon(
      icon: _fullscreen ? Icons.close_fullscreen : Icons.open_in_full,
      tooltip: _fullscreen ? '退出全屏' : '全屏',
      onPressed: () => _setFullscreen(!_fullscreen),
    ),
    _compactIcon(icon: Icons.tune, tooltip: '播放器设置', onPressed: _openSettings),
  ];

  /// 竖屏控制栏上的文字按钮：与 [_compactIcon] 同盒同字号。
  Widget _actionLabel(
    String label,
    String tooltip,
    VoidCallback onPressed, {
    VoidCallback? onLongPress,
    bool highlighted = false,
  }) => Tooltip(
    message: tooltip,
    child: TextButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      style: TextButton.styleFrom(
        minimumSize: Size(_box, _box),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: _fullscreen
            ? (highlighted ? Colors.white : Colors.white70)
            : LumeTheme.accent,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: LumeTypography.bodySize + 1,
          fontWeight: FontWeight.w600,
          shadows: _fullscreen ? _controlShadows : null,
        ),
      ),
    ),
  );

  /// 画面区：四态——设置库不可用 / 重建失败 / 正在准备 / 就绪。
  Widget _buildStage(AbstractPlayer? player) {
    if (_storeFailed) {
      return _PlayerStageNotice(
        icon: Icons.storage_outlined,
        title: '播放器设置库不可用',
        detail:
            '视频板块的设置库打不开，播放参数无法读写；可以重试打开，'
            '或返回后再进来。',
        actions: <Widget>[
          FilledButton.icon(
            onPressed: _retryBoot,
            icon: const LumeIcon(
              Icons.refresh,
              slot: 'video_player_page.4',
              size: 18,
            ),
            label: const Text('重试'),
          ),
        ],
      );
    }

    final failure = _rebuildFailure;
    if (player == null && failure != null) {
      return _PlayerStageNotice(
        icon: Icons.error_outline,
        title: '播放器准备失败',
        detail: failure,
        actions: <Widget>[
          FilledButton.icon(
            onPressed: _retryFailedKernel,
            icon: const LumeIcon(
              Icons.refresh,
              slot: 'video_player_page.5',
              size: 18,
            ),
            label: const Text('重试'),
          ),
          OutlinedButton(
            onPressed: _switchToAvPlayer,
            child: const Text('切回 AVPlayer'),
          ),
        ],
      );
    }

    if (player == null) {
      final kernel = _pendingKernel ?? _effectiveKernel;
      final hint = kernel == PlayerKernel.mpv
          ? 'MPV 首次启动要装载原生库，可能需要几秒；超过预算会自动回退 AVPlayer。'
          : '初始化完成后即可播放；一直没有响应可以切回 AVPlayer。';
      return _PlayerStageNotice(
        icon: Icons.hourglass_top_outlined,
        title: '正在准备 ${kernel.label} 播放器…',
        detail: hint,
        busy: true,
        actions: <Widget>[
          OutlinedButton(
            onPressed: _switchToAvPlayer,
            child: const Text('切回 AVPlayer'),
          ),
        ],
      );
    }

    return ValueListenableBuilder<PlayerSnapshot>(
      valueListenable: player.snapshot,
      builder: (context, snapshot, _) => snapshot.error == null
          ? _buildVideoArea(player)
          : _buildErrorStage(snapshot),
    );
  }

  /// 播放失败：如实显示内核给的文案（不再叠一层自己的话）。
  Widget _buildErrorStage(PlayerSnapshot snapshot) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: PlaybackFailurePanel(
            key: ValueKey(
              'playback-failure-${_target?.sourceId ?? widget.sourceId}',
            ),
            error: snapshot.error ?? '播放连接中断',
            dark: true,
            sourceId: _target?.sourceId ?? widget.sourceId,
            manager:
                widget.sourceManager ??
                (_fallbackManager ??= LumeSources.manager(Section.video)),
            retry: () => _restoreInlinePlayback(retry: true),
            onUpdated: () async {
              _nextEpisodeBuffer.discard();
              _source = null;
              await _openSource();
              if (mounted) _showToast('源已更新，请重试播放以获取新地址');
            },
            extraActions: [
              if (_target != null &&
                  ((snapshot.error ?? '').contains('403') ||
                      shouldOfferWebView(snapshot.error)))
                TextButton(
                  onPressed: _openPlaybackVerification,
                  child: const Text('播放网页验证'),
                ),
              if (_target != null)
                TextButton(
                  onPressed: _findAlternativeSource,
                  child: const Text('保持集数换源'),
                ),
              TextButton(
                onPressed: _offerAlternativeLines,
                child: const Text('换线路继续看'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _findAlternativeSource() async {
    final target = _target, library = _library;
    if (target == null || library == null) return;
    _saveProgress(force: true);
    final snapshot = _player?.snapshot.value;
    final resume = VideoResumeRequest(
      title: target.title,
      chapterTitle: target.chapterTitle,
      chapterIndex: target.chapterIndex,
      position: snapshot?.error == null
          ? snapshot?.position ?? _healthyPosition
          : _healthyPosition,
      duration: snapshot?.duration ?? Duration.zero,
    );
    await _player?.pause();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: Section.video,
          keyword: target.title,
          mode: SearchMode.aggregate,
          manager: widget.sourceManager,
          onOpenItem: (selection) async {
            if (!mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VideoDetailPage(
                  sourceId: selection.sourceId,
                  manager: widget.sourceManager,
                  loadSource: () =>
                      (widget.sourceManager ??
                              LumeSources.manager(Section.video))
                          .open(selection.sourceId),
                  item: selection.item,
                  library: library,
                  resumeRequest: resume,
                  onPlay: (media, next, qualities, prepared) async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => VideoPlayerPage(
                          media: media,
                          target: next,
                          qualities: qualities,
                          prelaunch: prepared,
                          sourceManager: widget.sourceManager,
                          library: library,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPlaybackVerification() async {
    final target = _target;
    final media = _media;
    if (target == null || media == null) return;
    final outcome = await runWafWebViewFlow(
      context: context,
      section: Section.video,
      sourceId: target.sourceId,
      sourceName: _source?.name ?? target.title,
      failureMessage: 'NEED_WEBVIEW_VERIFY：播放资源需要验证 ${media.uri}',
      originUrl: media.uri.toString(),
    );
    if (!mounted || !identical(media, _media)) return;
    if (outcome == WafWebViewOutcome.collected) {
      await _restoreInlinePlayback(retry: true);
    }
  }

  /// 已经记过日志的那条失败文案（同一条只记一次，别每秒刷屏）。
  String? _loggedFailure;

  /// 播放失败时记一行**能定位原因**的日志：失败地址的域名 + 这次带了哪些请求头。
  ///
  /// 用户报「播放链接中断 / 403」时，日志里必须能看出是哪个域名在拒绝：
  /// 源站自己的域名被拦（可以带该源验证过的会话再试）与独立媒体域名被拦
  /// （会话按纪律不发给它）是两件完全不同的事，没有这一行只能靠猜。
  void _logPlaybackFailure(PlayerSnapshot snapshot) {
    final error = snapshot.error ?? '';
    if (error.isEmpty || error == _loggedFailure) return;
    _loggedFailure = error;
    final media = _media;
    final headers = _playbackRequestHeaders;
    // 文案与错误卡一致（内核给的原文已经带「打开失败：」前缀时不再叠一层）。
    final reason = error.startsWith('打开失败：')
        ? error
        : PlayerErrorText.describe(error);
    LumeLog.warn(
      '[player] 播放失败：$reason'
      // 打**完整地址**：域名空白的见过（file:// 误判），只打 host 会看不到那条线索。
      '｜地址 ${media?.uri.toString() ?? '未知'}'
      '｜请求头 ${headers.isEmpty ? '无' : headers.keys.join(',')}',
    );
  }

  /// 就绪态的画面区：画面 + 亮度遮罩 + 弹幕层 + 手势层 + HUD（+ 锁屏开关）。
  ///
  /// 画面区铺一层**纯黑底**：竖屏短剧按原始比例居中渲染后，多出来的左右位置就是
  /// 这块黑边（用户要求：留黑边，禁止拉伸变形）；横片上下留边同理。以前这里是
  /// 页面底色（浅色），竖屏视频两侧会亮成一条白边，很显眼。
  Widget _buildVideoArea(AbstractPlayer player) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            // 铺满整个播放区域：手势与 HUD 必须覆盖黑边。
            fit: StackFit.expand,
            alignment: Alignment.bottomLeft,
            children: <Widget>[
              // 画面本身居中，并按设置做取景 / 缩放 / 旋转 / 镜像。
              Center(child: _buildPicture(player, constraints)),
              // 亮度遮罩：**降级路径**用（平台不支持改系统亮度时）。
              if (!_systemBrightness && _brightness < 1.0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: (1.0 - _brightness) * 0.75,
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  // 弹幕让开顶部状态/片名与底部进度/控制两段，避免文字压在 HUD 上。
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: _fullscreen ? 72 : 8,
                      // 竖屏底部多了安全区，留 110 才不压进度条。
                      bottom: _fullscreen
                          ? (size.height > size.width ? 110 : 96)
                          : 8,
                    ),
                    child: ValueListenableBuilder<PlayerSnapshot>(
                      valueListenable: player.snapshot,
                      builder: (context, snapshot, _) => DanmakuOverlay(
                        position: snapshot.position,
                        playing: snapshot.playing && !snapshot.buffering,
                        playbackRate: _settings.speed,
                        track: _danmaku,
                        settings: _danmakuSettings,
                      ),
                    ),
                  ),
                ),
              ),
              // 手势层：锁定时不吃手势（防误触的本意就在这里）。
              if (!_locked) Positioned.fill(child: _buildGestureLayer(size)),
              if (_locked)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showUnlock,
                  ),
                ),
              // 全屏时这两格挪到顶栏片名后面（见 [_buildImmersiveTopBar]）；
              // 竖屏/半屏仍然钉在画面左上与右下。
              if (!_fullscreen)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 48,
                  child: IgnorePointer(
                    child: PlayerHud(
                      stats: player.stats,
                      showSpeed: false,
                      showDetails: !_locked,
                    ),
                  ),
                ),
              if (!_fullscreen)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: PlayerHud(
                      stats: player.stats,
                      networkKbps: _networkSpeed.kbps,
                      showDetails: false,
                    ),
                  ),
                ),
              // 锁屏开关：锁定时只留它，其余控制全收起。
              if (!_fullscreen && !_locked)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      tooltip: _locked ? '解除锁定' : '锁定（防误触）',
                      icon: LumeIcon(
                        _locked ? Icons.lock : Icons.lock_open,
                        slot: 'video_player_page.7',
                        variant: true,
                        color: Colors.white,
                        shadows: const <Shadow>[
                          Shadow(color: Colors.black54, blurRadius: 6),
                        ],
                      ),
                      onPressed: _setLocked,
                    ),
                  ),
                ),
              // 顶部轻提示（换集、手势、失败等），不拦手势。
              Positioned(
                top: _fullscreen ? 64 : 8,
                left: 16,
                right: 16,
                child: IgnorePointer(child: _buildHintPill()),
              ),
              // 单击画面由手势层统一切换控制栏（见 _buildGestureLayer）；
              // 双击左右两侧快进/快退 10 秒（上面这层只吃点击，不吃拖动）。
              if (_fullscreen && !_locked) ...[
                for (final (alignment, direction) in <(Alignment, int)>[
                  (Alignment.centerLeft, -1),
                  (Alignment.centerRight, 1),
                ])
                  Align(
                    alignment: alignment,
                    child: SizedBox(
                      width: size.width * .27,
                      height: size.height,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _toggleOverlayByTap,
                        onDoubleTap: () => unawaited(_seekBySide(direction)),
                      ),
                    ),
                  ),
              ],
              Positioned.fill(
                child: ValueListenableBuilder<PlayerSnapshot>(
                  valueListenable: player.snapshot,
                  builder: (context, snapshot, _) => PlayerWaitingOverlay(
                    snapshot: snapshot,
                    operation: _operation,
                    locked: _locked,
                    onRetry: () =>
                        unawaited(_restoreInlinePlayback(retry: true)),
                    onSwitchLine: _offerAlternativeLines,
                  ),
                ),
              ),
              if (!_locked)
                Positioned(
                  right: 12,
                  bottom: _fullscreen ? 116 : 58,
                  child: _originalSkipPrompt(),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 画面取景与变换：适应 / 填充 / 倍率 + 旋转 + 镜像。
  ///
  /// 为什么放在页面层而不是各内核里：这三件事都是「把内核渲染好的画面怎么摆」，
  /// 与解码链无关。三套内核都只提供「一块能画画的区域」，因此这里按视频宽高比
  /// 先算好看画面的框，再叠加变换——内核之间不会出现「MPV 能转、MDK 不能转」。
  Widget _buildPicture(AbstractPlayer player, BoxConstraints constraints) {
    if (_musicMode) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(
            Icons.music_note_rounded,
            color: Colors.white54,
            size: 64,
          ),
        ),
      );
    }
    final prefs = _settings.current;
    final stats = player.stats.value;
    final view = player.buildView();

    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final aspect = _videoAspect(stats);
    if (aspect == null || width <= 0 || height <= 0) {
      // 还没有视频参数（起播瞬间）：原样放，参数到了自然就正了。
      return _transformed(view, prefs);
    }

    // 旋转 90 / 270 时用户看到的宽高是反的，取景要按「换轴后」的比例算。
    final visible = prefs.rotation.swapsAxes ? 1 / aspect : aspect;
    final containWidth = math.min(width, height * visible);
    final containHeight = containWidth / visible;
    final coverWidth = math.max(width, height * visible);
    final coverHeight = coverWidth / visible;
    final boxWidth = prefs.zoom.covers ? coverWidth : containWidth;
    final boxHeight = prefs.zoom.covers ? coverHeight : containHeight;

    return ClipRect(
      child: Center(
        child: _transformed(
          SizedBox(width: boxWidth, height: boxHeight, child: view),
          prefs,
        ),
      ),
    );
  }

  /// 视频宽高比（内核 HUD 参数里拿；拿不到时返回 null）。
  static double? _videoAspect(PlayerStats stats) {
    final width = stats.width;
    final height = stats.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return width / height;
  }

  /// 倍率 + 旋转 + 镜像（顺序固定：先转再镜像、最后缩放）。
  Widget _transformed(Widget child, KernelPrefs prefs) {
    final matrix = Matrix4.identity();
    if (prefs.rotation.degrees != 0) {
      matrix.rotateZ(prefs.rotation.degrees * math.pi / 180);
    }
    if (prefs.mirrored) matrix.scaleByDouble(-1.0, 1.0, 1.0, 1.0);
    if (prefs.zoom.scale != 1.0) {
      matrix.scaleByDouble(prefs.zoom.scale, prefs.zoom.scale, 1.0, 1.0);
    }
    return Transform(
      transform: matrix,
      alignment: Alignment.center,
      child: child,
    );
  }

  /// 控制栏：进度（带拖动预览）+ 主控制 + 次级控制。
  ///
  /// [player] 为空时传输类按钮禁用，但**设置入口与「播放源」入口照常可用**——
  /// 「播不了」不该顺带剥夺「改设置、换内核、贴地址重试」这些出路。
  ///
  /// 两处按用户要求改过（见 [VideoPlayerPage.controlTopGap] 的说明）：
  /// - 地址行收进播放源弹窗（右下角那颗小信息图标），控制栏不再铺长链接；
  /// - 常用功能固定排列，控制区与画面之间只留一小段间距。
  Widget _buildControlPanel(AbstractPlayer? player) {
    return Padding(
      key: VideoPlayerPage.controlPanelKey,
      padding: const EdgeInsets.fromLTRB(
        16,
        VideoPlayerPage.controlTopGap,
        16,
        VideoPlayerPage.controlBottomGap,
      ),
      child: PlaybackGlass(
        enabled: _settings.playbackGlass,
        child: Column(
          children: <Widget>[
            ValueListenableBuilder<PlayerSnapshot>(
              valueListenable: player?.snapshot ?? _idleSnapshot,
              builder: (context, snapshot, _) => Column(
                children: <Widget>[
                  _buildProgress(snapshot),
                  _buildPrimaryControls(snapshot),
                  _buildSecondaryControls(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开播放源弹窗：看当前地址、复制、换线路（用户要求）。
  ///
  /// 与「清晰度」按钮共用同一个切线路回调（[_selectQuality]），两条入口的行为
  /// 因此永远一致。**手动贴地址的入口已按用户口径删除**：播放页只播图源 /
  /// 作品给的地址，不再提供「贴一条链接起播」的通道。
  Future<void> _offerAlternativeLines({String? selectedLine}) async {
    if (_advancing || _switchingQuality) return;
    final target = _target;
    final previousMedia = _media;
    final previousQualities = _qualities;
    final previousQualityIndex = _qualityIndex;
    if (target == null) {
      await _openSourceSheet();
      return;
    }
    try {
      final source = await _openSource();
      if (source == null || !mounted) return;
      final all = await VideoEpisodeCatalog.load(source, target.itemId);
      if (!mounted || _target?.isSameEpisode(target) != true) return;
      final current = all
          .where((entry) => entry.id == target.chapterId)
          .firstOrNull;
      if (current == null) {
        _showToast('当前剧集已变更，请重新选集');
        return;
      }
      final grouped = VideoEpisodeCatalog.group(all);
      final alternatives = grouped.keys
          .where((line) => line != VideoEpisodeCatalog.lineOf(current))
          .toList();
      if (alternatives.isEmpty) {
        _showToast('没有其他剧集线路，可在播放源中切换清晰度');
        await _openSourceSheet();
        return;
      }
      ModalRoute<String>? pickerRoute;
      final next =
          selectedLine ??
          await _playbackMenu<String>(
            context: context,
            builder: (context) {
              pickerRoute = ModalRoute.of<String>(context);
              return SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(
                      title: Text('换线路继续看'),
                      subtitle: Text('仅切换到对应集，保留当前播放位置'),
                    ),
                    for (final line in alternatives)
                      ListTile(
                        title: Text(line),
                        subtitle: Text(
                          VideoEpisodeCatalog.matchingIndex(
                                    current,
                                    grouped[line]!,
                                  ) <
                                  0
                              ? '没有对应集，请返回详情页手动选集'
                              : VideoEpisodeCatalog.displayLabel(
                                  current,
                                  target.chapterIndex,
                                ),
                        ),
                        enabled:
                            VideoEpisodeCatalog.matchingIndex(
                              current,
                              grouped[line]!,
                            ) >=
                            0,
                        onTap: () => Navigator.pop(context, line),
                      ),
                  ],
                ),
              );
            },
          );
      await pickerRoute?.completed;
      if (next == null || !mounted || _target?.isSameEpisode(target) != true) {
        return;
      }
      final index = VideoEpisodeCatalog.matchingIndex(current, grouped[next]!);
      if (index < 0) return;
      setState(() {
        _advancing = true;
        _operation = '正在切换至 $next';
      });
      final chapter = grouped[next]![index];
      final snapshot = _player?.snapshot.value;
      final previous = _library?.videoEpisodeProgress(
        target.itemId,
        target.chapterId,
        sourceId: target.sourceId,
      );
      final position = snapshot != null && snapshot.position > Duration.zero
          ? snapshot.position
          : previous?.position ?? Duration.zero;
      final content = await source.content(
        itemId: target.itemId,
        chapterId: chapter.id,
      );
      final qualities = SourcePlayback.contentQualities(
        content,
        source: source,
      );
      final chosen = PlaybackQualityPreference.select(qualities, _settings);
      final address = chosen?.url ?? SourcePlayback.contentAddress(content);
      if (address == null) throw StateError('该线路未返回可播放地址');
      if (!mounted || _target?.isSameEpisode(target) != true) return;
      setState(() {
        _qualities = qualities;
        _qualityIndex = 0;
      });
      await _startPlayback(
        PlayerMedia(
          uri: address,
          title: '${target.title} · ${chapter.title}',
          headers:
              chosen?.headers ??
              SourcePlayback.contentHeaders(content, source: source),
        ),
        target: VideoPlayTarget(
          sourceId: target.sourceId,
          itemId: target.itemId,
          title: target.title,
          cover: target.cover,
          chapterIndex: index,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
        resumePosition: position,
      );
      if (_player?.snapshot.value.error != null) throw StateError('线路播放失败');
      if (snapshot != null && !snapshot.playing) await _player?.pause();
      _saveProgress(force: true);
      if (mounted) _showToast('已切换到 $next，继续当前集');
    } catch (_) {
      if (mounted && _advancing) {
        setState(() {
          _target = target;
          _media = previousMedia;
          _qualities = previousQualities;
          _qualityIndex = previousQualityIndex;
        });
      }
      if (mounted) _showToast('切换失败，请重试或返回详情页选择其他线路');
    } finally {
      _advancing = false;
      if (mounted) setState(() => _operation = null);
    }
  }

  SectionImagePipeline? _episodeImages;

  Future<void> _openSourceSheet({
    PlayerSourceTab initialTab = PlayerSourceTab.episodes,
  }) async {
    if (!mounted) return;
    _cancelAutoHide();
    final target = _target;
    await _playbackMenu<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => PlayerSourceSheet(
        fullBleed: true,
        initialTab: initialTab,
        initialView:
            PlayerEpisodeView.values
                .where(
                  (v) =>
                      v.name ==
                      PlayerExperienceStore.current.text('episodeView'),
                )
                .firstOrNull ??
            PlayerEpisodeView.grid,
        onViewChanged: (view) {
          final library = _library;
          if (library != null) {
            PlayerExperienceStore.forLibrary(library)
                .update({'episodeView': view.name});
          }
        },
        artworkBuilder: (context, chapter, index) {
          final images = _episodeImages;
          if (images == null) return const Icon(Icons.movie_outlined);
          return PosterCover(
            pipeline: images,
            url: chapter.cover ?? target?.cover,
            headers: chapter.coverHeaders,
            width: 240,
            title: chapter.title,
            borderRadius: BorderRadius.zero,
          );
        },
        includeQualityTab: true,
        loadLines: target == null
            ? null
            : () async {
                final source = await _openSource();
                if (source == null) throw StateError('图源不可用');
                final all = await VideoEpisodeCatalog.load(
                  source,
                  target.itemId,
                );
                final current = all
                    .where((c) => c.id == target.chapterId)
                    .firstOrNull;
                return [
                  for (final group in VideoEpisodeCatalog.group(all).entries)
                    PlayerSourceLine(
                      group.key,
                      current:
                          current != null &&
                          group.key == VideoEpisodeCatalog.lineOf(current),
                      available:
                          current != null &&
                          VideoEpisodeCatalog.matchingIndex(
                                current,
                                group.value,
                              ) >=
                              0,
                    ),
                ];
              },
        onSelectLine: (line) async {
          if (target == null || _target?.isSameEpisode(target) != true) {
            return false;
          }
          await _offerAlternativeLines(selectedLine: line);
          return mounted &&
              _target?.chapterId != target.chapterId &&
              _player?.snapshot.value.error == null;
        },
        onSwitchLine: target == null
            ? null
            : () {
                Navigator.pop(sheetContext);
                unawaited(_offerAlternativeLines());
              },
        loadEpisodes: target == null
            ? null
            : () async {
                final source = await _openSource();
                if (source == null) throw StateError('图源不可用，请稍后重试');
                if (!mounted) return const <SourceChapter>[];
                final library = _library;
                if (library != null) {
                  _episodeImages ??= SectionImagePipeline(
                    cacheDir: library.imageCacheDir,
                    memoryBudgetBytes:
                        SectionImagePipeline.thumbnailBudgetBytes,
                  );
                  _episodeImages!.bindSource(source);
                  _episodeImages!.bindSession(Section.video, target.sourceId);
                }
                return VideoEpisodeCatalog.forChapter(
                  await VideoEpisodeCatalog.load(source, target.itemId),
                  target.chapterId,
                );
              },
        currentChapterId: target?.chapterId,
        onSelectEpisode: (index) async {
          if (target == null || _target?.isSameEpisode(target) != true) {
            return false;
          }
          if (index == target.chapterIndex) return true;
          return _playEpisodeAt(index);
        },
        address: _media?.uri.toString() ?? '',
        qualities: _qualities,
        currentIndex: _qualityIndex,
        onSelectQuality: _selectQuality,
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  Widget _buildProgress(PlayerSnapshot snapshot) {
    final old = _legacyProgress(snapshot);
    return old;
  }

  Widget _legacyProgress(PlayerSnapshot snapshot) {
    final total = snapshot.duration.inMilliseconds;
    final preview = _previewTarget;
    final shown = preview ?? snapshot.position;
    final slider = NativeGlassSlider(
      value: _fraction(shown, snapshot.duration),
      secondaryTrackValue: _fraction(
        shown + (_player?.stats.value.buffered ?? Duration.zero),
        snapshot.duration,
      ),
      onChangeStart: total == 0
          ? null
          : (value) {
              _seekRevision++;
              _lastScrubSeek = null;
              _pendingScrubSeek = null;
              _seekWatchdog?.cancel();
              _seekWatchdogGeneration++;
              _cancelAutoHide();
              setState(
                () => _previewTarget = _positionAt(value, snapshot.duration),
              );
            },
      onChanged: total == 0
          ? null
          : (value) {
              final target = _positionAt(value, snapshot.duration);
              setState(() => _previewTarget = target);
              _scrubSeekThrottled(target);
            },
      onChangeEnd: total == 0
          ? null
          : (value) async {
              final target = _positionAt(value, snapshot.duration);
              final player = _player;
              final revision = _seekRevision;
              _lastScrubSeek = null;
              // 松手即作废还没下发的拖动落点：这一轮只留这次精确跳转。
              _pendingScrubSeek = null;
              try {
                if (player != null) {
                  final ok = await _seekAndConfirm(player, target);
                  if (!ok) _armSeekWatchdog(player, target);
                }
              } catch (error) {
                if (mounted) _showToast('跳转失败，请重试');
              } finally {
                if (mounted && revision == _seekRevision) {
                  setState(() => _previewTarget = null);
                  _scheduleAutoHide();
                }
              }
            },
    );
    if (_fullscreen) {
      final theme = SliderTheme.of(context).copyWith(
        trackHeight: 4,
        disabledActiveTrackColor: const Color(0x80F8F8F8),
        disabledInactiveTrackColor: Colors.white24,
        disabledThumbColor: const Color(0xFFF8F8F8),
        activeTrackColor: const Color(0xFFF8F8F8),
        inactiveTrackColor: Colors.white24,
        secondaryActiveTrackColor: Colors.white54,
        thumbColor: const Color(0xFFF8F8F8),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 8,
          elevation: 0,
          pressedElevation: 0,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preview != null)
            Text(
              '拖动到 ${_format(preview)} · ${PlayerLayout.seekDelta(snapshot.position, preview)}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFFF8F8F8),
                fontSize: LumeTypography.descriptionSize + 1,
                shadows: _controlShadows,
              ),
            ),
          Row(
            children: [
              Text(
                _format(shown),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF8F8F8),
                  fontSize: LumeTypography.descriptionSize + 1,
                  shadows: _controlShadows,
                ),
              ),
              Expanded(
                child: SizedBox(
                  // 行距收窄：滑条行高从 44 收到 34，进度行整体下沉贴近按钮行。
                  height: 34,
                  child: SliderTheme(data: theme, child: slider),
                ),
              ),
              Text(
                snapshot.duration > Duration.zero
                    ? _format(snapshot.duration)
                    : '时长未知',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF8F8F8),
                  fontSize: LumeTypography.descriptionSize + 1,
                  shadows: _controlShadows,
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      children: <Widget>[
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                _format(shown),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize + 1,
                  shadows: _fullscreen ? _controlShadows : null,
                  // 拖动预览用高亮色：一眼能看出「这不是当前位置」。
                  color: _fullscreen
                      ? Colors.white
                      : (preview == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurface),
                ),
              ),
              if (preview != null)
                Text(
                  '拖动到 ${_format(preview)} · ${PlayerLayout.seekDelta(snapshot.position, preview)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize + 1,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              Text(
                snapshot.duration > Duration.zero
                    ? _format(snapshot.duration)
                    : '时长未知',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize + 1,
                  shadows: _fullscreen ? _controlShadows : null,
                  color: _fullscreen
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 主控制：后退 10 秒 / 播放暂停 / 停止 / 倍速 / 前进 10 秒。
  ///
  /// 与上一排（选集 / 弹 / 记片头 / 内核 / 全屏 / 设置）用**同一套按钮盒与
  /// `spaceEvenly`**：两排的图标落在同样的列上，看着才是齐的（用户口径：
  /// 直屏播放页全部文字图标对齐、大小统一）。
  Widget _buildPrimaryControls(PlayerSnapshot snapshot) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: _primaryActions(snapshot),
    );
  }

  /// 传输类按钮（停止 / 后退 / 播放暂停 / 前进 / 倍速）：常规面板与全屏浮层
  /// 中间那一组都用它，图标尺寸统一 [VideoPlayerPage.controlIconSize]。
  List<Widget> _primaryActions(PlayerSnapshot snapshot) {
    final player = _player;
    final playing = snapshot.playing && snapshot.error == null;
    return <Widget>[
      IconButton(
        iconSize: _iconSize + 5,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        color: _fullscreen
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        tooltip: '停止',
        icon: LumeIcon(
          Icons.stop_circle,
          slot: 'video_player_page.10',
          shadows: _fullscreen ? _controlShadows : null,
        ),
        onPressed: player?.stop,
      ),
      IconButton(
        iconSize: _iconSize + 5,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        color: _fullscreen
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        tooltip: '后退 10 秒',
        icon: LumeIcon(
          Icons.replay_10,
          slot: 'video_player_page.8',
          shadows: _fullscreen ? _controlShadows : null,
        ),
        onPressed: player == null
            ? null
            : () => _seekBy(const Duration(seconds: -10)),
      ),
      IconButton(
        // 播放/暂停仍是这一组的主按钮，比旁边大一档，但不再夸张。
        iconSize: _iconSize + 11,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        padding: EdgeInsets.zero,
        color: _fullscreen
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        tooltip: playing ? '暂停' : '播放',
        icon: LumeIcon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
          slot: 'video_player_page.9',
          variant: true,
          shadows: _fullscreen ? _controlShadows : null,
        ),
        onPressed: player == null
            ? null
            : () => snapshot.error != null
                  ? _restoreInlinePlayback(retry: true)
                  : (snapshot.playing ? player.pause() : player.play()),
      ),
      IconButton(
        iconSize: _iconSize + 5,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        color: _fullscreen
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        tooltip: '前进 10 秒',
        icon: LumeIcon(
          Icons.forward_10,
          slot: 'video_player_page.12',
          shadows: _fullscreen ? _controlShadows : null,
        ),
        onPressed: player == null
            ? null
            : () => _seekBy(const Duration(seconds: 10)),
      ),
      IconButton(
        tooltip: '播放速度（${_settings.speed}x）',
        iconSize: _iconSize + 5,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        icon: LumeIcon(
          Icons.speed,
          slot: 'video_player_page.11',
          shadows: _fullscreen ? _controlShadows : null,
        ),
        color: _fullscreen
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface,
        onPressed: _showSpeedPicker,
      ),
    ].map((button) => button).toList();
  }

  /// 次级控制：清晰度 / 弹幕 / 连播 / 画中画 / 全屏 / 设置，最右侧是播放源。
  ///
  /// 按钮一排用 [Wrap] 而不是 `Row`：这一排在小屏（iPhone SE 320pt）上放不下是
  /// 常态，换行比溢出好——所有入口都在，只是排成两行。
  ///
  /// 播放源那颗小信息图标**钉在整排的右侧**（用户要求：长链接收起来后改成
  /// 控制栏右侧的小图标），其余按钮的居中排布与大小、间距、颜色都不动。
  Widget _buildSecondaryControls() => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: _essentialActions(),
    ),
  );

  /// 紧凑的图标按钮（次级控制排专用，避免窄屏溢出）。
  Widget _compactIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) => _compactIconBody(
    icon: icon,
    tooltip: tooltip,
    onPressed: onPressed,
    highlighted: highlighted,
  );

  Widget _compactIconBody({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    if (_fullscreen) {
      return Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 32,
          height: 36,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: PlayerControlGlyph(
              icon,
              size: _iconSize,
              color: onPressed == null
                  ? const Color(0x99F8F8F8)
                  : const Color(0xFFF8F8F8),
            ),
          ),
        ),
      );
    }
    return IconButton(
      iconSize: _iconSize,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(minWidth: _box, minHeight: _box),
      padding: EdgeInsets.zero,
      color: _fullscreen
          ? (highlighted ? Colors.white : Colors.white70)
          : LumeTheme.accent,
      tooltip: tooltip,
      icon: _fullscreen
          ? PlayerControlGlyph(icon, size: _iconSize)
          : LumeIcon(icon, slot: 'video_player_page.13', variant: true),
      onPressed: onPressed,
    );
  }

  /// 相对当前位置跳转（前进 / 后退按钮）。越界值夹到 [0, duration]。
  Future<void> _seekBy(Duration delta) async {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;
    var target = snapshot.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (snapshot.duration > Duration.zero && target > snapshot.duration) {
      target = snapshot.duration;
    }
    try {
      final ok = await _seekAndConfirm(player, target);
      if (!ok) _armSeekWatchdog(player, target);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn(
        '[player] ${_settings.kernel.label} 跳转失败：'
        '${snapshot.position.inMilliseconds}ms → ${target.inMilliseconds}ms',
      );
      if (mounted && identical(_player, player)) {
        _showToast('跳转失败，请重试');
      }
    }
  }

  /// 画中画按钮：不可用时**照旧显示**，点了弹可读提示（不直接隐藏按钮）。
  Widget _buildPipButton() {
    final session = _session;
    if (session == null) {
      return _compactIcon(
        icon: Icons.picture_in_picture_alt,
        tooltip: '画中画：正在准备',
        onPressed: null,
      );
    }
    return ValueListenableBuilder<PipSnapshot>(
      valueListenable: session.snapshot,
      builder: (context, snapshot, _) {
        // 平台/内核没有画中画时整颗隐藏，而不是留一个点不动的按钮。
        if (snapshot.state == PipState.unavailable) {
          return const SizedBox.shrink();
        }
        return _compactIcon(
          icon: snapshot.isActive
              ? Icons.picture_in_picture
              : Icons.picture_in_picture_alt,
          tooltip: snapshot.isActive ? '退出画中画' : '进入画中画',
          highlighted: snapshot.isActive,
          onPressed: _togglePip,
        );
      },
    );
  }

  double _fraction(Duration position, Duration duration) {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final value = position.inMilliseconds / total;
    return value.clamp(0.0, 1.0);
  }

  /// 进度条比例 → 时间点。
  static Duration _positionAt(double value, Duration duration) =>
      Duration(milliseconds: (duration.inMilliseconds * value).round());

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// 全屏顶边的状态行：左侧时间、右侧真实电量。
class _PlayerClock extends StatefulWidget {
  const _PlayerClock({this.showBattery = true});

  /// 抽屉打开时右侧 40% 被玻璃盖住、工具条又顶到最上面，
  /// 电量图标会从图标底下透出来——这时先不画。
  final bool showBattery;

  @override
  State<_PlayerClock> createState() => _PlayerClockState();
}

class _PlayerClockState extends State<_PlayerClock> {
  static const MethodChannel _batteryChannel = MethodChannel('lumebox/battery');
  Timer? _timer;
  int? _batteryPercent;
  @override
  void initState() {
    super.initState();
    _refreshBattery();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        if (DateTime.now().second % 30 == 0) _refreshBattery();
      }
    });
  }

  Future<void> _refreshBattery() async {
    try {
      final raw = await _batteryChannel.invokeMethod<int>('level');
      final value = raw?.clamp(0, 100).toInt();
      if (mounted && value != _batteryPercent) {
        setState(() => _batteryPercent = value);
      }
    } on PlatformException {
      // 其它平台没有此通道时省略真实电量百分比。
    } on MissingPluginException {
      // 其它平台没有此通道时省略真实电量百分比。
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    const style = TextStyle(
      color: Color(0xFFF8F8F8),
      fontSize: LumeTypography.captionSize + 1,
      fontWeight: FontWeight.w600,
      shadows: _VideoPlayerPageState._controlShadows,
    );
    return Semantics(
      label:
          '时间 $time${_batteryPercent == null ? '' : '，电量 $_batteryPercent%'}',
      child: ExcludeSemantics(
        child: Row(
          key: const Key('player-status-row'),
          children: [
            Text(time, key: const Key('player-clock-text'), style: style),
            const Spacer(),
            if (_batteryPercent != null && widget.showBattery)
              Row(
                key: const Key('player-battery-group'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_batteryPercent%',
                    key: const Key('player-battery-text'),
                    style: style,
                  ),
                  const SizedBox(width: 4),
                  _BatteryGlyph(percent: _batteryPercent!),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _BatteryGlyph extends StatelessWidget {
  const _BatteryGlyph({required this.percent});
  final int percent;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 20,
        height: 11,
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFF8F8F8), width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFFF8F8F8)),
            ),
          ),
        ),
      ),
      const SizedBox(width: 1),
      Container(
        width: 2,
        height: 5,
        decoration: BoxDecoration(
          color: const Color(0xFFF8F8F8),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    ],
  );
}

class _ResumePoint {
  const _ResumePoint({required this.position, required this.playing});

  final Duration position;
  final bool playing;

  bool get isAtStart => position == Duration.zero;

  static _ResumePoint of(AbstractPlayer player) {
    final snapshot = player.snapshot.value;
    return _ResumePoint(position: snapshot.position, playing: snapshot.playing);
  }
}

/// 播放区的状态说明卡：正在准备 / 准备失败 / 设置库不可用。
///
/// 每种状态都**必须带出口**（重试或切回 AVPlayer）：播放器起不来时，用户手上
/// 得有点得动的东西，而不是一个没有说明、也不知道要等多久的转圈。
class _PlayerStageNotice extends StatelessWidget {
  const _PlayerStageNotice({
    required this.icon,
    required this.title,
    required this.detail,
    this.actions = const <Widget>[],
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final List<Widget> actions;

  /// 是否为「进行中」状态（标题旁显示进度指示）。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy)
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                LumeIcon(
                  icon,
                  slot: 'video_player_page.14',
                  variant: true,
                  size: 26,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: LumeTypography.titleSize + 1,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize + 1,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Android / Windows 的 UI 骨架占位：播放与画中画都不实现，只说明边界。
class _VideoSkeleton extends StatelessWidget {
  const _VideoSkeleton();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                LumeTheme.appName,
                style: TextStyle(
                  fontSize: LumeTypography.sectionTitleSize,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '当前平台在 Phase1 仅保留页面骨架',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.bodySize + 1,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.bodySize + 1,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 手势提示浮层：屏幕中央显示当前操作与数值（松手即消失）。
class _GestureHint extends StatelessWidget {
  const _GestureHint({
    required this.state,
    required this.brightness,
    required this.startPosition,
    required this.baseSpeed,
    required this.boostSpeed,
  });

  final Duration startPosition;
  final double baseSpeed, boostSpeed;

  final PlayerGestureState state;
  final double brightness;

  @override
  Widget build(BuildContext context) {
    final isSeek = state.intent == PlayerGestureIntent.seek;
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -.25),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    LumeIcon(
                      switch (state.intent) {
                        PlayerGestureIntent.brightness => Icons.brightness_6,
                        PlayerGestureIntent.volume => Icons.volume_up,
                        PlayerGestureIntent.seek => Icons.fast_forward,
                        PlayerGestureIntent.boost => Icons.speed,
                        PlayerGestureIntent.none => Icons.touch_app,
                      },
                      slot: 'video_player_page.15',
                      variant: true,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _label(),
                      style: const TextStyle(
                        fontSize: LumeTypography.titleSize + 1,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                if (!isSeek &&
                    state.intent != PlayerGestureIntent.boost) ...<Widget>[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 140,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: state.intent == PlayerGestureIntent.brightness
                            ? brightness
                            : state.volume,
                        minHeight: 4,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _label() {
    switch (state.intent) {
      case PlayerGestureIntent.brightness:
        return '亮度 ${(brightness * 100).round()}%';
      case PlayerGestureIntent.volume:
        return '音量 ${(state.volume * 100).round()}%';
      case PlayerGestureIntent.seek:
        return '${PlayerGesturePolicy.describe(PlayerGestureIntent.seek, position: state.seekTarget)} · ${PlayerLayout.seekDelta(startPosition, state.seekTarget ?? startPosition)}';
      case PlayerGestureIntent.boost:
        return '临时 ${boostSpeed}x · 松手恢复 ${baseSpeed}x';
      case PlayerGestureIntent.none:
        return '';
    }
  }
}

/// 选择音轨 / 字幕轨的面板（一行一条，当前选中的打勾）。
class _TrackSheet extends StatelessWidget {
  const _TrackSheet({
    required this.title,
    required this.tracks,
    this.allowOff = false,
  });

  /// 「关闭字幕」这一项的哨兵 id（选中它 = 传 null 给内核）。
  static const String offId = '__off__';

  final String title;
  final List<PlayerTrack> tracks;

  /// 是否提供「关闭」项（字幕轨要，音轨不要——把音轨全关掉等于静音）。
  final bool allowOff;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.transparent),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize + 1,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    if (allowOff)
                      ListTile(
                        dense: true,
                        leading: const LumeIcon(
                          Icons.block,
                          slot: 'video_player_page.16',
                          size: 20,
                        ),
                        title: Text(
                          '关闭字幕',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(offId),
                      ),
                    for (final track in tracks)
                      ListTile(
                        dense: true,
                        leading: LumeIcon(
                          track.selected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          slot: 'video_player_page.17',
                          variant: true,
                          size: 20,
                          color: track.selected
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        title: Text(
                          track.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: track.language == null
                            ? null
                            : Text(
                                track.language!,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: LumeTypography.descriptionSize + 1,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                        onTap: () => Navigator.of(context).pop(track.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
