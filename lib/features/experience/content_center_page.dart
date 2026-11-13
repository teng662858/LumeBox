import '../video/video_player_settings.dart';
import '../video/video_episode_catalog.dart';
import '../video/playback_quality_preference.dart';
import 'tracking_resume.dart';
import '../../shared/widgets/glass_card.dart';

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../download/local_download_export.dart';
import '../../core/audio_book/audio_book_player.dart';
import '../../core/media/media_library.dart';
import '../media/media_resource_router.dart';
import 'tracking_service.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/experience/content_center.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_content_type.dart';
import '../comic/comic_detail_page.dart';
import '../comic/comic_reader_page.dart';
import '../novel/novel_reader_page.dart';
import '../video/video_player_page.dart';
import '../video/video_play_target.dart';
import '../video/source_playback.dart';
import '../../core/player/abstract_player.dart';

class ContentCenterPage extends StatefulWidget {
  const ContentCenterPage({
    super.key,
    this.initialTab = 0,
    this.initialReference,
    this.managerFor = LumeSources.manager,
  });
  final int initialTab;
  final String? initialReference;
  final SourceManager Function(Section) managerFor;
  @override
  State<ContentCenterPage> createState() => _ContentCenterPageState();
}

class _ContentCenterPageState extends State<ContentCenterPage> {
  final center = ContentCenter.instance;
  final libraries = <ReadingLibrary>[];
  bool checking = false;
  bool cancelled = false;
  String status = '';
  String clipFolder = '全部';
  List<Map<String, dynamic>> get visibleClips => center
      .rows('clips')
      .where(
        (v) =>
            ContentRef.parse(v['ref'])?.visible == true &&
            (clipFolder == '全部' || v['folder'] == clipFolder),
      )
      .toList();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      for (final section in Section.values) {
        libraries.add(await ReadingLibrary.open(section));
      }
      await AudioBookSettings.instance.load();
      await MediaLibrary.instance.boot();
      if (mounted) setState(() {});
      if (widget.initialReference != null) {
        final key = widget.initialReference;
        final target = unique
            .where((v) => ContentRef.of(v).key == key)
            .firstOrNull;
        if (target != null && mounted) {
          await run(() => open(ContentRef.of(target)));
        }
      }
    } catch (_) {
      if (mounted) setState(() => status = '本地记录读取失败，可返回后重试');
    }
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  List<({LibraryItem item, ReadingProgress progress})> get audioEntries {
    final entries = <({LibraryItem item, ReadingProgress progress})>[];
    final settings = AudioBookSettings.instance;
    for (final section in Section.values) {
      for (final resource in MediaLibrary.instance.entries(section)) {
        final saved = settings.positions[resource.id];
        if (resource.kind != ResourceKind.audioBook || saved == null) continue;
        final index = settings.indexFor(resource);
        entries.add((
          item: LibraryItem(
            section: section,
            itemId: resource.id,
            sourceId: '@audio-library',
            title: resource.title,
            chapterCount: resource.episodes.length,
            readChapterIndex: index,
            addedAt: DateTime.fromMillisecondsSinceEpoch(
              saved['updatedAt'] ?? 0,
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              saved['updatedAt'] ?? 0,
            ),
          ),
          progress: VideoProgress(
            section: section,
            sourceId: '@audio-library',
            itemId: resource.id,
            chapterIndex: index,
            chapterId:
                settings.chapterIds[resource.id] ??
                resource.episodes.elementAtOrNull(index)?.id ??
                '',
            chapterTitle: '听书',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              saved['updatedAt'] ?? 0,
            ),
            position: Duration(milliseconds: saved['position'] ?? 0),
          ),
        ));
      }
    }
    return entries;
  }

  List<LibraryItem> get entries => [
    ...audioEntries.map((v) => v.item),
    for (final lib in libraries) ...lib.history(limit: 10000),
    for (final lib in libraries) ...lib.favorites(),
  ];
  List<LibraryItem> get unique =>
      {for (final item in entries) ContentRef.of(item).key: item}.values
          .toList();
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作未完成，请检查源、网络或本地记录后重试')));
      }
    }
    if (mounted) setState(() {});
  }

  String _trackingResumeLabel(ContentRef ref) {
    final library = libraries
        .where((lib) => lib.section == ref.section)
        .firstOrNull;
    final progress = library?.progress(ref.item, sourceId: ref.source);
    return '${progress is VideoProgress ? '上次观看：${progress.chapterTitle} · ' : ''}${TrackingResume.label(progress is VideoProgress ? progress : null)}';
  }

  Future<void> open(
    ContentRef ref, {
    bool resume = true,
    bool nextUnwatched = false,
    int? chapter,
    String? chapterId,
    int? seconds,
    int? page,
  }) async {
    if (!ref.visible) {
      throw StateError('此内容已隐藏');
    }
    if (ref.source == '@audio-library') {
      final resource = MediaLibrary.instance
          .entries(ref.section)
          .where((r) => r.id == ref.item)
          .firstOrNull;
      if (resource == null) throw StateError('听书资源已移除或隐藏');
      if (!mounted) return;
      await openMediaResource(
        context,
        resource,
        index: chapterId == null
            ? chapter
            : TrackingResume.bookmarkIndex(
                resource.episodes.map((e) => e.id),
                chapterId,
              ),
        position: seconds == null ? null : Duration(seconds: seconds),
      );
      if (mounted) setState(() {});
      return;
    }
    final lib = await ReadingLibrary.open(ref.section);
    final manager = widget.managerFor(ref.section);
    final source = await manager.open(ref.source);
    if (source == null) throw StateError('源未安装或不可用');
    final target = ReadingTarget(
      sourceId: ref.source,
      itemId: ref.item,
      title: ref.title,
    );
    final progress = lib.progress(ref.item, sourceId: ref.source);
    Widget screen = ComicDetailPage(
      library: lib,
      manager: manager,
      target: target,
    );
    if (resume &&
        (progress != null ||
            chapter != null ||
            chapterId != null ||
            (nextUnwatched && ref.section == Section.video))) {
      var chapters = await VideoEpisodeCatalog.load(source, ref.item)
          .timeout(const Duration(seconds: 40));
      if (chapters.isEmpty) throw StateError('目录为空');
      if (ref.section == Section.video) {
        chapters = TrackingResume.episodes(
          chapters,
          progress is VideoProgress ? progress : null,
          chapterId: chapterId,
        );
        if (nextUnwatched) {
          final next = TrackingResume.index(
            chapters,
            progress is VideoProgress ? progress : null,
          );
          if (next < 0) throw StateError('当前线路暂无下一集，或上次剧集已变更，请在详情页选择');
          chapter = next;
        }
      }
      final saved = chapters.indexWhere((c) => c.id == progress?.chapterId);
      final index = chapterId != null
          ? TrackingResume.bookmarkIndex(chapters.map((c) => c.id), chapterId)
          : (chapter ?? (saved >= 0 ? saved : progress?.chapterIndex ?? 0))
                .clamp(0, chapters.length - 1);
      final explicitChapter = !nextUnwatched && (chapter != null || chapterId != null);
      final SourceContentType? type;
      if (page != null) {
        type = SourceContentType.comic;
      } else if (seconds != null) {
        type = SourceContentType.video;
      } else if (explicitChapter) {
        type = await detectSourceContent(
          source: source, itemId: ref.item, detail: null, chapters: [chapters[index]],
        ).timeout(const Duration(seconds: 40));
        if (type == null) throw const FormatException('书签对应的章节暂无内容');
      } else {
        type = switch (progress) {
          NovelProgress() => SourceContentType.novel,
          ComicProgress() => SourceContentType.comic,
          _ => SourceContentType.video,
        };
      }
      if (type == SourceContentType.novel) {
        screen = NovelReaderPage(
          source: source,
          library: lib,
          target: target,
          chapters: chapters,
          initialChapterIndex: index,
        );
      } else if (type == SourceContentType.comic) {
        screen = ComicReaderPage(
          library: lib,
          dataSource: source,
          target: target,
          chapters: chapters,
          initialChapterIndex: index,
          initialPage: page ?? (progress is ComicProgress &&
              progress.chapterId == chapters[index].id ? progress.page : 0),
        );
      } else {
        final content = await SourceContentRead.read(
          source, itemId: ref.item, chapterId: chapters[index].id,
        ).timeout(const Duration(seconds: 40));
        if (content is! VideoContent) throw const FormatException('此章节暂无可打开的内容');
        final qualities = SourcePlayback.contentQualities(
          content,
          source: source,
        );
        final selected = PlaybackQualityPreference.select(
          qualities,
          VideoPlayerSettingsStore(lib).load(),
        );
        final uri = selected?.url ?? SourcePlayback.contentAddress(content);
        if (uri == null) throw StateError('没有播放地址');
        screen = VideoPlayerPage(
          initialPosition: seconds == null
              ? null
              : Duration(seconds: seconds),
          media: PlayerMedia(
            uri: uri,
            headers:
                selected?.headers ??
                SourcePlayback.contentHeaders(content, source: source),
            title: ref.title,
          ),
          source: source,
          sourceManager: manager,
          library: lib,
          sourceId: ref.source,
          target: VideoPlayTarget(
            sourceId: ref.source,
            itemId: ref.item,
            title: ref.title,
            chapterIndex: index,
            chapterId: chapters[index].id,
            chapterTitle: chapters[index].title,
          ),
          qualities: qualities,
        );
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }

  Future<String?> ask(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Dialog route transition may still reference its controller.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<void> rules() async {
    final favorites = [for (final library in libraries) ...library.favorites()];
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('作品更新跳过规则'),
          content: SizedBox(
            width: 400,
            height: 360,
            child: ListView(
              children: [
                for (final item in favorites)
                  ListTile(
                    title: Text(item.title),
                    subtitle: Text(item.section.label),
                    trailing: DropdownButton<String>(
                      value: center.trackingState(ContentRef.of(item)),
                      items: const [
                        DropdownMenuItem(value: 'active', child: Text('正常更新')),
                        DropdownMenuItem(value: 'paused', child: Text('暂停追更')),
                        DropdownMenuItem(
                          value: 'completed',
                          child: Text('已完结跳过'),
                        ),
                      ],
                      onChanged: (v) => update(
                        () => center.setTrackingState(ContentRef.of(item), v!),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> check() async {
    if (checking) return;
    setState(() {
      checking = true;
      cancelled = false;
    });
    try {
      final report = await TrackingService.instance.check(
        libraries: libraries,
        onStatus: (value) {
          if (mounted) setState(() => status = value);
        },
        cancelled: () => cancelled || !mounted,
      );
      if (mounted) setState(() => status = report.summary);
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> link() async {
    final selected = <String>{};
    final items = unique;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('关联版本或原著／改编'),
          content: SizedBox(
            width: 400,
            height: 360,
            child: ListView(
              children: [
                for (final item in items)
                  CheckboxListTile(
                    title: Text(item.title),
                    subtitle: Text('${item.section.label} · ${item.sourceId}'),
                    value: selected.contains(ContentRef.of(item).key),
                    onChanged: (value) => update(() {
                      value == true
                          ? selected.add(ContentRef.of(item).key)
                          : selected.remove(ContentRef.of(item).key);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: selected.length < 2
                  ? null
                  : () async {
                      Navigator.pop(context);
                      final title = await ask('作品组名称');
                      if (title != null && title.trim().isNotEmpty) {
                        center.link(
                          title,
                          items
                              .where(
                                (v) => selected.contains(ContentRef.of(v).key),
                              )
                              .map(ContentRef.of)
                              .toList(),
                        );
                      }
                    },
              child: const Text('关联'),
            ),
          ],
        ),
      ),
    );
  }

  Widget row(
    ContentRef ref,
    String subtitle, {
    Widget? trailing,
    VoidCallback? tap,
  }) => ListTile(
    title: Text(ref.title, maxLines: 2),
    subtitle: Text(subtitle),
    onTap: tap ?? () => run(() => open(ref)),
    trailing: trailing,
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([center, ...libraries.map((l) => l.revision)]),
    builder: (context, _) {
      final recent =
          [
            ...audioEntries,
            for (final lib in libraries) ...lib.continueReading(limit: 100),
          ].where((v) => !center.hidden(ContentRef.of(v.item))).toList()..sort(
            (a, b) => b.progress.updatedAt.compareTo(a.progress.updatedAt),
          );
      final seenWorks = <String>{};
      recent.removeWhere(
        (entry) => !seenWorks.add(center.workKey(ContentRef.of(entry.item))),
      );
      return DefaultTabController(
        length: 4,
        initialIndex: widget.initialTab,
        child: GlassScaffold(
          effectModule: GlassModule.settings,
          title: '内容中心',
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '继续'),
              Tab(text: '追更'),
              Tab(text: '作品与版本'),
              Tab(text: '摘录'),
            ],
          ),
          child: TabBarView(
            children: [
              SettingsSurfaceList(
                children: [
                  if (recent.isEmpty)
                    const ListTile(title: Text('开始观看、阅读或收听后，记录会出现在这里')),
                  for (final entry in recent)
                    row(
                      ContentRef.of(entry.item),
                      '${entry.item.section.label} · ${entry.progress.describe()}',
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          final ref = ContentRef.of(entry.item);
                          if (action == 'hide') center.hide(ref, true);
                          if (action == 'versions' && mounted) {
                            await Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const ContentCenterPage(initialTab: 2),
                              ),
                            );
                          }
                          if (action == 'clip') {
                            final note = await ask('添加摘录／时间点备注');
                            if (note != null) {
                              center.clip(
                                ref,
                                text: note,
                                chapter: entry.progress.chapterIndex,
                                chapterId: entry.progress.chapterId,
                                seconds: entry.progress is VideoProgress
                                    ? (entry.progress as VideoProgress)
                                          .position
                                          .inSeconds
                                    : null,
                                page: entry.progress is ComicProgress
                                    ? (entry.progress as ComicProgress).page
                                    : null,
                              );
                            }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'versions',
                            child: Text('关联版本／原著'),
                          ),
                          PopupMenuItem(value: 'hide', child: Text('隐藏此条')),
                          PopupMenuItem(value: 'clip', child: Text('记录当前进度')),
                        ],
                      ),
                    ),
                  ListTile(
                    title: const Text('恢复隐藏条目'),
                    onTap: () => center.put('hidden', []),
                  ),
                ],
              ),
              SettingsSurfaceList(
                children: [
                  ListTile(
                    leading: const Icon(Icons.rule),
                    title: const Text('作品更新跳过规则'),
                    subtitle: const Text('暂停追更、已完结作品不请求；可随时恢复'),
                    onTap: rules,
                  ),
                  ListTile(
                    title: Text(checking ? '检查中' : '检查收藏更新'),
                    subtitle: Text(
                      status.isEmpty ? '逐源低频检查；15 分钟内不重复检查' : status,
                    ),
                    trailing: checking
                        ? IconButton(
                            onPressed: () => setState(() => cancelled = true),
                            icon: const Icon(Icons.stop),
                          )
                        : IconButton(
                            onPressed: check,
                            icon: const Icon(Icons.refresh),
                          ),
                  ),
                  SwitchListTile(
                    title: const Text('更新后下载新章节'),
                    value: center.enabled('downloadUpdates'),
                    onChanged: (v) => center.put('downloadUpdates', v),
                  ),
                  for (final update in center.rows('updates'))
                    if (ContentRef.parse(update['ref']) case final ref?
                        when ref.visible)
                      row(
                        ref,
                        '${update['count']} 个新章节 · ${update['latest']}\n${ref.section == Section.video
                            ? _trackingResumeLabel(ref)
                            : update['read'] == true
                            ? '已读'
                            : '未读'}',
                        tap: () {
                          run(() async {
                            await open(
                              ref,
                              nextUnwatched: ref.section == Section.video,
                            );
                            center.markRead('${update['id']}');
                          });
                        },
                        trailing: IconButton(
                          onPressed: () => center.markRead('${update['id']}'),
                          icon: Icon(
                            update['read'] == true
                                ? Icons.done_all
                                : Icons.done,
                          ),
                        ),
                      ),
                  if (center.rows('updates').isEmpty)
                    const ListTile(
                      title: Text('暂无更新记录'),
                      subtitle: Text('第一次检查建立目录基线；后续新增章节进入收件箱'),
                    ),
                ],
              ),
              SettingsSurfaceList(
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('关联作品与不同版本'),
                    subtitle: const Text('从历史或收藏选择，保留各来源进度；关联不合并或覆盖原记录'),
                    onTap: link,
                  ),
                  for (final group in center.rows('groups'))
                    ExpansionTile(
                      title: Text('${group['title']}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.link_off),
                        onPressed: () =>
                            center.remove('groups', '${group['id']}'),
                      ),
                      children: [
                        for (final raw in group['members'] as List)
                          if (ContentRef.parse(raw) case final ref?
                              when ref.visible)
                            row(
                              ref,
                              '${ref.section.label} · ${ref.source}',
                              trailing: const Icon(Icons.play_arrow),
                            ),
                      ],
                    ),
                ],
              ),
              SettingsSurfaceList(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: clipFolder,
                      items: [
                        for (final name in {
                          '全部',
                          ...center
                              .rows('clips')
                              .map((v) => '${v['folder'] ?? '默认'}'),
                        })
                          DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: (v) => setState(() => clipFolder = v!),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.ios_share),
                    title: const Text('导出当前收藏夹摘录'),
                    subtitle: const Text('保存为 JSON 文件，可保留作品身份与定位'),
                    onTap: () => run(() async {
                      final file = File(
                        '${(await getTemporaryDirectory()).path}/LumeBox-clips.json',
                      );
                      try {
                        await file.writeAsString(
                          const JsonEncoder.withIndent('  ')
                              .convert({'version': 1, 'clips': visibleClips}),
                          flush: true,
                        );
                        await LocalDownloadExport.file(file);
                      } finally {
                        if (await file.exists()) await file.delete();
                      }
                    }),
                  ),
                  ListTile(
                    title: const Text('复制全部摘录为 JSON'),
                    subtitle: const Text('可在“继续”页为当前进度添加摘录'),
                    trailing: const Icon(Icons.copy),
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: const JsonEncoder.withIndent('  ')
                              .convert(visibleClips),
                        ),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('已复制摘录')));
                      }
                    },
                  ),
                  for (final clip in visibleClips.reversed)
                    if (ContentRef.parse(clip['ref']) case final ref?
                        when ref.visible)
                      row(
                        ref,
                        '${clip['folder']} · ${clip['text']}',
                        tap: () => run(
                          () => open(
                            ref,
                            chapter: clip['chapter'] as int?,
                            chapterId: clip['chapterId'] as String?,
                            seconds: clip['seconds'] as int?,
                            page: clip['page'] as int?,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              center.remove('clips', '${clip['id']}'),
                        ),
                      ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
