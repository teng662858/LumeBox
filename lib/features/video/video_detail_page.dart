import 'playback_entry_preparation.dart';
import '../../core/source/source_content_type.dart';
import '../reading/content_detail_router.dart';
import '../download/download_selection.dart';
import '../comic/download_center_page.dart';
import 'video_download_center.dart';

import 'dart:convert';
import 'dart:math' as math;

import '../../core/player/playback_diagnostics.dart';

import 'video_resume_match.dart';
import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/native_glass_surfaces.dart';
import 'video_source_metadata.dart';
import 'playback_failure_panel.dart';
import '../../core/tmdb/tmdb.dart';
import 'detail_poster_background.dart';
import 'detail_artwork_motion.dart';
import 'video_episode_catalog.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/cover_palette.dart';
import '../../shared/widgets/lume_icon.dart';
import '../settings/tmdb_settings_page.dart';

import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

import '../../shared/widgets/poster_gradient_scaffold.dart';
import '../../shared/widgets/source_translation.dart';
import '../../shared/widgets/network_owned_state.dart';
import '../../core/net/network_cancellation.dart';

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
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/reading/comic_image_tools.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';

import 'package:flutter/services.dart';

import '../reading/poster_card.dart';
import 'bangumi_match_sheet.dart';
import 'source_playback.dart';
import 'source_web_player_page.dart';
import 'video_play_target.dart';
import '../../core/cat/cat_web_parse.dart';
import '../cat/cat_web_parse_page.dart';

// Increase weight without changing font sizes or accessibility scaling.
TextTheme _bolderTextTheme(TextTheme base) => base.copyWith(
  displayLarge: base.displayLarge?.apply(fontWeightDelta: 1),
  displayMedium: base.displayMedium?.apply(fontWeightDelta: 1),
  displaySmall: base.displaySmall?.apply(fontWeightDelta: 1),
  headlineLarge: base.headlineLarge?.apply(fontWeightDelta: 1),
  headlineMedium: base.headlineMedium?.apply(fontWeightDelta: 1),
  headlineSmall: base.headlineSmall?.apply(fontWeightDelta: 1),
  titleLarge: base.titleLarge?.apply(fontWeightDelta: 1),
  titleMedium: base.titleMedium?.apply(fontWeightDelta: 1),
  titleSmall: base.titleSmall?.apply(fontWeightDelta: 1),
  bodyLarge: base.bodyLarge?.apply(fontWeightDelta: 1),
  bodyMedium: base.bodyMedium?.apply(fontWeightDelta: 1),
  bodySmall: base.bodySmall?.apply(fontWeightDelta: 1),
  labelLarge: base.labelLarge?.apply(fontWeightDelta: 1),
  labelMedium: base.labelMedium?.apply(fontWeightDelta: 1),
  labelSmall: base.labelSmall?.apply(fontWeightDelta: 1),
);

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
    this.detectContent = true,
    this.source,
    this.loadSource,
    this.sourceId,
    this.manager,
    this.recordHistory = true,
    this.imagePipeline,
    required this.item,
    required this.library,
    required this.onPlay,
    this.prelaunch,
    this.downloadCenter,
    this.initialChapterId,
    this.resumeRequest,
  });
  final String? initialChapterId;
  final VideoResumeRequest? resumeRequest;
  final bool detectContent;
  final DataSource? source;
  final Future<DataSource?> Function()? loadSource;
  final String? sourceId;
  final SourceManager? manager;
  final bool recordHistory;
  final SectionImagePipeline? imagePipeline;
  final SourceItem item;
  final ReadingLibrary library;
  final OpenVideoPlayer onPlay;
  final PlayerPrelaunch? Function()? prelaunch;
  final VideoDownloadCenter? downloadCenter;
  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage>
    with NetworkOwnedState<VideoDetailPage> {
  late final tmdb = TmdbDetailController(
    widget.item.title,
    autoLoad: false,
    cacheIdentity: (widget.source?.id ?? widget.sourceId) == null
        ? null
        : jsonEncode([
            widget.source?.id ?? widget.sourceId,
            widget.item.id,
            widget.item.title,
          ]),
  );
  bool _initialChapterApplied = false;
  DataSource? _source;
  DataSource? _updatedSource;
  Object? _playFailure;
  SourceDetail? detail;
  String? get sourceCover => detail?.cover?.trim().isNotEmpty == true
      ? detail!.cover
      : widget.item.cover;
  List<SourceChapter> chapters = [];
  int selected = 0;
  Map<String, List<SourceChapter>> lines = {};
  String currentLine = '';
  bool descriptionExpanded = false, reversed = false, collapsedHeader = false;
  int episodePage = 0, compactEpisodeStart = 0;
  static const styleSetting = 'video.detail.originalStyle';
  bool originalStyle = true, playbackFailed = false;
  VideoProgress? lineResume;
  final _episodesKey = GlobalKey();
  final _scroll = ScrollController();

  Widget? _typedDetail;
  bool loading = true, resolving = false;
  String? error;
  late final pipeline =
      widget.imagePipeline ??
      SectionImagePipeline(
        cacheDir: widget.library.imageCacheDir,
        decodeTransform: (bytes) =>
            automaticUpscale(bytes, UpscaleSurface.videoPoster),
      );
  // TMDB 图片按自己的代理地址获取，不继承源站 Cookie/代理配置。
  late final tmdbImagePipeline = SectionImagePipeline(
    cacheDir: '${widget.library.imageCacheDir}/tmdb',
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    cacheOriginalBytes: true,
    decodeTransform: (bytes) =>
        automaticUpscale(bytes, UpscaleSurface.videoPoster),
  );
  @override
  void initState() {
    super.initState();
    originalStyle = widget.library.setting(styleSetting) != 'false';
    _scroll.addListener(() {
      final position = _scroll.positions.lastOrNull;
      final collapsed = position?.hasPixels == true && position!.pixels > 170;
      if (collapsed != collapsedHeader && mounted) {
        setState(() => collapsedHeader = collapsed);
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    tmdb.dispose();
    tmdbImagePipeline.dispose();
    if (widget.imagePipeline == null) pipeline.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      await networkRequests.run('detail', loadOwned);
    } on NetworkCancelled {
      // Leaving the page or replacing this load is not a source failure.
    }
  }

  Future<void> loadOwned() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final source =
          _updatedSource ?? widget.source ?? await widget.loadSource?.call();
      if (source == null) throw StateError('源不可用（未启用或脚本加载失败）');
      _source = source;
      pipeline.bindSource(source);
      pipeline.bindSession(source.section, source.id);
      final direct = SourcePlayback.itemAddress(widget.item.id);
      SourceDetail? metadata;
      try {
        metadata = await source.detail(widget.item.id);
      } catch (_) {
        // Some video sources only implement episodes/content. Metadata is optional.
      }
      NetworkCancellation.current?.check();
      if (!mounted) return;
      final cover = metadata?.cover ?? widget.item.cover;
      if (cover != null) {
        pipeline.configureImageHeaders({
          cover: metadata?.coverHeaders ?? widget.item.coverHeaders,
        });
      }
      if (metadata?.backdrop != null) {
        pipeline.configureImageHeaders({
          metadata!.backdrop!: metadata.coverHeaders,
        });
      }
      setState(() => detail = metadata);
      final sourceYear = metadata?.year.isNotEmpty == true
          ? metadata!.year
          : TmdbClient.titleYear(
              metadata?.subtitle ?? widget.item.subtitle ?? '',
            );
      tmdb.updateTitles(
        [metadata?.title ?? widget.item.title, widget.item.title],
        year: sourceYear,
        mediaType: ['movie', 'tv'].contains(metadata?.mediaType)
            ? metadata!.mediaType
            : null,
      );
      unawaited(updatePalette());
      List<SourceChapter> episodes;
      if (direct != null) {
        episodes = [SourceChapter(id: widget.item.id, title: '正片')];
      } else {
        try {
          episodes = await source.chapters(widget.item.id);
        } catch (_) {
          if (metadata?.chapters.isNotEmpty != true) rethrow;
          episodes = metadata!.chapters;
        }
        if (episodes.isEmpty && metadata?.chapters.isNotEmpty == true) {
          episodes = metadata!.chapters;
        }
      }
      if (!mounted) return;
      if (widget.detectContent && direct == null) {
        final type = await detectSourceContent(
          source: source,
          itemId: widget.item.id,
          detail: metadata,
          chapters: episodes,
          hint: widget.item.mediaType,
        );
        if (!mounted) return;
        if (type != null && type != SourceContentType.video) {
          setState(() {
            loading = false;
            _typedDetail = contentDetailPage(
              type: type,
              source: source,
              library: widget.library,
              manager: widget.manager,
              target: ReadingTarget(
                sourceId: source.id,
                itemId: widget.item.id,
                title: metadata?.title ?? widget.item.title,
                cover: sourceCover,
                subtitle: metadata?.subtitle ?? widget.item.subtitle,
              ),
            );
          });
          return;
        }
      }
      // 查看详情只写历史（favorite = 0）；收藏只能由心形按钮触发。
      if (widget.recordHistory) {
        widget.library.recordHistoryItem(
          sourceId: source.id,
          itemId: widget.item.id,
          title: metadata?.title ?? widget.item.title,
          cover: sourceCover,
          subtitle: metadata?.subtitle ?? widget.item.subtitle,
          chapterCount: episodes.length,
        );
      }
      final saved = widget.library.videoProgress(
        widget.item.id,
        sourceId: _source?.id ?? widget.sourceId,
      );
      var initialChapter = _initialChapterApplied
          ? null
          : widget.initialChapterId;
      VideoProgress? transferredProgress;
      SourceChapter? transferredChapter;
      if (!_initialChapterApplied &&
          widget.resumeRequest != null &&
          episodes.isNotEmpty) {
        final request = widget.resumeRequest!;
        final matches = request.candidates(
          episodes,
          workTitle: metadata?.title ?? widget.item.title,
        );
        SourceChapter? chosen;
        if (matches.length == 1 &&
            request.confident(
              matches.single,
              workTitle: metadata?.title ?? widget.item.title,
            )) {
          chosen = matches.single;
        } else if (mounted) {
          chosen = await showGlassModalBottomSheet<SourceChapter>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text('确认续播剧集'),
                    subtitle: Text(
                      '原进度：${request.chapterTitle} · ${request.position.inMinutes} 分钟；请选择对应剧集',
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final chapter
                            in matches.isEmpty ? episodes : matches)
                          ListTile(
                            title: Text(chapter.title),
                            subtitle: Text(VideoEpisodeCatalog.lineOf(chapter)),
                            onTap: () => Navigator.pop(context, chapter),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (!mounted) return;
        if (chosen != null) {
          transferredChapter = chosen;
          initialChapter = chosen.id;
          transferredProgress = request.progress(
            source.id,
            widget.item.id,
            chosen,
            episodes.indexOf(chosen),
            widget.library.section,
          );
        }
      }
      _initialChapterApplied = true;
      final grouped = VideoEpisodeCatalog.group(episodes);
      final resumed =
          transferredChapter ??
          episodes
              .where((e) => e.id == (initialChapter ?? saved?.chapterId))
              .firstOrNull;
      final rememberedLine = widget.library.setting(
        'video.line.work.${jsonEncode([source.id, widget.item.id])}',
      );
      final line = resumed == null
          ? (grouped.containsKey(rememberedLine)
                ? rememberedLine!
                : grouped.keys.firstOrNull ?? '')
          : VideoEpisodeCatalog.lineOf(resumed);
      final activeEpisodes = grouped[line] ?? <SourceChapter>[];
      var index = activeEpisodes.indexWhere(
        (e) => e.id == (initialChapter ?? saved?.chapterId),
      );
      if (index < 0) index = 0;
      setState(() {
        lineResume = transferredProgress;
        detail = metadata;
        lines = grouped;
        currentLine = line;
        chapters = activeEpisodes;
        selected = index;
        episodePage = index ~/ 50;
        compactEpisodeStart = index ~/ 10 * 10;
        loading = false;
      });
    } catch (failure) {
      if (NetworkCancellation.current?.isCancelled ?? false) return;
      if (mounted) {
        // Source-detail failure must not leave metadata permanently unstarted.
        // If detail already arrived, keep its year/type hints from the first call.
        if (detail == null) tmdb.updateTitles([widget.item.title]);
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

  Future<void> downloadVideo() async {
    if (_source == null || chapters.isEmpty || resolving) return;
    final source = _source!;
    final episodes = List<SourceChapter>.of(chapters);
    final indices = await selectDownloadChapters(
      context,
      episodes,
      initial: selected,
    );
    if (indices == null || !mounted) return;
    await (widget.downloadCenter ?? VideoDownloadCenter.instance).enqueue(
      sourceId: source.id,
      itemId: widget.item.id,
      title: widget.item.title,
      chapters: [for (final i in indices) episodes[i]],
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已添加 ${indices.length} 集到下载中心')));
    }
  }

  Future<void> play() async {
    if (resolving || chapters.isEmpty) return;
    setState(() {
      resolving = true;
      playbackFailed = false;
      _playFailure = null;
    });
    PlayerPrelaunch? prepared;
    try {
      final chapter = chapters[selected];
      final direct = SourcePlayback.itemAddress(widget.item.id);
      ChapterContent? content;
      {
        try {
          final resolveWatch = Stopwatch()..start();
          content =
              await SourceContentRead.read(
                _source!,
                itemId: widget.item.id,
                chapterId: chapter.id,
              ).whenComplete(() {
                PlaybackDiagnostics.record(
                  'source-resolve-complete',
                  source: _source!.id,
                  elapsedMs: resolveWatch.elapsedMilliseconds,
                );
              });
        } on CatWebParseRequired catch (request) {
          if (!mounted) return;
          if (request.webPlayer) {
            await showSourceWebPlayer(context, request);
            return;
          }
          final parsed = await showCatWebParsePage(context, request);
          if (parsed == null || !mounted) return;
          content = VideoContent(
            url: parsed,
            headers: {...request.headers, 'Referer': request.page.toString()},
          );
        } catch (_) {
          if (direct == null) rethrow;
          content = VideoContent(url: direct);
        }
      }
      if (!mounted) return;
      await MediaLibrary.instance.boot();
      final saved = MediaLibrary.instance.byId(
        MediaResource.sourceKey(_source!.section, _source!.id, widget.item.id),
      );
      if (content is TextContent || content is ImageContent) {
        if (!mounted) return;
        setState(
          () => _typedDetail = contentDetailPage(
            type: content is TextContent
                ? SourceContentType.novel
                : SourceContentType.comic,
            source: _source!,
            library: widget.library,
            manager: widget.manager,
            target: ReadingTarget(
              sourceId: _source!.id,
              itemId: widget.item.id,
              title: detail?.title ?? widget.item.title,
              cover: sourceCover,
              subtitle: detail?.subtitle ?? widget.item.subtitle,
            ),
          ),
        );
        return;
      }
      final address =
          SourcePlayback.contentAddress(content) ??
          direct ??
          MediaResourceService.address(content);
      if (address == null) throw StateError('源未返回有效的播放地址');
      if (lineResume != null && widget.recordHistory) {
        final saved = lineResume!;
        widget.library.saveProgress(
          VideoProgress(
            sourceId: _source!.id,
            section: widget.library.section,
            itemId: widget.item.id,
            chapterIndex: selected,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            updatedAt: DateTime.now(),
            position: saved.position,
            duration: saved.duration,
          ),
        );
        lineResume = null;
      }
      // Source-declared audio and recognizable video URLs need no second
      // native asset load before navigation. Probe only ambiguous addresses.
      final audioHint =
          content is VideoContent && content.audioOnly ||
          RegExp(
            r'\.(mp3|m4a|aac|flac|ogg|opus|wav)$',
            caseSensitive: false,
          ).hasMatch(address.path);
      final videoAddress = RegExp(
        r'\.(m3u8|mpd|mp4|m4v|mkv|webm|mov|avi|flv|ts)$',
        caseSensitive: false,
      ).hasMatch(address.path);
      final tracks = saved?.manual == true || audioHint || videoAddress
          ? const MediaTrackInfo()
          : await const MediaTrackProbe().inspect(
              address,
              headers: SourcePlayback.contentHeaders(content, source: _source!),
            );
      if ((saved?.manual == true && saved!.kind != ResourceKind.video) ||
          (saved?.manual != true &&
              (tracks.kind == ResourceKind.audioBook ||
                  !tracks.known && audioHint))) {
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
        widget.library.refresh();
        return;
      }
      if (!mounted) return;
      final media = PlayerMedia(
        uri: address,
        title: '${widget.item.title} · ${VideoEpisodeCatalog.labelOf(chapter)}',
        headers: SourcePlayback.contentHeaders(content, source: _source!),
      );
      prepared = await preparePlaybackRoute(
        media,
        library: widget.library,
        prelaunch: widget.prelaunch?.call(),
        stillActive: () => mounted,
      );
      if (!mounted) return;
      final transferred = prepared;
      prepared = null;
      await widget.onPlay(
        media,
        VideoPlayTarget(
          sourceId: _source!.id,
          itemId: widget.item.id,
          title: widget.item.title,
          cover: widget.item.cover,
          chapterIndex: selected,
          chapterId: chapter.id,
          chapterTitle: VideoEpisodeCatalog.labelOf(chapter),
        ),
        SourcePlayback.contentQualities(content, source: _source!),
        transferred,
      );
      widget.library.refresh();
      if (mounted) {
        final last = widget.library.videoProgress(
          widget.item.id,
          sourceId: _source?.id ?? widget.sourceId,
        );
        if (last?.chapterId == chapter.id && last!.position > Duration.zero) {
          widget.library.setSetting(
            'video.line.work.${jsonEncode([_source!.id, widget.item.id])}',
            currentLine,
          );
        }
        for (final entry in lines.entries) {
          final index = entry.value.indexWhere(
            (chapter) => chapter.id == last?.chapterId,
          );
          if (index >= 0) {
            setState(() {
              currentLine = entry.key;
              chapters = entry.value;
              selected = index;
              episodePage = index ~/ 50;
              compactEpisodeStart =
                  (reversed ? chapters.length - 1 - index : index) ~/ 10 * 10;
            });
            break;
          }
        }
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          playbackFailed = true;
          _playFailure = failure;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('解析失败：$failure'),
            action: lines.length > 1
                ? SnackBarAction(
                    label: '换线路',
                    onPressed: switchLineAfterFailure,
                  )
                : null,
          ),
        );
      }
    } finally {
      if (prepared != null) unawaited(prepared.discard());
      if (mounted) setState(() => resolving = false);
    }
  }

  void favorite() {
    if (widget.library.onShelf(
      widget.item.id,
      sourceId: _source?.id ?? widget.sourceId,
    )) {
      widget.library.removeFavorite(
        widget.item.id,
        sourceId: _source?.id ?? widget.sourceId,
      );
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

  Widget playbackRecovery() => PlaybackFailurePanel(
    error: _playFailure!,
    retry: play,
    sourceId: _source?.id ?? widget.sourceId,
    manager: widget.manager,
    onUpdated: () async {
      final id = _source?.id ?? widget.sourceId;
      if (id == null) return;
      _updatedSource =
          await (widget.manager ?? LumeSources.manager(widget.library.section))
              .open(id);
      if (mounted) await load();
    },
  );

  Color? _coverColor;
  String? _displayedPoster;
  int _paletteRevision = 0;
  void _artworkDisplayed(String? url) {
    if (_displayedPoster == url) return;
    _displayedPoster = url;
    unawaited(updatePalette());
  }

  String get appearanceKey => jsonEncode([
    widget.library.section.id,
    _source?.id ?? widget.sourceId ?? '',
    widget.item.id,
  ]);
  TmdbDetailAppearance get appearance =>
      tmdb.settings.appearanceFor(appearanceKey);
  Widget tmdbSettings() => TmdbSettingsPage(
    appearanceKey: appearanceKey,
    previewColor: _coverColor,
    loadPreview: () {
      final url = _displayedPoster ?? sourceCover;
      return url == null
          ? Future<Uint8List?>.value()
          : (_displayedPoster == null ? pipeline : tmdbImagePipeline).fetch(
              url,
            );
    },
  );
  Color get _pageColor {
    final appearance = this.appearance;
    if (originalStyle) {
      return tmdb.settings.detailBackdropEnabled
          ? adjustDetailBackground(
              _coverColor ?? Colors.black,
              brightness: appearance.backgroundBrightness,
              saturation: appearance.backgroundSaturation,
            )
          : const Color(0xff11131a);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xff11131a) : const Color(0xffdcdfe6);
    if (_coverColor == null || !tmdb.settings.detailBackdropEnabled) {
      return base;
    }
    return adjustDetailBackground(
      compactPosterPageColor(
        _coverColor!,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      brightness: appearance.backgroundBrightness,
      saturation: appearance.backgroundSaturation,
    );
  }

  Future<ui.Image?> _displayedPosterSample(String url) async {
    // 与显示共用原始字节缓存，取色不再另下图片，也不触发第二次超分。
    return tmdbImagePipeline.colorSample(url);
  }

  Future<void> updatePalette() async {
    // Match the visible poster, rather than an unrelated landscape backdrop.
    final cover = _displayedPoster ?? sourceCover;
    if (cover == null || cover.isEmpty) return;
    final revision = ++_paletteRevision;
    try {
      final color = await PosterPaletteCache.resolve(
        ('video-detail-poster-lower-hue-v8', cover),
        () async {
          final sample = _displayedPoster == cover
              ? await _displayedPosterSample(cover)
              : await pipeline.colorSample(cover);
          if (sample == null) throw StateError('Poster unavailable');
          try {
            final pixels = await sample.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (pixels == null) return null;
            // Group related hues and weight the lower artwork, where it fades
            // into the page, instead of letting grey scenery erase clothing.
            final artwork = immersiveArtworkColor(
              pixels.buffer.asUint8List(
                pixels.offsetInBytes,
                pixels.lengthInBytes,
              ),
              width: sample.width,
              height: sample.height,
            );
            return artwork == null ? null : immersiveCoverSurface(artwork);
          } finally {
            sample.dispose();
          }
        },
      );
      if (revision != _paletteRevision) return;
      if (mounted) {
        setState(() => _coverColor = color);
      }
    } catch (_) {
      /* Keep the soft poster fallback for unavailable images. */
    }
  }

  Future<void> searchCurrentVideo([String? keyword]) async {
    final source = _source;
    if (source == null) return;
    final chapter = chapters.isEmpty ? null : chapters[selected];
    final progress = chapters.isEmpty ? null : episodeProgress(selected);
    final resume = chapter == null
        ? null
        : VideoResumeRequest(
            title: detail?.title ?? widget.item.title,
            chapterTitle: VideoEpisodeCatalog.labelOf(chapter),
            chapterIndex: selected,
            position: progress?.position ?? Duration.zero,
            duration: progress?.duration ?? Duration.zero,
          );
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: widget.library.section,
          keyword: keyword ?? detail?.title ?? widget.item.title,
          mode: SearchMode.aggregate,
          manager: widget.manager,
          pipeline: pipeline,
          onOpenItem: (ExploreSelection selection) async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VideoDetailPage(
                  resumeRequest: resume,
                  sourceId: selection.sourceId,
                  manager: widget.manager,
                  loadSource: () =>
                      (widget.manager ??
                              LumeSources.manager(widget.library.section))
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
  Widget build(BuildContext context) =>
      _typedDetail ??
      Theme(
        data: Theme.of(context)
            .copyWith(textTheme: _bolderTextTheme(Theme.of(context).textTheme)),
        child: Builder(
          builder: (context) =>
              originalStyle ? _buildOriginal(context) : _buildCompact(context),
        ),
      );

  void setDetailStyle(bool original) {
    widget.library.setSetting(styleSetting, '$original');
    setState(() => originalStyle = original);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget detailCornerActions() => VideoGlassSurface(
    radius: 28,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: detailActions(glass: true).skip(1).take(2).toList(),
    ),
  );

  Widget detailBackButton() => VideoGlassSurface(
    radius: 28,
    child: IconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(
        Icons.arrow_back_ios_new_rounded,
        size: 20,
        color: VideoGlassSurface.foreground,
      ),
    ),
  );

  List<Widget> detailActions({bool glass = false}) {
    final inherited = Theme.of(context);
    const menuBackground = Colors.transparent;
    const menuForeground = VideoGlassSurface.foreground;
    return [
      IconButton(
        key: const Key('video-detail-search'),
        tooltip: '保持集数换源',
        onPressed: _source == null ? null : () => searchCurrentVideo(),
        icon: const Icon(Icons.search),
      ),
      IconButton(
        key: const Key('video-detail-favorite'),
        tooltip:
            widget.library.onShelf(
              widget.item.id,
              sourceId: _source?.id ?? widget.sourceId,
            )
            ? '已收藏'
            : '收藏',
        onPressed: _source == null || !widget.recordHistory ? null : favorite,
        icon: Icon(
          widget.library.onShelf(
                widget.item.id,
                sourceId: _source?.id ?? widget.sourceId,
              )
              ? Icons.favorite
              : Icons.favorite_border,
        ),
      ),
      Theme(
        data: inherited.copyWith(
          dividerColor: menuForeground.withValues(alpha: .16),
          colorScheme: inherited.colorScheme.copyWith(
            onSurface: menuForeground,
            primary: menuForeground,
          ),
          iconTheme: IconThemeData(color: menuForeground),
          popupMenuTheme: PopupMenuThemeData(
            color: menuBackground,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            textStyle: TextStyle(
              color: menuForeground,
              fontWeight: FontWeight.w600,
            ),
            labelTextStyle: WidgetStatePropertyAll(
              TextStyle(color: menuForeground, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        child: PopupMenuButton<String>(
          key: const Key('video-detail-more'),
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
          menuPadding: EdgeInsets.zero,
          icon: Icon(
            Icons.more_horiz,
            color: glass
                ? VideoGlassSurface.foreground
                : originalStyle
                ? Colors.white
                : inherited.colorScheme.onSurface,
          ),
          tooltip: '更多',
          onSelected: (action) {
            switch (action) {
              case 'downloads':
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const DownloadCenterPage(),
                  ),
                );
              case 'search':
                searchCurrentVideo();
              case 'resource-info':
                showSourceResourceInfo();
              case 'image-info':
                showImageProcessingInfo(
                  context,
                  pipeline: _displayedPoster == null
                      ? pipeline
                      : tmdbImagePipeline,
                  url: _displayedPoster ?? sourceCover,
                  surface: UpscaleSurface.videoPoster,
                  origin: _displayedPoster == null ? '源站海报' : 'TMDB 海报',
                );
              case 'bangumi':
                openBangumi();
              case 'original':
                setDetailStyle(true);
              case 'compact':
                setDetailStyle(false);
              case 'tmdb':
                showTmdbMatchPicker(context, tmdb);
              case 'poster':
                showTmdbPosterPicker(context, tmdb);
              case 'settings':
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => tmdbSettings()));
            }
          },
          itemBuilder: (_) => videoGlassMenuEntries<String>([
            const PopupMenuItem(value: 'downloads', child: Text('下载中心')),
            if (conciseVideoSubtitle(
                  rawSourceSubtitle,
                  availableEpisodes: chapters.length,
                ) !=
                rawSourceSubtitle)
              const PopupMenuItem(
                value: 'resource-info',
                child: Text('网盘资源详情'),
              ),
            const PopupMenuItem(value: 'search', child: Text('保持集数换源')),
            const PopupMenuItem(
              value: 'image-info',
              child: Text('图片信息 / 超分状态'),
            ),
            const PopupMenuItem(value: 'bangumi', child: Text('Bangumi 追番')),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
              value: 'original',
              checked: originalStyle,
              child: const Text('大封面版（旧版）'),
            ),
            CheckedPopupMenuItem(
              value: 'compact',
              checked: !originalStyle,
              child: const Text('紧凑版（当前版）'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'tmdb',
              enabled: tmdb.settings.configured && !tmdb.loading,
              child: const Text('重新匹配TMDB'),
            ),
            const PopupMenuItem(value: 'settings', child: Text('TMDB 设置与测试')),
            PopupMenuItem(
              value: 'poster',
              enabled: tmdb.metadata?.posters.isNotEmpty == true,
              child: const Text('选择海报'),
            ),
            PopupMenuItem(
              enabled: false,
              child: Text(
                tmdbStatusLabel,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(width: 8),
    ];
  }

  String get rawSourceSubtitle =>
      (detail?.subtitle ?? widget.item.subtitle ?? '').trim();

  Future<void> showSourceResourceInfo() => showGlassDialog<void>(
    context: context,
    videoGlass: true,
    builder: (context) => AlertDialog(
      title: const Text('网盘资源详情'),
      content: SingleChildScrollView(child: SelectableText(rawSourceSubtitle)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  String get tmdbStatusLabel {
    if (!tmdb.settings.enabled) return 'TMDB 未开启';
    if (!tmdb.settings.configured) return 'TMDB 未填写 API Key 或 Token';
    if (tmdb.loading) return 'TMDB 正在匹配资料…';
    final data = tmdb.metadata;
    if (data != null) {
      return 'TMDB 已匹配 · 演员 ${data.cast.length}';
    }
    return tmdb.status ?? 'TMDB 尚未匹配到资料';
  }

  Widget metadataRow(String rawSubtitle, String title) {
    final subtitle = conciseVideoSubtitle(
      rawSubtitle,
      availableEpisodes: chapters.length,
    );
    return Row(
      key: const Key('video-detail-metadata-row'),
      children: [
        Expanded(
          child: Text(
            [
              if (subtitle.trim().isNotEmpty)
                subtitle
                    .split(' · ')
                    .where(
                      (part) =>
                          !originalStyle ||
                          !(tmdb.metadata?.genres.contains(part.trim()) ??
                              false),
                    )
                    .join(' · '),
              if ((tmdb.metadata?.episodeCount ?? 0) > 0 &&
                  !subtitle.contains('集'))
                '共 ${tmdb.metadata!.episodeCount} 集',
              if (tmdb.metadata?.year.isNotEmpty == true &&
                  !subtitle.contains(tmdb.metadata!.year))
                tmdb.metadata!.year,
              if (!originalStyle &&
                  tmdb.metadata?.genres.isNotEmpty == true &&
                  !tmdb.metadata!.genres.any(subtitle.contains))
                tmdb.metadata!.genres.join(' · '),
              if (!originalStyle && (tmdb.metadata?.rating ?? 0) > 0)
                '★ ${tmdb.metadata!.rating.toStringAsFixed(1)}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: originalStyle ? TextAlign.center : TextAlign.left,
            style: TextStyle(
              fontSize: originalStyle ? 14 : 13,
              fontWeight: originalStyle ? FontWeight.w600 : FontWeight.w500,
              height: 1.4,
              color: originalStyle
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (!originalStyle && tmdb.metadata != null)
          IconButton(
            key: const Key('video-detail-tmdb-status'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: const EdgeInsets.all(4),
            tooltip:
                'TMDB 已匹配${tmdb.metadata!.cast.isEmpty ? '' : ' · ${tmdb.metadata!.cast.length} 位演员'}',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => tmdbSettings())),
            icon: SvgPicture.asset(
              'assets/branding/tmdb.svg',
              width: 28 * appearance.logoScale,
              height: 20 * appearance.logoScale,
            ),
          ),
      ],
    );
  }

  Widget tmdbRating() {
    final data = tmdb.metadata;
    if (data == null) return const SizedBox.shrink();
    return Tooltip(
      message: tmdbStatusLabel,
      child: TextButton(
        key: const Key('video-detail-tmdb-status'),
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => tmdbSettings())),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/branding/tmdb.svg',
              width: 18 * appearance.logoScale,
              height: 13 * appearance.logoScale,
              semanticsLabel: 'TMDB',
            ),
            if (data.rating > 0) ...[
              const SizedBox(width: 5),
              Text(
                data.rating.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get synopsis => tmdb.metadata?.overview.trim().isNotEmpty == true
      ? tmdb.metadata!.overview
      : detail?.description?.trim().isNotEmpty == true
      ? detail!.description!
      : '暂无简介';

  Widget summaryBlock(String title, String text) => Row(
    key: const Key('video-detail-summary-row'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: InkWell(
          key: const Key('video-detail-summary'),
          onTap: () =>
              setState(() => descriptionExpanded = !descriptionExpanded),
          child: SourceText(
            text,
            maxLines: descriptionExpanded ? null : 2,
            overflow: descriptionExpanded ? null : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: originalStyle ? 15 : 14,
              fontWeight: originalStyle ? FontWeight.w600 : null,
              height: 1.6,
              color: originalStyle
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ],
  );

  Widget linePicker() => LayoutBuilder(
    builder: (context, bounds) {
      final controls = <Widget>[
        Expanded(
          child: PopupMenuButton<String>(
            key: const Key('video-detail-original-line-selector'),
            tooltip: '选择播放线路',
            enabled: !resolving && lines.isNotEmpty,
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
            color: Colors.transparent,
            menuPadding: EdgeInsets.zero,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            onSelected: (line) => changeLine(line),
            itemBuilder: (_) => videoGlassMenuEntries<String>([
              for (final entry in lines.entries)
                PopupMenuItem<String>(
                  value: entry.key,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: entry.key == currentLine
                            ? const Icon(
                                Icons.check,
                                color: Color(0xFF202126),
                                size: 20,
                              )
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          '${entry.key} · ${entry.value.length} 集',
                          style: const TextStyle(
                            color: Color(0xFF202126),
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ]),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      currentLine.isEmpty ? '选择线路' : currentLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.white,
                    size: 21,
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(36, 44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...translationDownloadActions(),
              IconButton(
                tooltip: reversed ? '恢复正序' : '倒序排列',
                onPressed: chapters.isEmpty
                    ? null
                    : () => setState(() => reversed = !reversed),
                icon: const Icon(Icons.swap_vert, size: 20),
              ),
              IconButton(
                tooltip: '定位当前集',
                onPressed: chapters.isEmpty ? null : locateEpisodes,
                icon: const Icon(Icons.my_location_outlined, size: 19),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          key: const Key('video-detail-select-episodes'),
          onPressed: chapters.isEmpty ? null : showEpisodes,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.swap_horiz_rounded, size: 23),
              if (bounds.maxWidth >= 340 &&
                  MediaQuery.textScalerOf(context).scale(1) <= 1.3) ...[
                const SizedBox(width: 4),
                const Text(
                  '选集',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Text(
                  '${chapters.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
      if (bounds.maxWidth < 360 &&
          MediaQuery.textScalerOf(context).scale(1) > 1.3) {
        return Column(
          key: const Key('video-detail-line-heading'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [controls.first]),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: controls.skip(1).toList(),
            ),
          ],
        );
      }
      return Row(
        key: const Key('video-detail-line-heading'),
        children: controls,
      );
    },
  );

  Widget episodeStrip(List<int> visible, {bool grid = false}) => LayoutBuilder(
    builder: (context, bounds) {
      final width = (bounds.maxWidth - 20) / 3;
      final height = width * 9 / 16;
      final labelSize = originalStyle ? 14.0 : 13.0;
      final extent =
          height + 12 + MediaQuery.textScalerOf(context).scale(labelSize) * 1.5;
      Widget tile(int i) {
        final index = visible[i], chapter = chapters[index];
        final cover = chapter.cover?.trim().isNotEmpty == true
            ? chapter.cover
            : sourceCover;
        return SizedBox(
          width: width,
          child: InkWell(
            key: ValueKey('video-detail-episode-$index'),
            onTap: resolving ? null : () => chooseEpisode(index),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PosterCover(
                          pipeline: pipeline,
                          url: cover,
                          title: chapter.title,
                          headers: chapter.coverHeaders.isEmpty
                              ? detail?.coverHeaders ?? widget.item.coverHeaders
                              : chapter.coverHeaders,
                        ),
                        if (episodeProgress(index)?.position != null &&
                            episodeProgress(index)!.position > Duration.zero)
                          Positioned(
                            left: 4,
                            top: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  episodeProgress(index)!.isFinished
                                      ? '已看完'
                                      : '观看中',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (selected == index)
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        if (selected == index)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                key: ValueKey(
                                  'video-detail-episode-border-$index',
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Theme.of(this.context)
                                        .colorScheme
                                        .primary,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                episodeProgressBar(index),
                const SizedBox(height: 6),
                Text(
                  VideoEpisodeCatalog.displayLabel(chapter, index),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: labelSize,
                    fontWeight: originalStyle ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (grid) {
        return GridView.builder(
          key: const Key('video-detail-compact-episode-grid'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: extent,
          ),
          itemCount: visible.length,
          itemBuilder: (_, i) => tile(i),
        );
      }
      return SizedBox(
        height: extent,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, i) => tile(i),
        ),
      );
    },
  );

  Future<void> openBangumi() async {
    await showBangumiMatchSheet(
      sourceId: _source?.id ?? widget.sourceId ?? '',
      context: context,
      library: widget.library,
      item: widget.item,
      initialTitle: detail?.title ?? widget.item.title,
    );
  }

  VideoProgress? episodeProgress(int index) {
    final chapter = chapters[index];
    return widget.library.videoEpisodeProgress(
          widget.item.id,
          chapter.id,
          sourceId: _source?.id ?? widget.sourceId,
        ) ??
        (index == selected ? lineResume : null);
  }

  String get playLabel {
    if (resolving) return '正在解析';
    if (chapters.isEmpty) return '暂无可播放剧集';
    final progress = episodeProgress(selected);
    final label = VideoEpisodeCatalog.displayLabel(
      chapters[selected],
      selected,
    );
    return '${progress?.isFinished == true
        ? '重播'
        : progress != null && progress.position > Duration.zero
        ? '继续看'
        : '播放'} · $label';
  }

  Widget resumeHint() {
    final progress = chapters.isEmpty ? null : episodeProgress(selected);
    if (progress == null || progress.position <= Duration.zero) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        progress.isFinished ? '本集已看完' : '看到 ${progress.timeLabel}',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: originalStyle
              ? Colors.white70
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget episodeProgressBar(int index) {
    final progress = episodeProgress(index);
    if (progress == null || progress.position <= Duration.zero) {
      return const SizedBox.shrink();
    }
    return LinearProgressIndicator(
      key: ValueKey('video-episode-progress-$index'),
      value: progress.duration > Duration.zero ? progress.ratio : 0,
      minHeight: 3,
      color: originalStyle ? Colors.white : _compactAccent,
      backgroundColor: originalStyle
          ? Colors.white24
          : Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget castSection() {
    final metadata = tmdb.metadata;
    final nameSize = originalStyle ? 13.0 : 12.0;
    final titleSize = originalStyle ? 18.0 : 17.0;
    final scaler = MediaQuery.textScalerOf(context);
    final portraitRowHeight = math.max(48.0, scaler.scale(titleSize) * 1.2);
    final people = metadata?.cast.isNotEmpty == true
        ? [
            for (var i = 0; i < metadata!.cast.length; i++)
              SourcePerson(
                name: metadata.cast[i],
                avatar: i < metadata.profiles.length
                    ? metadata.profiles[i]
                    : null,
              ),
          ]
        : detail?.cast ?? const <SourcePerson>[];
    if (people.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(
        top: originalStyle ? (metadata != null ? 16 : 24) : 20,
      ),
      child: Row(
        key: const Key('video-detail-cast-row'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: portraitRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '演员',
                key: const Key('video-detail-cast-title'),
                style: TextStyle(
                  fontSize: titleSize,
                  height: 1.2,
                  fontWeight: originalStyle ? FontWeight.w800 : FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: portraitRowHeight + 6 + scaler.scale(nameSize) * 1.4 + 1,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: people.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => SizedBox(
                  width: 60,
                  child: Column(
                    children: [
                      SizedBox(
                        height: portraitRowHeight,
                        child: Center(
                          child: ClipOval(
                            child: SizedBox.square(
                              key: ValueKey('video-detail-cast-avatar-$i'),
                              dimension: 48,
                              child: people[i].avatar?.isNotEmpty == true
                                  ? PosterCover(
                                      pipeline: pipeline,
                                      url: people[i].avatar,
                                      title: people[i].name,
                                      headers: people[i].headers,
                                      width: 144,
                                      borderRadius: BorderRadius.zero,
                                    )
                                  : const ColoredBox(
                                      color: Color(0x22666666),
                                      child: Center(
                                        child: Icon(
                                          Icons.person_outline,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        people[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: nameSize,
                          height: 1.4,
                          fontWeight: originalStyle ? FontWeight.w600 : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool changeLine(String next, {bool allowMissing = false}) {
    if (next == currentLine) return true;
    if (resolving || !lines.containsKey(next) || lines[next]!.isEmpty) {
      return false;
    }
    final previous = chapters.isEmpty ? null : chapters[selected];
    final nextChapters = lines[next]!;
    final matched = previous == null
        ? -1
        : VideoEpisodeCatalog.matchingIndex(previous, nextChapters);
    if (matched < 0 && !allowMissing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('该线路没有对应集，请在选集里手动选择'),
          action: SnackBarAction(label: '选集', onPressed: showEpisodes),
        ),
      );
      return false;
    }
    final progress = matched >= 0 ? episodeProgress(selected) : null;
    setState(() {
      lineResume = progress;
      currentLine = next;
      chapters = nextChapters;
      selected = matched >= 0 ? matched : 0;
      episodePage = selected ~/ 50;
      compactEpisodeStart =
          (reversed ? chapters.length - 1 - selected : selected) ~/ 10 * 10;
    });
    return true;
  }

  Future<void> switchLineAfterFailure() async {
    final next = await showGlassModalBottomSheet<String>(
      context: context,
      videoGlass: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('换线路继续看'),
              subtitle: Text('保留当前集数；有观看记录时继续上次位置'),
            ),
            for (final line in lines.keys.where((line) => line != currentLine))
              ListTile(
                title: Text(line),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, line),
              ),
          ],
        ),
      ),
    );
    if (next != null && mounted && changeLine(next)) await play();
  }

  Future<void> chooseEpisode(int index) async {
    if (resolving || index < 0 || index >= chapters.length) return;
    setState(() {
      if (index != selected) lineResume = null;
      selected = index;
      compactEpisodeStart =
          (reversed ? chapters.length - 1 - selected : selected) ~/ 10 * 10;
    });
    if (PlayerExperienceStore.current.selectEpisodeOnly) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已选中剧集，点击上方播放按钮开始')));
      return;
    }
    await play();
  }

  void locateEpisodes() {
    setState(() {
      final position = reversed ? chapters.length - 1 - selected : selected;
      episodePage = position ~/ 50;
      compactEpisodeStart = position ~/ 10 * 10;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _episodesKey.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 280),
          alignment: .1,
        );
      }
    });
  }

  Widget episodeButton(int index, {bool modal = false}) {
    final chapter = chapters[index];
    final active = selected == index;
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton(
      key: ValueKey(
        modal
            ? 'video-detail-picker-episode-$index'
            : 'video-detail-episode-$index',
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        foregroundColor: active ? colors.primary : colors.onSurface,
        backgroundColor: active
            ? colors.primary.withValues(alpha: .12)
            : colors.onSurface.withValues(alpha: .035),
        side: BorderSide(
          color: active
              ? colors.primary.withValues(alpha: .5)
              : colors.onSurface.withValues(alpha: .08),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: resolving
          ? null
          : () {
              if (modal) Navigator.pop(context);
              chooseEpisode(index);
            },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            VideoEpisodeCatalog.displayLabel(chapter, index),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          episodeProgressBar(index),
        ],
      ),
    );
  }

  Widget episodeGrid(List<int> indexes, {bool modal = false, Key? activeKey}) =>
      LayoutBuilder(
        builder: (context, bounds) {
          final count = !modal && !originalStyle
              ? 3
              : bounds.maxWidth < 340
              ? 4
              : 5;
          final scale = MediaQuery.textScalerOf(context)
              .scale(1)
              .clamp(1.0, 2.0);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: 44 * scale,
            ),
            itemCount: indexes.length,
            itemBuilder: (_, i) => KeyedSubtree(
              key: indexes[i] == selected ? activeKey : null,
              child: episodeButton(indexes[i], modal: modal),
            ),
          );
        },
      );

  Future<void> showEpisodes() async {
    if (chapters.isEmpty) return;
    var page = (reversed ? chapters.length - 1 - selected : selected) ~/ 50;
    final scroll = ScrollController();
    final activeKey = GlobalKey();
    var listMode = chapters.any(
      (e) => VideoEpisodeCatalog.labelOf(e).length > 18,
    );
    await showGlassModalBottomSheet<void>(
      context: context,
      videoGlass: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          final order = [
            for (var i = 0; i < chapters.length; i++)
              reversed ? chapters.length - 1 - i : i,
          ];
          final filtered = order;
          final pages = (filtered.length / 50).ceil().clamp(1, 999999);
          page = page.clamp(0, pages - 1);
          final visible = filtered.skip(page * 50).take(50).toList();
          return SafeArea(
            top: false,
            child: FractionallySizedBox(
              heightFactor: .78,
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选集 · $currentLine · ${chapters.length} 集',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '定位当前集',
                        icon: const Icon(Icons.my_location),
                        onPressed: () {
                          final position = reversed
                              ? chapters.length - 1 - selected
                              : selected;
                          refresh(() => page = position ~/ 50);
                          WidgetsBinding.instance.addPostFrameCallback((
                            _,
                          ) async {
                            if (!scroll.hasClients) return;
                            final count =
                                (chapters.length - (position ~/ 50) * 50).clamp(
                                  1,
                                  50,
                                );
                            final fraction = count <= 1
                                ? 0.0
                                : (position % 50) / (count - 1);
                            scroll.jumpTo(
                              scroll.position.maxScrollExtent * fraction,
                            );
                            await WidgetsBinding.instance.endOfFrame;
                            final target = activeKey.currentContext;
                            if (target != null && target.mounted) {
                              await Scrollable.ensureVisible(
                                target,
                                alignment: .25,
                                duration: const Duration(milliseconds: 250),
                              );
                            }
                          });
                        },
                      ),
                      IconButton(
                        tooltip: '倒序排列',
                        onPressed: () {
                          setState(() => reversed = !reversed);
                          refresh(() => page = 0);
                        },
                        icon: const Icon(Icons.swap_vert),
                      ),
                      IconButton(
                        tooltip: listMode ? '网格显示' : '列表显示',
                        onPressed: () => refresh(() => listMode = !listMode),
                        icon: Icon(
                          listMode ? Icons.grid_view : Icons.view_list,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭选集',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (lines.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final line in lines.keys)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(line),
                                selected: line == currentLine,
                                onSelected: resolving
                                    ? null
                                    : (_) {
                                        changeLine(line, allowMissing: true);
                                        refresh(() {
                                          page = 0;
                                        });
                                      },
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (pages > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: DropdownButtonFormField<int>(
                        key: ValueKey('video-episode-picker-range-$page'),
                        initialValue: page,
                        isExpanded: true,
                        items: [
                          for (var i = 0; i < pages; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                '${i * 50 + 1}—${((i + 1) * 50).clamp(0, filtered.length)} 集',
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) refresh(() => page = v);
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有匹配的剧集'),
                    )
                  else if (listMode) ...[
                    for (final i in visible) ...[
                      KeyedSubtree(
                        key: i == selected ? activeKey : null,
                        child: ListTile(
                          key: ValueKey('video-detail-picker-episode-$i'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          minTileHeight: 56,
                          selected: i == selected,
                          leading: Text('${i + 1}'),
                          title: Text(
                            VideoEpisodeCatalog.displayLabel(chapters[i], i),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.play_circle_outline),
                          onTap: resolving
                              ? null
                              : () {
                                  Navigator.pop(sheetContext);
                                  chooseEpisode(i);
                                },
                        ),
                      ),
                      if (i != visible.last)
                        Divider(
                          height: 1,
                          thickness: .5,
                          indent: 48,
                          endIndent: 24,
                          color: Theme.of(sheetContext).colorScheme.onSurface
                              .withValues(alpha: .18),
                        ),
                    ],
                  ] else
                    episodeGrid(visible, modal: true, activeKey: activeKey),
                ],
              ),
            ),
          );
        },
      ),
    );
    scroll.dispose();
  }

  Widget episodeSection({bool immersive = false}) {
    final order = [
      for (var i = 0; i < chapters.length; i++)
        reversed ? chapters.length - 1 - i : i,
    ];
    final page = episodePage.clamp(
      0,
      ((chapters.length - 1) ~/ 50).clamp(0, 999999),
    );
    final visible = originalStyle
        ? order.skip(page * 50).take(50).toList()
        : order
              .skip(
                compactEpisodeStart.clamp(
                  0,
                  (order.length - 1).clamp(0, 999999),
                ),
              )
              .take(6)
              .toList();
    final artwork =
        immersive ||
        sourceCover?.trim().isNotEmpty == true ||
        chapters.any((e) => e.cover?.trim().isNotEmpty == true);
    return Column(
      key: _episodesKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (originalStyle && chapters.length > 50)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<int>(
              key: ValueKey('video-episode-range-$page'),
              initialValue: page,
              isExpanded: true,
              items: [
                for (var i = 0; i < (chapters.length / 50).ceil(); i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i * 50 + 1}—${((i + 1) * 50).clamp(0, chapters.length)} 集',
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => episodePage = v);
              },
            ),
          ),
        if (chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('暂无可用剧集'),
          )
        else if (artwork)
          episodeStrip(visible, grid: !originalStyle)
        else
          episodeGrid(visible),
      ],
    );
  }

  static const _compactAccent = Color(0xFFE83E68);

  List<Widget> translationDownloadActions() => [
    SourceTranslationAction(
      key: const Key('video-detail-translation'),
      texts: [detail?.title ?? widget.item.title, synopsis],
    ),
    IconButton(
      key: const Key('video-detail-download'),
      tooltip: '下载视频 / 选集',
      onPressed: resolving || chapters.isEmpty ? null : downloadVideo,
      icon: const Icon(Icons.download_outlined, size: 20),
    ),
  ];

  Widget compactPlaybackControls() => Row(
    key: const Key('video-detail-compact-playback'),
    children: [
      Expanded(
        child: VideoGlassSurface(
          radius: 28,
          child: FilledButton.icon(
            key: const Key('video-detail-play'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: Colors.transparent,
              elevation: 0,
              foregroundColor: VideoGlassSurface.foreground,
              shape: const StadiumBorder(),
            ),
            onPressed: loading || resolving || chapters.isEmpty ? null : play,
            icon: resolving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(
              playLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      detailCornerActions(),
    ],
  );

  Widget compactEpisodeSection() {
    final order = [
      for (var i = 0; i < chapters.length; i++)
        reversed ? chapters.length - 1 - i : i,
    ];
    final start = chapters.isEmpty
        ? 0
        : (compactEpisodeStart ~/ 10 * 10).clamp(
            0,
            (chapters.length - 1) ~/ 10 * 10,
          );
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: _episodesKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, bounds) => Row(
            children: [
              if (bounds.maxWidth < 370 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 84),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '选集',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '共 ${chapters.length} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '选集',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '共 ${chapters.length} 集',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              const SizedBox(width: 8),
              Expanded(
                child: PopupMenuButton<String>(
                  key: const Key('video-compact-line-selector'),
                  tooltip: '选择播放线路',
                  enabled: !resolving && lines.isNotEmpty,
                  position: PopupMenuPosition.under,
                  constraints: const BoxConstraints(
                    minWidth: 180,
                    maxWidth: 320,
                  ),
                  color: Colors.transparent,
                  menuPadding: EdgeInsets.zero,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  onSelected: (line) => changeLine(line),
                  itemBuilder: (_) => videoGlassMenuEntries<String>([
                    for (final line in lines.keys)
                      PopupMenuItem<String>(
                        key: ValueKey('video-compact-line-$line'),
                        value: line,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$line · ${lines[line]!.length} 集',
                                style: TextStyle(
                                  color: line == currentLine
                                      ? _compactAccent
                                      : const Color(0xFF26272C),
                                ),
                              ),
                            ),
                            if (line == currentLine)
                              const Icon(
                                Icons.check_rounded,
                                color: _compactAccent,
                                size: 18,
                              ),
                          ],
                        ),
                      ),
                  ]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            currentLine.isEmpty ? '选择线路' : currentLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _compactAccent,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: _compactAccent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(36, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...translationDownloadActions(),
                    IconButton(
                      tooltip: reversed ? '恢复正序' : '倒序排列',
                      onPressed: chapters.isEmpty
                          ? null
                          : () => setState(() {
                              reversed = !reversed;
                              compactEpisodeStart = 0;
                            }),
                      icon: const Icon(Icons.swap_vert, size: 20),
                    ),
                  ],
                ),
              ),
              if (bounds.maxWidth < 470 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3)
                IconButton(
                  key: const Key('video-detail-select-episodes'),
                  tooltip: '选集工具',
                  onPressed: chapters.isEmpty ? null : showEpisodes,
                  icon: const Icon(Icons.tune),
                )
              else
                OutlinedButton.icon(
                  key: const Key('video-detail-select-episodes'),
                  onPressed: chapters.isEmpty ? null : showEpisodes,
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('选集工具'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _compactAccent,
                    side: BorderSide(
                      color: colors.onSurface.withValues(alpha: .1),
                    ),
                    backgroundColor: colors.surface.withValues(alpha: .35),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
            ],
          ),
        ),
        if (chapters.isNotEmpty) ...[
          SingleChildScrollView(
            key: const Key('video-compact-ranges'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < chapters.length; i += 10)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('video-compact-range-$i'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(
                        '${i + 1}–${(i + 10).clamp(0, chapters.length)} 集',
                      ),
                      selected: start == i,
                      showCheckmark: false,
                      color: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? _compactAccent
                            : colors.surface.withValues(alpha: .4),
                      ),
                      selectedColor: _compactAccent,
                      backgroundColor: colors.surface.withValues(alpha: .4),
                      side: BorderSide.none,
                      labelStyle: TextStyle(
                        color: start == i
                            ? Colors.white
                            : colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: const StadiumBorder(),
                      onSelected: (_) =>
                          setState(() => compactEpisodeStart = i),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, bounds) {
              final visible = order.skip(start).take(10).toList();
              final count = bounds.maxWidth >= 400 ? 6 : 5;
              final width = (bounds.maxWidth - (count - 1) * 8) / count;
              return Wrap(
                key: const Key('video-detail-compact-episode-grid'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final index in visible)
                    SizedBox(
                      width: width,
                      child: OutlinedButton(
                        key: ValueKey('video-detail-episode-$index'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 42),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          alignment: Alignment.centerLeft,
                          foregroundColor: selected == index
                              ? _compactAccent
                              : colors.onSurface,
                          backgroundColor: colors.surface.withValues(
                            alpha: selected == index ? .8 : .5,
                          ),
                          side: selected == index
                              ? const BorderSide(color: _compactAccent)
                              : BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: resolving
                            ? null
                            : () => chooseEpisode(index),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _compactEpisodeLabel(index),
                              style: const TextStyle(fontSize: 14, height: 1.3),
                            ),
                            episodeProgressBar(index),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ] else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('暂无可用剧集'),
          ),
      ],
    );
  }

  String _compactEpisodeLabel(int index) {
    final label = VideoEpisodeCatalog.displayLabel(chapters[index], index);
    final number = RegExp(r'^(?:第\s*)?(\d+)(?:\s*[集话期])?$')
        .firstMatch(label.trim());
    return number == null ? label : number.group(1)!.padLeft(2, '0');
  }

  Widget _buildCompact(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      tmdb,
      tmdb.settings.detailAppearance,
      tmdb.settings.detailOverrides,
    ]),
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final title = detail?.title ?? widget.item.title;
      final subtitle = conciseVideoSubtitle(
        rawSourceSubtitle
            .replaceAll(RegExp(r'(?:更新至\s*){2,}'), '更新至')
            .replaceAll(RegExp(r'集\s*集'), '集'),
        availableEpisodes: chapters.length,
      );
      final hasArtwork =
          sourceCover?.trim().isNotEmpty == true ||
          tmdb.metadata?.posters.isNotEmpty == true ||
          tmdb.metadata?.backdrops.isNotEmpty == true;
      final data = tmdb.metadata;
      final metadata = [
        if (data?.year.isNotEmpty == true && !subtitle.contains(data!.year))
          data.year,
        if (subtitle.isNotEmpty) subtitle,
        if (data?.genres.isNotEmpty == true &&
            !data!.genres.any(subtitle.contains))
          data.genres.join(' · '),
      ].join(' · ');
      return Scaffold(
        backgroundColor: _pageColor,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: collapsedHeader ? _pageColor : Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: Theme.of(context).brightness == Brightness.light
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light,
          leadingWidth: 64,
          leading: Padding(
            padding: const EdgeInsets.only(
              left: 14,
              top: 6,
              bottom: 6,
              right: 6,
            ),
            child: detailBackButton(),
          ),
          title: collapsedHeader
              ? Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                )
              : null,
          actions: collapsedHeader
              ? [
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: detailCornerActions(),
                  ),
                ]
              : null,
        ),
        body: LayoutBuilder(
          builder: (context, bounds) {
            final heroHeight = (bounds.maxWidth * 1.25).clamp(320.0, 700.0);
            // Extend only the artwork fade; the tightened content keeps its position.
            final artworkHeight = heroHeight + bounds.maxWidth * .06;
            return SingleChildScrollView(
              controller: _scroll,
              key: const Key('video-detail-scroll'),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              child: Stack(
                key: const Key('video-detail-immersive'),
                children: [
                  if (hasArtwork)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: artworkHeight,
                      key: const Key('video-detail-compact-banner'),
                      child: IgnorePointer(
                        child: TmdbPosterGallery(
                          imagePipeline: tmdbImagePipeline,
                          onArtworkDisplayed: _artworkDisplayed,
                          controller: tmdb,
                          fit: BoxFit.cover,
                          fallback: PosterCover(
                            pipeline: pipeline,
                            url: sourceCover,
                            title: title,
                            headers:
                                detail?.coverHeaders ??
                                widget.item.coverHeaders,
                          ),
                        ),
                      ),
                    ),
                  if (hasArtwork)
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
                              stops: const [0, .68, .84, .97, 1],
                              colors: [
                                Colors.transparent,
                                Colors.transparent,
                                _pageColor.withValues(alpha: .3),
                                _pageColor.withValues(alpha: .9),
                                _pageColor,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      14,
                      hasArtwork
                          ? heroHeight + 18
                          : MediaQuery.paddingOf(context).top +
                                kToolbarHeight +
                                20,
                      14,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SourceText(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 30,
                            height: 1.25,
                            fontWeight: FontWeight.w800,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          metadata,
                          key: const Key('video-detail-metadata-row'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Center(
                          child: TextButton(
                            key: const Key('video-detail-tmdb-status'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.teal.shade600,
                              minimumSize: const Size(44, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              textStyle: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: tmdb.loading
                                ? null
                                : () {
                                    if (!tmdb.settings.configured) {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => tmdbSettings(),
                                        ),
                                      );
                                    } else {
                                      showTmdbMatchPicker(context, tmdb);
                                    }
                                  },
                            child: Text(
                              data != null
                                  ? 'TMDB · 已匹配'
                                  : tmdb.loading
                                  ? 'TMDB · 正在匹配…'
                                  : tmdb.settings.configured
                                  ? '匹配 TMDB'
                                  : '配置 TMDB',
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        compactPlaybackControls(),
                        if (chapters.isNotEmpty &&
                            episodeProgress(selected) != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '看到 ${episodeProgress(selected)!.timeLabel}',
                              key: const Key('video-detail-compact-progress'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        const SizedBox(height: 2),
                        if (loading)
                          const Center(child: CircularProgressIndicator()),
                        if (error != null) ...[
                          Text(error!),
                          TextButton(onPressed: load, child: const Text('重试')),
                        ],
                        if (_playFailure != null) playbackRecovery(),
                        compactEpisodeSection(),
                        const SizedBox(height: 24),
                        summaryBlock(title, synopsis),
                        if (playbackFailed && lines.length > 1)
                          OutlinedButton.icon(
                            onPressed: switchLineAfterFailure,
                            icon: const Icon(Icons.alt_route),
                            label: const Text('换线路继续看'),
                          ),
                        if (playbackFailed)
                          TextButton.icon(
                            onPressed: () => searchCurrentVideo(),
                            icon: const Icon(Icons.search),
                            label: const Text('保持集数换源'),
                          ),
                        castSection(),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
  Widget _buildOriginal(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      tmdb,
      tmdb.settings.detailAppearance,
      tmdb.settings.detailOverrides,
    ]),
    builder: (context, _) {
      final dark = ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: _pageColor,
        textTheme: _bolderTextTheme(
          LumeTheme.readableTextTheme(Brightness.dark).apply(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
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
            foregroundColor: VideoGlassSurface.foreground,
            systemOverlayStyle: SystemUiOverlayStyle.light,
            leadingWidth: 64,
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              child: detailBackButton(),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 14, top: 6, bottom: 6),
                child: detailCornerActions(),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final artworkHeight = (constraints.maxWidth * 1.48).clamp(
                460.0,
                760.0,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (tmdb.settings.detailBackdropEnabled)
                    ColoredBox(
                      key: const Key('video-detail-poster-color-background'),
                      color: _pageColor,
                    ),
                  SingleChildScrollView(
                    controller: _scroll,
                    key: const Key('video-detail-scroll'),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: Stack(
                      key: const Key('video-detail-immersive'),
                      children: [
                        if (tmdb.settings.detailBackdropEnabled &&
                            _coverColor != null)
                          SizedBox(
                            width: double.infinity,
                            height: constraints.maxHeight,
                          ),
                        if (tmdb.settings.detailBackdropEnabled &&
                            _coverColor != null)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: artworkHeight + constraints.maxWidth * .65,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                key: const Key('video-detail-surface-gradient'),
                                decoration: BoxDecoration(
                                  gradient: detailPosterSurfaceGradient(
                                    _pageColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: artworkHeight,
                          child: DetailArtworkMotion(
                            scroll: _scroll,
                            height: artworkHeight,
                            child: IgnorePointer(
                              child: DetailPosterFade(
                                strength: tmdb
                                    .settings
                                    .detailAppearance
                                    .value
                                    .fadeStrength,
                                brightness: tmdb
                                    .settings
                                    .detailAppearance
                                    .value
                                    .posterBrightness,
                                key: tmdb.settings.detailBackdropEnabled
                                    ? const Key('video-detail-gradient')
                                    : null,
                                child: TmdbPosterGallery(
                                  imagePipeline: tmdbImagePipeline,
                                  onArtworkDisplayed: _artworkDisplayed,
                                  controller: tmdb,
                                  fit: BoxFit.cover,
                                  fallback: PosterCover(
                                    pipeline: pipeline,
                                    url: sourceCover,
                                    width:
                                        (constraints.maxWidth *
                                                MediaQuery.devicePixelRatioOf(
                                                  context,
                                                ))
                                            .ceil()
                                            .clamp(320, 1600),
                                    title: widget.item.title,
                                    headers:
                                        detail?.coverHeaders ??
                                        widget.item.coverHeaders,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (!tmdb.settings.detailBackdropEnabled)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: artworkHeight + 2,
                            child: DetailArtworkMotion(
                              scroll: _scroll,
                              height: artworkHeight,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  key: const Key('video-detail-gradient'),
                                  decoration: BoxDecoration(
                                    gradient: posterOverlayGradient(_pageColor),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            artworkHeight * .61 + 44,
                            16,
                            24 + MediaQuery.paddingOf(context).bottom,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TmdbTitleArtwork(
                                controller: tmdb,
                                fallback: SourceText(
                                  detail?.title ?? widget.item.title,
                                  textAlign: TextAlign.center,
                                  style: dark.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black54,
                                        blurRadius: 12,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              metadataRow(
                                (detail?.subtitle ?? widget.item.subtitle ?? '')
                                    .replaceAll(
                                      RegExp(r'(?:更新至\s*){2,}'),
                                      '更新至',
                                    )
                                    .replaceAll(RegExp(r'集\s*集'), '集'),
                                detail?.title ?? widget.item.title,
                              ),
                              if (tmdb.metadata != null)
                                Padding(
                                  padding: EdgeInsets.zero,
                                  child: Wrap(
                                    key: const Key(
                                      'video-detail-genre-rating-row',
                                    ),
                                    alignment: WrapAlignment.center,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 10,
                                    children: [
                                      if (tmdb.metadata!.genres.isNotEmpty)
                                        Text(
                                          tmdb.metadata!.genres.join(' · '),
                                          key: const Key('video-detail-genres'),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      tmdbRating(),
                                    ],
                                  ),
                                ),
                              resumeHint(),
                              SizedBox(height: tmdb.metadata != null ? 0 : 4),
                              Center(
                                child: FractionallySizedBox(
                                  widthFactor: .82,
                                  child: VideoGlassSurface(
                                    radius: 30,
                                    child: FilledButton.icon(
                                      key: const Key('video-detail-play'),
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size.fromHeight(50),
                                        backgroundColor: Colors.transparent,
                                        foregroundColor:
                                            VideoGlassSurface.foreground,
                                        shape: const StadiumBorder(),
                                        elevation: 0,
                                      ),
                                      onPressed:
                                          loading ||
                                              resolving ||
                                              chapters.isEmpty
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
                                          : const LumeIcon(
                                              Icons.play_arrow,
                                              slot: 'video_detail_page.4',
                                            ),
                                      label: Text(
                                        playLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              summaryBlock(
                                detail?.title ?? widget.item.title,
                                synopsis,
                              ),
                              if (playbackFailed && lines.length > 1)
                                OutlinedButton.icon(
                                  onPressed: switchLineAfterFailure,
                                  icon: const Icon(Icons.alt_route),
                                  label: const Text('换线路继续看'),
                                ),
                              if (playbackFailed)
                                TextButton.icon(
                                  onPressed: () => searchCurrentVideo(),
                                  icon: const Icon(Icons.search),
                                  label: const Text('保持集数换源'),
                                ),
                              if (loading)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                    child: CircularProgressIndicator(),
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
                              if (_playFailure != null) playbackRecovery(),
                              const SizedBox(height: 4),
                              linePicker(),
                              const SizedBox(height: 10),
                              episodeSection(immersive: true),
                              castSection(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
