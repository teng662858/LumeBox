import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
import '../../core/player/pip_frame_pump.dart';
import '../../core/player/mpv_engine.dart';
import '../../core/player/mpv_player.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/board_tabs.dart';
import '../shell/shell_dock.dart';
import '../source/add_source_button.dart';
import '../source/source_home_page.dart';
import '../source/source_section_page.dart';
import 'continue_watching.dart';
import 'danmaku/danmaku_models.dart';
import 'danmaku/danmaku_overlay.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_settings_sheet.dart';
import 'player_gestures.dart';
import 'player_hud.dart';
import 'player_settings_page.dart';
import 'source_playback.dart';
import 'video_history_page.dart';
import 'watch_calendar.dart';
import 'watch_calendar_page.dart';
import 'video_play_target.dart';
import 'video_player_settings.dart';

/// 视频板块：**首页是当前图源的内容展示页**（浏览），播放器在同板块的「播放」页签。
///
/// 浏览：图源条（切换当前图源）+ 分类 / 搜索 / 列表（[SourceBrowsePane]），点条目
/// 直接起播——条目自带地址（列表里的 `url`）就直接放；否则走「剧集 → 内容」
/// 链路（章节选择 → `content` 的视频地址）。没有可用图源时首页给出导入引导，
/// 播放器仍可手动输入地址使用。
///
/// 播放内核由设置页选择：iOS 上 AVPlayer（video_player）与 MPV（libmpv / media_kit）
/// 三套都可用。页面只认 [AbstractPlayer] 与 [PlayerStats]：内核切换、
/// 控制栏与 HUD 都不需要跟着改。Android / Windows 按宪法只保留 UI 骨架占位，
/// 画中画业务逻辑只在 iOS 侧接线（原生实现落地前，设置页与画中画按钮显示为占位）。
///
/// 播放设置（内核 / 倍速 / 字幕）落在本板块自己的库里；页面退出时按顺序释放：
/// 退出画中画 → 释放播放器 → 关闭库句柄。
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    this.playerFactory,
    this.catalog,
    this.pipBackend,
    this.brightnessBackend,
    this.sourceManager,
    this.library,
  });

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端。为空时按平台选择（iOS 走原生通道，其余平台如实降级）。
  final PipBackend? pipBackend;

  /// 屏幕亮度后端。为空时按平台选择；不支持时亮度手势回退为页面内遮罩。
  final BrightnessBackend? brightnessBackend;

  /// 图源管理端口（首页的浏览面用它取本板块图源）。为空时用正式实现。
  final SourceManager? sourceManager;

  /// 本板块阅读库（进度与继续观看）；为空时按板块打开正式实现。
  final ReadingLibrary? library;

  /// 页签顺序：0 = 浏览（首页，图源展示页），1 = 播放。
  static const int browseTabIndex = 0;
  static const int playerTabIndex = 1;

  /// 页签文案（与其他板块的页签同一套排布，见 [BoardTabs]）。
  static const List<String> tabLabels = <String>['浏览', '播放'];

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _input = TextEditingController();

  /// 页签控制器：点条目起播后要主动跳到「播放」。
  late final TabController _tabs =
      TabController(length: VideoPage.tabLabels.length, vsync: this);

  late final PlayerKernelCatalog _catalog =
      widget.catalog ?? const PlatformPlayerKernelCatalog();

  /// 内核启动器：异步创建 + 8 秒超时 + 失败回退 AVPlayer（见 [PlayerKernelLauncher]）。
  /// 创建动作因此不会落在 build / initState 的同步路径上。
  late final PlayerKernelLauncher _launcher = PlayerKernelLauncher(
    factory: widget.playerFactory,
  );

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
  /// 的出口。空转一个没有说明的转圈，是上一版最要命的体验问题。
  PlayerKernel? _pendingKernel;

  /// 重建失败的原因（非空即失败态）。失败态必须带出口（重试 / 切回 AVPlayer），
  /// 绝不允许停在「什么都点不动」的状态里。
  String? _rebuildFailure;

  /// 失败的内核：重试时按它重来（而不是按已被回退改写的当前设置）。
  PlayerKernel? _failedKernel;

  /// 重建序号：连续切换内核时，只有最后一次重建的结果算数，过期结果直接丢弃
  /// （否则先完成的旧构建会覆盖新构建，页面上出现与所选内核不符的画面）。
  int _rebuildSeq = 0;

  /// 空闲快照：没有播放器时控制栏仍要用一个可监听的空值渲染（控制栏常在，
  /// 只是按钮禁用——「播放器设置」这个入口因此不会消失）。
  final ValueNotifier<PlayerSnapshot> _idleSnapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  /// 播放中隐藏底部 Dock 用的令牌（从 [ShellDockScope] 取控制器；不在导航壳
  /// 里时为空，此时也无需隐藏）。播放是沉浸态，暂停 / 停止 / 出错即恢复。
  final Object _dockToken = Object();
  ShellDockController? _dock;

  String? _error;

  /// 设置库打不开：设置读写不可用，但播放链路继续（用默认设置）。
  bool _storeFailed = false;

  /// 浏览面换代：从图源管理页返回后 +1，重挂浏览面（列表与当前图源重算）。
  int _browseRevision = 0;

  /// 本板块的阅读库：视频进度（集数 + 时间点）与「继续观看」落在它里面。
  ReadingLibrary? _library;

  /// 浏览列表的封面图管线：**本板块自己**的（缓存落在 sections/video 之下，
  /// 与小说 / 漫画板块互不共享）。随阅读库一起建立；建不出来时列表退化为
  /// 纯文字排布，封面缺失不影响浏览与播放。
  SectionImagePipeline? _pipeline;

  /// 当前正在播的图源条目：有它才记进度（手动贴地址不记，没有作品身份可记）。
  VideoPlayTarget? _target;

  /// 进度落盘节流：播放中每 5 秒写一次，暂停 / 切集 / 退出时立即写。
  Timer? _progressTimer;
  static const Duration _progressInterval = Duration(seconds: 5);

  /// 上次落盘的时间点：避免同一秒重复写库。
  Duration _lastSavedPosition = Duration.zero;

  /// 「继续观看」列表换代：进度落盘后 +1，首页那一块重算。
  int _continueWatchingRevision = 0;

  /// 正在销毁：dispose 里还要落一次进度，但那时不能再 setState（元素已 defunct）。
  bool _disposing = false;

  /// 正在自动连播下一集：防止「播完」的多次快照回调触发连播两次。
  bool _advancing = false;

  /// 自动连播开关（默认开：看完一集接着下一集是追剧的常态）。
  // 用户可在控制栏切换（setState 改它），因此不是 final。
  // ignore: prefer_final_fields
  bool _autoNext = true;

  /// 当前播放的作品（连播下一集要用它的剧集列表）。
  DataSource? _playSource;

  /// 画中画帧转发泵：画中画激活期间按帧率节拍取帧并转发。
  ///
  /// 只在 MPV 内核 + 画中画激活时启动——AVPlayer 自带画中画通路（原生侧
  /// `AVPlayerLayer`），不需要帧转发。
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
  /// 判定成立的那一帧会把之前的位移一起吞掉（slop），逐帧累加会少算一截——
  /// 快速轻扫时尤其明显（一帧就滑完，累计值接近 0，手势像没生效）。
  Offset? _gestureOrigin;

  /// 屏幕亮度（0..1）。
  ///
  /// 平台支持改系统亮度时它就是系统亮度；不支持时退化为「页面内遮罩」的强度
  /// （见播放区里的亮度遮罩），手势手感一致，只是暗得有限度。
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
    if (_anyKernelAvailable) _boot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dock = ShellDockScope.maybeOf(context);
  }

  @override
  void dispose() {
    // 顺序要紧：进度必须**在摘监听、清空 _player 之前**落盘——那两步之后
    // 就读不到播放位置了（记录会静默丢掉）。此刻也不能再 setState。
    _disposing = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    _saveProgress(force: true);

    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    // 离开板块时底部导航必须回来：先摘监听再释放隐藏令牌。
    player?.snapshot.removeListener(_onSnapshotChanged);
    _dock?.show(_dockToken);
    // 资源边界：先退画中画再释放播放器，最后关库（顺序不能反）。
    unawaited(() async {
      await session?.dispose();
      await player?.dispose();
    }());
    // 封面管线先于阅读库释放（它持有网络客户端与解码位图）。
    _pipeline?.dispose();
    _store?.close();
    if (widget.library == null) ReadingLibrary.close(Section.video);
    _input.dispose();
    _idleSnapshot.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// 播放状态变化 → Dock 显隐；顺带在「从播放转为非播放」时立即落盘进度
  /// （暂停 / 停止 / 播放出错都是该记准的时刻，不能等 5 秒节流）。
  void _onSnapshotChanged() {
    final snapshot = _player?.snapshot.value;
    final playing = snapshot?.playing ?? false;
    if (_wasPlaying && !playing) _saveProgress(force: true);
    _wasPlaying = playing;
    _syncDockForPlayback();
    if (snapshot != null && _isFinished(snapshot)) _autoAdvance();
  }

  /// 是否已播到结尾（留 1 秒余量：播放器到结尾前会先停下）。
  ///
  /// 时长未知时一律返回 false——宁可不连播，也不在半途跳走。
  static bool _isFinished(PlayerSnapshot snapshot) {
    if (snapshot.duration <= Duration.zero) return false;
    if (snapshot.error != null) return false;
    return snapshot.position >= snapshot.duration - const Duration(seconds: 1);
  }

  /// 自动连播下一集。
  ///
  /// 只有「从图源条目起播、且还有下一集」时才连播；手动贴地址没有剧集列表，
  /// 自然不连播。取不到地址就安静停在当前状态，不弹提示打扰（用户没要求跳集）。
  Future<void> _autoAdvance() async {
    if (!_autoNext || _advancing) return;
    final target = _target;
    final source = _playSource;
    if (target == null || source == null) return;

    _advancing = true;
    try {
      final List<SourceChapter> chapters;
      try {
        chapters = await source.chapters(target.itemId);
      } on SourceException {
        return;
      }
      final nextIndex = target.chapterIndex + 1;
      if (nextIndex >= chapters.length) return;
      final next = chapters[nextIndex];

      final content = await source.content(
        itemId: target.itemId,
        chapterId: next.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null || !mounted) return;

      await _startPlayback(
        PlayerMedia(uri: address, title: '${target.title} · ${next.title}'),
        target: VideoPlayTarget(
          sourceId: target.sourceId,
          itemId: target.itemId,
          title: target.title,
          cover: target.cover,
          chapterIndex: nextIndex,
          chapterId: next.id,
          chapterTitle: next.title,
        ),
      );
      if (!mounted) return;
      _showPlayerToast('已自动播放：${next.title}');
    } on SourceException {
      // 连播失败不打扰：用户没主动要求跳集，安静停在当前状态即可。
    } finally {
      _advancing = false;
    }
  }

  bool _wasPlaying = false;

  /// 播放状态变化 → Dock 显隐：播放中隐藏，其余状态恢复。
  void _syncDockForPlayback() {
    final dock = _dock;
    if (dock == null) return;
    if (_player?.snapshot.value.playing ?? false) {
      dock.hide(_dockToken);
    } else {
      dock.show(_dockToken);
    }
  }

  Future<void> _boot() async {
    // 阅读库（进度 / 继续观看）与播放器设置库分开打开：前者失败不该拦住播放。
    try {
      final library = widget.library ?? await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      setState(() {
        _library = library;
        // 封面缩略图管线：与阅读板块同一套纪律（引用计数 + LRU + 磁盘缓存），
        // 缓存目录属于视频板块自己。
        _pipeline = SectionImagePipeline(
          cacheDir: library.imageCacheDir,
          memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        );
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[video] 阅读库打不开，本次不记录播放进度');
    }
    try {
      final library = _library;
      if (library != null) {
        _danmakuSettings = DanmakuSettingsStore(library).load();
      }
      final store = await VideoPlayerSettingsStore.open();
      if (!mounted) {
        store.close();
        return;
      }
      _store = store;
      _settings = store.load();
    } catch (error, stackTrace) {
      // 本板块的库打不开：不起播放器，页面给出可读提示（与图源页同一口径）。
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
    await _probeBrightness();
    await _rebuildPlayer();
  }

  /// 探测系统亮度能力，并把当前值对齐到亮度手势的起点。
  ///
  /// 对齐的意义：用户一滑就跳到别的值会让人以为「亮度被重置了」；读到真实值后
  /// 手势是从当前亮度继续增减。不支持时保持 1.0（遮罩降级，不显示遮罩）。
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
  /// 运行时切换内核与首次启动走同一条路：拆旧内核 → 建新内核 → 补挂设置 →
  /// 重新加载媒体 → 恢复位置与播放状态。
  ///
  /// 三条硬约束（上一版的空转问题就是从这里漏出去的）：
  /// 1. **一定收敛到终态**：无论成功、回退、失败还是中途抛错，函数退出时页面
  ///    要么拿着一个播放器，要么拿着一条带出口的失败说明——不会停在「转圈」上；
  /// 2. **实例不泄漏**：任何路径下建出来但没被采用的播放器都要 dispose；
  ///    过期重建（用户又切了别的内核）的结果同样丢弃并释放；
  /// 3. **落库失败不拖垮播放**：写设置库失败只记日志并提示，绝不因此丢掉刚建好的
  ///    播放器（那是「内核明明起来了，页面却一直转圈」的一条隐蔽路径）。
  Future<void> _rebuildPlayer() async {
    final seq = ++_rebuildSeq;
    final previous = _player;
    final resume = previous == null ? null : _ResumePoint.of(previous);
    _player = null;
    if (previous != null) {
      // 摘的必须是**当初挂上去的那个**回调（[_onSnapshotChanged]，见采用新播放器
      // 处）。挂 A 摘 B 等于没摘：旧实例在释放过程中若还吐快照，页面会拿它去
      // 落进度、判连播、改 Dock 显隐——那些动作都属于已经作废的播放器。
      previous.snapshot.removeListener(_onSnapshotChanged);
      await _disposeQuietly(previous, '切换内核时释放旧播放器');
    }

    // 先亮出「正在准备 <内核> 播放器」：初始化在异步流程里跑，UI 不阻塞。
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
      // 启动器自己已经把异常吃掉了；这里再兜一层，保证重建永远有结论。
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
      // 连兜底内核都起不来：给出可操作的失败态，而不是空转。
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
      _showPlayerToast(launch.message);
    } else {
      _failedKernel = null;
    }

    final player = launch.player;
    // 落库失败与播放无关：只记日志、提示一次，不让它中断下面的接线。
    try {
      _store?.save(_settings);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[video] 播放器设置写库失败，本次仍按已生效的内核播放');
    }
    setState(() {
      _player = player;
      _loaded = false;
      _pendingKernel = null;
      _rebuildFailure = null;
    });
    // 播放状态驱动底部 Dock 的显隐（播放中沉浸）。
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
      // 接续失败：播放器已在手上（画面能出），如实报一条可重试的说明。
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
      LumeLog.warn('[video] 释放播放器失败（$reason）');
    }
  }

  /// 重试：按失败的那个内核再来一次（先解除熔断，否则重试仍会被拦下）。
  ///
  /// 用 [AbstractPlayer] 重建而不是走 `_applySettings`：失败的那次**不改配置**，
  /// 设置里可能已经是这个内核了，而 `_applySettings` 只在「内核变了」时重建
  /// ——走它就等于原地不动（重试按钮点了没反应）。
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

  /// 切回 AVPlayer：失败态与等待态都留着的出口（一键回到一定能用的内核）。
  Future<void> _switchToAvPlayer() async {
    if (_settings.kernel == PlayerKernel.avplayer) {
      await _rebuildPlayer();
      return;
    }
    await _applySettings(_settings.copyWith(kernel: PlayerKernel.avplayer));
  }

  /// 重试打不开的设置库（页面里直接给出口，不必重启应用）。
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
    if (!mounted) return;
    // 播放失败的文案由播放器给（已在内核侧归一成人话），在画面位置显示一次；
    // 地址栏下面那行只留给「地址本身有问题」（例如地址无效），不重复同一句话。
    setState(() => _loaded = player.snapshot.value.error == null);
  }

  /// 设置变更：落库并立即生效；换内核走重建，其余项直接应用到当前内核。
  Future<void> _applySettings(PlayerSettings next) async {
    final kernelChanged = next.kernel != _settings.kernel;
    if (!mounted) return;
    setState(() => _settings = next);
    if (kernelChanged) {
      // 换内核：落库由 _rebuildPlayer 决定——只有真正生效的内核才写得进去。
      await _rebuildPlayer();
    } else {
      _store?.save(next);
      await _player?.applySettings(next);
    }
  }

  /// 可读提示（不冒泡异常）。
  void _showPlayerToast(String? message) {
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 图源变更后重挂浏览面：列表与当前图源重新解析。
  ///
  /// 与小说 / 漫画板块的 `_onSourcesChanged` 同一套做法——右上角「+」导入
  /// 完成后立即刷新，不用手动重试或切页签。
  void _onSourcesChanged() => setState(() => _browseRevision++);

  /// 打开本板块的图源管理页（启用 / 禁用 / 重命名 / 导出 / 删除都在那里）。
  ///
  /// 返回后重挂浏览面：图源可能被导入、停用或删除，列表与当前图源都要重算
  /// （与小说 / 漫画板块「图源变更后重挂内容」同一套做法）。
  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSectionPage(
          section: Section.video,
          manager: widget.sourceManager,
        ),
      ),
    );
    if (!mounted) return;
    _onSourcesChanged();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerSettingsPage(
          settings: _settings,
          catalog: _catalog,
          onChanged: _applySettings,
        ),
      ),
    );
  }

  Uri? _resolve(String text) {
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    const networkSchemes = <String>{'http', 'https', 'file'};
    return networkSchemes.contains(parsed.scheme) ? parsed : Uri.file(text);
  }

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
    await _loadMedia(PlayerMedia(uri: uri));
  }

  // ------------------------------------------------------ 图源条目 → 起播

  /// 图源列表里点一个条目：**能直接播就直接播**，否则走剧集链路。
  ///
  /// 直接播的判据是条目自带可播放地址（列表里的 `url` 会落到条目 id 上，见
  /// `SourceItem.parse` 的宽容口径）——视频类图源最常见的形状就是
  /// `{title, url}`。条目只有 id 时按「作品 → 剧集 → 内容」取地址。
  Future<void> _playFromSource(DataSource source, SourceItem item) async {
    final direct = SourcePlayback.directAddress(item.id);
    if (direct != null) {
      // 条目自带地址 = 单集作品：作品身份就是它自己，能记进继续观看。
      await _startPlayback(
        PlayerMedia(uri: direct, title: item.title),
        source: source,
        target: VideoPlayTarget(
          sourceId: source.id,
          itemId: item.id,
          title: item.title,
          cover: item.cover,
          chapterIndex: 0,
          chapterId: item.id,
          chapterTitle: item.title,
        ),
      );
      return;
    }

    final List<SourceChapter> chapters;
    try {
      chapters = await source.chapters(item.id);
    } on SourceException catch (error) {
      _showPlayerToast(
        '${error.message}；条目自带播放地址（url）时可直接起播',
      );
      return;
    }
    if (!mounted) return;
    if (chapters.isEmpty) {
      _showPlayerToast('「${item.title}」没有可播放的剧集');
      return;
    }

    // 只有一集就不必让用户再选一次。
    final chapter = chapters.length == 1
        ? chapters.first
        : await _pickChapter(item, chapters);
    if (chapter == null || !mounted) return;

    try {
      final content = await source.content(
        itemId: item.id,
        chapterId: chapter.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null) {
        _showPlayerToast('「${chapter.title}」不是视频内容');
        return;
      }
      final chapterIndex = chapters.indexWhere(
        (candidate) => candidate.id == chapter.id,
      );
      await _startPlayback(
        PlayerMedia(uri: address, title: '${item.title} · ${chapter.title}'),
        source: source,
        target: VideoPlayTarget(
          sourceId: source.id,
          itemId: item.id,
          title: item.title,
          cover: item.cover,
          chapterIndex: chapterIndex < 0 ? 0 : chapterIndex,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
      );
    } on SourceException catch (error) {
      _showPlayerToast(error.message);
    }
  }

  /// 交给播放器并切到「播放」页签。播放器不可用时如实提示，不静默失败。
  ///
  /// [target] 是作品身份：给了就记进度（继续观看），不给（手动贴地址）不记。
  Future<void> _startPlayback(
    PlayerMedia media, {
    VideoPlayTarget? target,
    DataSource? source,
  }) async {
    if (_player == null) {
      _showPlayerToast(
        _anyKernelAvailable ? '播放器还在准备，请稍后再试' : '本平台不提供播放内核',
      );
      return;
    }
    if (!mounted) return;
    // 换作品前先把上一部的进度落盘（切集也走这里）。
    _saveProgress(force: true);
    _target = target;
    _playSource = source;
    _input.text = media.uri.toString();
    _tabs.animateTo(VideoPage.playerTabIndex);
    await _loadMedia(media);
    await _restoreProgress();
    _startProgressTicker();
    // 弹幕按「作品 + 剧集」加载：手动地址没有身份，自然没有弹幕。
    unawaited(_loadDanmaku(target, source));
  }

  /// 加载本集弹幕：先查内存缓存，再问图源契约（`danmaku({id, chapterId})`）。
  ///
  /// 弹幕是**可选能力**：图源没实现、网络失败、格式不符都只是「这集没弹幕」，
  /// 绝不能影响播放——因此全程静默降级，只记日志。
  Future<void> _loadDanmaku(VideoPlayTarget? target, DataSource? source) async {
    if (target == null || source == null) {
      if (mounted) setState(() => _danmaku = DanmakuTrack.empty);
      return;
    }
    final cached = _danmakuCache.get(target.itemId, target.chapterId);
    if (cached != null) {
      if (mounted) setState(() => _danmaku = cached);
      return;
    }
    if (mounted) setState(() => _danmaku = DanmakuTrack.empty);

    // 能力检测：图源没实现弹幕是正常情况（不是错误），直接当作没有。
    if (source is! DanmakuCapable) return;
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
        LumeLog.info('[video] 本集弹幕 ${track.length} 条');
      }
    } catch (error) {
      // 弹幕失败不影响播放，只记日志（含「脚本没实现 danmaku」这种正常情况）。
      LumeLog.info('[video] 本集无弹幕（$error）');
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
        onChanged: (next) {
          setState(() => _danmakuSettings = next);
          final library = _library;
          if (library != null) DanmakuSettingsStore(library).save(next);
        },
      ),
    );
  }

  /// 发一条弹幕：先上报图源（支持写入时），成功后再进本地。
  ///
  /// 顺序很重要：先上报再本地显示，用户看到的「已发送」才与事实一致。
  /// 图源不支持写入时**只进本地**并如实提示「仅本机可见」——不假装发出去了。
  Future<void> _composeDanmaku() async {
    final target = _target;
    final snapshot = _player?.snapshot.value;
    if (target == null || snapshot == null) {
      _showPlayerToast('从源条目起播才能发弹幕（手动地址没有作品身份）');
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

    // 上报：能写就写，不能写就只进本地（两者都不阻断「本机可见」这件事）。
    final outcome = await _postDanmaku(target, item);
    if (!mounted) return;

    final merged = DanmakuTrack.parse(<Object?>[
      for (final existing in _danmaku.items) existing,
      item,
    ]);
    _danmakuCache.put(target.itemId, target.chapterId, merged);
    setState(() => _danmaku = merged);
    _showPlayerToast(outcome);
  }

  /// 上报一条弹幕，返回给用户看的提示文案。
  Future<String> _postDanmaku(VideoPlayTarget target, DanmakuItem item) async {
    final source = _playSource;
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
      // 上报失败但本地已经记下了：如实说明「只在本机可见」，不谎报成功。
      LumeLog.warn('[video] 弹幕上报失败: ${error.message}');
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
    _showPlayerToast('已从上次位置继续：${_format(saved.position)}');
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
    if (!force && (position - _lastSavedPosition).abs() < const Duration(seconds: 2)) {
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
    // dispose 期间不触发重建（元素已 defunct）；其余时刻刷新首页那一块。
    if (mounted && !_disposing) {
      setState(() => _continueWatchingRevision++);
    }
  }

  /// 打开追剧日历：按月看「哪天有更新 / 哪天看过」。
  ///
  /// 更新时间来自图源的章节时间（可选能力）：当前图源支持就带进来，不支持则
  /// 日历只显示播放记录——如实降级，不编造更新。
  Future<void> _openCalendar() async {
    final library = _library;
    if (library == null) return;
    final updates = await _collectCalendarUpdates();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchCalendarPage(
          library: library,
          updates: updates,
          onOpen: (entry) => _openFromCalendar(entry),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _continueWatchingRevision++);
  }

  /// 收集「更新」：对书架上的作品逐个问图源的章节时间。
  ///
  /// 逐个串行（网络层有并发限制，且日历不是实时视图）；失败只跳过该作品。
  Future<List<CalendarUpdate>> _collectCalendarUpdates() async {
    final library = _library;
    final manager = widget.sourceManager ?? LumeSources.manager(Section.video);
    if (library == null) return const <CalendarUpdate>[];

    final updates = <CalendarUpdate>[];
    for (final item in library.continueWatching(limit: 30)) {
      if (!mounted) return updates;
      try {
        final source = await manager.open(item.sourceId);
        if (source == null) continue;
        final chapters = await source.chapters(item.itemId);
        for (final chapter in chapters) {
          final published = chapter.publishedAt;
          if (published == null) continue;
          updates.add(
            CalendarUpdate(
              date: published,
              entry: CalendarEntry(
                itemId: item.itemId,
                title: item.title,
                chapterTitle: chapter.title,
              ),
            ),
          );
        }
      } catch (error) {
        LumeLog.info('[video] 日历更新取不到（${item.title}）：$error');
      }
    }
    return updates;
  }

  /// 从日历点条目：按作品找回播放记录并续看。
  void _openFromCalendar(CalendarEntry entry) {
    final library = _library;
    if (library == null) return;
    final item = library.item(entry.itemId);
    final progress = library.videoProgress(entry.itemId);
    if (item == null || progress == null) {
      _showPlayerToast('「${entry.title}」还没有播放记录，先从源列表打开一次');
      return;
    }
    _resumeFromProgress(item, progress);
  }

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

  // ------------------------------------------------------------------ 手势

  /// 手势开始：记录起点（位置 / 音量 / 亮度 / 分区）。
  ///
  /// 注意起点用 `globalPosition`：拖拽识别器在判定成立的那一帧才回调 `onPanStart`，
  /// 此时触点已经离手指最初落点有一段距离（slop）。真正的起点由 [onPanDown] 记录，
  /// 这里只做「没有 down 记录」时的兜底。
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

  /// 手指落下：记录真正的起点（用于算总位移与分区）。
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

  /// 手势进行：按意图更新亮度 / 音量 / 目标进度。
  void _onGestureUpdate(DragUpdateDetails details, Size size) {
    final player = _player;
    final snapshot = player?.snapshot.value;
    if (player == null || snapshot == null) return;

    // 总位移 = 当前触点 − 起点（不是逐帧累加，见 [_gestureOrigin]）。
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
      // 判定为调进度时，以「此刻的播放位置」为基准，位移仍从按下点算起：
      // 这样预览跟手（滑多远走多远），也不会因为 slop 那点距离而跳变。
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
        // 平台支持就改系统亮度；不支持时由页面内的亮度遮罩兜底（见播放区）。
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

  /// 手势结束：调进度的手势在这里才真正 seek（拖动中不反复 seek，省解码开销）。
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
    unawaited(player.applySettings(_settings.copyWith(speed: _gestureSpeedBeforeBoost)));
  }

  /// 打开完整播放历史（首页的「继续观看」只到最近 10 条）。
  Future<void> _openHistory() async {
    final library = _library;
    if (library == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoHistoryPage(
          library: library,
          onResume: (item, progress) {
            Navigator.of(context).pop();
            _resumeFromProgress(item, progress);
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _continueWatchingRevision++);
  }

  /// 继续观看：按记录里的剧集与时间点续播。
  ///
  /// 记的是剧集 id 而不是序号，因此图源章节改名或重排也能找回同一集；只有剧集
  /// 取不到（图源改了）才回退到按序号定位。
  Future<void> _resumeFromProgress(
    LibraryItem item,
    VideoProgress progress,
  ) async {
    final manager = widget.sourceManager ?? LumeSources.manager(Section.video);
    final source = await manager.open(item.sourceId);
    if (!mounted) return;
    if (source == null) {
      _showPlayerToast('「${item.title}」的源不可用（未启用或脚本载入失败）');
      return;
    }

    final List<SourceChapter> chapters;
    try {
      chapters = await source.chapters(item.itemId);
    } on SourceException catch (error) {
      _showPlayerToast(error.message);
      return;
    }
    if (!mounted) return;
    if (chapters.isEmpty) {
      _showPlayerToast('「${item.title}」没有可播放的剧集');
      return;
    }

    // 优先按剧集 id 找；找不到再按序号；都没有就用第一集。
    var index = chapters.indexWhere((chapter) => chapter.id == progress.chapterId);
    if (index < 0 && progress.chapterIndex < chapters.length) {
      index = progress.chapterIndex;
    }
    if (index < 0) index = 0;
    final chapter = chapters[index];

    try {
      final content = await source.content(
        itemId: item.itemId,
        chapterId: chapter.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null) {
        _showPlayerToast('「${chapter.title}」不是视频内容');
        return;
      }
      await _startPlayback(
        PlayerMedia(uri: address, title: '${item.title} · ${chapter.title}'),
        source: source,
        target: VideoPlayTarget(
          sourceId: item.sourceId,
          itemId: item.itemId,
          title: item.title,
          cover: item.cover,
          chapterIndex: index,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
      );
    } on SourceException catch (error) {
      _showPlayerToast(error.message);
    }
  }

  /// 移除一条播放记录（书架条目一并撤下）。
  void _removeProgress(LibraryItem item) {
    final library = _library;
    if (library == null) return;
    library.unshelve(item.itemId);
    setState(() => _continueWatchingRevision++);
  }

  /// 剧集选择面板：一集一个条目，取消返回 null。
  Future<SourceChapter?> _pickChapter(
    SourceItem item,
    List<SourceChapter> chapters,
  ) {
    return showModalBottomSheet<SourceChapter>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChapterSheet(title: item.title, chapters: chapters),
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
    if (rejection != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rejection)),
      );
    }
  }

  /// 画中画事件回调：原生失败给可读提示；进入 / 退出时开关帧转发。
  void _onPipEvent(PipEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case PipEventKind.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(event.message ?? '画中画失败')),
        );
      case PipEventKind.entered:
        _startFrameForwarding();
      case PipEventKind.exited:
        _stopFrameForwarding();
      case PipEventKind.restored:
        LumeLog.info('[video] 画中画事件: ${event.kind.id}');
    }
  }

  /// 开始帧转发（仅 MPV 内核需要：AVPlayer 走原生 `AVPlayerLayer` 通路）。
  ///
  /// 引擎不支持取帧（如 AVPlayer / 未来 MDK）时如实不启动，画中画窗口会由
  /// 系统显示为空白——这比假装能转发、实际卡住要好。
  void _startFrameForwarding() {
    final player = _player;
    final backend = widget.pipBackend ?? createPlatformPipBackend();
    final engine = _mpvEngineOf(player);
    if (player == null || backend is! MethodChannelPipBackend) {
      LumeLog.info('[video] 当前内核不需要帧转发（或画中画后端非原生）');
      return;
    }
    if (engine == null) {
      LumeLog.info('[video] 当前内核没有帧导出能力，画中画将显示空白');
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
  ///
  /// 通过 [MpvPlayer] 暴露的引擎访问点拿；这不是「猜类型」，而是播放器工厂
  /// 明确约定的能力查询。
  MpvEngine? _mpvEngineOf(AbstractPlayer? player) {
    if (player is MpvPlayer) return player.engine;
    return null;
  }

  // ------------------------------------------------------------------ 构建

  /// 右上角动作（四个板块统一口径）：**图源管理** + 添加图源。
  ///
  /// 播放器设置不在这里——它属于播放器本身，放在播放控制栏的齿轮上
  /// （与文档草图 2 的 [⚙️] 一致），避免和「图源管理」抢同一个位置。
  List<Widget> _buildActions() => <Widget>[
        IconButton(
          tooltip: '追剧日历',
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: _openCalendar,
        ),
        IconButton(
          tooltip: '源管理',
          icon: const Icon(Icons.source_outlined),
          onPressed: _manageSources,
        ),
        // 右上角统一的「+」添加图源：导入完成即刷新首页（与小说 / 漫画同口径）。
        AddSourceButton(
          section: Section.video,
          manager: widget.sourceManager,
          onImported: _onSourcesChanged,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: Section.video.label,
      actions: _buildActions(),
      // 页签条做成顶栏的一部分（整条玻璃），内容从它下面滚过。
      bottom: BoardTabHeader(labels: VideoPage.tabLabels, controller: _tabs),
      behindBar: true,
      child: BoardTabs(
        controller: _tabs,
        children: <Widget>[
          // 首页：继续观看（有记录才显示）+ 当前图源的内容展示页
          // （右上角已有「图源管理」，图源条不再重复）。
          // 浏览面不是滚动视图（继续观看 + 图源列表各占一块），整块让出顶栏
          // 高度：继续观看为空时也要让，否则图源列表会顶到页签条下面去。
          Padding(
            padding: GlassScaffold.barInset(
              context,
              extra: BoardTabHeader.height,
            ),
            child: Column(
              children: <Widget>[
                // **内容在前，历史在后**（真机反馈：历史条目一多就把搜索栏、
                // 分类与首页内容全部挤到屏幕下方，进页面第一眼看不到内容）。
                // 顺序按用户要求固定为：搜索 → 分类 → 内容列表 → 继续观看。
                Expanded(
                  child: SourceBrowsePane(
                    section: Section.video,
                    manager: widget.sourceManager,
                    showSourceActions: false,
                    // 封面管线的缓存属于视频板块自己，与其他板块不共享。
                    pipeline: _pipeline,
                    onItemTap: _playFromSource,
                    // 图源变更后原地重解析（不换 Key：重挂会与旧实例的 dispose
                    // 抢同一份板块注册表，反而报「图源存储不可用」）。
                    revision: _browseRevision,
                  ),
                ),
                if (_library != null)
                  // 放在整页最底端；只展示最近 3 条（不再限高包一层滚动）：
                  // 条目数与高度都可预期，不会把上面的内容列表压没。
                  // 完整历史走标题栏那个「全部」按钮（onShowAll）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: ContinueWatchingSection(
                      key: ValueKey<int>(_continueWatchingRevision),
                      library: _library!,
                      onResume: _resumeFromProgress,
                      onRemove: _removeProgress,
                      onShowAll: _openHistory,
                      maxItems: 3,
                    ),
                  ),
              ],
            ),
          ),
          _buildPlayerTab(),
        ],
      ),
    );
  }

  /// 「播放」页签：播放器本体（骨架 / 设置库故障 / 准备中 / 就绪四态）。
  ///
  /// 无论哪种状态，浏览页签都照常可用——图源列表与播放器互不牵连。
  Widget _buildPlayerTab() {
    if (!_anyKernelAvailable) return const _VideoSkeleton();
    // 播放区不能被玻璃顶栏压住（顶栏一直浮在最上层）：整块让出顶栏 + 页签条。
    return Padding(
      padding: GlassScaffold.barInset(
        context,
        extra: BoardTabHeader.height,
      ),
      child: _buildPlayerTabBody(),
    );
  }

  Widget _buildPlayerTabBody() {
    if (!_anyKernelAvailable) return const _VideoSkeleton();
    final player = _player;
    // 控制栏**任何状态下都在**：它是「播放器设置」这个入口的家，不能因为
    // 播放器还没准备好就整块消失（用户上一次就是这么被卡死在一个转圈上的）。
    return Column(
      children: <Widget>[
        Expanded(child: _buildStage(player)),
        _buildControlPanel(player),
      ],
    );
  }

  /// 画面区：四态——设置库不可用 / 重建失败 / 正在准备 / 就绪。
  Widget _buildStage(AbstractPlayer? player) {
    if (_storeFailed) {
      return _PlayerStageNotice(
        icon: Icons.storage_outlined,
        title: '播放器设置库不可用',
        detail: '视频板块的设置库打不开，播放参数无法读写；可以重试打开，'
            '或重启应用后再说。',
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
      return _PlayerStageNotice(
        icon: Icons.hourglass_top_outlined,
        title: '正在准备 ${kernel.label} 播放器…',
        detail: kernel == PlayerKernel.mpv
            ? 'MPV 首次启动要装载原生库，可能需要几秒；超过预算会自动回退 AVPlayer。'
            : '初始化完成后即可播放；一直没有响应可以切回 AVPlayer。',
        busy: true,
        actions: <Widget>[
          OutlinedButton(
            onPressed: _switchToAvPlayer,
            child: const Text('切回 AVPlayer'),
          ),
        ],
      );
    }

    return _buildVideoArea(player);
  }

  /// 就绪态的画面区：画面 + 亮度遮罩 + 弹幕层 + 手势层 + HUD。
  Widget _buildVideoArea(AbstractPlayer player) {
    return Center(
      child: ValueListenableBuilder<PlayerSnapshot>(
        valueListenable: player.snapshot,
        builder: (context, snapshot, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: snapshot.error == null
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      // 铺满整个播放区域：手势与 HUD 必须覆盖黑边，
                      // 否则竖屏视频两侧的字母框按不到（手势层只跟着画面走）。
                      fit: StackFit.expand,
                      alignment: Alignment.bottomLeft,
                      children: <Widget>[
                        // 画面本身居中；黑边留白由外层承担。
                        Center(child: player.buildView()),
                        // 亮度遮罩：**降级路径**用（平台不支持改系统亮度时）。
                        // 支持系统亮度时画面亮度由系统负责，这里不再叠一层，
                        // 否则同一手势会被应用两次（暗得比预期快）。
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
                        // 弹幕层：吃播放位置与设置，盖在画面上、HUD 之下。
                        Positioned.fill(
                          child: DanmakuOverlay(
                            position: snapshot.position,
                            playing: snapshot.playing,
                            track: _danmaku,
                            settings: _danmakuSettings,
                          ),
                        ),
                        // 手势层：左侧滑调亮度、右侧滑调音量、横滑调进度、
                        // 长按临时倍速。盖在画面上（弹幕之上，避免弹幕挡住手势）。
                        Positioned.fill(
                          child: _buildGestureLayer(size),
                        ),
                        // HUD 只吃 AbstractPlayer 暴露的参数：换内核零改动。
                        // 贴左下角（StackFit.expand 下子项会被撑满，因此显式对齐）。
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: PlayerHud(stats: player.stats),
                        ),
                      ],
                    );
                  },
                )
              : Text(
                  snapshot.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: LumeTheme.muted,
                  ),
                ),
        ),
      ),
    );
  }

  /// 控制栏：地址输入 + 进度 + 播放控制 + 弹幕 / 自动连播 / **播放器设置** / 画中画。
  ///
  /// [player] 为空时传输类按钮禁用，但**齿轮与地址栏照常可用**——「播不了」
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
              ),
              onSubmitted: (_) => _open(),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12,
                  color: LumeTheme.danger,
                ),
              ),
            const SizedBox(height: 8),
            ValueListenableBuilder<PlayerSnapshot>(
              valueListenable: player?.snapshot ?? _idleSnapshot,
              builder: (context, snapshot, _) => Column(
                children: <Widget>[
                  Slider(
                    value: _fraction(snapshot),
                    onChanged: snapshot.duration.inMilliseconds == 0
                        ? null
                        : (value) => player?.seek(
                              Duration(
                                milliseconds:
                                    (snapshot.duration.inMilliseconds * value)
                                        .round(),
                              ),
                            ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        _format(snapshot.position),
                        style: TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                      Text(
                        _format(snapshot.duration),
                        style: TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      IconButton(
                        iconSize: 34,
                        color: LumeTheme.textPrimary,
                        icon: Icon(
                          snapshot.playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                        ),
                        onPressed: player == null
                            ? null
                            : () => snapshot.playing
                                ? player.pause()
                                : player.play(),
                      ),
                      IconButton(
                        iconSize: 28,
                        color: LumeTheme.textPrimary,
                        icon: const Icon(Icons.stop_circle),
                        onPressed: player?.stop,
                      ),
                      IconButton(
                        iconSize: 28,
                        color: _danmakuSettings.enabled
                            ? LumeTheme.textPrimary
                            : LumeTheme.muted,
                        tooltip: _danmakuSettings.enabled
                            ? '弹幕：开'
                            : '弹幕：关',
                        icon: const Icon(Icons.subtitles_outlined),
                        onPressed: () {
                          final next = _danmakuSettings.copyWith(
                            enabled: !_danmakuSettings.enabled,
                          );
                          setState(() => _danmakuSettings = next);
                          final library = _library;
                          if (library != null) {
                            DanmakuSettingsStore(library).save(next);
                          }
                        },
                      ),
                      IconButton(
                        iconSize: 28,
                        color: LumeTheme.textPrimary,
                        tooltip: '发弹幕',
                        icon: const Icon(Icons.chat_bubble_outline),
                        onPressed: _composeDanmaku,
                      ),
                      IconButton(
                        iconSize: 28,
                        color: LumeTheme.textPrimary,
                        tooltip: '弹幕设置',
                        icon: const Icon(Icons.tune),
                        onPressed: _openDanmakuSettings,
                      ),
                      IconButton(
                        iconSize: 28,
                        color: _autoNext
                            ? LumeTheme.textPrimary
                            : LumeTheme.muted,
                        tooltip: _autoNext ? '自动连播：开' : '自动连播：关',
                        icon: const Icon(Icons.skip_next),
                        onPressed: () =>
                            setState(() => _autoNext = !_autoNext),
                      ),
                      IconButton(
                        iconSize: 28,
                        color: LumeTheme.textPrimary,
                        tooltip: '播放器设置',
                        // 与「弹幕设置」的 tune 区分开：这颗是播放器设置（内核 / 倍速 / 字幕）。
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: _openSettings,
                      ),
                      _buildPipButton(),
                      IconButton(
                        iconSize: 28,
                        color: LumeTheme.textPrimary,
                        icon: const Icon(Icons.download),
                        onPressed: _open,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 画中画按钮：不可用时是禁用占位（平台不支持或原生实现未接入）。
  Widget _buildPipButton() {
    final session = _session;
    if (session == null) {
      return const IconButton(
        iconSize: 28,
        icon: Icon(Icons.picture_in_picture_alt),
        onPressed: null,
        tooltip: '画中画：正在准备',
      );
    }
    return ValueListenableBuilder<PipSnapshot>(
      valueListenable: session.snapshot,
      builder: (context, snapshot, _) {
        if (snapshot.state == PipState.unavailable) {
          return const IconButton(
            iconSize: 28,
            icon: Icon(Icons.picture_in_picture_alt),
            onPressed: null,
            tooltip: '画中画：iOS 专属（原生接入前仅占位）',
          );
        }
        final busy = snapshot.state == PipState.entering ||
            snapshot.state == PipState.exiting;
        return IconButton(
          iconSize: 28,
          color: LumeTheme.textPrimary,
          icon: Icon(
            snapshot.isActive
                ? Icons.picture_in_picture
                : Icons.picture_in_picture_alt,
          ),
          onPressed: busy ? null : _togglePip,
          tooltip: snapshot.isActive ? '退出画中画' : '进入画中画',
        );
      },
    );
  }

  double _fraction(PlayerSnapshot snapshot) {
    final total = snapshot.duration.inMilliseconds;
    if (total <= 0) return 0;
    final value = snapshot.position.inMilliseconds / total;
    return value.clamp(0.0, 1.0);
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// 内核切换前记录的位置与播放状态（新内核加载完成后接回去）。
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

/// 剧集选择面板：图源条目有多集时先选一集再起播。
///
/// 与图源切换面板同一套玻璃外观（顶部圆角 + 深色背景），一行一集。
class _ChapterSheet extends StatelessWidget {
  const _ChapterSheet({required this.title, required this.chapters});

  /// 作品标题（面板抬头用）。
  final String title;

  final List<SourceChapter> chapters;

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '选择剧集',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = chapters[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: LumeTheme.textPrimary),
                      ),
                      onTap: () => Navigator.of(context).pop(chapter),
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
