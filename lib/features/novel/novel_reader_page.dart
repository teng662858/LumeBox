import '../../shared/widgets/network_owned_state.dart';
import '../../core/source/source_content_type.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/speech/speech.dart';
import '../reading/speech_modes_panel.dart';
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
Iterable<int> novelPageOffsets(
  String text,
  TextStyle style,
  Size size,
  TextScaler scaler,
  TextDirection direction,
) sync* {
  yield 0;
  if (text.isEmpty || size.width <= 0 || size.height <= 0) return;
  var start = 0;
  while (start < text.length) {
    final painter = TextPainter(textDirection: direction, textScaler: scaler);
    try {
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
    } finally {
      painter.dispose();
    }
    if (start < text.length) yield start;
  }
}

List<int> novelPageStarts(
  String text,
  TextStyle style,
  Size size,
  TextScaler scaler,
  TextDirection direction,
) => novelPageOffsets(text, style, size, scaler, direction).toList();

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.source,
    required this.library,
    required this.target,
    required this.chapters,
    this.initialChapterIndex = 0,
    this.speechBackend,
  });
  final DataSource source;
  final ReadingLibrary library;
  final ReadingTarget target;
  final List<SourceChapter> chapters;
  final int initialChapterIndex;
  final SpeechBackend? speechBackend;
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
  String? _requestedLayout;
  bool _paginationComplete = false;
  int get _pageCount => _paginationComplete
      ? _starts.length
      : (_starts.length - 1).clamp(1, _starts.length);
  final _paginationCache = <String, List<int>>{};

  void _schedulePagination(
    String key,
    TextStyle style,
    Size size,
    TextScaler scaler,
    TextDirection direction,
  ) {
    if (_requestedLayout == key) return;
    _requestedLayout = key;
    _paginationComplete = false;
    final text = _text;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _requestedLayout != key) return;
      final cached = _paginationCache[key];
      final starts = <int>[];
      var painted = false;
      void publish(bool complete) {
        if (!mounted || _requestedLayout != key) return;
        setState(() {
          _starts = List.of(starts);
          _paginationComplete = complete;
          if (!painted) {
            _page = _starts
                .lastIndexWhere((start) => start <= _offset)
                .clamp(0, _starts.length - 1);
            final old = _controller;
            _controller = PageController(initialPage: _page);
            WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
            painted = true;
            _layoutKey = key;
          }
          _pageLabel.value =
              '${_page + 1} / $_pageCount${complete ? '' : '+'} 页';
        });
      }

      try {
        if (cached != null) {
          starts.addAll(cached);
          publish(true);
          return;
        }
        final watch = Stopwatch()..start();
        for (final start in novelPageOffsets(
          text,
          style,
          size,
          scaler,
          direction,
        )) {
          if (!mounted || _requestedLayout != key) return;
          starts.add(start);
          if (watch.elapsedMilliseconds >= 4) {
            // Restore by character offset before exposing the first visible pages.
            if (starts.last > _offset || painted) publish(false);
            await Future<void>.delayed(Duration.zero);
            watch.reset();
          }
        }
        if (!mounted || _requestedLayout != key) return;
        _paginationCache[key] = List.of(starts);
        while (_paginationCache.length > 3) {
          _paginationCache.remove(_paginationCache.keys.first);
        }
        publish(true);
      } catch (error) {
        if (mounted && _requestedLayout == key) {
          setState(() => _error = '$error');
        }
      }
    });
  }

  PageController? _controller;
  Timer? _saveTimer;
  final _pageLabel = ValueNotifier<String>('');
  late SpeechSettings _speechSettings;
  late SpeechSession _speech;
  bool _continueSpeech = false;
  bool _autoNext = true;
  void _speechChanged() {
    if (mounted) setState(() {});
  }

  void _speechPosition(int offset) {
    if (!mounted || !_speechSettings.followAlong || _starts.isEmpty) return;
    final page = _starts.lastIndexWhere((start) => start <= offset);
    if (page >= 0 && page != _page && (_controller?.hasClients ?? false)) {
      _controller!.jumpToPage(page);
    }
  }

  Future<void> _startSpeech() async {
    if (_loading || _error != null || _text.isEmpty) return;
    final backend = _speech.backend;
    if (backend is MethodChannelSpeechBackend) {
      backend.applySettings(_speechSettings);
    }
    final segments = SpeechSegments.split(
      _text,
      fromOffset: _offset,
      maxChars: _speechSettings.maxCharsPerSegment,
    );
    await _speech.setNowPlaying(
      title: widget.target.title,
      subtitle: widget.chapters[_chapter].title,
    );
    final error = await _speech.start(segments);
    if (mounted && error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _speechOptions() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('语速 ${(_speechSettings.rate / .5).toStringAsFixed(1)} 倍'),
                Slider(
                  value: _speechSettings.rate,
                  min: SpeechSettings.minRate,
                  max: SpeechSettings.maxRate,
                  onChanged: (value) {
                    _setSpeechSettings(_speechSettings.copyWith(rate: value));
                    update(() {});
                  },
                ),
                Text('音量 ${(_speechSettings.volume * 100).round()}%'),
                Slider(
                  value: _speechSettings.volume,
                  min: 0,
                  max: 1,
                  onChanged: (value) {
                    _setSpeechSettings(_speechSettings.copyWith(volume: value));
                    update(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('朗读跟随翻页'),
                  value: _speechSettings.followAlong,
                  onChanged: (value) {
                    _setSpeechSettings(
                      _speechSettings.copyWith(followAlong: value),
                    );
                    update(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('读完自动下一章'),
                  value: _autoNext,
                  onChanged: (value) {
                    setState(() => _autoNext = value);
                    widget.library.setSetting(
                      'novel.speech.autoNext',
                      '$value',
                    );
                    update(() {});
                  },
                ),
                SpeechModesPanel(
                  settings: _speechSettings,
                  onChanged: (value) {
                    _setSpeechSettings(value);
                    update(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setSpeechSettings(SpeechSettings value) {
    setState(() => _speechSettings = value);
    widget.library.setSetting(SpeechSettings.settingKey, value.encode());
    final backend = _speech.backend;
    if (backend is MethodChannelSpeechBackend) backend.applySettings(value);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speechSettings = SpeechSettings.decode(
      widget.library.setting(SpeechSettings.settingKey),
    );
    _autoNext = widget.library.setting('novel.speech.autoNext') != 'false';
    _speech = SpeechSession(
      backend: widget.speechBackend ?? createPlatformSpeechBackend(),
      onPosition: _speechPosition,
      onEvent: (event) {
        if (mounted && event.kind == SpeechEventKind.failed) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(event.message ?? '朗读失败，请检查语音设置')),
          );
        }
      },
      onCompleted: () {
        if (mounted && _autoNext && _chapter + 1 < widget.chapters.length) {
          _changeChapter(_chapter + 1, continueSpeech: true);
        }
      },
    );
    _speech.state.addListener(_speechChanged);
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
    _speech.state.removeListener(_speechChanged);
    unawaited(_speech.dispose());
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
    _requestedLayout = null;
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
      if (_continueSpeech) {
        _continueSpeech = false;
        await _startSpeech();
      }
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

  void _changeChapter(int index, {bool continueSpeech = false}) {
    if (index < 0 || index >= widget.chapters.length || index == _chapter) {
      return;
    }
    _saveTimer?.cancel();
    _continueSpeech = continueSpeech;
    if (!continueSpeech) unawaited(_speech.stop());
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
    final style = Theme.of(context).textTheme.bodyLarge!
        .copyWith(fontSize: _font, height: _height, color: foreground);
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
            if (_speech.isActive || _speech.isPaused || _continueSpeech)
              IconButton(
                onPressed: () {
                  _continueSpeech = false;
                  unawaited(_speech.stop());
                  setState(() {});
                },
                tooltip: '停止朗读',
                icon: const Icon(Icons.stop),
              ),
            IconButton(
              onPressed: _speechOptions,
              tooltip: '朗读设置',
              icon: const Icon(Icons.record_voice_over_outlined),
            ),
            IconButton(
              onPressed: _loading
                  ? null
                  : () async {
                      if (_speech.isActive) {
                        await _speech.pause();
                      } else if (_speech.isPaused) {
                        await _speech.resume();
                      } else {
                        await _startSpeech();
                      }
                    },
              tooltip: _speech.isActive ? '暂停朗读' : '朗读',
              icon: Icon(_speech.isActive ? Icons.pause : Icons.headphones),
            ),
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
                          '$_revision:${size.width}:${size.height}:$_font:$_height:${scaler.scale(_font)}:$direction:${style.fontFamily}:${style.fontWeight}:${style.fontStyle}';
                      if (_layoutKey != key) {
                        _schedulePagination(
                          key,
                          style,
                          size,
                          scaler,
                          direction,
                        );
                        return const Center(child: CircularProgressIndicator());
                      }
                      return PageView.builder(
                        key: ValueKey('$_revision:$key'),
                        controller: _controller,
                        itemCount: _pageCount,
                        onPageChanged: (index) {
                          setState(() {
                            _page = index;
                            _offset = _starts[index];
                            _pageLabel.value =
                                '${index + 1} / $_pageCount${_paginationComplete ? '' : '+'} 页';
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
