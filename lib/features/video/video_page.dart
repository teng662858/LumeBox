import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
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
import 'player_hud.dart';
import 'player_settings_page.dart';
import 'source_playback.dart';
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
  });

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端。为空时按平台选择（iOS 走原生通道，其余平台如实降级）。
  final PipBackend? pipBackend;

  /// 图源管理端口（首页的浏览面用它取本板块图源）。为空时用正式实现。
  final SourceManager? sourceManager;

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
    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    // 离开板块时底部导航必须回来：先摘监听再释放隐藏令牌。
    player?.snapshot.removeListener(_syncDockForPlayback);
    _dock?.show(_dockToken);
    // 资源边界：先退画中画再释放播放器，最后关库（顺序不能反）。
    unawaited(() async {
      await session?.dispose();
      await player?.dispose();
    }());
    _store?.close();
    _input.dispose();
    _tabs.dispose();
    super.dispose();
  }

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
    player.snapshot.addListener(_syncDockForPlayback);

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
      await _startPlayback(PlayerMedia(uri: direct, title: item.title));
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
      await _startPlayback(
        PlayerMedia(uri: address, title: '${item.title} · ${chapter.title}'),
      );
    } on SourceException catch (error) {
      _showPlayerToast(error.message);
    }
  }

  /// 交给播放器并切到「播放」页签。播放器不可用时如实提示，不静默失败。
  Future<void> _startPlayback(PlayerMedia media) async {
    if (_player == null) {
      _showPlayerToast(
        _anyKernelAvailable ? '播放器还在准备，请稍后再试' : '本平台不提供播放内核',
      );
      return;
    }
    if (!mounted) return;
    _input.text = media.uri.toString();
    _tabs.animateTo(VideoPage.playerTabIndex);
    await _loadMedia(media);
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
          // 首页：当前图源的内容展示页（右上角已有「图源管理」，图源条不再重复）。
          SourceBrowsePane(
            key: ValueKey<int>(_browseRevision),
            section: Section.video,
            manager: widget.sourceManager,
            showSourceActions: false,
            onItemTap: _playFromSource,
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
