import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import 'playback_glass.dart';
import '../../core/session/app_preferences.dart';

import 'dart:io' show Platform;

import '../../core/net/ios_verified_webview.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/buffering.dart';
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
import 'danmaku/danmaku_service_sheet.dart';
import 'danmaku/danmaku_overlay.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_settings_sheet.dart';
import 'player_gestures.dart';
import 'player_hud.dart';
import 'player_control_glyph.dart';
import 'playback_source_validator.dart';
import 'playback_quality_preference.dart';
import 'player_kernel_picker.dart';
import 'next_episode_buffer.dart';
import 'player_settings_sheet.dart';
import 'player_source_sheet.dart';
import 'player_speed_meter.dart';
import 'source_playback.dart';
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

  /// 候选清晰度线路（图源给多条时才有）。空 / 单条时「清晰度」按钮弹提示，
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
  static const double controlHorizontalPadding = 16;

  /// 进度条行与按钮行之间的固定行距（用户口径：两行给一个固定值）。
  static const double controlRowGap = 10;

  /// 控制栏里图标按钮的统一尺寸（图标 21 / 触达盒 40）：顶部与底部、横屏与
  /// 竖屏都用它，尺寸与间距才一致（用户口径：图标尺寸统一、文字图标大小统一）。
  /// 这里是 **100% 档**的基准值，实际取值再乘模块设置里的「控件尺寸」倍率。
  static const double controlIconSize = 21;
  static const double controlBox = 40;

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

  /// 锁屏防误触：锁定后手势层与所有控制都不响应，只留一个解锁按钮。
  bool _locked = false;

  /// 全屏（沉浸）模式：顶栏与控制栏收起，点画面切换浮层控制栏。
  late bool _fullscreen = widget.fullscreenOnly;
  final _nextEpisodeBuffer = NextEpisodeBuffer();

  /// 全屏模式下的浮层控制栏是否可见。
  bool _overlayVisible = true;

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
  double get _box => VideoPlayerPage.controlBox * _controlScale;
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
          _session?.state != PipState.active) {
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

  Future<void> _restoreInlinePlayback({bool retry = false}) async {
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
        final position = _healthyPosition;
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
        if (position > Duration.zero) await player.seek(position);
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
    } else {
      _scheduleAutoHide();
    }
  }

  @override
  void dispose() {
    _rebuildSeq++;
    _introGeneration++;
    _intro?.dispose();
    _nextEpisodeBuffer.discard();
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
    if (snapshot != null &&
        snapshot.error == null &&
        !_recoveringPlayback &&
        (_lifecycle == AppLifecycleState.resumed ||
            (playing && snapshot.position > Duration.zero))) {
      _healthyPosition = snapshot.position;
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
          _autoNext &&
          _lifecycle == AppLifecycleState.resumed &&
          _session?.state != PipState.active &&
          snapshot.position >= const Duration(seconds: 10) &&
          remaining >= const Duration(seconds: 5) &&
          remaining <= const Duration(seconds: 30) &&
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
      // 新播放默认按媒体比例适应，旧的缩小档位不影响新播放。
      _settings = store.load().copyWith(zoom: ZoomMode.fit);
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
    await _rebuildPlayer();
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
  Future<void> _rebuildPlayer() async {
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
    final resume = previous == null ? null : _ResumePoint.of(previous);
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
      _suppressProgressSave = false;
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
    player.snapshot.addListener(_onSnapshotChanged);
    // 分辨率参数也算全屏方向的输入（「自动」档要按宽高比判断，见 [_onStatsChanged]）。
    player.stats.addListener(_onStatsChanged);

    try {
      // 缓冲参数要先于装载落定（见 [AbstractPlayer.setBuffering]）：模块设置里的
      // 「前向缓冲」就是经这里真正生效的（0 = 交给内核自动决定）。
      await player.setBuffering(_buffering);
      if (!mounted || !identical(player, _player)) return;
      await player.applySettings(_settings);
      if (!mounted || !identical(player, _player)) return;
      final media = _media;
      if (media != null) await _loadMedia(media);
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
      _suppressProgressSave = false;
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
    _nextEpisodeBuffer.discard();
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
    _playbackRequestHeaders = media.headers ?? const {};
    if (!alreadyLoaded) {
      final headers = Platform.isIOS && _target != null
          ? await IosVerifiedWebView.resourceHeaders(
              media.uri.toString(),
              media.headers ?? const {},
            )
          : media.headers;
      if (!mounted ||
          !identical(player, _player) ||
          !identical(media, _media)) {
        return;
      }
      _playbackRequestHeaders = headers ?? const {};
      await player.load(
        PlayerMedia(uri: media.uri, title: media.title, headers: headers),
      );
    }
    if (!mounted || !identical(player, _player) || !identical(media, _media)) {
      return;
    }
    // 起播那几秒里同一个 CDN 域名上多一条 256KB 探测，就是和首帧缓冲抢带宽。
    if (!mounted) return;
    setState(() => _loaded = player.snapshot.value.error == null);
  }

  /// 设置变更：落库并立即生效；换内核走重建，其余项直接应用到当前内核。
  Future<void> _applySettings(PlayerSettings next) async {
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
    }
  }

  /// 可读提示（不冒泡异常）。
  ///
  /// 时长与排队按用户口径调过：默认是 4 秒一条**且排队**——像「这条视频没有可选
  /// 音轨」这种连着来的提示，黑条会在控制栏上压完一条又一条，看着像卡住了。
  /// 现在 1.6 秒、悬浮，并且新提示直接顶掉上一条（不排队）。
  void _showToast(String? message) {
    if (message == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          (_fullscreen
                  ? 100.0
                  : math.min(
                      MediaQuery.sizeOf(context).height * .32,
                      220 * _controlScale,
                    )) +
              MediaQuery.paddingOf(context).bottom +
              8,
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
    if (index < 0 || index >= _qualities.length) return;
    // Manual intent also invalidates a preloaded next episode when this is already the active level.
    _nextEpisodeBuffer.discard();
    {
      _settings = _settings.copyWith(
        manualQualityLabel: _qualities[index].label,
      );
      _store?.save(_settings);
    }
    if (index == _qualityIndex) return;
    final player = _player;
    if (player == null) return;

    final snapshot = player.snapshot.value;
    final resume = snapshot.position;
    final playing = snapshot.playing;
    final quality = _qualities[index];
    // 换线路同样是「旧地址停、新地址起」：先落盘、期间抑制自动落盘，
    // 否则会把位置 0 写进记录（与换内核同一条坑）。
    _saveProgress(force: true);
    _suppressProgressSave = true;
    setState(() => _qualityIndex = index);

    await _loadMedia(
      PlayerMedia(
        uri: quality.url,
        title: _media?.title,
        // 线路自己的头优先，没有就沿用主地址的（防盗链头大多写在主地址上）。
        headers: quality.headers.isEmpty ? _media?.headers : quality.headers,
      ),
    );
    _suppressProgressSave = false;
    if (!mounted) return;
    if (resume > Duration.zero) await player.seek(resume);
    if (playing) await player.play();
    if (!mounted) return;
    _showToast('已切换到 ${quality.label}');
  }

  /// 打开清晰度菜单；只有一条线路时按用户口径**弹提示**而不是藏按钮。
  Future<T?> _playbackMenu<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    Color? backgroundColor,
    bool isScrollControlled = false,
    bool useSafeArea = false,
  }) => showPlaybackMenu<T>(
    context: context,
    builder: builder,
    glass: _settings.playbackGlass,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
  );

  Future<void> _openQualityMenu() async {
    if (_qualities.isEmpty) {
      _showToast('当前图源不提供多清晰度选项');
      return;
    }
    final selected = await _playbackMenu<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _QualitySheet(qualities: _qualities, currentIndex: _qualityIndex),
    );
    if (selected == null || !mounted) return;
    await _selectQuality(selected);
  }

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
    await _loadMedia(media, alreadyLoaded: preparedPlayer != null);
    if (!mounted || !identical(media, _media)) return;
    await _restoreProgress();
    _startProgressTicker();
    unawaited(_loadDanmaku(target));
    // 打开视频即自动播放（用户要求）：装载与续播定位都做完之后再发 play，
    // 免得播放器在 seek 之前就开跑、位置被拉回开头。
    if (_player != null && mounted) {
      await _player!.play();
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
      await player.setVolume(_gesture.volume);
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
      setState(() => _player = player);
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
    if (_advancing) return false;
    final target = _target;
    final source = await _openSource();
    if (!mounted) return false;
    if (target == null || source == null) {
      if (!auto) _showToast('手动贴地址播放时没有剧集列表');
      return false;
    }

    _advancing = true;
    try {
      final prepared = _session?.state == PipState.active
          ? null
          : _nextEpisodeBuffer.take(target, index, _settings.kernel);
      final List<SourceChapter>? chapters;
      try {
        chapters = prepared == null
            ? await source.chapters(target.itemId)
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
      await _startPlaybackSafely(
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
      if (auto) _showToast('已自动播放：${next.title}');
      return true;
    } on SourceException {
      // 连播失败不打扰：用户没主动要求跳集，安静停在当前状态即可。
      return false;
    } finally {
      _advancing = false;
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
        _publicDanmakuStatus = '正在匹配公共弹幕…';
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
            var id = _library?.setting(_matchingKey(target, config.baseUrl));
            if (id == null) {
              final matches = await client.search(
                target.title,
                episode: target.chapterIndex + 1,
              );
              id = DandanplayClient.exactMatch(matches, target.title)?.id;
            }
            if (!publicCurrent()) return;
            if (id == null) {
              setState(() => _publicDanmakuStatus = '未能唯一匹配，请手动选择弹幕');
              return;
            }
            track = await client.comments(id);
          }
          if (!publicCurrent()) return;
          _publicDanmakuCache.put(cacheKey, target.chapterId, track);
          setState(() {
            _publicDanmakuTrack = track!;
            _publicDanmakuCount = track.length;
            _publicDanmakuStatus = track.isEmpty
                ? '公共库本集暂无弹幕'
                : '公共库已加载 ${track.length} 条';
            _danmaku = _combinedDanmaku();
          });
        } catch (_) {
          if (publicCurrent()) {
            setState(() => _publicDanmakuStatus = '公共弹幕加载失败，可重试或换服务');
          }
        } finally {
          client?.close();
          _danmakuClients.remove(client);
          if (publicCurrent()) _notifyDanmakuSheet();
        }
      }(),
    ]);
  }

  Future<void> _configureDanmakuService() async {
    final config = await DandanplayCredentials.load();
    if (!mounted) return;
    final updated = await _playbackMenu<DandanplayCredentials>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DanmakuServiceSheet(initial: config),
    );
    if (updated != null && mounted) await _loadDanmaku(_target, force: true);
  }

  Future<void> _matchPublicDanmaku() async {
    final target = _target;
    if (target == null) {
      _showToast('请先从源条目播放视频');
      return;
    }
    final title = await _playbackMenu<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DanmakuMatchSheet(initial: target.title),
    );
    if (title == null || title.isEmpty || !mounted) return;
    final client = DandanplayClient(
      credentials: await DandanplayCredentials.load(),
    );
    _danmakuClients.add(client);
    try {
      final items = await client.search(
        title,
        episode: target.chapterIndex + 1,
      );
      if (!mounted || !(_target?.isSameEpisode(target) ?? false)) return;
      if (items.isEmpty) {
        _showToast('未找到这部作品的本集弹幕，可以修改片名或更换服务');
        return;
      }
      final selected = await _playbackMenu<DandanplayEpisode>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: DrawerGeometry.height(context),
            child: ListView(
              children: [
                const ListTile(title: Text('选择对应作品和集数')),
                for (final item in items)
                  ListTile(
                    title: Text(item.title),
                    subtitle: Text(item.episode),
                    onTap: () => Navigator.pop(context, item),
                  ),
              ],
            ),
          ),
        ),
      );
      if (selected == null ||
          !mounted ||
          !(_target?.isSameEpisode(target) ?? false)) {
        return;
      }
      final publicSeq = ++_publicDanmakuSeq;
      final track = await client.comments(selected.id);
      if (publicSeq != _publicDanmakuSeq) return;
      if (!mounted || !(_target?.isSameEpisode(target) ?? false)) return;
      _library?.setSetting(
        _matchingKey(target, client.credentials.baseUrl),
        selected.id,
      );
      _publicDanmakuTrack = track;
      _publicDanmakuCache.put(
        '${client.credentials.baseUrl}:${_danmakuKey(target)}',
        target.chapterId,
        track,
      );
      _applyDanmakuSettings(_danmakuSettings.copyWith(enabled: true));
      setState(() {
        _danmaku = _combinedDanmaku();
        _publicDanmakuCount = track.length;
        _publicDanmakuStatus = '公共库已加载 ${track.length} 条';
      });
      _notifyDanmakuSheet();
      _showToast('已加载 ${track.length} 条公共弹幕');
    } catch (_) {
      if (mounted && (_target?.isSameEpisode(target) ?? false)) {
        _showToast('公共弹幕搜索失败，请检查服务地址或更换服务');
      }
    } finally {
      client.close();
      _danmakuClients.remove(client);
    }
  }

  /// 打开弹幕设置面板。
  Future<void> _openDanmakuSettings() async {
    _cancelAutoHide();
    await _playbackMenu<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _danmakuRevision,
        builder: (_, revision, child) => DanmakuSettingsSheet(
          settings: _danmakuSettings,
          danmakuCount: _danmaku.length,
          status:
              '源弹幕 $_sourceDanmakuCount 条 · 公共弹幕 $_publicDanmakuCount 条\n$_publicDanmakuStatus',
          onMatch: _matchPublicDanmaku,
          onConfigureService: _configureDanmakuService,
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

    final saved = library.videoProgress(target.itemId);
    if (saved == null || saved.chapterIndex != target.chapterIndex) return;
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
    _skipMarks = SkipMarksStore(library).load(target.itemId);
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
    SkipMarksStore(library).save(target.itemId, next);
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
    SkipMarksStore(library).clear(target.itemId);
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
            fontSize: LumeTypography.bodySize,
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
    final target = _target;
    final library = _library;
    final snapshot = _player?.snapshot.value;
    if (target == null || library == null || snapshot == null) return;
    if (library.setting('history.incognito') == 'true') return;
    if (snapshot.error != null) return;

    final position = snapshot.position;
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
    if (_pipPlaying == snapshot.playing && _pipDuration == snapshot.duration) {
      return;
    }
    _pipPlaying = snapshot.playing;
    _pipDuration = snapshot.duration;
    unawaited(
      backend.updatePlaybackState(
        playing: snapshot.playing,
        duration: snapshot.duration,
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
    return GestureDetector(
      key: _gestureLayerKey,
      behavior: HitTestBehavior.opaque,
      onLongPressStart: !_settings.gestures.enabled || !_settings.gestures.boost
          ? null
          : (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _endBoost(),
      onLongPressCancel: _endBoost,
      onPanDown: (details) => _onGestureDown(details, size),
      onPanStart: (details) => _onGestureStart(details, size),
      onPanUpdate: (details) => _onGestureUpdate(details, size),
      onPanEnd: _onGestureEnd,
      onPanCancel: () {
        _endBoost();
        setState(() => _gesture = PlayerGestureState.idle);
      },
      child: _gesture.active
          ? _GestureHint(state: _gesture, brightness: _brightness)
          : const SizedBox.expand(),
    );
  }

  void _onGestureStart(DragStartDetails details, Size size) {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;
    _gestureOrigin ??= details.globalPosition;
    _gestureStartPosition = snapshot.position;
    _gestureStartVolume = _gesture.volume;
    _gestureStartBrightness = _brightness;
    final local = _localPositionOf(_gestureOrigin!, size);
    _gestureStartFraction = size.width <= 0 ? 0.5 : local.dx / size.width;
  }

  void _onGestureDown(DragDownDetails details, Size size) {
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

    // 已判定的意图优先：中途不换功能（换功能最让人恼火）。
    var intent = _gesture.intent;
    if (intent == PlayerGestureIntent.none) {
      intent = PlayerGesturePolicy.intentFor(
        dx: totalDx,
        dy: totalDy,
        startFraction: _gestureStartFraction,
      );
      if (intent == PlayerGestureIntent.seek) {
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
        unawaited(player.setVolume(next));
      case PlayerGestureIntent.seek:
        final target = PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: _gestureStartPosition,
          duration: snapshot.duration,
          dx: totalDx,
          width: size.width,
          window: Duration(seconds: _settings.gestures.seekSeconds),
        );
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
      unawaited(player.seek(target));
    }
    _endBoost();
    _gestureOrigin = null;
    setState(
      () => _gesture = PlayerGestureState.idle.copyWith(
        volume: _gesture.volume,
        brightness: _brightness,
      ),
    );
  }

  /// 长按：临时倍速。
  void _onLongPressStart() {
    final player = _player;
    if (player == null) return;
    _gestureSpeedBeforeBoost = _settings.speed;
    if (!_settings.gestures.enabled || !_settings.gestures.boost) return;
    final boosted = _settings.gestures.boostMultiplier == 2
        ? PlayerGesturePolicy.boostSpeed(_settings.speed)
        : (_settings.speed * _settings.gestures.boostMultiplier)
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
      extraControls: _buildPlaybackSettings(),
    );
  }

  Widget _buildPlaybackSettings() => StatefulBuilder(
    builder: (context, update) {
      final buffer = _buffering.forwardBuffer.inSeconds;
      final supported = _player?.capabilities.bufferingParams ?? false;
      return GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '播放与连接',
              style: TextStyle(
                fontSize: LumeTypography.sectionTitleSize,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
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
            Text('音量 ${(_gesture.volume * 100).round()}%'),
            Slider(
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
                      unawaited(_player!.setVolume(value));
                    },
            ),
            Text(
              supported
                  ? '前向缓冲 ${buffer == 0 ? '自动' : '$buffer 秒'}'
                  : '当前内核未提供缓冲参数',
            ),
            Slider(
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
    await player.selectSubtitleTrack(
      selected == _TrackSheet.offId ? null : selected,
    );
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
    final file = await openFile(acceptedTypeGroups: _subtitleTypes);
    if (file == null || !mounted) return;
    final ok = await player.loadSubtitleFile(file.path);
    if (!mounted) return;
    if (!ok) {
      _showToast('这个内核加载外挂字幕失败，可以换个内核再试');
      return;
    }
    if (!_settings.subtitlesEnabled) {
      await _applySettings(_settings.copyWith(subtitlesEnabled: true));
    }
    if (mounted) _showToast('已加载字幕：${file.name}');
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
          if (_locked && !_fullscreen)
            Align(alignment: Alignment.topRight, child: _buildUnlockButton()),
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
        // 竖屏短剧（宽 < 高）→ 竖屏全屏；其余（含参数未知）→ 横屏全屏，
        // 与历史行为一致：普通横片照旧横屏，不会因为这次改造反而变竖。
        return _isPortraitVideo
            ? const <DeviceOrientation>[DeviceOrientation.portraitUp]
            : const <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ];
    }
  }

  /// 当前视频是不是竖屏（宽 < 高）。参数没到 / 内核不报时按横片处理。
  bool get _isPortraitVideo {
    final stats = _player?.stats.value;
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
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_overlayVisible || _locked,
            child: AnimatedSwitcher(
              key: const Key('fullscreen-controls'),
              duration: const Duration(milliseconds: 200),
              child: !_overlayVisible || _locked
                  ? const SizedBox.shrink()
                  : SafeArea(
                      key: const Key('fullscreen-visible-controls'),
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: VideoPlayerPage.controlHorizontalPadding,
                              ),
                              child: _topIcon(
                                icon: Icons.lock_open,
                                tooltip: '锁定（防误触）',
                                onPressed: () {
                                  _cancelAutoHide();
                                  setState(() => _locked = true);
                                },
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                right: VideoPlayerPage.controlHorizontalPadding,
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
        if (_locked)
          SafeArea(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildUnlockButton(),
            ),
          ),
      ],
    );
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
      final narrow = constraints.maxWidth < 480;
      final title = _target?.title ?? widget.title ?? _media?.title ?? '播放';
      final episode = _target?.chapterTitle;
      return Padding(
        key: const Key('fullscreen-topbar'),
        padding: const EdgeInsets.symmetric(
          horizontal: VideoPlayerPage.controlHorizontalPadding,
          vertical: 4,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _topIcon(
              icon: Icons.arrow_back_ios_new,
              tooltip: '退出全屏',
              onPressed: () => _setFullscreen(false),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Row(
                children: [
                  Flexible(
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
                        if (episode != null &&
                            episode != '播放' &&
                            episode != title)
                          Text(
                            episode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: LumeTypography.captionSize,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFF8F8F8),
                              shadows: _controlShadows,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_player != null) ...[
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: narrow ? 68 : 180),
                      child: PlayerStatsInline(
                        stats: _player!.stats,
                        networkKbps: _networkSpeed.kbps,
                        stacked: narrow,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            _buildPipButton(),
            const SizedBox(width: 4),
            _topIcon(
              icon: VideoPlayerPage.playerKernelIcon,
              tooltip: '播放内核',
              onPressed: _openKernelPicker,
            ),
            const SizedBox(width: 4),
            _topIcon(
              icon: Icons.more_horiz,
              tooltip: '播放器设置',
              onPressed: _openSettings,
            ),
            const SizedBox(width: 4),
            const SizedBox(width: 48, child: _PlayerClock()),
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
            8,
            VideoPlayerPage.controlHorizontalPadding,
            2,
          ),
          child: ValueListenableBuilder<PlayerSnapshot>(
            valueListenable: _player?.snapshot ?? _idleSnapshot,
            builder: (context, snapshot, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
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

  /// 左侧播放与片头标记、右侧选集与弹幕倍速；组内固定 4dp 间隔。
  Widget _buildFloatingSplitControls(PlayerSnapshot snapshot) => LayoutBuilder(
    builder: (context, constraints) {
      final target = _target;
      final side = ((_box * 8 + 28) > constraints.maxWidth)
          ? ((constraints.maxWidth - 28) / 8).clamp(24.0, _box).toDouble()
          : _box;
      Widget action(
        String label,
        String tooltip,
        IconData icon,
        VoidCallback? callback, {
        VoidCallback? longPress,
      }) {
        return Tooltip(
          message: tooltip,
          child: SizedBox(
            width: side,
            height: 40,
            child: TextButton(
              onPressed: callback,
              onLongPress: longPress,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: const Color(0xFFF8F8F8),
                disabledForegroundColor: const Color(0x99F8F8F8),
              ),
              child: _settings.controlStyle == PlayerControlStyle.text
                  ? Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: (side < 34 ? 10 : 11) + 1,
                        fontWeight: FontWeight.w600,
                        shadows: _controlShadows,
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
      }

      final playing = snapshot.playing && snapshot.error == null;
      return Row(
        key: const Key('fullscreen-actions'),
        children: [
          action(
            '上集',
            '上一集',
            Icons.skip_previous,
            target == null || target.chapterIndex <= 0
                ? null
                : () => _playEpisodeAt(target.chapterIndex - 1),
          ),
          const SizedBox(width: 4),
          action(
            playing ? '暂停' : '播放',
            playing ? '暂停' : '播放',
            playing ? Icons.pause : Icons.play_arrow,
            _player == null
                ? null
                : () => unawaited(playing ? _player!.pause() : _player!.play()),
          ),
          const SizedBox(width: 4),
          action(
            '下集',
            '下一集',
            Icons.skip_next,
            target == null
                ? null
                : () => _playEpisodeAt(target.chapterIndex + 1),
          ),
          const SizedBox(width: 4),
          action(
            _skipQuickLabel(snapshot),
            _skipQuickTooltip(snapshot),
            Icons.bookmark_add_outlined,
            () => _intro?.prompt != null
                ? _originalSkipNow()
                : _markSkipFromQuick(snapshot),
            longPress: _clearSkipMarksFromQuick,
          ),
          const Spacer(),
          action(
            '画质',
            '清晰度',
            Icons.high_quality_outlined,
            _media == null ? null : _openQualityMenu,
          ),
          const SizedBox(width: 4),
          action(
            '选集',
            '线路 / 选集',
            Icons.playlist_play_outlined,
            _openSourceSheet,
          ),
          const SizedBox(width: 4),
          action(
            '弹幕',
            _danmakuSettings.enabled ? '弹幕：开' : '弹幕：关',
            Icons.chat_bubble_outline,
            _openDanmakuSettings,
          ),
          const SizedBox(width: 4),
          action(
            '${_settings.speed}x',
            '播放速度（${_settings.speed}x）',
            Icons.speed,
            _showSpeedPicker,
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
    if (_media != null) _actionLabel('画质', '清晰度', _openQualityMenu),
    _actionLabel('选集', '线路 / 选集', _openSourceSheet),
    _actionLabel(
      '弹',
      _danmakuSettings.enabled ? '弹幕：开' : '弹幕：关',
      _openDanmakuSettings,
      onLongPress: _toggleDanmaku,
      highlighted: _danmakuSettings.enabled,
    ),
    _skipQuickButton(),
    _actionLabel('片头尾', '片头片尾设置', _openOriginalIntro),
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
          fontSize: LumeTypography.bodySize,
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
    return _PlayerStageNotice(
      icon: Icons.wifi_off_rounded,
      title: (snapshot.error ?? '').contains('403') ? '视频服务器拒绝访问' : '播放连接中断',
      detail: (snapshot.error ?? '').startsWith('打开失败：')
          ? snapshot.error!
          : PlayerErrorText.describe(snapshot.error),
      actions: <Widget>[
        FilledButton.icon(
          onPressed: () => _restoreInlinePlayback(retry: true),
          icon: const LumeIcon(Icons.refresh, slot: 'video_player_page.6'),
          label: const Text('重试播放'),
        ),
        if (_target != null &&
            ((snapshot.error ?? '').contains('403') ||
                shouldOfferWebView(snapshot.error)))
          OutlinedButton(
            onPressed: _openPlaybackVerification,
            child: const Text('播放网页验证'),
          ),
        OutlinedButton(onPressed: _openSourceSheet, child: const Text('更换线路')),
      ],
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
              // 手势层：锁定时不吃手势（防误触的本意就在这里）。
              if (!_locked && _settings.gestures.enabled)
                Positioned.fill(child: _buildGestureLayer(size)),
              if (_locked)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showToast('已锁定：点锁图标解开'),
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
                      onPressed: () => setState(() => _locked = !_locked),
                    ),
                  ),
                ),
              // 全屏浮层收起时：点画面唤出控制栏。
              if (_fullscreen && !_overlayVisible && !_locked)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _overlayVisible = true);
                      _scheduleAutoHide();
                    },
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
  Future<void> _openSourceSheet() async {
    if (!mounted) return;
    _cancelAutoHide();
    final target = _target;
    await _playbackMenu<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PlayerSourceSheet(
        loadEpisodes: target == null
            ? null
            : () async {
                final source = await _openSource();
                if (source == null) throw StateError('图源不可用，请稍后重试');
                return source.chapters(target.itemId);
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
    final slider = Slider(
      value: _fraction(shown, snapshot.duration),
      secondaryTrackValue: _fraction(
        shown + (_player?.stats.value.buffered ?? Duration.zero),
        snapshot.duration,
      ),
      onChangeStart: total == 0
          ? null
          : (value) {
              _seekRevision++;
              _cancelAutoHide();
              setState(
                () => _previewTarget = _positionAt(value, snapshot.duration),
              );
            },
      onChanged: total == 0
          ? null
          : (value) => setState(
              () => _previewTarget = _positionAt(value, snapshot.duration),
            ),
      onChangeEnd: total == 0
          ? null
          : (value) async {
              final target = _positionAt(value, snapshot.duration);
              final player = _player;
              final revision = _seekRevision;
              final acknowledged = Completer<void>();
              void checkPosition() {
                if (player != null &&
                    !acknowledged.isCompleted &&
                    (player.snapshot.value.position - target).abs() <=
                        const Duration(seconds: 1)) {
                  acknowledged.complete();
                }
              }

              player?.snapshot.addListener(checkPosition);
              try {
                if (player != null) {
                  await player.seek(target);
                  checkPosition();
                  await acknowledged.future.timeout(
                    const Duration(seconds: 2),
                    onTimeout: () {},
                  );
                }
              } catch (error) {
                if (mounted) _showToast('跳转失败，请重试');
              } finally {
                player?.snapshot.removeListener(checkPosition);
                if (mounted && revision == _seekRevision) {
                  setState(() => _previewTarget = null);
                  _scheduleAutoHide();
                }
              }
            },
    );
    if (_fullscreen) {
      final theme = SliderTheme.of(context).copyWith(
        trackHeight: 3,
        disabledActiveTrackColor: const Color(0x80F8F8F8),
        disabledInactiveTrackColor: Colors.white24,
        disabledThumbColor: const Color(0xFFF8F8F8),
        activeTrackColor: const Color(0xFFF8F8F8),
        inactiveTrackColor: Colors.white24,
        secondaryActiveTrackColor: Colors.white54,
        thumbColor: const Color(0xFFF8F8F8),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 6,
          elevation: 0,
          pressedElevation: 0,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preview != null)
            Text(
              '拖动到 ${_format(preview)}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFFF8F8F8),
                fontSize: LumeTypography.descriptionSize,
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
                  fontSize: LumeTypography.descriptionSize,
                  shadows: _controlShadows,
                ),
              ),
              Expanded(
                child: SliderTheme(data: theme, child: slider),
              ),
              Text(
                _format(snapshot.duration),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF8F8F8),
                  fontSize: LumeTypography.descriptionSize,
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
                  fontSize: LumeTypography.descriptionSize,
                  shadows: _fullscreen ? _controlShadows : null,
                  // 拖动预览用高亮色：一眼能看出「这不是当前位置」。
                  color: _fullscreen
                      ? Colors.white
                      : (preview == null
                            ? LumeTheme.muted
                            : LumeTheme.textPrimary),
                ),
              ),
              if (preview != null)
                Text(
                  '拖动到 ${_format(preview)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    color: LumeTheme.textPrimary,
                  ),
                ),
              Text(
                _format(snapshot.duration),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize,
                  shadows: _fullscreen ? _controlShadows : null,
                  color: _fullscreen ? Colors.white : LumeTheme.muted,
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

  /// 传输类按钮（后退 / 播放暂停 / 停止 / 倍速 / 前进）：常规面板与全屏浮层
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
        color: _fullscreen ? Colors.white : LumeTheme.textPrimary,
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
        color: _fullscreen ? Colors.white : LumeTheme.textPrimary,
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
        color: _fullscreen ? Colors.white : LumeTheme.textPrimary,
        tooltip: '停止',
        icon: LumeIcon(
          Icons.stop_circle,
          slot: 'video_player_page.10',
          shadows: _fullscreen ? _controlShadows : null,
        ),
        onPressed: player?.stop,
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
        color: _fullscreen ? Colors.white : LumeTheme.textPrimary,
        onPressed: _showSpeedPicker,
      ),
      IconButton(
        iconSize: _iconSize + 5,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        color: _fullscreen ? Colors.white : LumeTheme.textPrimary,
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
      await player.seek(target);
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
      builder: (context, snapshot, _) => _compactIcon(
        icon: snapshot.isActive
            ? Icons.picture_in_picture
            : Icons.picture_in_picture_alt,
        tooltip: snapshot.state == PipState.unavailable
            ? '画中画：当前平台不支持'
            : (snapshot.isActive ? '退出画中画' : '进入画中画'),
        highlighted: snapshot.isActive,
        onPressed: _togglePip,
      ),
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

/// 内核切换前记录的位置与播放状态（新内核加载完成后接回去）。
class _PlayerClock extends StatefulWidget {
  const _PlayerClock();
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
      final value = await _batteryChannel.invokeMethod<int>('level');
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BatteryGlyph(percent: _batteryPercent),
            const SizedBox(width: 3),
            Text(
              '${_batteryPercent ?? '--'}%',
              style: const TextStyle(
                color: Color(0xFFF8F8F8),
                fontSize: LumeTypography.captionSize,
                fontWeight: FontWeight.w600,
                shadows: _VideoPlayerPageState._controlShadows,
              ),
            ),
          ],
        ),
        Text(
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(
            color: Color(0xFFF8F8F8),
            fontSize: LumeTypography.captionSize,
            fontWeight: FontWeight.w600,
            shadows: _VideoPlayerPageState._controlShadows,
          ),
        ),
      ],
    );
  }
}

class _BatteryGlyph extends StatelessWidget {
  const _BatteryGlyph({required this.percent});
  final int? percent;

  @override
  Widget build(BuildContext context) {
    final value = percent;
    return SizedBox(
      width: 8,
      height: 13,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFF8F8F8), width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
          borderRadius: BorderRadius.circular(2),
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: value == null ? 0 : (value / 100).clamp(0.0, 1.0),
            child: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFFF8F8F8)),
            ),
          ),
        ),
      ),
    );
  }
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
                  color: LumeTheme.textSecondary,
                ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: LumeTypography.titleSize,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize,
                  height: 1.5,
                  color: LumeTheme.descriptionColor,
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
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '当前平台在 Phase1 仅保留页面骨架',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.bodySize,
                  color: LumeTheme.muted,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.bodySize,
                  color: LumeTheme.muted,
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
  const _GestureHint({required this.state, required this.brightness});

  final PlayerGestureState state;
  final double brightness;

  @override
  Widget build(BuildContext context) {
    final isSeek = state.intent == PlayerGestureIntent.seek;
    return IgnorePointer(
      child: Center(
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
                        fontSize: LumeTypography.titleSize,
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
        return PlayerGesturePolicy.describe(
          PlayerGestureIntent.seek,
          position: state.seekTarget,
        );
      case PlayerGestureIntent.boost:
        return '快进中（松手恢复）';
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
                      fontSize: LumeTypography.titleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
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
                            color: LumeTheme.textPrimary,
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
                              ? LumeTheme.textPrimary
                              : LumeTheme.muted,
                        ),
                        title: Text(
                          track.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        subtitle: track.language == null
                            ? null
                            : Text(
                                track.language!,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: LumeTypography.descriptionSize,
                                  color: LumeTheme.descriptionColor,
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

/// 清晰度线路选择面板。
///
/// 只有图源给了多条线路时才会打开（单条时页面直接弹提示），因此这里不做空表兜底：
/// 每一条都是图源声明的「画质 → 地址」。
class _QualitySheet extends StatelessWidget {
  const _QualitySheet({required this.qualities, required this.currentIndex});

  final List<VideoQuality> qualities;
  final int currentIndex;

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
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '清晰度',
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '切换会保留当前位置继续播放',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.descriptionSize,
                      color: LumeTheme.descriptionColor,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: qualities.length,
                  itemBuilder: (context, index) {
                    final quality = qualities[index];
                    final selected = index == currentIndex;
                    return ListTile(
                      dense: true,
                      leading: LumeIcon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        slot: 'video_player_page.18',
                        variant: true,
                        size: 20,
                        color: selected
                            ? LumeTheme.textPrimary
                            : LumeTheme.muted,
                      ),
                      title: Text(
                        quality.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop(index),
                    );
                  },
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

/// 「匹配公共弹幕」的片名输入：**底部面板 + 跟随键盘**（用户口径）。
///
/// 原来用的是 AlertDialog：真机全屏（横屏）里键盘一顶，对话框被挤到只剩一条，
/// 输入框的标签与文字全糊在一条下划线上（用户截图）。换成底部面板后，键盘顶上来
/// 面板跟着上移，输入框、取消 / 搜索都在键盘上方，横竖屏都不会被挤扁。
class _DanmakuMatchSheet extends StatefulWidget {
  const _DanmakuMatchSheet({required this.initial});

  final String initial;

  @override
  State<_DanmakuMatchSheet> createState() => _DanmakuMatchSheetState();
}

class _DanmakuMatchSheetState extends State<_DanmakuMatchSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.transparent),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // 键盘高度由系统的 viewInsets 给：面板整体上移，输入框不会被盖住。
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '匹配公共弹幕',
                    style: TextStyle(
                      fontSize: LumeTypography.sectionTitleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: '片名',
                      hintText: '输入要匹配的番剧名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _submit,
                          child: const Text('搜索'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
