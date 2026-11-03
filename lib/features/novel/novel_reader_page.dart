import '../../shared/widgets/network_owned_state.dart';
import '../../core/source/source_content_type.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';

/// Preserve every UTF-16 offset while giving blank paragraph lines a compact
/// height. Pagination and painting must use this identical span tree.
TextSpan novelBodySpan(String text, TextStyle style) {
  final children = <InlineSpan>[];
  var cursor = 0;
  for (final match in RegExp(r'\n[ \t]*\n+').allMatches(text)) {
    children.add(TextSpan(text: text.substring(cursor, match.start + 1)));
    children.add(
      TextSpan(
        text: text.substring(match.start + 1, match.end),
        style: style.copyWith(fontSize: (style.fontSize ?? 20) * .4, height: 1),
      ),
    );
    cursor = match.end;
  }
  children.add(TextSpan(text: text.substring(cursor)));
  return TextSpan(style: style, children: children);
}

/// Paginate actual body text using the same dimensions/scaler as the rendered
/// page. Checkpoints are UTF-16 offsets, never screen-dependent page numbers.
List<int> novelPageStarts(
  String text,
  TextStyle style,
  Size size,
  TextScaler scaler,
  TextDirection direction,
) {
  if (text.isEmpty || size.width <= 0 || size.height <= 0) return [0];
  final starts = <int>[0];
  var start = 0;
  final painter = TextPainter(textDirection: direction, textScaler: scaler);
  try {
    while (start < text.length) {
      // Bound layout work for long chapters; grow only when the page fits.
      var limit = (start + 4096).clamp(0, text.length);
      while (true) {
        painter.text = novelBodySpan(text.substring(start, limit), style);
        painter.layout(maxWidth: size.width);
        if (painter.height > size.height || limit == text.length) break;
        limit = (limit + 4096).clamp(0, text.length);
      }
      if (painter.height <= size.height && limit == text.length) break;
      final lines = painter.computeLineMetrics();
      final fitting = lines
          .where((line) => line.baseline + line.descent <= size.height)
          .toList();
      if (fitting.isEmpty) throw StateError('字号过大，请调小字号或旋转屏幕');
      final line = fitting.last;
      final position = painter.getPositionForOffset(Offset(0, line.baseline));
      final boundary = painter.getLineBoundary(position);
      var next = start + boundary.end;
      if (next < text.length && text.codeUnitAt(next) == 10) next++;
      if (next < text.length &&
          next > start &&
          text.codeUnitAt(next) >= 0xDC00 &&
          text.codeUnitAt(next) <= 0xDFFF) {
        next--;
      }
      if (next <= start) throw StateError('当前屏幕无法容纳正文');
      start = next;
      if (start < text.length) starts.add(start);
    }
    return starts;
  } finally {
    painter.dispose();
  }
}

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.source,
    required this.library,
    required this.target,
    required this.chapters,
    this.initialChapterIndex = 0,
  });
  final DataSource source;
  final ReadingLibrary library;
  final ReadingTarget target;
  final List<SourceChapter> chapters;
  final int initialChapterIndex;
  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage>
    with WidgetsBindingObserver, NetworkOwnedState<NovelReaderPage> {
  late int _chapter;
  int _revision = 0, _offset = 0, _page = 0;
  String _text = '';
  String? _error;
  bool _loading = true;
  double _font = 20, _height = 1.5;
  int _theme = 0;
  List<int> _starts = [0];
  String? _layoutKey;
  PageController? _controller;
  Timer? _saveTimer;
  final _pageLabel = ValueNotifier<String>('');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chapter = widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    _font =
        (double.tryParse(widget.library.setting('novel.fontSize') ?? '') ?? 20)
            .clamp(14, 32);
    _height =
        (double.tryParse(widget.library.setting('novel.lineHeight') ?? '') ??
                1.5)
            .clamp(1.3, 2.3);
    _theme = (int.tryParse(widget.library.setting('novel.theme') ?? '') ?? 0)
        .clamp(0, 2);
    final saved = widget.library.progress(
      widget.target.itemId,
      sourceId: widget.target.sourceId,
    );
    if (saved is NovelProgress &&
        saved.chapterId == widget.chapters[_chapter].id) {
      _offset = saved.offset;
    }
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  @override
  void dispose() {
    _pageLabel.dispose();
    _revision++;
    _saveTimer?.cancel();
    _save();
    _controller?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    networkRequests.cancelAll();
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final content = await networkRequests.run(
        'chapter',
        () => SourceContentRead.read(
          widget.source,
          itemId: widget.target.itemId,
          chapterId: widget.chapters[_chapter].id,
        ),
      );
      if (!mounted || revision != _revision) return;
      if (content is! TextContent || content.text.trim().isEmpty) {
        throw StateError(
          content == null ? '本章暂无正文' : '本章返回的不是小说正文，请返回详情检查内容类型',
        );
      }
      setState(() {
        _text = content.text;
        _offset = _offset.clamp(0, _text.length - 1);
        _loading = false;
        _layoutKey = null;
      });
      _save();
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  void _save() {
    if (_loading || _error != null || _text.isEmpty) return;
    final chapter = widget.chapters[_chapter];
    widget.library.saveProgress(
      NovelProgress(
        section: widget.library.section,
        sourceId: widget.target.sourceId,
        itemId: widget.target.itemId,
        chapterIndex: _chapter,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        updatedAt: DateTime.now(),
        offset: _offset,
        textLength: _text.length,
      ),
    );
  }

  void _changeChapter(int index) {
    if (index < 0 || index >= widget.chapters.length || index == _chapter) {
      return;
    }
    _saveTimer?.cancel();
    _save();
    _chapter = index;
    _offset = 0;
    _load();
  }

  Future<void> _directory() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView.builder(
        itemCount: widget.chapters.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(widget.chapters[index].title),
          selected: index == _chapter,
          onTap: () => Navigator.pop(context, index),
        ),
      ),
    );
    if (selected != null && mounted) _changeChapter(selected);
  }

  void _settings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('字号 ${_font.round()}'),
                Slider(
                  value: _font,
                  min: 14,
                  max: 32,
                  divisions: 18,
                  onChanged: (value) {
                    setState(() => _font = value);
                    update(() {});
                    widget.library.setSetting('novel.fontSize', '$value');
                  },
                ),
                const Text('行距'),
                Slider(
                  value: _height,
                  min: 1.3,
                  max: 2.3,
                  divisions: 10,
                  onChanged: (value) {
                    setState(() => _height = value);
                    update(() {});
                    widget.library.setSetting('novel.lineHeight', '$value');
                  },
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('跟随系统')),
                    ButtonSegment(value: 1, label: Text('护眼')),
                    ButtonSegment(value: 2, label: Text('夜间')),
                  ],
                  selected: {_theme},
                  onSelectionChanged: (value) {
                    setState(() => _theme = value.first);
                    update(() {});
                    widget.library.setSetting('novel.theme', '$_theme');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark =
        _theme == 2 ||
        (_theme == 0 && Theme.of(context).brightness == Brightness.dark);
    final background = dark
        ? const Color(0xff17191d)
        : _theme == 1
        ? const Color(0xfff1e6ce)
        : Theme.of(context).colorScheme.surface;
    final foreground = dark ? const Color(0xffd4d2ca) : const Color(0xff302c27);
    final style = TextStyle(
      fontSize: _font,
      height: _height,
      color: foreground,
    );
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: background,
        appBarTheme: AppBarTheme(
          backgroundColor: background,
          foregroundColor: foreground,
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.chapters[_chapter].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              onPressed: _directory,
              tooltip: '目录',
              icon: const Icon(Icons.list),
            ),
            IconButton(
              onPressed: _settings,
              tooltip: '阅读设置',
              icon: const Icon(Icons.text_fields),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ),
              )
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final scaler = MediaQuery.textScalerOf(context);
                      final direction = Directionality.of(context);
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      final key =
                          '${size.width}:${size.height}:$_font:$_height:${scaler.scale(_font)}:$direction';
                      if (_layoutKey != key) {
                        try {
                          _starts = novelPageStarts(
                            _text,
                            style,
                            size,
                            scaler,
                            direction,
                          );
                        } catch (error) {
                          return Center(child: Text('$error'));
                        }
                        _page = _starts
                            .lastIndexWhere((start) => start <= _offset)
                            .clamp(0, _starts.length - 1);
                        final old = _controller;
                        _controller = PageController(initialPage: _page);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          old?.dispose();
                        });
                        _layoutKey = key;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            _pageLabel.value =
                                '${_page + 1} / ${_starts.length} 页';
                          }
                        });
                      }
                      return PageView.builder(
                        key: ValueKey('$_revision:$key'),
                        controller: _controller,
                        itemCount: _starts.length,
                        onPageChanged: (index) {
                          setState(() {
                            _page = index;
                            _offset = _starts[index];
                            _pageLabel.value =
                                '${index + 1} / ${_starts.length} 页';
                          });
                          _saveTimer?.cancel();
                          _saveTimer = Timer(
                            const Duration(milliseconds: 250),
                            _save,
                          );
                        },
                        itemBuilder: (context, index) => Align(
                          alignment: Alignment.topLeft,
                          child: Text.rich(
                            novelBodySpan(
                              _text.substring(
                                _starts[index],
                                index + 1 < _starts.length
                                    ? _starts[index + 1]
                                    : _text.length,
                              ),
                              style,
                            ),
                            textScaler: scaler,
                            textDirection: direction,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: _chapter == 0
                    ? null
                    : () => _changeChapter(_chapter - 1),
                child: const Text('上一章'),
              ),
              ValueListenableBuilder<String>(
                valueListenable: _pageLabel,
                builder: (context, label, _) => Text(
                  _loading ? '正在加载' : label,
                  style: TextStyle(color: foreground),
                ),
              ),
              TextButton(
                onPressed: _chapter + 1 >= widget.chapters.length
                    ? null
                    : () => _changeChapter(_chapter + 1),
                child: const Text('下一章'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
