import '../../shared/widgets/network_owned_state.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../core/media/media_library.dart';

import 'dart:async';

import '../../shared/widgets/missing_cover.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/source/home_browse_mode.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/net/waf.dart';
import '../../core/net/secure_connection_failure.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../source/waf_webview_page.dart';
import 'poster_card.dart';
import 'adaptive_cover_surface.dart';
import 'section_image.dart';
import 'cover_viewport.dart';
import '../shell/section_preloader.dart';

/// 板块首页：**多板块横滑**（用户口径任务 3：视频 / 漫画三块共用）。
///
/// 数据全部来自图源的 `home()`，两套格式由 [SourceHome.parse] 自动识别：
/// - **多板块模式**：每个板块一行横向滑动（标题 + 可选「更多」），标题文字由
///   图源给，App 不硬编码；板块内为空整块跳过；
/// - **旧兼容模式**：图源直接给一份 Item 数组 → 这里渲染普通网格，
///   **不渲染任何横向板块组件**；
/// - 首页为空 → 「暂无首页推荐内容」+ 引导去分类浏览。
///
/// 卡片复用现有的 [PosterCard]（与探索页同一套，含「遮罩内置 / 外置独立」标题
/// 风格）——不新建卡片样式。
class SourceHomeView extends StatefulWidget {
  const SourceHomeView({
    super.key,
    required this.source,
    required this.pipeline,
    required this.onOpenItem,
    this.onOpenMore,
    this.originUrl = '',
    this.topInset = 8,
    this.bottomInset = 0,
    this.onRefreshMetadata,
    this.onHomeLoaded,
    this.onTranslationTexts,
    this.browseMode,
  });

  final DataSource source;
  final String? browseMode;
  final double topInset;
  final double bottomInset;
  final Future<void> Function()? onRefreshMetadata;
  final VoidCallback? onHomeLoaded;
  final ValueChanged<List<String>>? onTranslationTexts;

  /// 图源的订阅地址（可选）：过 WAF 时用它兜底拿站点 origin。
  final String originUrl;
  final SectionImagePipeline? pipeline;

  /// 点条目：交给宿主打开（与列表条目同一条链路）。
  final void Function(SourceItem item) onOpenItem;

  /// 点「更多」：宿主负责压栈到「更多」页（传 moreUrl）。
  final void Function(String title, String moreUrl)? onOpenMore;

  @override
  State<SourceHomeView> createState() => _SourceHomeViewState();
}

class _SourceHomeViewState extends State<SourceHomeView>
    with NetworkOwnedState<SourceHomeView> {
  SourceHome? _home;
  Object? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    MediaLibrary.instance.addListener(_mediaChanged);
    BrowseLayoutSettings.instance.addListener(_layoutChanged);
    _bindSession();
    _load();
  }

  void _layoutChanged() {
    if (mounted) setState(() {});
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    MediaLibrary.instance.removeListener(_mediaChanged);
    BrowseLayoutSettings.instance.removeListener(_layoutChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(SourceHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换图源：重新取首页（代号作废在飞结果）。
    if (!identical(oldWidget.source, widget.source)) {
      networkRequests.cancelAll();
      _bindSession();
      // Source ids are stable across settings changes. A new DataSource object
      // therefore needs a forced load: cancel old warm data and advance _seq,
      // even when _loadingSourceId still equals this id.
      _load(force: true);
    } else if (!identical(oldWidget.pipeline, widget.pipeline) &&
        _home != null) {
      _bindSession();
      _preloadFirstScreen(_home!);
    }
  }

  /// 把「源站会话」挂到封面管线上：源站上了 Cloudflare 校验时，封面请求不带
  /// `cf_clearance` 就是一片空白（正文却能看）——详见 `SectionImagePipeline.bindSession`。
  void _bindSession() =>
      widget.pipeline?.bindSession(widget.source.section, widget.source.id);

  /// 运行时被换掉（换源/改站点地址/重载）时，在飞的请求会以「请求已取消」
  /// 结束——这不是用户要看的失败，静默重来一次即可。
  static bool _superseded(Object error) {
    final text = error is SourceException ? error.message : '$error';
    return text.contains('请求已取消') ||
        text.contains('源已释放') ||
        text.contains('网页请求已取消');
  }

  /// 正在加载的源 id：同一源的非强制重入直接复用，不再 cancel 重启
  /// （真机日志里出现过 30 秒内 30 次「请求已取消」的取消风暴）。
  String? _loadingSourceId;

  Future<void> _load({bool force = false, bool retried = false}) async {
    final source = widget.source;
    if (!force && _loadingSourceId == source.id) return;
    final seq = ++_seq;
    _loadingSourceId = source.id;
    networkRequests.cancel('home');
    setState(() {
      _home = null;
      _error = null;
    });
    if (source is! HomeCapable) {
      _loadingSourceId = null;
      if (!mounted) return;
      setState(() => _home = const SourceHome());
      return;
    }
    try {
      if (force) SectionPreloader.discard(source.section);
      await SectionPreloader.waitForWarm(
        source.section,
        sourceId: source.id,
        home: true,
      );
      if (!mounted || seq != _seq) return;
      final home =
          SectionPreloader.takeWarmHome(source.section, sourceId: source.id) ??
          await networkRequests.run<SourceHome>(
            'home',
            () => (source as HomeCapable).home(),
            timeout: const Duration(seconds: 40),
            timeoutError: () => const SourceException(
              SourceErrorKind.network,
              '首页请求超时，请重试或检查网页验证会话',
            ),
          );
      if (!mounted || seq != _seq) return;
      setState(() => _home = home);
      _preloadFirstScreen(home);
      widget.onTranslationTexts?.call([
        ...home.items.map((item) => item.title),
        for (final board in home.boards) ...[
          board.title,
          ...board.items.map((item) => item.title),
        ],
      ]);
      widget.onHomeLoaded?.call();
    } catch (error) {
      if (!mounted || seq != _seq) return;
      if (!retried && _superseded(error)) {
        // 给新运行时一点启动时间（保存设置后引擎是重建的）。
        // 先让出「正在加载」标记，否则重试会被自己的去重挡掉。
        _loadingSourceId = null;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!mounted || seq != _seq) return;
        return _load(force: force, retried: true);
      }
      setState(() => _error = error);
    } finally {
      if (seq == _seq) _loadingSourceId = null;
    }
  }

  /// 用户显式发起的一次尝试（卡片上的【重试】）：**先武装，再重放**。
  ///
  /// **不自动开验证窗**（用户口径，连续两轮）：验证窗只在用户点【网页视图】时
  /// 打开；点【重试】若仍被拦下，看到的还是这张错误卡。
  Future<void> _retry() async {
    await Future.wait<void>([
      _load(force: true),
      if (widget.onRefreshMetadata != null) widget.onRefreshMetadata!(),
    ]);
  }

  /// 数据返回后立刻预取首屏，按页面的平铺顺序和实际解码档准备封面。
  void _preloadFirstScreen(SourceHome home) {
    final pipeline = widget.pipeline;
    if (pipeline == null) return;
    pipeline.bindSource(widget.source);
    _bindSession();
    final items = home.isBoards
        ? home.boards.expand((board) => board.items)
        : home.items;
    final urls = <String>[];
    for (final item in items) {
      if (urls.length >= 12) break;
      final cover = (item.cover ?? '').trim();
      if (cover.isNotEmpty) {
        pipeline.configureImageHeaders({cover: item.coverHeaders});
        urls.add(cover);
      }
    }
    final mode = BrowseLayoutSettings.instance.modeFor(widget.source.section);
    pipeline.preload(
      urls,
      targetWidth: switch (mode) {
        BrowseLayoutMode.list => 200,
        BrowseLayoutMode.list2 => 200,
        _ => _HomeCard.coverWidth,
      },
    );
  }

  /// 被 WAF 拦下：网页视图过校验 → 存会话 → 重新拉首页（用户口径 2.1）。
  ///
  /// **点这里的按钮一定会有反应**（真机反馈过三轮「点了没反应」）：地址走统一
  /// 兜底链，四层全落空时弹地址输入框；开窗失败也会弹窗说明——三条出口都在
  /// [runWafWebViewFlow] 里，三个页面共用。
  Future<void> _openWebViewForWaf() async {
    final detail = _error is SourceException
        ? (_error! as SourceException).message
        : '$_error';
    final outcome = await runWafWebViewFlow(
      context: context,
      section: widget.source.section,
      sourceId: widget.source.id,
      sourceName: widget.source.name,
      failureMessage: detail,
      originUrl: widget.originUrl,
    );
    if (!mounted) return;
    switch (outcome) {
      case WafWebViewOutcome.notOpened:
        return;
      case WafWebViewOutcome.emptySession:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没取到会话：等验证通过、站点页面真正显示出来后再点 ✕ 关闭')),
        );
        return;
      case WafWebViewOutcome.collected:
        await _retry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      final detail = error is SourceException ? error.message : '$error';
      final connection = secureConnectionFailureOf(error);
      final description = connection == null
          ? detail
          : '$detail\n\n${secureConnectionHint(connection)}';
      final kind = wafKindOf(detail);
      // 「网页视图」出口与提示**必须同时出现或同时不出现**（真机反馈：卡片上写着
      // 「可点【网页视图】过校验」却找不到按钮——首页超时这类失败原本不给按钮）。
      final offerWebView = shouldOfferWebView(detail);
      // 站址解析结果直接写在卡片上（用户口径：报错信息里要能看出拿到了源站地址）。
      final hint = offerWebView
          ? webViewTargetHint(
              failureMessage: detail,
              sourceId: widget.source.id,
              originUrl: widget.originUrl,
            )
          : null;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              NoticeCard(
                title: '首页加载失败',
                subtitle: kind == WafFailureKind.bridge
                    ? '$description\n\n$wafBridgeHint'
                    : (hint == null ? description : '$description\n\n$hint'),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  OutlinedButton(onPressed: _retry, child: const Text('重试')),
                  if (offerWebView) ...<Widget>[
                    const SizedBox(width: 10),
                    // 与列表页同一个出口（用户口径 2.1）：内置网页视图过校验后自动重拉。
                    OutlinedButton.icon(
                      onPressed: _openWebViewForWaf,
                      icon: const LumeIcon(
                        Icons.public,
                        slot: 'source_home_view.1',
                        size: 18,
                      ),
                      label: const Text('网页视图'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }
    final original = _home;
    bool visible(SourceItem item) => MediaLibrary.instance.visibleAtOrigin(
      widget.source.section,
      widget.source.id,
      item.id,
    );
    final home = original == null
        ? null
        : SourceHome(
            items: original.items.where(visible).toList(),
            boards: [
              for (final board in original.boards)
                SourceHomeBoard(
                  title: board.title,
                  moreUrl: board.moreUrl,
                  items: board.items.where(visible).toList(),
                ),
            ],
          );
    if (home == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (home.isEmpty) {
      // 用户口径任务 3.2：空首页给提示并引导去分类。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const NoticeCard(
                title: '暂无首页推荐内容',
                subtitle: '这个源没有给出首页模块。可以到分类里挑一部看。',
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const LumeIcon(
                  Icons.grid_view_outlined,
                  slot: 'source_home_view.2',
                  size: 18,
                ),
                label: const Text('去分类浏览'),
              ),
            ],
          ),
        ),
      );
    }
    final boards = widget.browseMode == null
        ? home.boards
        : home.boards
              .where(
                (board) =>
                    homeBrowsePattern(widget.browseMode!).hasMatch(board.title),
              )
              .toList();
    if (widget.browseMode != null && boards.isEmpty) {
      return Center(
        child: NoticeCard(
          title: '当前源未提供${widget.browseMode}内容',
          subtitle: '请选择源提供的分类，或切换站点。',
        ),
      );
    }
    final items = home.isBoards
        ? {
            for (final board in boards)
              for (final item in board.items) item.id: item,
          }.values.toList()
        : home.items;
    return AdaptiveCoverSurface(
      pipeline: widget.pipeline,
      item: items.isEmpty ? null : items.first,
      child: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _load(force: true),
            if (widget.onRefreshMetadata != null) widget.onRefreshMetadata!(),
          ]);
        },
        child: CoverViewport(child: _buildFlat(items)),
      ),
    );
  }

  /// 旧兼容模式：普通网格首页（不出现任何横向板块组件）。
  Widget _buildFlat(List<SourceItem> items) {
    final mode =
        BrowseLayoutSettings.instance.modeFor(widget.source.section) ??
        BrowseLayoutMode.grid3;
    if (mode == BrowseLayoutMode.list) {
      return ListView.separated(
        scrollCacheExtent: const ScrollCacheExtent.viewport(1),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          widget.topInset,
          16,
          16 + widget.bottomInset,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1),
        itemBuilder: (context, index) {
          final item = items[index];
          return CompactSourceItemTile(
            item: item,
            pipeline: widget.pipeline,
            onTap: () => widget.onOpenItem(item),
            columns: 1,
            coverWidth: 80,
            coverHeight: 100,
            flat: true,
            showMenu: true,
          );
        },
      );
    }
    final compactGrid = mode == BrowseLayoutMode.grid3;
    final sidePadding = compactGrid
        ? ThreeColumnPosterLayout.sidePadding
        : TwoColumnSourceLayout.sidePadding;
    final spacing = compactGrid
        ? ThreeColumnPosterLayout.spacing
        : TwoColumnSourceLayout.spacing;
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        scrollCacheExtent: const ScrollCacheExtent.viewport(1),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          sidePadding,
          widget.topInset,
          sidePadding,
          16 + widget.bottomInset,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: mode.columns,
          mainAxisSpacing: compactGrid
              ? ThreeColumnPosterLayout.rowSpacing
              : TwoColumnSourceLayout.rowSpacing,
          crossAxisSpacing: spacing,
          // 双列行高同时适配实际列宽和系统字号。
          mainAxisExtent: mode == BrowseLayoutMode.list2
              ? TwoColumnSourceLayout.itemExtent(
                  context,
                  TwoColumnSourceLayout.cellWidth(constraints.maxWidth),
                )
              : null,
          // mainAxisExtent 非空时这个值会被忽略，给它默认 1 即可。
          childAspectRatio: mode == BrowseLayoutMode.list2
              ? 1
              : mode.tileAspectRatio,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => mode == BrowseLayoutMode.list2
            ? TwoColumnSourceItemTile(
                item: items[index],
                pipeline: widget.pipeline,
                onTap: () => widget.onOpenItem(items[index]),
              )
            : _HomeCard(
                compactGrid: compactGrid,
                item: items[index],
                pipeline: widget.pipeline,
                onTap: () => widget.onOpenItem(items[index]),
              ),
      ),
    );
  }
}

/// 首页 / 更多页的卡片：复用探索页的 [PosterCard] 与标题风格设置（不新建卡片样式）。
class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.item,
    required this.pipeline,
    required this.onTap,
    this.compactGrid = false,
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;
  final bool compactGrid;

  /// 封面解码宽度：与探索页网格同一档（`CoverThumb(width: 300)`）。
  ///
  /// 卡片本身约 104 宽，以前**不给解码宽度**＝按原图解：一屏几十张原图直接冲爆
  /// 缩略图预算（24MB），而且缓存键是裸 URL、与探索页那两档（160 / 300）都对不上，
  /// 同一张封面在首页与列表里各存一份。统一到 300：清晰度够，键也统一。
  static const int coverWidth = 300;

  @override
  Widget build(BuildContext context) {
    final style = BrowseLayoutSettings.instance.gridTitleStyle;
    return PosterCard(
      onTap: onTap,
      footnoteBelow: style == GridTitleStyle.below,
      footnoteGap: ThreeColumnPosterLayout.titleGap,
      footnotePadding: const EdgeInsets.symmetric(horizontal: 2),
      footnote: PosterTitle(
        item.title,
        overlay: style == GridTitleStyle.overlay,
      ),
      child: pipeline == null
          // 管线还在准备（封面先出占位，与探索页同口径）。
          ? ColoredBox(color: LumeTheme.fill)
          : SectionImage(
              pipeline: pipeline!,
              url: item.cover ?? '',
              placeholder: MissingCover(
                title: item.title,
                section: pipeline!.section,
              ),
              headers: item.coverHeaders,
              targetWidth: coverWidth,
              fit: BoxFit.cover,
            ),
    );
  }
}

/// 「更多」页（用户口径任务 3.2）：按 moreUrl 调图源接口，网格分页展示。
class SourceHomeMorePage extends StatefulWidget {
  const SourceHomeMorePage({
    super.key,
    required this.source,
    required this.title,
    required this.moreUrl,
    required this.pipeline,
    required this.onOpenItem,
  });

  final DataSource source;
  final String title;

  /// 板块给的「更多」标识：原样作为 categoryId 交给脚本（脚本自己解释它）。
  final String moreUrl;
  final SectionImagePipeline? pipeline;
  final void Function(SourceItem item) onOpenItem;

  @override
  State<SourceHomeMorePage> createState() => _SourceHomeMorePageState();
}

class _SourceHomeMorePageState extends State<SourceHomeMorePage>
    with NetworkOwnedState<SourceHomeMorePage> {
  final List<SourceItem> _items = <SourceItem>[];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    widget.pipeline?.bindSource(widget.source);
    widget.pipeline?.bindSession(widget.source.section, widget.source.id);
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final page = _page + 1;
    try {
      final result = await networkRequests.run(
        'browse',
        () => widget.source.list(categoryId: widget.moreUrl, page: page),
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _hasMore = result.hasMore;
        _items.addAll(result.items);
        _loading = false;
      });
      _preload(result.items, more: page > 1);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  /// 尾部「加载失败，点击重试」：同上，不自动开验证窗。
  Future<void> _retryMore() => _loadMore();

  /// 预取封面（与探索页同一套口径：只取开头一小段、解码宽度与 tile 一致）。
  ///
  /// 排行榜这类「更多」页以前完全不预取：一屏十几张封面同时冷启，图床按 IP 限流时
  /// 一批会集体空白（用户口径：首页/二级列表很多封面显示不出来）。
  void _preload(List<SourceItem> items, {bool more = false}) {
    final pipeline = widget.pipeline;
    if (pipeline == null) return;
    final limit = more ? 8 : 12;
    final urls = <String>[];
    for (final item in items) {
      if (urls.length >= limit) break;
      final cover = (item.cover ?? '').trim();
      if (cover.isNotEmpty) {
        pipeline.configureImageHeaders({cover: item.coverHeaders});
        urls.add(cover);
      }
    }
    pipeline.preload(urls, targetWidth: _HomeCard.coverWidth);
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: widget.title,
      child: CoverViewport(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 600) _loadMore();
            return false;
          },
          child: GridView.builder(
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            padding: GlassScaffold.barInset(context)
                .add(const EdgeInsets.fromLTRB(10, 8, 10, 16)),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: ThreeColumnPosterLayout.rowSpacing,
              crossAxisSpacing: ThreeColumnPosterLayout.spacing,
              childAspectRatio: 0.62,
            ),
            itemCount: _items.length + (_hasMore || _error != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _items.length) {
                if (_error != null) {
                  return Center(
                    child: TextButton(
                      onPressed: _retryMore,
                      child: const Text('加载失败，点击重试'),
                    ),
                  );
                }
                return const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final item = _items[index];
              return _HomeCard(
                compactGrid: true,
                item: item,
                pipeline: widget.pipeline,
                onTap: () => widget.onOpenItem(item),
              );
            },
          ),
        ),
      ),
    );
  }
}
