import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/audio_book/audio_book_player.dart';
import '../../core/media/media_library.dart';
import 'section_toolbar.dart';
import '../../shared/widgets/glass_card.dart';
import '../comic/comic_reader_page.dart';
import '../novel/novel_reader_page.dart';
import '../video/video_detail_page.dart';
import '../video/video_player_page.dart';
import '../video/video_download_center.dart';
import '../video/video_play_target.dart';
import '../video/video_resume_match.dart';
import '../video/playback_entry_preparation.dart';
import '../media/media_resource_router.dart';
import 'history_privacy.dart';
import 'search_results_page.dart';

class ContinueActivityPage extends StatefulWidget {
  const ContinueActivityPage({super.key, this.managers = const {}});
  final Map<Section, SourceManager> managers;
  @override
  State<ContinueActivityPage> createState() => _ContinueActivityPageState();
}

class _Activity {
  const _Activity(
    this.section,
    this.at, {
    this.item,
    this.progress,
    this.resource,
    this.audioPosition,
  });
  final Section section;
  final DateTime at;
  final LibraryItem? item;
  final ReadingProgress? progress;
  final MediaResource? resource;
  final Map<String, int>? audioPosition;
}

class _ContinueActivityPageState extends State<ContinueActivityPage>
    with WidgetsBindingObserver {
  final unlocked = <Section, String>{};
  List<_Activity> rows = [];
  List<ReadingLibrary> locked = [];
  String? error;
  String? opening;
  bool loading = true;
  SourceManager manager(Section section) =>
      widget.managers[section] ?? LumeSources.manager(section);
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      generation++;
      if (mounted) {
        setState(() {
          unlocked.clear();
          rows = [];
        });
      }
    } else {
      load();
    }
  }

  Future<void> load() async {
    final seq = ++generation;
    if (mounted) setState(() => loading = true);
    final next = <_Activity>[];
    final concealed = <ReadingLibrary>[];
    final allowed = <Section>{};
    try {
      for (final section in Section.values) {
        final library = await ReadingLibrary.open(section);
        if (!mounted || seq != generation) return;
        if ((library.setting(HistoryPrivacy.lockKey) ?? '').isNotEmpty &&
            unlocked[section] != library.setting(HistoryPrivacy.lockKey)) {
          concealed.add(library);
          continue;
        }
        allowed.add(section);
        for (final entry in library.continueReading()) {
          next.add(
            _Activity(
              section,
              entry.progress.updatedAt,
              item: entry.item,
              progress: entry.progress,
            ),
          );
        }
      }
      await MediaLibrary.instance.boot();
      await AudioBookSettings.instance.load();
      for (final section in allowed) {
        for (final resource in MediaLibrary.instance.entries(section)) {
          if (resource.kind != ResourceKind.audioBook ||
              (resource.originSection != null &&
                  !allowed.contains(resource.originSection))) {
            continue;
          }
          final position = AudioBookSettings.instance.positions[resource.id];
          if (position == null) continue;
          next.add(
            _Activity(
              section,
              DateTime.fromMillisecondsSinceEpoch(
                (position['updatedAt'] ?? 0).clamp(
                  0,
                  DateTime.now().millisecondsSinceEpoch,
                ),
              ),
              resource: resource,
              audioPosition: position,
            ),
          );
        }
      }
      next.sort((a, b) => b.at.compareTo(a.at));
      if (mounted && seq == generation) {
        setState(() {
          rows = next;
          locked = concealed;
          error = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted && seq == generation) {
        setState(() {
          error = '读取记录失败，请重试';
          loading = false;
        });
      }
    }
  }

  Future<void> detail(
    DataSource source,
    SourceItem item,
    ReadingLibrary library,
    ReadingProgress? progress, {
    String? resumeTitle,
    bool differentItem = false,
  }) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => VideoDetailPage(
          source: source,
          sourceId: source.id,
          manager: manager(library.section),
          item: item,
          library: library,
          initialChapterId: differentItem ? null : progress?.chapterId,
          resumeRequest: progress is VideoProgress
              ? VideoResumeRequest(
                  title: resumeTitle ?? item.title,
                  chapterTitle: progress.chapterTitle,
                  chapterIndex: progress.chapterIndex,
                  position: progress.position,
                  duration: progress.duration,
                )
              : null,
          onPlay: (origin, media, target, qualities, prepared) async {
            final context = origin.context;
            final route = ModalRoute.of(context);
            final entering =
                prepared ??
                await preparePlaybackRoute(
                  media,
                  library: library,
                  target: target,
                  stillActive: () => context.mounted && route?.isCurrent != false,
                );
            if (!context.mounted || route?.isCurrent == false) {
              await entering?.discard();
              return;
            }
            await Navigator.push<void>(
              context,
              PageRouteBuilder(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, _, _) => VideoPlayerPage(
                  media: media,
                  target: target,
                  source: origin.source,
                  sourceId: target.sourceId,
                  sourceManager: manager(library.section),
                  library: library,
                  qualities: qualities,
                  prelaunch: entering,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> alternative(_Activity row) async {
    final item = row.item!;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: row.section,
          keyword: item.title,
          mode: SearchMode.aggregate,
          onOpenItem: (selection) async {
            try {
              final source = await manager(row.section)
                  .open(selection.sourceId)
                  .timeout(const Duration(seconds: 15));
              if (source != null) {
                await detail(
                  source,
                  selection.item,
                  await ReadingLibrary.open(row.section),
                  row.progress,
                  resumeTitle: row.item?.title,
                  differentItem: selection.sourceId != item.sourceId ||
                      selection.item.id != item.itemId,
                );
              }
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('来源暂时无法打开')));
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> open(_Activity row) async {
    if (opening != null) return;
    final key = row.resource?.id ?? row.item!.identity;
    setState(() => opening = key);
    final activeGeneration = generation;
    try {
      if (row.resource != null) {
        await openMediaResource(context, row.resource!);
      } else {
        final item = row.item!, progress = row.progress!;
        final library = await ReadingLibrary.open(row.section);
        if (!mounted || activeGeneration != generation) return;
        if (progress is VideoProgress) {
          final file = await VideoDownloadCenter.instance.completedPlayback(
            item.sourceId,
            item.itemId,
            progress.chapterId,
          );
          if (!mounted || activeGeneration != generation) {
            await file?.close();
            return;
          }
          if (file != null) {
            try {
              await Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => VideoPlayerPage(
                    media: file.media(item.title),
                    library: library,
                    target: VideoPlayTarget(
                      sourceId: item.sourceId,
                      itemId: item.itemId,
                      title: item.title,
                      cover: item.cover,
                      chapterIndex: progress.chapterIndex,
                      chapterId: progress.chapterId,
                      chapterTitle: progress.chapterTitle,
                    ),
                    sourceManager: manager(row.section),
                  ),
                ),
              );
            } finally {
              await file.close();
            }
            return;
          }
        }
        final source = await manager(row.section)
            .open(item.sourceId)
            .timeout(const Duration(seconds: 15));
        if (source == null) throw StateError('来源不可用');
        if (source.section != row.section) throw StateError('来源板块不匹配');
        if (!mounted || activeGeneration != generation) return;
        final target = ReadingTarget(
          sourceId: item.sourceId,
          itemId: item.itemId,
          title: item.title,
          cover: item.cover,
          subtitle: item.subtitle,
        );
        if (progress is ComicProgress || progress is NovelProgress) {
          final chapters = await source
              .chapters(item.itemId)
              .timeout(const Duration(seconds: 15));
          if (!mounted || activeGeneration != generation) return;
          final index = chapters.indexWhere((c) => c.id == progress.chapterId);
          if (index < 0) {
            await detail(
              source,
              SourceItem(id: item.itemId, title: item.title, cover: item.cover),
              library,
              progress,
            );
          } else if (mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => progress is NovelProgress
                    ? NovelReaderPage(
                        source: source,
                        library: library,
                        target: target,
                        chapters: chapters,
                        initialChapterIndex: index,
                      )
                    : ComicReaderPage(
                        dataSource: source,
                        library: library,
                        target: target,
                        chapters: chapters,
                        initialChapterIndex: index,
                        initialPage: (progress as ComicProgress).page,
                      ),
              ),
            );
          }
        } else {
          await detail(
            source,
            SourceItem(
              id: item.itemId,
              title: item.title,
              cover: item.cover,
              subtitle: item.subtitle,
            ),
            library,
            progress,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('原来源暂不可用，记录已保留'),
            action: row.item == null
                ? null
                : SnackBarAction(
                    label: '搜索其他来源',
                    onPressed: () => alternative(row),
                  ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => opening = null);
        await load();
      }
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '继续看／读／听',
    actions: [
      IconButton(
        onPressed: load,
        tooltip: '刷新记录',
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: SettingsSurfaceList(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('汇总各板块最近进度。视频进入续播详情，漫画和小说继续原章节；记录仍保存在原板块。'),
        if (error != null) Text(error!),
        for (final library in locked)
          ListTile(
            title: Text('${library.section.label}记录已锁定'),
            leading: const Icon(Icons.lock),
            trailing: TextButton(
              onPressed: () async {
                if (await HistoryPrivacy.unlock(context, library) && mounted) {
                  unlocked[library.section] =
                      library.setting(HistoryPrivacy.lockKey) ?? '';
                  await load();
                }
              },
              child: const Text('解锁'),
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        if (!loading && rows.isEmpty && error == null)
          const ListTile(title: Text('暂无可显示的继续记录')),
        for (final row in rows)
          ListTile(
            leading: Icon(
              row.resource != null
                  ? Icons.headphones
                  : row.progress is VideoProgress
                  ? Icons.play_circle_outline
                  : Icons.menu_book,
            ),
            title: Text(row.item?.title ?? row.resource!.title),
            subtitle: Text(
              '${row.section.label} · ${row.progress?.describe() ?? '第 ${(row.audioPosition?['index'] ?? 0) + 1} 集 · 已听 ${((row.audioPosition?['position'] ?? 0) / 1000).floor()} 秒'}',
            ),
            trailing: opening == (row.resource?.id ?? row.item!.identity)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: () => open(row),
          ),
      ],
    ),
  );
}
