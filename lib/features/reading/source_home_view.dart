import '../../core/media/media_library.dart';

import 'dart:async';

import '../../shared/widgets/missing_cover.dart';

import 'package:flutter/material.dart';

import '../../core/source/home_browse_mode.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/net/waf.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../source/waf_webview_page.dart';
import 'poster_card.dart';
import 'section_image.dart';
import '../shell/section_preloader.dart';

/// 板块首页：**多板块横滑**（用户口径任务 3：视频 / 小说 / 漫画三块共用）。
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
    this.browseMode,
  });

  final DataSource source;
  final String? browseMode;
  final double topInset;
  final double bottomInset;
  final Future<void> Function()? onRefreshMetadata;

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

class _SourceHomeViewState extends State<SourceHomeView> {
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
      _bindSession();
      _load();
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

  Future<void> _load({bool force = false}) async {
    final seq = ++_seq;
    setState(() {
      _home = null;
      _error = null;
    });
    final source = widget.source;
    if (source is! HomeCapable) {
      if (!mounted) return;
      setState(() => _home = const SourceHome());
      return;
    }
    try {
      if (force) SectionPreloader.discard(source.section);
      await SectionPreloader.waitForWarm(source.section);
      if (!mounted || seq != _seq) return;
      final home =
          SectionPreloader.takeWarmHome(source.section, sourceId: source.id) ??
          await (source as HomeCapable).home().timeout(
            const Duration(seconds: 40),
            onTimeout: () => throw const SourceException(
              SourceErrorKind.network,
              '首页请求超时，请重试或检查网页验证会话',
            ),
          );
      if (!mounted || seq != _seq) return;
      setState(() => _home = home);
      _preloadFirstScreen(home);
    } catch (error) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = error);
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

  /// 首屏封面的预取：第一块板块的前几张。
  ///
  /// 横向板块是懒构建的（只建可见卡片），后面的卡片进视口时自己会取；这里补的是
  /// 「首屏那几张要立刻出现」。以前这里完全不预取、而且卡片按原图解（见
  /// [_HomeCard]），首屏封面一边下载一边解码，看着就是「半天不出图」。
  void _preloadFirstScreen(SourceHome home) {
    final pipeline = widget.pipeline;
    if (pipeline == null) return;
    pipeline.bindSource(widget.source);
    _bindSession();
    final items = home.isBoards
        ? (home.boards.isEmpty ? const <SourceItem>[] : home.boards.first.items)
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
    pipeline.preload(urls, targetWidth: _HomeCard.coverWidth);
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
                    ? '$detail\n\n$wafBridgeHint'
                    : (hint == null ? detail : '$detail\n\n$hint'),
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
                      icon: const Icon(Icons.public, size: 18),
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
                icon: const Icon(Icons.grid_view_outlined, size: 18),
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
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          _load(force: true),
          if (widget.onRefreshMetadata != null) widget.onRefreshMetadata!(),
        ]);
      },
      child: _buildFlat(
        home.isBoards
            ? {
                for (final board in boards)
                  for (final item in board.items) item.id: item,
              }.values.toList()
            : home.items,
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
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          widget.topInset,
          16,
          16 + widget.bottomInset,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
            leading: SizedBox(
              width: 48,
              height: 64,
              child: widget.pipeline == null
                  ? ColoredBox(color: LumeTheme.fill)
                  : PosterCover(
                      pipeline: widget.pipeline!,
                      url: item.cover,
                      headers: item.coverHeaders,
                      title: item.title,
                      width: 160,
                    ),
            ),
            title: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => widget.onOpenItem(item),
          );
        },
      );
    }
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        16,
        widget.topInset,
        16,
        16 + widget.bottomInset,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: mode.columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: mode.tileAspectRatio,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => mode == BrowseLayoutMode.list2
          ? CompactSourceItemTile(
              item: items[index],
              pipeline: widget.pipeline,
              onTap: () => widget.onOpenItem(items[index]),
            )
          : _HomeCard(
              item: items[index],
              pipeline: widget.pipeline,
              onTap: () => widget.onOpenItem(items[index]),
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
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;

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
      // 与探索页同一套标题呈现（遮罩内置白字 / 外置独立黑字）。
      footnote: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style == GridTitleStyle.below
                ? TextStyle(
                    fontSize: LumeTypography.bodySize,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  )
                : const TextStyle(
                    fontSize: LumeTypography.bodySize,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: <Shadow>[
                      Shadow(color: Color(0xB3000000), blurRadius: 4),
                    ],
                  ),
          ),
        ],
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

class _SourceHomeMorePageState extends State<SourceHomeMorePage> {
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
      final result = await widget.source.list(
        categoryId: widget.moreUrl,
        page: page,
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
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 600) _loadMore();
          return false;
        },
        child: GridView.builder(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.fromLTRB(16, 8, 16, 16)),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
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
              item: item,
              pipeline: widget.pipeline,
              onTap: () => widget.onOpenItem(item),
            );
          },
        ),
      ),
    );
  }
}
