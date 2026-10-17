import 'package:lume_box/core/theme/lume_typography.dart';

import '../../core/media/playback_focus.dart';
import '../../shared/widgets/subscription_status_icon.dart';
import 'video_detail_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/pip.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/explore_view.dart';
import '../reading/history_sheet.dart';
import '../source/source_subscription_page.dart';
import '../source/source_section_page.dart';
import '../reading/source_filter_page.dart';
import 'video_play_target.dart';
import 'video_player_page.dart';
import 'video_player_settings.dart';

/// 视频板块：**只保留【浏览】**（真机反馈：播放子页签移除）。
///
/// 页面职责**只有浏览**：
/// - 图源条（切换当前图源）+ 分类 / 搜索 / 列表（[ExploreView]）；
/// - 右上角：⏱️ 历史（底部抽屉）+ 图源管理与「+」添加图源。
///
/// 首页底部原先那块「继续观看」**已按用户要求删除**：首页只当浏览用，播放记录
/// （含续看 / 删单条 / 清空）统一从 ⏱️ 抽屉进，不再有两处入口。
///
/// **点条目不再切页签，而是唤起独立播放器页**（[VideoPlayerPage]）：播放是沉浸
/// 场景，独立页面能返回、能带自己的标题，也不再占板块的页签位。没有可用图源时
/// 首页给出导入引导。
///
/// 播放内核与播放设置的读写都搬到了播放器页：本页不再创建播放器，因此也不持有
/// 播放器设置库——只持有浏览列表封面用的图片管线与本板块阅读库。
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
  ///
  /// 本页自己不建播放器，这个端口只用于**透传**给唤起的播放器页（测试注入同一份
  /// 替身，就不必分别配置两处）。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。同样只用于透传给播放器页。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端（透传给播放器页）。
  final PipBackend? pipBackend;

  /// 屏幕亮度后端（透传给播放器页）。
  final BrightnessBackend? brightnessBackend;

  /// 图源管理端口（首页的浏览面用它取本板块图源）。为空时用正式实现。
  final SourceManager? sourceManager;

  /// 本板块阅读库（播放进度）；为空时按板块打开正式实现。
  final ReadingLibrary? library;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  /// 本板块的阅读库：视频进度（集数 + 时间点）落在它里面，记录从 ⏱️ 抽屉看。
  ReadingLibrary? _library;

  /// 浏览列表的封面图管线：**本板块自己**的（缓存落在 sections/video 之下）。
  SectionImagePipeline? _pipeline;

  /// 浏览面换代：从图源管理页返回后 +1，重挂浏览面（列表与当前图源重算）。
  int _browseRevision = 0;

  /// 阅读库打不开：浏览照常，但进度与播放记录不可用。
  bool _libraryFailed = false;

  bool _detailRouteOpen = false;

  /// 是否有播放器页正压在栈上（由 [_openPlayer] 维护）。
  ///
  /// 用来守住一个真实踩到的坑：退出时板块页与播放器页会在**同一帧**被销毁，
  /// 而 Flutter 不保证板块页晚于播放器页销毁。如果板块页先把共享的阅读库关了，
  /// 播放器页在 dispose 里写的最后一条进度就落进一个已关闭的库——store 对已关闭
  /// 库的写入是**静默降级**，结果是「退出 App 时最后几秒的进度丢失」（实测复现）。
  /// 因此只要播放器页还在栈上，板块页就不关它；等播放器页自己退栈后，下一次
  /// 板块页销毁（或 App 退出）再收尾。
  bool _playerRouteOpen = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _pipeline?.dispose();
    // 自己开的阅读库自己关（注入进来的不代管）；播放器页还在栈上时先让给它用
    // （见 [_playerRouteOpen]）。
    if (widget.library == null && !_playerRouteOpen) {
      ReadingLibrary.close(Section.video);
    }
    // 自己开的图源板块也自己关（与阅读库同一条纪律，注入进来的不代管）。
    // 收在板块页而不是浏览面 [ExploreView]：那边只是借用板块级的图源管理器，
    // 它一 close 就等于关掉整个板块的图源库（真机报「database has already been
    // closed」的根因）。播放器页也借用同一份（连播 / 弹幕），所以它还在栈上时
    // 同样先让给它用——与阅读库同一条理由。
    if (widget.sourceManager == null && !_playerRouteOpen) {
      LumeSources.close(Section.video);
    }
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final library =
          widget.library ?? await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      setState(() {
        _library = library;
        // 封面缩略图管线：与阅读板块同一套纪律（引用计数 + LRU + 磁盘缓存）。
        _pipeline = SectionImagePipeline(
          cacheDir: library.imageCacheDir,
          memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
          // 封面网格按封面并发（4）跑：并发太大被图床限流，反而更多空白。
          maxConcurrent: SectionImagePipeline.coverConcurrency,
        );
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _libraryFailed = true);
    }
  }

  /// 图源变更后重挂浏览面：列表与当前图源重新解析。
  void _onSourcesChanged() => setState(() => _browseRevision++);

  // ------------------------------------------------------ 图源条目 → 独立播放器

  /// 预启动一次内核：**在等播放地址的这几秒里先把内核建起来**（见 [PlayerPrelaunch]）。
  ///
  /// 按**本板块设置里存的那个内核**预启动（正式链路同样按它创建）；它在目录里
  /// 不可用时按目录回退（与播放器页的「生效内核」同一口径），免得预启动的实例
  /// 与页面要的内核不匹配而白建。设置库拿不到就不预启动——正式链路自己会建。
  PlayerPrelaunch? _startPrelaunch() {
    final library = _library;
    if (library == null) return null;
    final stored = VideoPlayerSettingsStore(library).load().kernel;
    final catalog = widget.catalog ?? const PlatformPlayerKernelCatalog();
    var kernel = stored;
    if (!catalog.isAvailable(kernel)) {
      for (final candidate in PlayerKernel.values) {
        if (catalog.isAvailable(candidate)) {
          kernel = candidate;
          break;
        }
      }
    }
    return PlayerPrelaunch.start(
      kernel,
      factory: widget.playerFactory,
      // 等一帧再开始：内核创建里的原生装载是同步阻塞的
      // （见 [PlayerKernelLauncher]），先让忙态上屏，用户看到的才是
      // 「正在解析地址」而不是一个卡住不动的列表。
      after: WidgetsBinding.instance.endOfFrame,
    );
  }

  /// 放弃一次预启动（拿不到设置库时本来就没预启动）。
  void _discardPrelaunch(PlayerPrelaunch? prelaunch) {
    final pre = prelaunch;
    if (pre != null) unawaited(pre.discard());
  }

  /// Push detail immediately; loading a cold or unavailable source belongs to that page.
  Future<void> _playFromSelection(ExploreSelection selection) async {
    final library = _library;
    if (!mounted || library == null || _detailRouteOpen) return;
    final manager = widget.sourceManager ?? LumeSources.manager(Section.video);
    _detailRouteOpen = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => VideoDetailPage(
            sourceId: selection.sourceId,
            loadSource: () => manager.open(selection.sourceId),
            item: selection.item,
            library: library,
            prelaunch: _startPrelaunch,
            onPlay: (media, target, qualities, prelaunch) => _openPlayer(
              media,
              target: target,
              qualities: qualities,
              prelaunch: prelaunch,
            ),
          ),
        ),
      );
    } finally {
      _detailRouteOpen = false;
    }
  }

  /// 唤起独立播放器页。
  ///
  /// 返回后**不必刷新任何列表**：首页不再有「继续观看」区块（用户要求删除），
  /// 播放记录只在右上角 ⏱️ 的抽屉里看，抽屉每次打开都会重读库。
  ///
  /// [prelaunch] 是浏览页在解析地址时预启动的内核，交给播放器页接手
  /// （见 [PlayerPrelaunch]）；页面已经不在时由这里负责释放。
  Future<void> _openPlayer(
    PlayerMedia media, {
    VideoPlayTarget? target,
    List<VideoQuality> qualities = const <VideoQuality>[],
    PlayerPrelaunch? prelaunch,
  }) async {
    if (!mounted) {
      _discardPrelaunch(prelaunch);
      return;
    }
    await PlaybackFocus.acquire('video');
    if (!mounted) {
      _discardPrelaunch(prelaunch);
      return;
    }
    _playerRouteOpen = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, animation, secondaryAnimation) => VideoPlayerPage(
            media: media,
            title: target?.title,
            target: target,
            sourceId: target?.sourceId,
            playerFactory: widget.playerFactory,
            catalog: widget.catalog,
            pipBackend: widget.pipBackend,
            brightnessBackend: widget.brightnessBackend,
            sourceManager: widget.sourceManager,
            library: _library,
            qualities: qualities,
            prelaunch: prelaunch,
          ),
        ),
      );
    } finally {
      _playerRouteOpen = false;
    }
  }

  /// 视频筛选入口（用户要求：点「筛选」**直接跳转到独立的第一层页面**）。
  ///
  /// 层级：第一层只列一级大分类（电影 / 电视剧 / 综艺 / 动漫 / 短剧，来自脚本）
  /// → 选中后进第二层填标签（剧集类型 / 题材 / 地区 / 年份 / 语言…）
  /// → 应用后整条链路一起返回，宿主据此拉列表。
  /// **不再有旧的「筛选下拉 / 分类抽屉」那条链路**（用户要求删掉）。
  Future<({String? categoryId, Map<String, String> filters})?> _openFacetFilter(
    BuildContext context,
    DataSource source,
    String? currentCategoryId,
    String originUrl,
  ) async {
    return openSourceFacetFilter(
      context: context,
      source: source,
      currentCategoryId: currentCategoryId,
      originUrl: originUrl,
    );
  }

  Future<void> _resumeFromProgress(LibraryItem item, VideoProgress progress) =>
      _playFromSelection(
        ExploreSelection(
          sourceId: item.sourceId,
          item: SourceItem(
            id: item.itemId,
            title: item.title,
            cover: item.cover,
            subtitle: item.subtitle,
          ),
        ),
      );

  // ------------------------------------------------------------------ 历史

  /// 打开历史抽屉（底部 Sheet）：在抽屉里直接浏览播放记录。
  ///
  /// 真机反馈：时钟图标点进来是「随手看一眼就回去」，因此**不新开全屏页面**。
  /// 首页不再有「继续观看」区块（用户要求删除），因此抽屉是播放记录的**唯一**
  /// 入口：删单条 / 清空也都在里面（视频的记录就是它的「书架」，清掉不丢别的）。
  Future<void> _openHistory({bool favorites = false}) async {
    final library = _library;
    if (library == null) return;
    await showReadingHistorySheet(
      context: context,
      section: Section.video,
      library: library,
      initialTab: favorites
          ? HistoryDrawerTab.favorites
          : HistoryDrawerTab.records,
      onOpenItem: (item) {
        Navigator.of(context).pop();
        _playFromSelection(
          ExploreSelection(
            sourceId: item.sourceId,
            item: SourceItem(
              id: item.itemId,
              title: item.title,
              cover: item.cover,
            ),
          ),
        );
      },
      onResume: (item, progress) {
        if (progress is! VideoProgress) return;
        Navigator.of(context).pop();
        _resumeFromProgress(item, progress);
      },
    );
    if (!mounted) return;
  }

  // ------------------------------------------------------------------ 构建

  /// 右上角动作（三个板块统一口径）：
  /// ⏱️ 历史抽屉，外加**图源管理**与「+」添加图源。
  ///
  /// 播放器设置不在这里——它属于播放器本身，在播放器页的控制栏齿轮上。
  List<Widget> _buildActions() => <Widget>[
    IconButton(
      tooltip: '播放历史',
      icon: const Icon(Icons.history),
      onPressed: _openHistory,
    ),
    const SizedBox(width: 2),
    IconButton(
      tooltip: '收藏',
      icon: const Icon(Icons.bookmark_outline),
      onPressed: () => _openHistory(favorites: true),
    ),
    const SizedBox(width: 2),
    IconButton(
      tooltip: '源管理',
      icon: const Icon(Icons.dns_outlined),
      onPressed: () async {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SourceSectionPage(
              section: Section.video,
              manager: widget.sourceManager,
            ),
          ),
        );
        if (mounted) _onSourcesChanged();
      },
    ),
    // 右上角统一的「+」添加图源：导入完成即刷新首页（与小说 / 漫画同口径）。
    const SizedBox(width: 2),
    Tooltip(
      message: '订阅',
      child: IconButton(
        icon: const SubscriptionStatusIcon(section: Section.video),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SourceSubscriptionPage(
                section: Section.video,
                manager: widget.sourceManager,
              ),
            ),
          );
          if (mounted) _onSourcesChanged();
        },
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      effectModule: GlassModule.video,
      // **不随键盘收缩**：板块内容区（ExploreView）自己处理键盘内边距
      // （列表底部让出键盘高度）。外层若跟着收缩，固定的工具栏 / 搜索行会被
      // 挤出屏幕——真机反馈过两次「键盘弹起后搜索框不见了」。
      resizeToAvoidBottomInset: false,
      title: Section.video.label,
      actions: _buildActions(),
      // **不再有页签条**（用户口径：删掉顶部那个「浏览」文字，内容直接往上顶，
      // 与猫源板块的顶部一致）。视频页本来也只剩一个浏览面——播放是独立的
      // 播放器页，页签条只是白占一条高度。
      behindBar: true,
      floatingBar: true,
      mergeHomeHeader: !_libraryFailed,
      child: _buildBrowseTab(),
    );
  }

  /// 浏览页签内容：只有图源列表。
  ///
  /// 底部原先挂着一块「继续观看」（最近 3 条 + 「全部」），**已按用户要求删除**：
  /// 首页只当浏览用，播放记录统一从右上角 ⏱️ 的抽屉进（不再有两处入口）。
  ///
  /// 起播期间（[busyLabel] 非空）在上面盖一层忙态：列表被挡住、在等什么写在
  /// 卡片上——点按有反馈，也不会被连点两次。
  Widget _buildBrowseTab() {
    // library 打不开时的说明卡（浏览照常，只是进度与记录不可用）。
    final content = _libraryFailed
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: GlassCard(
                padding: EdgeInsets.all(20),
                child: Text(
                  '视频板块的阅读库打不开，播放进度与记录暂不可用；浏览与播放不受影响。',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.bodySize,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          )
        // 与小说 / 漫画**同一个浏览组件**：同款工具栏（源下拉 → 排序 → 布局 →
        // 搜索 → 筛选）、同款搜索（聚合 / 当前源）与分页 / 预热。视频板块因此
        // 不再有一套自己的浏览实现——三块的肌肉记忆真正一致。
        : ExploreView(
            section: Section.video,
            // 管线可能还在准备：为空时封面先出占位（不挂转圈等它，见 ExploreView）。
            pipeline: _pipeline,
            manager: widget.sourceManager,
            layout: ExploreLayout.list,
            // 顶栏已经有「源管理」，图源条里不再重复放一个。
            showSourceManage: false,
            // 导入 / 删除图源后原地重解析（不重挂：重挂会与旧实例的 dispose
            // 抢同一份板块注册表，真机上会报「图源存储不可用」）。
            revision: _browseRevision,
            onOpenItem: _playFromSelection,
            // 视频筛选：一级分类（底部弹窗）→ 独立筛选子页（分页跳转模式，用户口径）。
            onOpenFacetFilter: _openFacetFilter,
          );
    return content;
  }
}
