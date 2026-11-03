import '../reading/section_image.dart';
import '../../shared/widgets/network_owned_state.dart';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import 'novel_reader_page.dart';

class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({
    super.key,
    required this.source,
    required this.library,
    required this.target,
    this.imagePipeline,
  });
  final DataSource source;
  final ReadingLibrary library;
  final ReadingTarget target;
  final SectionImagePipeline? imagePipeline;
  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage>
    with NetworkOwnedState<NovelDetailPage> {
  late final SectionImagePipeline _pipeline;
  SourceDetail? _detail;
  String get _cover {
    final detailCover = _detail?.cover?.trim() ?? '';
    return detailCover.isNotEmpty
        ? detailCover
        : widget.target.cover?.trim() ?? '';
  }

  Map<String, String> get _coverHeaders =>
      _detail?.cover?.trim().isNotEmpty == true
      ? _detail!.coverHeaders
      : const {};

  List<SourceChapter> _chapters = [];
  String? _error;
  bool _loading = true, _reversed = false;
  String get _title => _detail?.title ?? widget.target.title;
  ReadingProgress? get _progress => widget.library.progress(
    widget.target.itemId,
    sourceId: widget.target.sourceId,
  );
  @override
  void initState() {
    super.initState();
    _pipeline =
        widget.imagePipeline ??
        SectionImagePipeline(
          cacheDir: widget.library.imageCacheDir,
          maxConcurrent: SectionImagePipeline.coverConcurrency,
          diskCache: SectionImagePipeline.diskCacheFor(widget.source.section),
        );
    _pipeline.bindSource(widget.source);
    _pipeline.bindSession(widget.source.section, widget.source.id);
    _load();
  }

  @override
  void dispose() {
    if (widget.imagePipeline == null) _pipeline.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    networkRequests.cancelAll();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await networkRequests.run(
        'detail',
        () => widget.source.detail(widget.target.itemId),
      );
      var chapters = await networkRequests.run(
        'chapters',
        () => widget.source.chapters(widget.target.itemId),
      );
      if (chapters.isEmpty) chapters = detail?.chapters ?? [];
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _chapters = chapters;
        _loading = false;
      });
      widget.library.recordHistoryItem(
        sourceId: widget.target.sourceId,
        itemId: widget.target.itemId,
        title: _title,
        cover: _cover.isEmpty ? null : _cover,
        subtitle: detail?.subtitle ?? widget.target.subtitle,
        chapterCount: chapters.length,
      );
      widget.library.syncChapters(
        widget.target.itemId,
        chapters.length,
        sourceId: widget.target.sourceId,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _read(int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelReaderPage(
          source: widget.source,
          library: widget.library,
          target: widget.target,
          chapters: _chapters,
          initialChapterIndex: index,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _shelve() {
    final library = widget.library, target = widget.target;
    if (library.onShelf(target.itemId, sourceId: target.sourceId)) {
      library.unshelve(target.itemId, sourceId: target.sourceId);
    } else {
      library.shelve(
        sourceId: target.sourceId,
        itemId: target.itemId,
        title: _title,
        cover: _cover.isEmpty ? null : _cover,
        subtitle: _detail?.subtitle ?? target.subtitle,
        chapterCount: _chapters.length,
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final saved = _progress;
    final resume = _chapters.indexWhere(
      (chapter) => chapter.id == saved?.chapterId,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('小说详情'),
        actions: [
          IconButton(
            onPressed: _shelve,
            tooltip: '收藏',
            icon: Icon(
              widget.library.onShelf(
                    widget.target.itemId,
                    sourceId: widget.target.sourceId,
                  )
                  ? Icons.favorite
                  : Icons.favorite_border,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _chapters.length + 1,
              itemBuilder: (context, position) {
                if (position == 0) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 100,
                              height: 148,
                              child: SectionImage(
                                key: const ValueKey('novel-detail-cover'),
                                pipeline: _pipeline,
                                url: _cover,
                                headers: _coverHeaders,
                                targetWidth:
                                    (100 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall,
                                  ),
                                  if (_detail?.author?.isNotEmpty == true)
                                    Text('作者：${_detail!.author}'),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_detail?.description?.isNotEmpty == true)
                          SelectableText(
                            TextContent.fromHtml(_detail!.description!).text,
                          ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _chapters.isEmpty
                              ? null
                              : () => _read(resume < 0 ? 0 : resume),
                          child: Text(
                            resume < 0
                                ? '开始阅读'
                                : '继续阅读 · ${saved!.chapterTitle}',
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(child: Text('目录 · ${_chapters.length} 章')),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _reversed = !_reversed),
                              child: Text(_reversed ? '倒序' : '正序'),
                            ),
                          ],
                        ),
                        if (_chapters.isEmpty) const Text('来源尚未提供章节'),
                      ],
                    ),
                  );
                }
                final index = _reversed
                    ? _chapters.length - position
                    : position - 1;
                return ListTile(
                  title: Text(_chapters[index].title),
                  selected: index == resume,
                  leading: Text('${index + 1}'),
                  onTap: () => _read(index),
                );
              },
            ),
    );
  }
}
