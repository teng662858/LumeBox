import '../../core/theme/lume_theme.dart';
import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../reading/search_results_page.dart';
import '../reading/explore_view.dart';
import '../reading/section_toolbar.dart';
import '../media/media_resource_router.dart';
import 'tmdb_artwork.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';

import 'package:flutter/services.dart';

import '../reading/poster_card.dart';
import 'source_playback.dart';
import 'video_play_target.dart';

typedef OpenVideoPlayer = Future<void> Function(
  PlayerMedia media,
  VideoPlayTarget target,
  List<VideoQuality> qualities,
  PlayerPrelaunch? prelaunch,
);

/// Episode selection opens playback; the play button remains a second entry.
class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    this.source,
    this.loadSource,
    this.sourceId,
    required this.item,
    required this.library,
    required this.onPlay,
    this.prelaunch,
  });
  final DataSource? source;
  final Future<DataSource?> Function()? loadSource;
  final String? sourceId;
  final SourceItem item;
  final ReadingLibrary library;
  final OpenVideoPlayer onPlay;
  final PlayerPrelaunch? Function()? prelaunch;
  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage> {
  late final tmdb = TmdbDetailController(widget.item.title);
  DataSource? _source;
  SourceDetail? detail;
  String? get sourceCover => detail?.cover?.trim().isNotEmpty == true
      ? detail!.cover
      : widget.item.cover;
  List<SourceChapter> chapters = [];
  int selected = 0;
  bool loading = true, resolving = false;
  String? error;
  late final pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
  );
  @override
  void initState() {
    super.initState();
    unawaited(load());
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
      final source = widget.source ?? await widget.loadSource?.call();
      if (source == null) throw StateError('源不可用（未启用或脚本加载失败）');
      _source = source;
      final direct = SourcePlayback.itemAddress(widget.item.id);
      SourceDetail? metadata;
      try {
        metadata = await source.detail(widget.item.id);
      } catch (_) {
        // Some video sources only implement episodes/content. Metadata is optional.
      }
      detail = metadata;
      unawaited(updatePalette());
      final episodes = direct == null
          ? await source.chapters(widget.item.id)
          : [SourceChapter(id: widget.item.id, title: '正片')];
      if (!mounted) return;
      final saved = widget.library.videoProgress(widget.item.id);
      var index = episodes.indexWhere((e) => e.id == saved?.chapterId);
      if (index < 0) index = 0;
      setState(() {
        detail = metadata;
        chapters = episodes;
        selected = index;
        loading = false;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('加载失败：$failure')));
          }
        });
      }
    }
  }

  Future<void> play() async {
    if (resolving || chapters.isEmpty) return;
    setState(() => resolving = true);
    PlayerPrelaunch? prepared;
    try {
      final chapter = chapters[selected];
      final direct = SourcePlayback.itemAddress(widget.item.id);
      final content = direct == null
          ? await _source!.content(
              itemId: widget.item.id,
              chapterId: chapter.id,
            )
          : null;
      await MediaLibrary.instance.boot();
      final saved = MediaLibrary.instance.byId(
        MediaResource.sourceKey(_source!.section, _source!.id, widget.item.id),
      );
      if (saved?.manual == true && saved!.kind == ResourceKind.novel ||
          saved?.manual != true &&
              content is TextContent &&
              MediaResourceService.address(content) == null) {
        final entry = saved?.manual == true
            ? saved!
            : await MediaResourceService().source(
                source: _source!,
                item: widget.item,
                chapters: chapters,
                firstContent: content,
                hint: ResourceKind.novel,
              );
        if (mounted) await openMediaResource(context, entry, index: selected);
        return;
      }
      final address =
          direct ??
          SourcePlayback.contentAddress(content) ??
          MediaResourceService.address(content);
      if (address == null) throw StateError('源未返回有效的播放地址');
      final tracks = saved?.manual == true
          ? const MediaTrackInfo()
          : await const MediaTrackProbe().inspect(
              address,
              headers: SourcePlayback.contentHeaders(content, source: _source!),
            );
      if ((saved?.manual == true && saved!.kind != ResourceKind.video) ||
          (saved?.manual != true &&
              (tracks.kind == ResourceKind.audioBook ||
                  !tracks.known &&
                      (content is VideoContent && content.audioOnly ||
                          RegExp(
                            r'\.(mp3|m4a|aac|flac|ogg|opus|wav)$',
                            caseSensitive: false,
                          ).hasMatch(address.path))))) {
        final entry = saved?.manual == true
            ? saved!
            : await MediaResourceService().source(
                source: _source!,
                item: widget.item,
                chapters: chapters,
                firstContent:
                    content ?? VideoContent(url: address, audioOnly: true),
                hint: ResourceKind.audioBook,
              );
        if (!mounted) return;
        await openMediaResource(context, entry, index: selected);
        return;
      }
      if (!mounted) return;
      prepared = widget.prelaunch?.call();
      final transferred = prepared;
      prepared = null;
      await widget.onPlay(
        PlayerMedia(
          uri: address,
          title: '${widget.item.title} · ${chapter.title}',
          headers: direct == null
              ? SourcePlayback.contentHeaders(content, source: _source!)
              : null,
        ),
        VideoPlayTarget(
          sourceId: _source!.id,
          itemId: widget.item.id,
          title: widget.item.title,
          cover: widget.item.cover,
          chapterIndex: selected,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
        SourcePlayback.contentQualities(content, source: _source!),
        transferred,
      );
      if (mounted) {
        final last = widget.library.videoProgress(widget.item.id);
        final index = chapters.indexWhere(
          (entry) => entry.id == last?.chapterId,
        );
        if (index >= 0) setState(() => selected = index);
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('解析失败：$failure')));
      }
    } finally {
      if (prepared != null) unawaited(prepared.discard());
      if (mounted) setState(() => resolving = false);
    }
  }

  void favorite() {
    if (widget.library.onShelf(widget.item.id)) {
      widget.library.removeFavorite(widget.item.id);
    } else {
      widget.library.shelve(
        sourceId: _source!.id,
        itemId: widget.item.id,
        title: detail?.title ?? widget.item.title,
        cover: sourceCover,
      );
    }
    setState(() {});
  }

  Color _pageColor = const Color(0xff805b7a);
  Future<void> updatePalette() async {
    final cover = sourceCover;
    if (cover == null || cover.isEmpty) return;
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(
          cover,
          headers: detail?.coverHeaders ?? widget.item.coverHeaders,
        ),
      );
      if (mounted) {
        setState(
          () => _pageColor = Color.lerp(
            scheme.primary,
            const Color(0xffa87996),
            .45,
          )!,
        );
      }
    } catch (_) {
      /* Keep the soft poster fallback for unavailable images. */
    }
  }

  Future<void> searchCurrentVideo() async {
    final source = _source;
    if (source == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: widget.library.section,
          keyword: detail?.title ?? widget.item.title,
          mode: SearchMode.aggregate,
          onOpenItem: (ExploreSelection selection) async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VideoDetailPage(
                  sourceId: selection.sourceId,
                  loadSource: () =>
                      LumeSources.manager(widget.library.section)
                          .open(selection.sourceId),
                  item: selection.item,
                  library: widget.library,
                  onPlay: widget.onPlay,
                  prelaunch: widget.prelaunch,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) {
      final dark = ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: _pageColor,
        textTheme: LumeTheme.readableTextTheme(
          Brightness.dark,
        ).apply(fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffb5b9df),
          brightness: Brightness.dark,
          surface: _pageColor,
        ),
      );
      return Theme(
        data: dark,
        child: Scaffold(
          backgroundColor: _pageColor,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            flexibleSpace: const SizedBox.expand(),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            systemOverlayStyle: SystemUiOverlayStyle.light,
            actions: [
              IconButton(
                tooltip: '搜索当前视频',
                icon: const Icon(Icons.search),
                onPressed: _source == null ? null : searchCurrentVideo,
              ),
              IconButton(
                tooltip: widget.library.onShelf(widget.item.id) ? '已收藏' : '收藏',
                onPressed: _source == null ? null : favorite,
                icon: Icon(
                  widget.library.onShelf(widget.item.id)
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
              ),
              TmdbRematchMenu(controller: tmdb),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final artworkHeight = (constraints.maxWidth * 1.48).clamp(
                460.0,
                760.0,
              );
              return SingleChildScrollView(
                key: const Key('video-detail-scroll'),
                child: Stack(
                  key: const Key('video-detail-immersive'),
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: artworkHeight,
                      child: IgnorePointer(
                        child: TmdbPosterGallery(
                          controller: tmdb,
                          fit: BoxFit.cover,
                          fallback: PosterCover(
                            pipeline: pipeline,
                            url: sourceCover,
                            title: widget.item.title,
                            headers:
                                detail?.coverHeaders ??
                                widget.item.coverHeaders,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: artworkHeight + 2,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const Key('video-detail-gradient'),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0, .32, .55, .76, .92, 1],
                              colors: [
                                Color(0x55151820),
                                Color(0x00151820),
                                Color(0x33151820),
                                _pageColor.withValues(alpha: .65),
                                _pageColor.withValues(alpha: .95),
                                _pageColor,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        artworkHeight * .61,
                        16,
                        24 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            detail?.title ?? widget.item.title,
                            textAlign: TextAlign.center,
                            style: dark.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: const [
                                Shadow(color: Colors.black54, blurRadius: 12),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            detail?.subtitle ?? widget.item.subtitle ?? '',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const Key('video-detail-play'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              backgroundColor: Colors.white.withValues(
                                alpha: .35,
                              ),
                              foregroundColor: Colors.white,
                              shape: const StadiumBorder(),
                              elevation: 4,
                            ),
                            onPressed: loading || resolving || chapters.isEmpty
                                ? null
                                : play,
                            icon: resolving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow),
                            label: Text(
                              resolving
                                  ? '正在解析'
                                  : widget.library.videoProgress(
                                          widget.item.id,
                                        ) ==
                                        null
                                  ? '播放'
                                  : '继续播放 · ${chapters.isEmpty ? '' : chapters[selected].title}',
                            ),
                          ),
                          if (loading)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          const SizedBox(height: 24),
                          Text(
                            tmdb.metadata?.overview.trim().isNotEmpty == true
                                ? tmdb.metadata!.overview
                                : (detail?.description?.trim().isNotEmpty ==
                                          true
                                      ? detail!.description!
                                      : '暂无简介'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              height: 1.65,
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            Text(error!),
                            TextButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                          const SizedBox(height: 24),
                          Text(
                            '选集（${chapters.length}）',
                            style: dark.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 126,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: chapters.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 10),
                              itemBuilder: (context, index) => SizedBox(
                                width: 152,
                                child: InkWell(
                                  key: ValueKey('video-detail-episode-$index'),
                                  onTap: resolving
                                      ? null
                                      : () {
                                          setState(() => selected = index);
                                          play();
                                        },
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: SizedBox(
                                          height: 90,
                                          width: 152,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              PosterCover(
                                                pipeline: pipeline,
                                                url: sourceCover,
                                                title: widget.item.title,
                                                headers:
                                                    detail?.coverHeaders ??
                                                    widget.item.coverHeaders,
                                              ),
                                              if (index == selected)
                                                const Center(
                                                  child: Icon(
                                                    Icons.play_circle_fill,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        chapters[index].title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (tmdb.metadata != null) ...[
                            const SizedBox(height: 24),
                            if (tmdb.metadata!.rating > 0)
                              Text(
                                'TMDB 评分 ${tmdb.metadata!.rating.toStringAsFixed(1)} / 10',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            if (tmdb.metadata!.cast.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              Text('演员', style: dark.textTheme.titleMedium),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (
                                    var i = 0;
                                    i < tmdb.metadata!.cast.length;
                                    i++
                                  )
                                    SizedBox(
                                      width: 66,
                                      child: Column(
                                        children: [
                                          CircleAvatar(
                                            radius: 27,
                                            backgroundColor: Colors.white24,
                                            foregroundImage:
                                                i <
                                                        tmdb
                                                            .metadata!
                                                            .profiles
                                                            .length &&
                                                    tmdb
                                                        .metadata!
                                                        .profiles[i]
                                                        .isNotEmpty
                                                ? NetworkImage(
                                                    tmdb.metadata!.profiles[i],
                                                  )
                                                : null,
                                            child: const Icon(
                                              Icons.person,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            tmdb.metadata!.cast[i],
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize:
                                                  LumeTypography.captionSize,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                          if (tmdb.status != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              tmdb.status!,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
