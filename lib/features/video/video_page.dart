import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
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
import 'player_hud.dart';
import 'player_settings_page.dart';
import 'source_playback.dart';
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
/// 都可用，MDK 只预留接口。页面只认 [AbstractPlayer] 与 [PlayerStats]：内核切换、
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
    this.sourceManager,
    this.library,
  });

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端。为空时按平台选择（iOS 走原生通道，其余平台如实降级）。
  final PipBackend? pipBackend;

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
    _store?.close();
    if (widget.library == null) ReadingLibrary.close(Section.video);
    _input.dispose();
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
      setState(() => _library = library);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[video] 阅读库打不开，本次不记录播放进度');
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
    await _rebuildPlayer();
  }

  /// 按当前设置创建播放器，并把媒体与播放位置接回去。
  ///
  /// 运行时切换内核与首次启动走同一条路：拆旧内核 → 建新内核 → 补挂设置 →
  /// 重新加载媒体 → 恢复位置与播放状态。
  Future<void> _rebuildPlayer() async {
    final previous = _player;
    final resume = previous == null ? null : _ResumePoint.of(previous);
    _player = null;
    if (previous != null) {
      previous.snapshot.removeListener(_syncDockForPlayback);
      await previous.dispose();
    }

    // 先亮出「正在准备播放器」：初始化在异步流程里跑，UI 不阻塞。
    if (mounted) {
      setState(() {
        _player = null;
        _loaded = false;
      });
    }

    final launch = await _launcher.launch(_effectiveKernel);
    if (!mounted) {
      await launch?.player.dispose();
      return;
    }
    if (launch == null) {
      // 连兜底内核都起不来：不再落库，页面按骨架/空态处理。
      setState(() => _player = null);
      return;
    }
    if (launch.didFallback) {
      // 回退：设置改成实际生效的内核并提示；**失败的内核绝不写进配置**。
      _settings = _settings.copyWith(kernel: launch.kernel);
      _showPlayerToast(launch.message);
    }
    _store?.save(_settings);
    final player = launch.player;
    setState(() {
      _player = player;
      _loaded = false;
    });
    // 播放状态驱动底部 Dock 的显隐（播放中沉浸）。
    player.snapshot.addListener(_onSnapshotChanged);

    await player.applySettings(_settings);
    final media = _media;
    if (media == null) return;
    await _loadMedia(media);
    if (resume != null && !resume.isAtStart) {
      await player.seek(resume.position);
      if (resume.playing) await player.play();
    }
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
    setState(() => _browseRevision++);
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
      _showPlayerToast('「${item.title}」的图源不可用（未启用或脚本载入失败）');
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

  /// 画中画事件回调：原生失败给可读提示，其余事件只记录。
  void _onPipEvent(PipEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case PipEventKind.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(event.message ?? '画中画失败')),
        );
      case PipEventKind.entered:
      case PipEventKind.exited:
      case PipEventKind.restored:
        LumeLog.info('[video] 画中画事件: ${event.kind.id}');
    }
  }

  // ------------------------------------------------------------------ 构建

  /// 右上角动作（四个板块统一口径）：**图源管理** + 添加图源。
  ///
  /// 播放器设置不在这里——它属于播放器本身，放在播放控制栏的齿轮上
  /// （与文档草图 2 的 [⚙️] 一致），避免和「图源管理」抢同一个位置。
  List<Widget> _buildActions() => <Widget>[
        IconButton(
          tooltip: '图源管理',
          icon: const Icon(Icons.source_outlined),
          onPressed: _manageSources,
        ),
        const AddSourceButton(section: Section.video),
      ];

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: Section.video.label,
      actions: _buildActions(),
      child: BoardTabs(
        controller: _tabs,
        labels: VideoPage.tabLabels,
        children: <Widget>[
          // 首页：继续观看（有记录才显示）+ 当前图源的内容展示页
          // （右上角已有「图源管理」，图源条不再重复）。
          Column(
            children: <Widget>[
              if (_library != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ContinueWatchingSection(
                    key: ValueKey<int>(_continueWatchingRevision),
                    library: _library,
                    onResume: _resumeFromProgress,
                    onRemove: _removeProgress,
                  ),
                ),
              Expanded(
                child: SourceBrowsePane(
                  key: ValueKey<int>(_browseRevision),
                  section: Section.video,
                  manager: widget.sourceManager,
                  showSourceActions: false,
                  onItemTap: _playFromSource,
                ),
              ),
            ],
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
    if (_storeFailed) {
      return const Center(
        child: Text(
          '播放器设置库不可用',
          style: TextStyle(color: LumeTheme.muted),
        ),
      );
    }
    final player = _player;
    if (player == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: ValueListenableBuilder<PlayerSnapshot>(
              valueListenable: player.snapshot,
              builder: (context, snapshot, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: snapshot.error == null
                    ? Stack(
                        alignment: Alignment.bottomLeft,
                        children: <Widget>[
                          player.buildView(),
                          // HUD 只吃 AbstractPlayer 暴露的参数：换内核零改动。
                          PlayerHud(stats: player.stats),
                        ],
                      )
                    : Text(
                        snapshot.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          color: LumeTheme.muted,
                        ),
                      ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GlassCard(
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _input,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
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
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFFF8A80),
                    ),
                  ),
                const SizedBox(height: 8),
                ValueListenableBuilder<PlayerSnapshot>(
                  valueListenable: player.snapshot,
                  builder: (context, snapshot, _) => Column(
                    children: <Widget>[
                      Slider(
                        value: _fraction(snapshot),
                        onChanged: snapshot.duration.inMilliseconds == 0
                            ? null
                            : (value) => player.seek(
                                  Duration(
                                    milliseconds:
                                        (snapshot.duration.inMilliseconds *
                                                value)
                                            .round(),
                                  ),
                                ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            _format(snapshot.position),
                            style: const TextStyle(
                              fontSize: 12,
                              color: LumeTheme.muted,
                            ),
                          ),
                          Text(
                            _format(snapshot.duration),
                            style: const TextStyle(
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
                            color: Colors.white,
                            icon: Icon(
                              snapshot.playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                            ),
                            onPressed: () => snapshot.playing
                                ? player.pause()
                                : player.play(),
                          ),
                          IconButton(
                            iconSize: 28,
                            color: Colors.white,
                            icon: const Icon(Icons.stop_circle),
                            onPressed: player.stop,
                          ),
                          IconButton(
                            iconSize: 28,
                            color:
                                _autoNext ? Colors.white : LumeTheme.muted,
                            tooltip: _autoNext ? '自动连播：开' : '自动连播：关',
                            icon: const Icon(Icons.skip_next),
                            onPressed: () =>
                                setState(() => _autoNext = !_autoNext),
                          ),
                          IconButton(
                            iconSize: 28,
                            color: Colors.white,
                            tooltip: '播放器设置',
                            icon: const Icon(Icons.tune),
                            onPressed: _openSettings,
                          ),
                          _buildPipButton(),
                          IconButton(
                            iconSize: 28,
                            color: Colors.white,
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
        ),
      ],
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
          color: Colors.white,
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
              const Text(
                LumeTheme.appName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '当前平台在 Phase1 仅保留页面骨架',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: LumeTheme.muted),
              ),
              const SizedBox(height: 8),
              const Text(
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
                    const Text(
                      '选择剧集',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
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
                        style: const TextStyle(color: Colors.white),
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
