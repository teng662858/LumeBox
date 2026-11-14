import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/music/music_models.dart';
import '../../core/music/music_service.dart';
import '../../core/cat/cat_data_source.dart';
import '../../core/cat/cat_service.dart';
import '../../core/net/network_cancellation.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/network_owned_state.dart';
import '../comic/comic_detail_page.dart';
import '../music/music_page.dart';
import '../reading/section_toolbar.dart';
import '../video/video_detail_page.dart';
import '../video/video_player_page.dart';

class GlobalContentHit {
  const GlobalContentHit({
    required this.section,
    required this.hit,
    this.manager,
    this.kind,
  });
  final Section section;
  final SearchHit hit;
  final SourceManager? manager;
  final String? kind;
  String get label => kind == 'comic'
      ? '漫画'
      : section == Section.cat
      ? '视频'
      : section.label;
}

class GlobalSearchResults {
  const GlobalSearchResults({
    this.content = const [],
    this.music = const [],
    this.failures = const [],
  });
  final List<GlobalContentHit> content;
  final List<MusicTrack> music;
  final List<String> failures;
}

typedef GlobalSearch = Future<GlobalSearchResults> Function(String query);

Future<GlobalSearchResults> searchEverywhere(
  String query, {
  ValueChanged<GlobalSearchResults>? onProgress,
}) async {
  final batches = <Section, List<GlobalContentHit>>{};
  final failures = <String>[];
  List<MusicTrack> music = [];
  GlobalSearchResults snapshot() => GlobalSearchResults(
    content: [for (final section in Section.values) ...?batches[section]],
    music: List.of(music),
    failures: List.of(failures),
  );
  void publish() => onProgress?.call(snapshot());
  await Future.wait([
    for (final section in [Section.comic, Section.video])
      () async {
        try {
          final manager = LumeSources.manager(section);
          final sources = await LumeSources.list(section);
          final result = await AggregateSearch.run(
            sources: sources,
            open: manager.open,
            keyword: query,
            concurrency: 2,
            onProgress: (progress) {
              batches[section] = progress.hits
                  .map((hit) => GlobalContentHit(section: section, hit: hit))
                  .toList();
              publish();
            },
          );
          batches[section] = result.hits
              .map((hit) => GlobalContentHit(section: section, hit: hit))
              .toList();
          if (result.failed > 0) {
            failures.add('${section.label}：${result.failed} 个源搜索失败');
          }
        } catch (e) {
          if (e is NetworkCancelled) rethrow;
          failures.add('${section.label}：$e');
        }
        publish();
      }(),
    () async {
      try {
        final manager = CatAggregateSourceManager(CatService.instance);
        final sources = await manager.list();
        final kinds = {for (final site in manager.sites) site.id: site.kind};
        List<GlobalContentHit> hits(List<SearchHit> values) => [
          for (final hit in values)
            GlobalContentHit(
              section: Section.cat,
              hit: hit,
              manager: manager,
              kind: kinds[hit.sourceId],
            ),
        ];
        final result = await AggregateSearch.run(
          sources: sources,
          open: manager.open,
          keyword: query,
          concurrency: 2,
          onProgress: (progress) {
            batches[Section.cat] = hits(progress.hits);
            publish();
          },
        );
        batches[Section.cat] = hits(result.hits);
        if (result.failed > 0) {
          failures.add('TVBox / 猫源：${result.failed} 个源搜索失败');
        }
      } catch (e) {
        if (e is NetworkCancelled) rethrow;
        failures.add('TVBox / 猫源：$e');
      }
      publish();
    }(),
    () async {
      try {
        final result = await MusicService.instance.search(query);
        music = result.tracks;
        failures.addAll(result.failures);
      } catch (e) {
        if (e is NetworkCancelled) rethrow;
        failures.add('音乐：$e');
      }
      publish();
    }(),
  ]);
  return snapshot();
}

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, this.search = searchEverywhere});
  final GlobalSearch search;
  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage>
    with NetworkOwnedState<GlobalSearchPage> {
  final _query = TextEditingController();
  GlobalSearchResults _results = const GlobalSearchResults();
  String _filter = '全部', _submitted = '';
  bool _busy = false;
  int _revision = 0;
  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _submitted = query;
      _results = const GlobalSearchResults();
    });
    try {
      final results = await networkRequests.run(
        'global-search',
        () => widget.search == searchEverywhere
            ? searchEverywhere(
                query,
                onProgress: (results) {
                  if (mounted && revision == _revision) {
                    setState(() => _results = results);
                  }
                },
              )
            : widget.search(query),
      );
      if (mounted && revision == _revision) setState(() => _results = results);
    } catch (e) {
      if (e is! NetworkCancelled && mounted && revision == _revision) {
        setState(() => _results = GlobalSearchResults(failures: ['搜索失败：$e']));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _open(GlobalContentHit row) async {
    final section = row.section, hit = row.hit;
    try {
      final manager = row.manager ?? LumeSources.manager(section);
      final library = await ReadingLibrary.open(section);
      final target = ReadingTarget(
        sourceId: hit.sourceId,
        itemId: hit.item.id,
        title: hit.item.title,
        cover: hit.item.cover,
        subtitle: hit.item.subtitle,
      );
      Widget page;
      if (section == Section.comic || row.kind == 'comic') {
        page = ComicDetailPage(
          library: library,
          manager: manager,
          target: target,
        );
      } else {
        final source = await manager.open(hit.sourceId);
        if (source == null) throw StateError('源已停用或删除');
        page = VideoDetailPage(
          source: source,
          sourceId: hit.sourceId,
          manager: manager,
          item: hit.item,
          library: library,
          onPlay: (origin, media, playTarget, qualities, prelaunch) async {
            await Navigator.of(origin.context).push(
              MaterialPageRoute<void>(
                builder: (_) => VideoPlayerPage(
                  media: media,
                  title: playTarget.title,
                  target: playTarget,
                  sourceId: playTarget.sourceId,
                  source: origin.source,
                  sourceManager: manager,
                  library: library,
                  qualities: qualities,
                  prelaunch: prelaunch,
                ),
              ),
            );
          },
        );
      }
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _results.content
        .where((row) => _filter == '全部' || _filter == row.label)
        .toList();
    final music = _filter == '全部' || _filter == '音乐'
        ? _results.music
        : <MusicTrack>[];
    return GlassScaffold(
      title: '全局搜索',
      effectModule: GlassModule.search,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜索漫画、视频、小说、有声和音乐',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: _search,
                  icon: const Icon(Icons.arrow_forward),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: 16),
                for (final label in ['全部', '漫画', '视频', '音乐'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _filter == label,
                      onSelected: (_) => setState(() => _filter = label),
                    ),
                  ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_results.failures.isNotEmpty)
            ExpansionTile(
              title: Text('${_results.failures.length} 项搜索未完成'),
              children: [
                for (final error in _results.failures)
                  ListTile(dense: true, title: Text(error)),
              ],
            ),
          Expanded(
            child: content.isEmpty && music.isEmpty
                ? Center(
                    child: Text(
                      _busy
                          ? '正在搜索全部已启用源…'
                          : _submitted.isEmpty
                          ? '输入关键词，跨板块搜索所有已启用源'
                          : '未搜索到相关内容',
                    ),
                  )
                : ListView.builder(
                    itemCount: content.length + music.length,
                    itemBuilder: (context, index) {
                      if (index >= content.length) {
                        return MusicTrackTile(
                          track: music[index - content.length],
                          tracks: music,
                          index: index - content.length,
                        );
                      }
                      final row = content[index];
                      return ListTile(
                        leading: Icon(
                          row.section == Section.comic
                              ? Icons.auto_stories_outlined
                              : Icons.play_circle_outline,
                        ),
                        title: Text(row.hit.item.title),
                        subtitle: Text(
                          '${row.label} · ${row.hit.sourceName}${row.hit.item.subtitle?.isNotEmpty == true ? ' · ${row.hit.item.subtitle}' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(row),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
