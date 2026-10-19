import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import '../video/tmdb_artwork.dart';
import '../../shared/widgets/missing_cover.dart';

import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/cat/cat_service.dart';
import '../../core/theme/lume_theme.dart';
import '../video/source_playback.dart';

import 'package:flutter/material.dart';

import '../../core/cat/cat_data_source.dart';
import '../../core/source/source.dart';
import '../../core/reading/reading.dart';
import '../../core/reading/comic_image_tools.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../video/video_player_settings.dart';
import '../../shared/widgets/glass_card.dart';
import '../video/video_player_page.dart';
import '../video/player_choice.dart';
import '../video/video_play_target.dart';
import '../reading/section_image.dart';

class CatDetailPage extends StatefulWidget {
  const CatDetailPage({
    super.key,
    required this.source,
    required this.item,
    required this.library,
  });
  final CatDataSource source;
  final SourceItem item;
  final ReadingLibrary library;
  @override
  State<CatDetailPage> createState() => _CatDetailPageState();
}

class _CatDetailPageState extends State<CatDetailPage> {
  late final pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    maxConcurrent: SectionImagePipeline.coverConcurrency,
    decodeTransform: (bytes) => automaticUpscale(bytes, UpscaleSurface.cover),
  );
  late final tmdb = TmdbDetailController(widget.item.title);
  SourceDetail? detail;
  List<SourceChapter> chapters = [];
  String? error;
  bool loading = true, playing = false, descriptionExpanded = false;
  Map<String, dynamic> raw = {};
  Map<String, List<SourceChapter>> lines = {};
  String line = '';
  String? lastChapterId;
  String? selectedChapterId;
  List<SourceChapter> get episodes => lines[line] ?? [];
  String get cover => detail?.cover?.trim().isNotEmpty == true
      ? detail!.cover!
      : widget.item.cover ?? '';
  Map<String, String> get coverHeaders =>
      detail?.coverHeaders ?? widget.item.coverHeaders;
  String get title => detail?.title ?? widget.item.title;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    tmdb.dispose();
    pipeline.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final metadata = await widget.source.rawDetail(widget.item.id);
      final data = await widget.source.detail(widget.item.id);
      final episodes = await widget.source.chapters(widget.item.id);
      if (mounted) {
        setState(() {
          detail = data;
          chapters = episodes;
          raw = metadata;
          lines = CatDataSource.episodeLines(episodes);
          final progress = widget.library.videoProgress(widget.item.id);
          lastChapterId = progress?.chapterId;
          selectedChapterId = lastChapterId;
          final resumed = episodes
              .where((chapter) => chapter.id == lastChapterId)
              .firstOrNull;
          line = resumed == null
              ? lines.keys.firstOrNull ?? ''
              : CatDataSource.flagOf(resumed);
          loading = false;
        });
        // 猫源列表标题经常带站点前缀/别名；详情标题才是视频模块里能命中的
        // 那个干净标题。首次列表标题没匹配到 TMDB 时，用详情标题/原始标题
        // 再回退匹配一次；已经命中则不重复请求。
        if (tmdb.metadata == null) {
          final detailTitle = data?.title ?? '';
          final rawTitle = catText(
            metadata['vod_name'] ??
                metadata['book_name'] ??
                metadata['comic_name'] ??
                metadata['name'] ??
                metadata['title'] ??
                '',
          );
          final alias = catText(metadata['vod_en'] ?? metadata['vod_alias']);
          tmdb.updateTitles(<String>[
            if (detailTitle.trim().isNotEmpty) detailTitle,
            if (rawTitle.trim().isNotEmpty) rawTitle,
            if (alias.trim().isNotEmpty) alias,
            widget.item.title,
          ]);
        }
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  Future<void> play(int index) async {
    if (playing) return;
    setState(() => playing = true);
    PlayerPrelaunch? prelaunch;
    var openedPlayer = false;
    try {
      if (PlayerFactory.isSupported) {
        final preferred = VideoPlayerSettingsStore(widget.library)
            .load()
            .kernel;
        final kernel = PlayerFactory.isAvailable(preferred)
            ? preferred
            : PlayerKernel.avplayer;
        prelaunch = PlayerPrelaunch.start(
          kernel,
          after: WidgetsBinding.instance.endOfFrame,
        );
      }
      final chapter = chapters[index];
      final playbackLine = CatDataSource.flagOf(chapter);
      final lineEpisodes = lines[playbackLine] ?? [chapter];
      final content = await widget.source.content(
        itemId: widget.item.id,
        chapterId: chapter.id,
      );
      if (content is! VideoContent) throw StateError('站点未返回视频地址');
      if (!mounted) return;
      widget.source.service.playInfo = {
        'name': widget.item.title,
        'title': widget.item.title,
        'episode': chapter.title,
        'epName': chapter.title,
        'url': SourcePlayback.contentAddress(content)!.toString(),
      };
      final transferred = prelaunch;
      openedPlayer = true;
      final opening = Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerChoiceRoute(
            original: VideoPlayerPage(
              prelaunch: transferred,
              media: PlayerMedia(
                uri: SourcePlayback.contentAddress(content)!,
                headers: SourcePlayback.contentHeaders(
                  content,
                  source: widget.source,
                ),
                title: '${widget.item.title} · ${chapter.title}',
              ),
              library: widget.library,
              sourceManager: CatSourceManager(
                widget.source.service,
                widget.source.site,
                chapterFlag: playbackLine,
              ),
              sourceId: widget.source.id,
              qualities: SourcePlayback.contentQualities(
                content,
                source: widget.source,
              ),
              target: VideoPlayTarget(
                sourceId: widget.source.id,
                itemId: widget.item.id,
                title: widget.item.title,
                cover: widget.item.cover,
                chapterIndex: lineEpisodes.indexWhere(
                  (entry) => entry.id == chapter.id,
                ),
                chapterId: chapter.id,
                chapterTitle: chapter.title,
              ),
            ),
          ),
        ),
      );
      prelaunch = null;
      await opening;
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$failure')));
      }
    } finally {
      if (prelaunch != null) unawaited(prelaunch.discard());
      if (mounted) {
        // 播放器返回：进度已落库，主动通知历史抽屉重新取数。
        widget.library.refresh();
        setState(() {
          playing = false;
          lastChapterId =
              widget.library.videoProgress(widget.item.id)?.chapterId ??
              lastChapterId;
          if (openedPlayer && lastChapterId != null) {
            selectedChapterId = lastChapterId;
          }
        });
      }
    }
  }

  Future<void> toggleFavorite() async {
    await widget.source.service.toggleFavorite(widget.source.site, {
      'id': widget.item.id,
      'title': title,
      'cover': cover,
      'headers': coverHeaders,
    });
    if (mounted) setState(() {});
  }

  void playEpisode(SourceChapter chapter) {
    if (playing) return;
    final index = chapters.indexWhere((entry) => entry.id == chapter.id);
    if (index >= 0) {
      setState(() {
        selectedChapterId = chapter.id;
        line = CatDataSource.flagOf(chapter);
      });
      unawaited(play(index));
    }
  }

  Future<void> pickEpisode() async {
    final selected = await showLumeBottomSheet<SourceChapter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: LumeTheme.surface,
      builder: (context) => CatEpisodePicker(
        lines: lines,
        initialLine: line,
        currentId: selectedChapterId ?? lastChapterId,
      ),
    );
    if (selected != null && mounted) {
      setState(() => line = CatDataSource.flagOf(selected));
      playEpisode(selected);
    }
  }

  Widget image({int? width, BorderRadius? radius}) => TmdbPosterGallery(
    controller: tmdb,
    fallback: SectionImage(
      pipeline: pipeline,
      placeholder: MissingCover(
        title: widget.item.title,
        section: pipeline.section,
      ),
      url: cover,
      headers: coverHeaders,
      targetWidth: width,
      borderRadius: radius,
    ),
  );

  List<String> get metadata => [
    for (final value in [
      raw['vod_year'],
      raw['vod_area'],
      raw['type_name'] ?? raw['vod_class'],
      raw['vod_duration'],
    ])
      if (catText(value).trim().isNotEmpty && catText(value) != '0')
        catText(value).trim(),
  ];

  Widget hero() {
    final height = (MediaQuery.sizeOf(context).width * 1.15 + 80).clamp(
      340.0,
      500.0,
    );
    final score = double.tryParse(catText(raw['vod_score'] ?? raw['score']));
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image(
            width:
                (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(320, 1280),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, .45, .75, 1],
                colors: [
                  Colors.black.withValues(alpha: .15),
                  Colors.transparent,
                  LumeTheme.base.withValues(alpha: .85),
                  LumeTheme.base,
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: LumeTypography.displayMediumSize,
                    fontWeight: FontWeight.w700,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.source.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.bodySize,
                    color: LumeTheme.muted,
                  ),
                ),
                if (metadata.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      metadata.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                        fontSize: LumeTypography.bodySize,
                      ),
                    ),
                  ),
                if (detail?.subtitle?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      detail!.subtitle!,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: LumeTypography.bodySize,
                        color: LumeTheme.muted,
                      ),
                    ),
                  ),
                if (score != null && score > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '★ ${score.toStringAsFixed(1)}',
                      style: TextStyle(
                        color: LumeTheme.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget episodePreview() {
    final current = episodes;
    if (current.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('站点未返回剧集。网盘站点可到猫源配置中心登录后重试。'),
      );
    }
    final short = current.every(
      (chapter) => CatDataSource.labelOf(chapter).length <= 14,
    );
    final preview = current.take(short ? 12 : 4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: line,
                  isExpanded: true,
                  dropdownColor: LumeTheme.surface,
                  items: [
                    for (final flag in lines.keys)
                      DropdownMenuItem(
                        value: flag,
                        child: Text(
                          flag.isEmpty ? '默认线路' : flag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: LumeTypography.titleSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                  onChanged: playing
                      ? null
                      : (value) {
                          if (value != null) setState(() => line = value);
                        },
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: playing ? null : pickEpisode,
              icon: const LumeIcon(
                Icons.playlist_play,
                slot: 'cat_detail_page.1',
              ),
              label: Text('全部 ${current.length} 集'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (short)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: MediaQuery.sizeOf(context).width < 360 ? 3 : 4,
            mainAxisExtent: 44,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final chapter in preview)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor:
                        chapter.id == (selectedChapterId ?? lastChapterId)
                        ? LumeTheme.accent.withValues(alpha: .12)
                        : null,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                  ),
                  onPressed: playing ? null : () => playEpisode(chapter),
                  child: Text(
                    CatDataSource.labelOf(chapter),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          )
        else
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisExtent: 145,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final chapter in preview)
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: playing ? null : () => playEpisode(chapter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            image(
                              width: 320,
                              radius: BorderRadius.circular(14),
                            ),
                            Center(
                              child: LumeIcon(
                                Icons.play_circle_fill,
                                slot: 'cat_detail_page.2',
                                color: Colors.white.withValues(alpha: .9),
                                size: 32,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        CatDataSource.labelOf(chapter),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: LumeTypography.descriptionSize,
                          fontWeight: chapter.id == lastChapterId
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: chapter.id == lastChapterId
                              ? LumeTheme.accent
                              : LumeTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget description() {
    final text = tmdb.metadata?.overview.trim().isNotEmpty == true
        ? tmdb.metadata!.overview
        : (detail?.description?.trim() ?? '');
    if (text.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text(
          '简介',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: LumeTypography.sectionTitleSize,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          text,
          maxLines: descriptionExpanded ? null : 3,
          overflow: descriptionExpanded
              ? TextOverflow.visible
              : TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            height: 1.6,
            color: LumeTheme.textPrimary,
          ),
        ),
        if (text.length > 90)
          TextButton(
            onPressed: () =>
                setState(() => descriptionExpanded = !descriptionExpanded),
            child: Text(descriptionExpanded ? '收起简介' : '展开简介'),
          ),
      ],
    );
  }

  Widget cast() {
    final text = catText(raw['vod_actor']).trim();
    if (text.isEmpty || ['内详', '未知', '暂无'].contains(text)) {
      return const SizedBox.shrink();
    }
    final names = text
        .split(RegExp(r'[,，/、]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        const Text(
          '演职人员',
          style: TextStyle(
            fontSize: LumeTypography.sectionTitleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final name in names) Chip(label: Text(name))],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final resumed = episodes
        .where((chapter) => chapter.id == lastChapterId)
        .firstOrNull;
    final selected = episodes
        .where((chapter) => chapter.id == selectedChapterId)
        .firstOrNull;
    final start = selected ?? resumed ?? episodes.firstOrNull;
    final favorited = widget.source.service.favorites.contains(
      '${widget.source.id}|${widget.item.id}',
    );
    return ListenableBuilder(
      listenable: tmdb,
      builder: (context, _) => Scaffold(
        backgroundColor: LumeTheme.base,
        body: Stack(
          children: [
            Positioned.fill(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!),
                            TextButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        hero(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                ),
                                onPressed: playing || start == null
                                    ? null
                                    : () => play(
                                        chapters.indexWhere(
                                          (entry) => entry.id == start.id,
                                        ),
                                      ),
                                icon: playing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const LumeIcon(
                                        Icons.play_arrow,
                                        slot: 'cat_detail_page.3',
                                      ),
                                label: Text(
                                  playing
                                      ? '正在获取播放地址'
                                      : start == null
                                      ? '播放'
                                      : start.id == lastChapterId
                                      ? '继续播放 · ${CatDataSource.labelOf(start)}'
                                      : '播放 · ${CatDataSource.labelOf(start)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(height: 16),
                              episodePreview(),
                            ],
                          ),
                        ),
                        TmdbInformation(controller: tmdb),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [description(), cast()],
                          ),
                        ),
                      ],
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      GlassPanel(
                        radius: 24,
                        padding: EdgeInsets.zero,
                        child: IconButton(
                          tooltip: '返回',
                          onPressed: () => Navigator.maybePop(context),
                          icon: const LumeIcon(
                            Icons.arrow_back,
                            slot: 'cat_detail_page.4',
                          ),
                        ),
                      ),
                      const Spacer(),
                      GlassPanel(
                        radius: 24,
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '收藏',
                              onPressed: toggleFavorite,
                              icon: LumeIcon(
                                favorited
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                slot: 'cat_detail_page.5',
                                variant: true,
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: '更多',
                              icon: const LumeIcon(
                                Icons.more_horiz,
                                slot: 'cat_detail_page.6',
                              ),
                              onSelected: (value) {
                                if (value == 'tmdb') {
                                  tmdb.rematch();
                                } else if (value == 'reload') {
                                  load();
                                } else {
                                  Clipboard.setData(ClipboardData(text: title));
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'tmdb',
                                  enabled:
                                      tmdb.settings.configured && !tmdb.loading,
                                  child: const Text('重新匹配TMDB'),
                                ),
                                const PopupMenuItem(
                                  value: 'reload',
                                  child: Text('刷新详情'),
                                ),
                                const PopupMenuItem(
                                  value: 'copy',
                                  child: Text('复制影片名称'),
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
            ),
          ],
        ),
      ),
    );
  }
}

/// Full episode list is scoped to one line; original chapter identities survive sorting.
class CatEpisodePicker extends StatefulWidget {
  const CatEpisodePicker({
    super.key,
    required this.lines,
    required this.initialLine,
    this.currentId,
  });
  final Map<String, List<SourceChapter>> lines;
  final String initialLine;
  final String? currentId;
  @override
  State<CatEpisodePicker> createState() => _CatEpisodePickerState();
}

class _CatEpisodePickerState extends State<CatEpisodePicker> {
  late String line = widget.initialLine;
  bool reversed = false;
  String query = '';
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  List<SourceChapter> get items {
    final list = (widget.lines[line] ?? [])
        .where(
          (chapter) =>
              CatDataSource.labelOf(chapter)
                  .toLowerCase()
                  .contains(query.toLowerCase()),
        )
        .toList();
    return reversed ? list.reversed.toList() : list;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      height: DrawerGeometry.height(context),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '选集',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.pageTitleSize,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: line,
                      isExpanded: true,
                      dropdownColor: LumeTheme.surface,
                      items: [
                        for (final flag in widget.lines.keys)
                          DropdownMenuItem(
                            value: flag,
                            child: Text(
                              flag.isEmpty ? '默认线路' : flag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => line = value);
                      },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '倒序',
                  icon: LumeIcon(
                    reversed ? Icons.arrow_upward : Icons.arrow_downward,
                    slot: 'cat_detail_page.7',
                    variant: true,
                  ),
                  onPressed: () => setState(() => reversed = !reversed),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const LumeIcon(Icons.close, slot: 'cat_detail_page.8'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索集数或文件名 · ${items.length} 集',
                prefixIcon: const LumeIcon(
                  Icons.search,
                  slot: 'cat_detail_page.9',
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final chapter = items[index];
                return ListTile(
                  selected: chapter.id == widget.currentId,
                  selectedTileColor: LumeTheme.accent.withValues(alpha: .1),
                  leading: Text('${index + 1}'),
                  title: Text(
                    CatDataSource.labelOf(chapter),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.titleSize,
                    ),
                  ),
                  trailing: const LumeIcon(
                    Icons.play_circle_outline,
                    slot: 'cat_detail_page.10',
                  ),
                  onTap: () => Navigator.pop(context, chapter),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
