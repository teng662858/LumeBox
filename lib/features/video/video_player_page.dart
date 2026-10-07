import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/playback_session.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
import '../../core/player/pip_frame_pump.dart';
import '../../core/player/mpv_engine.dart';
import '../../core/player/mpv_player.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../../core/player/player_stats.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'danmaku/danmaku_models.dart';
import 'danmaku/danmaku_overlay.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_settings_sheet.dart';
import 'player_gestures.dart';
import 'player_hud.dart';
import 'player_settings_sheet.dart';
import 'player_speed_meter.dart';
import 'source_playback.dart';
import 'video_play_target.dart';
import 'video_player_settings.dart';

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
  });

  /// 起播媒体（含防盗链请求头）。
  ///
  /// 为空时页面照常创建播放器，只是**不装载任何媒体**：地址栏留空，用户贴一个
  /// 地址按播放键即可起播（手动地址没有作品身份，因此不记进度、不连播）。
  final PlayerMedia? media;

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

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  final TextEditingController _input = TextEditingController();

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

  String? _error;

  /// 设置库打不开：设置读写不可用，但播放链路继续（用默认设置）。
  bool _storeFailed = false;

  /// 本板块的阅读库：视频进度与「继续观看」落在它里面。
  ReadingLibrary? _library;

  /// 当前正在播的图源条目：有它才记进度。
  VideoPlayTarget? _target;

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
  bool _fullscreen = false;

  /// 全屏模式下的浮层控制栏是否可见。
  bool _overlayVisible = true;

  /// 进度条拖动预览的目标位置（拖动中显示，松手才真 seek）。
  Duration? _previewTarget;

  /// 网速表：按播放地址实测（三套内核都适用，见 [PlaybackSpeedMeter]）。
  late final PlaybackSpeedMeter _speed = widget.speedMeter ?? PlaybackSpeedMeter();

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
  bool _autoNext = true;

  /// 画中画帧转发泵：画中画激活期间按帧率节拍取帧并转发（仅 MPV 内核）。
  PipFramePump? _framePump;

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

  /// 弹幕：设置 + 本集弹幕 + 内存缓存（换集时按 itemId/chapterId 取）。
  DanmakuSettings _danmakuSettings = DanmakuSettings.defaults;
  DanmakuTrack _danmaku = DanmakuTrack.empty;
  final DanmakuCache _danmakuCache = DanmakuCache();

  /// 本平台是否提供任一播放内核（没有就是骨架占位）。
  bool get _anyKernelAvailable =>
      PlayerKernel.values.any(_catalog.isAvailable);

  /// 设置里选的内核不可用时回退到第一个可用内核（库被改坏也不至于打不开）。
  PlayerKernel get _effectiveKernel {
    if (_catalog.isAvailable(_settings.kernel)) return _settings.kernel;
    return PlayerKernel.values.firstWhere(_catalog.isAvailable);
  }

  @override
  void initState() {
    super.initState();
    final media = widget.media;
    _input.text = media?.uri.toString() ?? '';
    _syncQualityIndex(media);
    // 作品身份由 [_startPlayback] 在起播时落定：这里不预设，否则「换作品前先落盘
    // 上一部进度」那一步会在首次起播时写出一条位置为 0 的空记录。
    _media = media;
    if (_anyKernelAvailable) _boot();
  }

  @override
  void dispose() {
    // 顺序要紧：进度必须**在摘监听、清空 _player 之前**落盘——那两步之后
    // 就读不到播放位置了（记录会静默丢掉）。此刻也不能再 setState。
    _progressTimer?.cancel();
    _progressTimer = null;
    _saveProgress(force: true);

    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    player?.snapshot.removeListener(_onSnapshotChanged);
    // 锁屏播放条属于「当前这次播放」：页面退出即收起（听书那套随后可接管）。
    unawaited(_playback.stop());
    // 从全屏直接返回时把方向还原成竖屏（否则整个 App 留在横屏里）。
    if (_fullscreen) unawaited(_applyOrientation(false));
    unawaited(_commandSubscription?.cancel());
    // 资源边界：先退画中画再释放播放器，最后关库（顺序不能反）。
    unawaited(() async {
      await session?.dispose();
      await player?.dispose();
    }());
    _store?.close();
    if (widget.library == null) ReadingLibrary.close(Section.video);
    _input.dispose();
    _idleSnapshot.dispose();
    // 注入进来的网速表由调用方释放。
    if (widget.speedMeter == null) _speed.dispose();
    super.dispose();
  }

  /// 播放状态变化：在「从播放转为非播放」时立即落盘进度，并检查是否播完。
  void _onSnapshotChanged() {
    final snapshot = _player?.snapshot.value;
    final playing = snapshot?.playing ?? false;
    if (_wasPlaying && !playing) _saveProgress(force: true);
    _wasPlaying = playing;
    if (snapshot != null) {
      // 锁屏播放条跟随播放状态（进度在会话内部节流，不必在这里省）。
      unawaited(
        _playback.update(
          position: snapshot.position,
          playing: playing,
          duration: snapshot.duration > Duration.zero ? snapshot.duration : null,
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

  /// 是否已播到结尾（留 1 秒余量：播放器到结尾前会先停下）。
  ///
  /// 时长未知时一律返回 false——宁可不连播，也不在半途跳走。
  static bool _isFinished(PlayerSnapshot snapshot) {
    if (snapshot.duration <= Duration.zero) return false;
    if (snapshot.error != null) return false;
    return snapshot.position >= snapshot.duration - const Duration(seconds: 1);
  }

  Future<void> _boot() async {
    // 阅读库（进度）与播放器设置库分开打开：前者失败不该拦住播放。
    try {
      final library = widget.library ?? await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      setState(() {
        _library = library;
        _danmakuSettings = DanmakuSettingsStore(library).load();
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 阅读库打不开，本次不记录播放进度');
    }
    try {
      final store = await VideoPlayerSettingsStore.open();
      if (!mounted) {
        store.close();
        return;
      }
      _store = store;
      _settings = store.load();
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
      canEnter: () => _loaded && _player != null,
      onEvent: _onPipEvent,
    );
    _commandSubscription = _playback.commands.listen(_onPlaybackCommand);
    await _probeBrightness();
    await _rebuildPlayer();
    // 内核就绪后再把媒体交出去（有媒体、且播放器真的在手上时）。
    //
    // 播放器起不来时**不**走这一步：失败态已经有带出口的说明卡，再弹一条
    // 「还在准备」既不准确，又会用 SnackBar 盖住控制栏——真机上就是「点哪都没
    // 反应」（实测：发起播的 SnackBar 压在控制栏上，设置 / 全屏都点不到）。
    final media = widget.media;
    if (media != null && _player != null) {
      await _startPlaybackSafely(media, target: widget.target);
    }
  }

  /// 探测系统亮度能力，并把当前值对齐到亮度手势的起点。
  Future<void> _probeBrightness() async {
    final supported = await _brightnessBackend.isSupported();
    final current = supported ? await _brightnessBackend.currentBrightness() : null;
    if (!mounted) return;
    setState(() {
      _systemBrightness = supported;
      if (current != null) _brightness = current;
    });
  }

  /// 按当前设置创建播放器，并把媒体与播放位置接回去。
  ///
  /// 三条硬约束（沿用旧实现，见每次修复的注释）：
  /// 1. **一定收敛到终态**：无论成功、回退、失败还是中途抛错，函数退出时页面
  ///    要么拿着一个播放器，要么拿着一条带出口的失败说明——不会停在「转圈」上；
  /// 2. **实例不泄漏**：任何路径下建出来但没被采用的播放器都要 dispose；
  /// 3. **落库失败不拖垮播放**：写设置库失败只记日志并提示。
  Future<void> _rebuildPlayer() async {
    final seq = ++_rebuildSeq;
    final previous = _player;
    final resume = previous == null ? null : _ResumePoint.of(previous);
    _player = null;
    if (previous != null) {
      // 摘的必须是**当初挂上去的那个**回调（[onSnapshotChanged]）。
      previous.snapshot.removeListener(_onSnapshotChanged);
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
      launch = await _launcher.launch(kernel);
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
      final orphan = launch?.player;
      if (orphan != null) await _disposeQuietly(orphan, '页面已退出');
      return;
    }

    if (launch == null) {
      setState(() {
        _player = null;
        _pendingKernel = null;
        _failedKernel = kernel;
        _rebuildFailure = '${kernel.label} 无法启动'
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

    try {
      await player.applySettings(_settings);
      final media = _media;
      if (media != null) await _loadMedia(media);
      if (resume != null && !resume.isAtStart) {
        await player.seek(resume.position);
        if (resume.playing) await player.play();
      }
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (mounted && seq == _rebuildSeq) {
        setState(() => _rebuildFailure = '播放器已就绪，但接续上次播放失败：$error');
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

  Future<void> _loadMedia(PlayerMedia media) async {
    final player = _player;
    if (player == null) return;
    _media = media;
    if (mounted) setState(() => _loaded = false);
    await player.load(media);
    // 起播时实测一次网速（同一地址不重复测；点信息条上的「测速」可强制重测）。
    if (media.isNetwork) {
      unawaited(_speed.measure(media.uri, headers: media.headers));
    }
    if (!mounted) return;
    setState(() => _loaded = player.snapshot.value.error == null);
  }

  /// 设置变更：落库并立即生效；换内核走重建，其余项直接应用到当前内核。
  Future<void> _applySettings(PlayerSettings next) async {
    final kernelChanged = next.kernel != _settings.kernel;
    if (!mounted) return;
    setState(() => _settings = next);
    if (kernelChanged) {
      await _rebuildPlayer();
    } else {
      _store?.save(next);
      await _player?.applySettings(next);
    }
  }

  /// 可读提示（不冒泡异常）。
  void _showToast(String? message) {
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Uri? _resolve(String text) {
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    const networkSchemes = <String>{'http', 'https', 'file'};
    return networkSchemes.contains(parsed.scheme) ? parsed : Uri.file(text);
  }

  /// 手动贴地址起播（播放页自带的兜底入口）。
  Future<void> _open() async {
    final player = _player;
    final text = _input.text.trim();
    if (player == null || text.isEmpty) return;
    final uri = _resolve(text);
    if (uri == null) {
      setState(() => _error = '地址无效');
      return;
    }
    setState(() => _error = null);
    // 手动地址没有作品身份：进度不记（与旧实现同口径），但连播要断开。
    _target = null;
    await _startPlaybackSafely(PlayerMedia(uri: uri), target: null);
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
    if (index == _qualityIndex) return;
    final player = _player;
    if (player == null) return;

    final snapshot = player.snapshot.value;
    final resume = snapshot.position;
    final playing = snapshot.playing;
    final quality = _qualities[index];
    setState(() => _qualityIndex = index);

    await _loadMedia(
      PlayerMedia(
        uri: quality.url,
        title: _media?.title,
        // 线路自己的头优先，没有就沿用主地址的（防盗链头大多写在主地址上）。
        headers: quality.headers.isEmpty ? _media?.headers : quality.headers,
      ),
    );
    if (!mounted) return;
    if (resume > Duration.zero) await player.seek(resume);
    if (playing) await player.play();
    if (!mounted) return;
    _showToast('已切换到 ${quality.label}');
  }

  /// 打开清晰度菜单；只有一条线路时按用户口径**弹提示**而不是藏按钮。
  Future<void> _openQualityMenu() async {
    if (_qualities.length <= 1) {
      _showToast('当前图源不提供多清晰度选项');
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _QualitySheet(
        qualities: _qualities,
        currentIndex: _qualityIndex,
      ),
    );
    if (selected == null || !mounted) return;
    await _selectQuality(selected);
  }

  /// 起播的**异常安全**入口：内核的 load 抛错时不让异常冒到 initState 的异步
  /// 路径上（那会变成「页面还在、错误没人管」），而是如实说一次并保留出口
  /// （画面仍在、地址栏与播放键仍在，用户可重试或改内核）。
  Future<void> _startPlaybackSafely(
    PlayerMedia media, {
    VideoPlayTarget? target,
  }) async {
    try {
      await _startPlayback(media, target: target);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _showToast('起播失败：$error');
    }
  }

  /// 交给播放器：先按需切换内核（防盗链降级），再装载、恢复进度、起连播与弹幕。
  Future<void> _startPlayback(
    PlayerMedia media, {
    VideoPlayTarget? target,
  }) async {
    if (_player == null) {
      _showToast(
        _anyKernelAvailable ? '播放器还在准备，请稍后再试' : '本平台不提供播放内核',
      );
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
    _target = target;
    _input.text = media.uri.toString();
    await _loadMedia(media);
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
    for (final kernel in <PlayerKernel>[PlayerKernel.mpv, PlayerKernel.avplayer]) {
      if (_catalog.isAvailable(kernel)) return kernel;
    }
    return _settings.kernel;
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
  Future<void> _playEpisodeAt(int index, {bool auto = false}) async {
    if (_advancing) return;
    final target = _target;
    final source = await _openSource();
    if (target == null || source == null) {
      if (!auto) _showToast('手动贴地址播放时没有剧集列表');
      return;
    }

    _advancing = true;
    try {
      final List<SourceChapter> chapters;
      try {
        chapters = await source.chapters(target.itemId);
      } on SourceException {
        return;
      }
      if (index < 0 || index >= chapters.length) {
        // 越界：自动连播时安静停下（没下一集了），手动切集时如实说一句。
        if (!auto) {
          _showToast(index < 0 ? '已经是第一集' : '已经是最后一集');
        }
        return;
      }
      final next = chapters[index];

      final content = await source.content(
        itemId: target.itemId,
        chapterId: next.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null || !mounted) return;

      // 换集时线路也可能完全不同：把这一集的候选线路一起换掉。
      setState(() {
        _qualities = SourcePlayback.contentQualities(content);
        _qualityIndex = 0;
      });
      await _startPlaybackSafely(
        PlayerMedia(
          uri: address,
          title: '${target.title} · ${next.title}',
          // 连播 / 切集同样要带防盗链头（否则下一集很可能 403 卡住）。
          headers: SourcePlayback.contentHeaders(content),
        ),
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
      if (!mounted) return;
      if (auto) _showToast('已自动播放：${next.title}');
    } on SourceException {
      // 连播失败不打扰：用户没主动要求跳集，安静停在当前状态即可。
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
    final manager = widget.sourceManager ??
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
  Future<void> _loadDanmaku(VideoPlayTarget? target) async {
    if (target == null) {
      if (mounted) setState(() => _danmaku = DanmakuTrack.empty);
      return;
    }
    final cached = _danmakuCache.get(target.itemId, target.chapterId);
    if (cached != null) {
      if (mounted) setState(() => _danmaku = cached);
      return;
    }
    if (mounted) setState(() => _danmaku = DanmakuTrack.empty);

    final source = await _openSource();
    if (source == null || source is! DanmakuCapable) return;
    try {
      final raw = await (source as DanmakuCapable).danmaku(
        itemId: target.itemId,
        chapterId: target.chapterId,
      );
      final track = DanmakuTrack.parse(raw);
      _danmakuCache.put(target.itemId, target.chapterId, track);
      if (!mounted) return;
      // 期间可能已经切集：只在仍是同一集时上屏。
      if (_target?.isSameEpisode(target) ?? false) {
        setState(() => _danmaku = track);
      }
      if (!track.isEmpty) {
        LumeLog.info('[player] 本集弹幕 ${track.length} 条');
      }
    } catch (error) {
      LumeLog.info('[player] 本集无弹幕（$error）');
    }
  }

  /// 打开弹幕设置面板。
  Future<void> _openDanmakuSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DanmakuSettingsSheet(
        settings: _danmakuSettings,
        danmakuCount: _danmaku.length,
        onChanged: _applyDanmakuSettings,
      ),
    );
  }

  /// 发一条弹幕：先上报图源（支持写入时），成功后再进本地。
  Future<void> _composeDanmaku() async {
    final target = _target;
    final snapshot = _player?.snapshot.value;
    if (target == null || snapshot == null) {
      _showToast('从源条目起播才能发弹幕（手动地址没有作品身份）');
      return;
    }
    final result = await showDialog<({String text, DanmakuMode mode})>(
      context: context,
      builder: (_) => const DanmakuComposeDialog(),
    );
    if (result == null || !mounted) return;

    final item = DanmakuItem(
      time: snapshot.position,
      text: result.text,
      mode: result.mode,
    );

    final outcome = await _postDanmaku(target, item);
    if (!mounted) return;

    final merged = DanmakuTrack.parse(<Object?>[
      for (final existing in _danmaku.items) existing,
      item,
    ]);
    _danmakuCache.put(target.itemId, target.chapterId, merged);
    setState(() => _danmaku = merged);
    _showToast(outcome);
  }

  /// 上报一条弹幕，返回给用户看的提示文案。
  Future<String> _postDanmaku(VideoPlayTarget target, DanmakuItem item) async {
    final source = await _openSource();
    if (source is! DanmakuPostCapable) {
      return '弹幕已发送（本源不支持上报，仅本机可见）';
    }
    try {
      final accepted = await (source as DanmakuPostCapable).postDanmaku(
        itemId: target.itemId,
        chapterId: target.chapterId,
        text: item.text,
        positionMs: item.time.inMilliseconds,
        mode: item.mode.id,
        color: item.color,
      );
      return accepted ? '弹幕已发送' : '弹幕已发送（本源不支持上报，仅本机可见）';
    } on SourceException catch (error) {
      LumeLog.warn('[player] 弹幕上报失败: ${error.message}');
      return '上报失败（${error.message}），已记在本机';
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return '上报失败，已记在本机';
    }
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

  /// 保存当前播放进度（集数 + 时间点）。
  ///
  /// [force] 为 true 时忽略节流（暂停、切集、退出这些「状态改变」的时刻必须写准）。
  void _saveProgress({bool force = false}) {
    final target = _target;
    final library = _library;
    final snapshot = _player?.snapshot.value;
    if (target == null || library == null || snapshot == null) return;
    if (snapshot.error != null) return;

    final position = snapshot.position;
    // 刚开播还没走表、或位置没动过，不必写库（省掉大量无意义的写）。
    if (!force &&
        (position - _lastSavedPosition).abs() < const Duration(seconds: 2)) {
      return;
    }
    if (position <= Duration.zero && !force) return;

    _lastSavedPosition = position;
    library.shelve(
      sourceId: target.sourceId,
      itemId: target.itemId,
      title: target.title,
      cover: target.cover,
      chapterCount: 0,
    );
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: target.itemId,
        chapterIndex: target.chapterIndex,
        chapterId: target.chapterId,
        chapterTitle: target.chapterTitle,
        updatedAt: DateTime.now(),
        position: position,
        duration: snapshot.duration,
      ),
    );
  }

  // ---------------------------------------------------------------- 画中画

  Future<void> _togglePip() async {
    final session = _session;
    if (session == null) return;
    final outcome = session.state == PipState.active
        ? await session.exit()
        : await session.enter();
    if (!mounted) return;
    final rejection = outcome.rejection;
    if (rejection != null) _showToast(rejection);
  }

  /// 画中画事件回调：原生失败给可读提示；进入 / 退出时开关帧转发。
  void _onPipEvent(PipEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case PipEventKind.failed:
        _showToast(event.message ?? '画中画失败');
      case PipEventKind.entered:
        _startFrameForwarding();
      case PipEventKind.exited:
        _stopFrameForwarding();
      case PipEventKind.restored:
        LumeLog.info('[player] 画中画事件: ${event.kind.id}');
    }
  }

  /// 开始帧转发（仅 MPV 内核需要：AVPlayer 走原生 `AVPlayerLayer` 通路）。
  void _startFrameForwarding() {
    final player = _player;
    final backend = widget.pipBackend ?? createPlatformPipBackend();
    final engine = _mpvEngineOf(player);
    if (player == null || backend is! MethodChannelPipBackend) {
      LumeLog.info('[player] 当前内核不需要帧转发（或画中画后端非原生）');
      return;
    }
    if (engine == null) {
      LumeLog.info('[player] 当前内核没有帧导出能力，画中画将显示空白');
      return;
    }
    _framePump ??= PipFramePump(
      engine: engine,
      frameSource: backend.frameSource,
    );
    _framePump!.start();
  }

  void _stopFrameForwarding() {
    _framePump?.stop();
  }

  /// 取播放器背后的 MPV 引擎（非 MPV 内核返回 null）。
  MpvEngine? _mpvEngineOf(AbstractPlayer? player) {
    if (player is MpvPlayer) return player.engine;
    return null;
  }

  // ------------------------------------------------------------------ 手势

  /// 手势层：透明触摸面 + 手势提示浮层。
  Widget _buildGestureLayer(Size size) {
    return GestureDetector(
      key: _gestureLayerKey,
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _onLongPressStart(),
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
    if (intent == PlayerGestureIntent.none) return;

    switch (intent) {
      case PlayerGestureIntent.brightness:
        final next = PlayerGesturePolicy.applyVerticalDelta(
          startValue: _gestureStartBrightness,
          dy: totalDy,
          height: size.height,
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
    setState(() => _gesture = PlayerGestureState.idle.copyWith(
          volume: _gesture.volume,
          brightness: _brightness,
        ));
  }

  /// 长按：临时倍速。
  void _onLongPressStart() {
    final player = _player;
    if (player == null) return;
    _gestureSpeedBeforeBoost = _settings.speed;
    final boosted = PlayerGesturePolicy.boostSpeed(_settings.speed);
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
      // 弹幕设置也收进同一份设置弹窗（用户点名：所有功能入口都固定在这里）；
      // 控制栏那颗 tune 仍保留为快捷入口。
      danmaku: _danmakuSettings,
      danmakuCount: _danmaku.length,
      onDanmakuChanged: _applyDanmakuSettings,
    );
  }

  /// 弹幕设置变更：上屏 + 落库（与「弹幕设置」弹窗同一套落库口径）。
  void _applyDanmakuSettings(DanmakuSettings next) {
    setState(() => _danmakuSettings = next);
    final library = _library;
    if (library != null) DanmakuSettingsStore(library).save(next);
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
    final selected = await showModalBottomSheet<String>(
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
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _TrackSheet(
        title: '选择字幕轨',
        tracks: tracks,
        allowOff: true,
      ),
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
  Widget build(BuildContext context) {
    final body = _anyKernelAvailable ? _buildBody() : const _VideoSkeleton();
    // 全屏（沉浸）模式：整页只剩画面 + 浮层控制栏——顶栏与标准控制栏都收起。
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _buildImmersive(body)),
      );
    }
    return GlassScaffold(
      title: widget.title ?? _target?.title ?? '播放',
      behindBar: true,
      child: Padding(
        padding: GlassScaffold.barInset(context),
        child: body,
      ),
    );
  }

  Widget _buildBody() {
    final player = _player;
    // 控制栏**任何状态下都在**：它是「播放器设置」这个入口的家，不能因为
    // 播放器还没准备好就整块消失。两处例外，都是有意的：
    // - 锁屏：防误触就是要挡住这些；
    // - 全屏：标准控制栏换成压在画面上的浮层（点画面切换显隐）。
    if (_locked || _fullscreen) {
      return Column(
        children: <Widget>[
          Expanded(child: _buildStage(player)),
        ],
      );
    }
    return Column(
      children: <Widget>[
        Expanded(child: _buildStage(player)),
        _buildControlPanel(player),
      ],
    );
  }

  /// 切换全屏：**进全屏自动横屏，退出还原竖屏**（用户要求）。
  ///
  /// 方向交给 `SystemChrome.setPreferredOrientations`：锁横屏两个方向（左右都收，
  /// 用户横握哪边都行），退出时还原竖屏。页面 dispose 时也会还原一次——否则
  /// 从全屏直接返回会把整个 App 留在横屏里。
  void _setFullscreen(bool value) {
    setState(() {
      _fullscreen = value;
      _overlayVisible = true;
    });
    unawaited(_applyOrientation(value));
  }

  /// 应用屏幕方向：全屏 = 横屏，否则竖屏。
  Future<void> _applyOrientation(bool fullscreen) async {
    try {
      await SystemChrome.setPreferredOrientations(
        fullscreen
            ? const <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
    } catch (error) {
      // 桌面 / 测试环境没有方向概念：失败只记日志，不影响播放。
      LumeLog.info('[player] 设置屏幕方向失败（当前平台可能不支持）：$error');
    }
  }

  /// 全屏模式的布局：画面铺满 + 浮层控制栏（点画面切换显隐）。
  Widget _buildImmersive(Widget body) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: body),
        if (_overlayVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildFloatingControls(),
          ),
        if (_overlayVisible)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildImmersiveTopBar(),
          ),
      ],
    );
  }

  /// 全屏浮层顶栏：退出全屏 + 标题。
  Widget _buildImmersiveTopBar() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '退出全屏',
              icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
              onPressed: () => _setFullscreen(false),
            ),
            Expanded(
              child: Text(
                widget.title ?? _target?.title ?? '播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 全屏浮层控制栏：进度 + 主要控制 + 次级控制（退出全屏与设置都在里面）。
  Widget _buildFloatingControls() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[
            Colors.black.withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: ValueListenableBuilder<PlayerSnapshot>(
          valueListenable: _player?.snapshot ?? _idleSnapshot,
          builder: (context, snapshot, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildProgress(snapshot),
              _buildPrimaryControls(snapshot),
              _buildSecondaryControls(),
            ],
          ),
        ),
      ),
    );
  }

  /// 画面区：四态——设置库不可用 / 重建失败 / 正在准备 / 就绪。
  Widget _buildStage(AbstractPlayer? player) {
    if (_storeFailed) {
      return _PlayerStageNotice(
        icon: Icons.storage_outlined,
        title: '播放器设置库不可用',
        detail: '视频板块的设置库打不开，播放参数无法读写；可以重试打开，'
            '或返回后再进来。',
        actions: <Widget>[
          FilledButton.icon(
            onPressed: _retryBoot,
            icon: const Icon(Icons.refresh, size: 18),
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
            icon: const Icon(Icons.refresh, size: 18),
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          snapshot.error!,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: LumeTheme.muted),
        ),
      ),
    );
  }

  /// 就绪态的画面区：画面 + 亮度遮罩 + 弹幕层 + 手势层 + HUD（+ 锁屏开关）。
  Widget _buildVideoArea(AbstractPlayer player) {
    return LayoutBuilder(
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
                    playing: snapshot.playing,
                    track: _danmaku,
                    settings: _danmakuSettings,
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
                  onTap: () => _showToast('已锁定：点右上角的锁解开'),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: PlayerHud(stats: player.stats),
                ),
              ),
            ),
            // 锁屏开关：锁定时只留它，其余控制全收起。
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: IconButton(
                  tooltip: _locked ? '解除锁定' : '锁定（防误触）',
                  icon: Icon(
                    _locked ? Icons.lock : Icons.lock_open,
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
            if (_fullscreen && !_overlayVisible)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _overlayVisible = true),
                ),
              ),
          ],
        );
      },
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
      matrix.scaleByDouble(
        prefs.zoom.scale,
        prefs.zoom.scale,
        1.0,
        1.0,
      );
    }
    return Transform(
      transform: matrix,
      alignment: Alignment.center,
      child: child,
    );
  }

  /// 控制栏：地址输入 + 进度（带拖动预览）+ 主控制 + 次级控制。
  ///
  /// [player] 为空时传输类按钮禁用，但**设置入口与地址栏照常可用**——「播不了」
  /// 不该顺带剥夺「改设置、换内核、贴地址重试」这些出路。
  Widget _buildControlPanel(AbstractPlayer? player) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GlassCard(
        child: Column(
          children: <Widget>[
            TextField(
              controller: _input,
              style: TextStyle(color: LumeTheme.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '视频地址或本地路径',
                hintStyle: TextStyle(color: LumeTheme.muted),
                icon: Icon(Icons.link, color: LumeTheme.muted),
                suffixIcon: IconButton(
                  tooltip: '播放这个地址',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: _open,
                ),
              ),
              onSubmitted: (_) => _open(),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: LumeTheme.danger),
              ),
            // 当前视频的实时信息：分辨率 / 码率（内核 HUD 参数）+ 实测网速。
            _buildInfoRow(player),
            const SizedBox(height: 8),
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

  /// 当前视频信息行：分辨率 · 码率 · 网速（网速点一下重测）。
  ///
  /// 分辨率与码率来自内核自己报的 HUD 参数（[PlayerStats]，三套内核各自填）；
  /// 网速是本页对播放地址的**实测**读数（见 [PlaybackSpeedMeter]：
  /// 播放器内核在原生侧取流，Dart 侧没有可统计的对象，只能自己探测）。
  Widget _buildInfoRow(AbstractPlayer? player) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 14, color: LumeTheme.muted),
          const SizedBox(width: 6),
          Expanded(
            child: player == null
                ? Text(
                    '等待播放器就绪…',
                    style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                  )
                : ValueListenableBuilder<PlayerStats>(
                    valueListenable: player.stats,
                    builder: (context, stats, _) => Text(
                      _infoText(stats),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                    ),
                  ),
          ),
          ValueListenableBuilder<int?>(
            valueListenable: _speed.kbps,
            builder: (context, kbps, _) => ValueListenableBuilder<bool>(
              valueListenable: _speed.busy,
              builder: (context, busy, _) => TextButton.icon(
                onPressed: _measureSpeed,
                icon: busy
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed, size: 16),
                label: Text(
                  busy
                      ? '测速中'
                      : (PlaybackSpeedMeter.describe(kbps) == null
                          ? '测速'
                          : '网速 ${PlaybackSpeedMeter.describe(kbps)}'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 信息行文案：分辨率 · 码率 · 缓冲（缺项自动省略，不编造）。
  static String _infoText(PlayerStats stats) {
    final pieces = <String>[
      if (stats.resolutionText != null) '分辨率 ${stats.resolutionText}',
      if (stats.bitrateText != null) '码率 ${stats.bitrateText}',
      if (stats.codecText != null) stats.codecText!,
      if (stats.fpsText != null) stats.fpsText!,
      if (stats.bufferText != null) stats.bufferText!,
    ];
    return pieces.isEmpty ? '等待视频参数…' : pieces.join(' · ');
  }

  /// 手动测速（同一地址强制重测一次）。
  void _measureSpeed() {
    final media = _media;
    if (media == null || !media.isNetwork) {
      _showToast('当前不是网络地址，无需测速');
      return;
    }
    unawaited(_speed.measure(media.uri, headers: media.headers, force: true));
  }

  /// 进度条：拖动中显示预览（松手才真 seek），两端是时间。
  Widget _buildProgress(PlayerSnapshot snapshot) {
    final total = snapshot.duration.inMilliseconds;
    final preview = _previewTarget;
    final shown = preview ?? snapshot.position;
    return Column(
      children: <Widget>[
        Slider(
          value: _fraction(shown, snapshot.duration),
          onChangeStart: total == 0
              ? null
              : (value) => setState(
                    () => _previewTarget =
                        _positionAt(value, snapshot.duration),
                  ),
          onChanged: total == 0
              ? null
              : (value) => setState(
                    () => _previewTarget =
                        _positionAt(value, snapshot.duration),
                  ),
          onChangeEnd: total == 0
              ? null
              : (value) {
                  final target = _positionAt(value, snapshot.duration);
                  setState(() => _previewTarget = null);
                  final player = _player;
                  if (player != null) unawaited(player.seek(target));
                },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                _format(shown),
                style: TextStyle(
                  fontSize: 12,
                  // 拖动预览用高亮色：一眼能看出「这不是当前位置」。
                  color:
                      preview == null ? LumeTheme.muted : LumeTheme.textPrimary,
                ),
              ),
              if (preview != null)
                Text(
                  '拖动到 ${_format(preview)}',
                  style: TextStyle(fontSize: 12, color: LumeTheme.textPrimary),
                ),
              Text(
                _format(snapshot.duration),
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 主控制：后退 10 秒 / 播放暂停 / 停止 / 前进 10 秒。
  Widget _buildPrimaryControls(PlayerSnapshot snapshot) {
    final player = _player;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          iconSize: 28,
          color: LumeTheme.textPrimary,
          tooltip: '后退 10 秒',
          icon: const Icon(Icons.replay_10),
          onPressed: player == null
              ? null
              : () => _seekBy(const Duration(seconds: -10)),
        ),
        IconButton(
          iconSize: 38,
          color: LumeTheme.textPrimary,
          tooltip: snapshot.playing ? '暂停' : '播放',
          icon: Icon(
            snapshot.playing
                ? Icons.pause_circle_filled
                : Icons.play_circle_fill,
          ),
          onPressed: player == null
              ? null
              : () => snapshot.playing ? player.pause() : player.play(),
        ),
        IconButton(
          iconSize: 28,
          color: LumeTheme.textPrimary,
          tooltip: '停止',
          icon: const Icon(Icons.stop_circle),
          onPressed: player?.stop,
        ),
        IconButton(
          iconSize: 28,
          color: LumeTheme.textPrimary,
          tooltip: '前进 10 秒',
          icon: const Icon(Icons.forward_10),
          onPressed:
              player == null ? null : () => _seekBy(const Duration(seconds: 10)),
        ),
      ],
    );
  }

  /// 次级控制：清晰度 / 弹幕 / 连播 / 画中画 / 全屏 / 设置。
  ///
  /// 用 [Wrap] 而不是 `Row`：这一排在小屏（iPhone SE 320pt）上放不下是常态，
  /// 换行比溢出好——所有入口都在，只是排成两行。
  Widget _buildSecondaryControls() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 2,
        runSpacing: 2,
        children: <Widget>[
          _compactIcon(
            icon: Icons.high_quality_outlined,
            tooltip: '清晰度',
            onPressed: _openQualityMenu,
            // 有线路时高亮：一眼能看出这部片有多清晰度可切。
            highlighted: _qualities.length > 1,
          ),
          _compactIcon(
            icon: Icons.subtitles_outlined,
            tooltip: _danmakuSettings.enabled ? '弹幕：开' : '弹幕：关',
            highlighted: _danmakuSettings.enabled,
            onPressed: () => _applyDanmakuSettings(
              _danmakuSettings.copyWith(enabled: !_danmakuSettings.enabled),
            ),
          ),
          _compactIcon(
            icon: Icons.chat_bubble_outline,
            tooltip: '发弹幕',
            onPressed: _composeDanmaku,
          ),
          _compactIcon(
            icon: Icons.tune,
            tooltip: '弹幕设置',
            onPressed: _openDanmakuSettings,
          ),
          _compactIcon(
            icon: Icons.skip_next,
            tooltip: _autoNext ? '自动连播：开' : '自动连播：关',
            highlighted: _autoNext,
            onPressed: () => setState(() => _autoNext = !_autoNext),
          ),
          _buildPipButton(),
          _compactIcon(
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            tooltip: _fullscreen ? '退出全屏' : '全屏',
            onPressed: () => _setFullscreen(!_fullscreen),
          ),
          _compactIcon(
            icon: Icons.settings_outlined,
            tooltip: '播放器设置',
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  /// 紧凑的图标按钮（次级控制排专用，避免窄屏溢出）。
  Widget _compactIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    return IconButton(
      iconSize: 24,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      color: highlighted ? LumeTheme.textPrimary : LumeTheme.muted,
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  /// 相对当前位置跳转（前进 / 后退按钮）。越界值夹到 [0, duration]。
  void _seekBy(Duration delta) {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;
    var target = snapshot.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (snapshot.duration > Duration.zero && target > snapshot.duration) {
      target = snapshot.duration;
    }
    unawaited(player.seek(target));
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
  static Duration _positionAt(double value, Duration duration) => Duration(
        milliseconds: (duration.inMilliseconds * value).round(),
      );

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
/// 内核切换前记录的位置与播放状态（新内核加载完成后接回去）。
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
                Icon(icon, size: 26, color: LumeTheme.textSecondary),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: LumeTheme.muted,
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
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '当前平台在 Phase1 仅保留页面骨架',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: LumeTheme.muted),
              ),
              const SizedBox(height: 8),
              Text(
                '播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: LumeTheme.muted),
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
                    Icon(
                      switch (state.intent) {
                        PlayerGestureIntent.brightness => Icons.brightness_6,
                        PlayerGestureIntent.volume => Icons.volume_up,
                        PlayerGestureIntent.seek => Icons.fast_forward,
                        PlayerGestureIntent.boost => Icons.speed,
                        PlayerGestureIntent.none => Icons.touch_app,
                      },
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _label(),
                      style: const TextStyle(
                        fontSize: 14,
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
        decoration: LumeTheme.background,
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
                      fontSize: 15,
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
                        leading: const Icon(Icons.block, size: 20),
                        title: Text(
                          '关闭字幕',
                          style: TextStyle(color: LumeTheme.textPrimary),
                        ),
                        onTap: () => Navigator.of(context).pop(offId),
                      ),
                    for (final track in tracks)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          track.selected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 20,
                          color: track.selected
                              ? LumeTheme.textPrimary
                              : LumeTheme.muted,
                        ),
                        title: Text(
                          track.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: LumeTheme.textPrimary),
                        ),
                        subtitle: track.language == null
                            ? null
                            : Text(
                                track.language!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: LumeTheme.muted,
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
        decoration: LumeTheme.background,
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
                      fontSize: 15,
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
                    style: TextStyle(fontSize: 12, color: LumeTheme.muted),
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
                      leading: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        size: 20,
                        color:
                            selected ? LumeTheme.textPrimary : LumeTheme.muted,
                      ),
                      title: Text(
                        quality.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: LumeTheme.textPrimary),
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
