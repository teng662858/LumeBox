import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/video_glass_surface.dart';
import 'player_layout.dart';
import 'danmaku/danmaku_panel.dart';
import 'video_episode_catalog.dart';

class PlayerSourceLine {
  const PlayerSourceLine(
    this.name, {
    this.current = false,
    this.available = true,
  });
  final String name;
  final bool current, available;
}

enum PlayerEpisodeView {
  grid('网格'),
  list('列表'),
  cover('封面');

  const PlayerEpisodeView(this.label);
  final String label;
}

enum PlayerSourceTab { episodes, lines, quality }

/// Chapters, source routes and media variants have distinct selection semantics.
class PlayerSourceSheet extends StatefulWidget {
  const PlayerSourceSheet({
    super.key,
    required this.address,
    this.qualities = const [],
    this.currentIndex = 0,
    this.onSelectQuality,
    this.loadEpisodes,
    this.currentChapterId,
    this.onSelectEpisode,
    this.onSwitchLine,
    this.loadLines,
    this.onSelectLine,
    this.initialTab = PlayerSourceTab.episodes,
    this.includeQualityTab = true,
    this.initialView = PlayerEpisodeView.grid,
    this.onViewChanged,
    this.artworkBuilder,
    this.fullBleed = false,
  });

  /// 竖屏抽屉铺满屏幕宽度：卡片贴边，只有工具条保留内边距。
  final bool fullBleed;
  final String address;
  final List<VideoQuality> qualities;
  final int currentIndex;
  final FutureOr<void> Function(int)? onSelectQuality;
  final Future<List<SourceChapter>> Function()? loadEpisodes;
  final String? currentChapterId;
  final Future<bool> Function(int)? onSelectEpisode;
  final VoidCallback? onSwitchLine;
  final Future<List<PlayerSourceLine>> Function()? loadLines;
  final Future<bool> Function(String)? onSelectLine;
  final PlayerSourceTab initialTab;
  final bool includeQualityTab;
  final PlayerEpisodeView initialView;
  final ValueChanged<PlayerEpisodeView>? onViewChanged;
  final Widget Function(BuildContext, SourceChapter, int)? artworkBuilder;

  @override
  State<PlayerSourceSheet> createState() => _PlayerSourceSheetState();
}

class _PlayerSourceSheetState extends State<PlayerSourceSheet> {
  Future<List<SourceChapter>>? _episodes;
  Future<List<PlayerSourceLine>>? _lines;
  late PlayerSourceTab _tab = widget.initialTab;
  late PlayerEpisodeView _view = widget.initialView;
  double _rowExtent = 52;
  final _scroll = ScrollController();
  bool _busy = false, _reverse = false, _located = false;
  String? _error;
  int? _pending;
  int _columns = 4, _segment = 0;
  List<SourceChapter> _chapters = [];
  bool get _qualityOnly => widget.initialTab == PlayerSourceTab.quality;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _select(int index, {bool quality = false, String? line}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pending = quality ? null : index;
      _error = null;
    });
    try {
      final bool ok;
      if (line != null) {
        ok = await widget.onSelectLine?.call(line) ?? false;
      } else if (quality) {
        await widget.onSelectQuality?.call(index);
        ok = true;
      } else {
        ok = await widget.onSelectEpisode?.call(index) ?? false;
      }
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = line != null ? '切换失败，请重试' : '切集失败，请重试');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = quality || line != null ? '切换失败，请重试' : '切集失败，请重试',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pending = null;
        });
      }
    }
  }

  void _locate(int index) {
    if (index < 0 || index >= _chapters.length) return;
    final orderedIndex = _reverse ? _chapters.length - 1 - index : index;
    final segment = orderedIndex ~/ 50;
    if (_segment != segment) setState(() => _segment = segment);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        ((orderedIndex % 50) ~/ _columns * _rowExtent).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
        duration: PlayerLayout.motion(context),
        curve: Curves.easeOutCubic,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _locateCurrent() =>
      _locate(_chapters.indexWhere((c) => c.id == widget.currentChapterId));

  Future<void> _jump() async {
    final controller = TextEditingController();
    final index = await showPlayerDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转集数'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: '第几集（1–${_chapters.length}）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= 1 && value <= _chapters.length) {
                Navigator.pop(context, value - 1);
              }
            },
            child: const Text('定位'),
          ),
        ],
      ),
    );
    // Dialog exit animation can still reference its controller.
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (mounted && index != null) _locate(index);
  }

  Widget _buildEpisodes() {
    _episodes ??= widget.loadEpisodes?.call();
    return FutureBuilder<List<SourceChapter>>(
      future: _episodes,
      builder: (context, snapshot) {
        if (_episodes == null) return const Center(child: Text('当前视频没有剧集列表'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton.icon(
              onPressed: () => setState(() {
                _located = false;
                _episodes = widget.loadEpisodes?.call();
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('剧集加载失败，点击重试'),
            ),
          );
        }
        _chapters = snapshot.data ?? [];
        if (_chapterCount != _chapters.length) {
          // 头部工具条要显示集数与分段，这里只同步一次，避免构建期改状态。
          final count = _chapters.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _chapterCount != count) {
              setState(() => _chapterCount = count);
            }
          });
        }
        if (_chapters.isEmpty) return const Center(child: Text('图源暂未提供剧集'));
        if (!_located) {
          _located = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _locateCurrent();
          });
        }
        final start = _segment * 50;
        final end = (start + 50).clamp(0, _chapters.length);
        return LayoutBuilder(
          builder: (context, bounds) {
            final media = MediaQuery.sizeOf(context);
            final portraitSheet = media.height > media.width;
            final longLabels = _chapters.any(
              (c) => VideoEpisodeCatalog.labelOf(c).length > 8,
            );
            final longest = [
              for (final (i, chapter) in _chapters.indexed)
                VideoEpisodeCatalog.displayLabel(chapter, i),
            ].reduce((a, b) => a.length >= b.length ? a : b);
            final measure = TextPainter(
              text: TextSpan(
                text: longest,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontSize: 13),
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            _columns = PlayerLayout.episodeColumns(
              bounds.maxWidth,
              longLabels: longLabels,
              labelWidth: measure.width,
            );
            measure.dispose();
            if (_view != PlayerEpisodeView.grid) {
              _columns = 1;
              // 卡片高度 = 行高 - 下方间距：列表 50 = 48 + 2，封面 82 = 78 + 4。
              _rowExtent = _view == PlayerEpisodeView.cover ? 82 : 50;
              return ListView.builder(
                key: ValueKey(_view),
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 12),
                itemExtent: _rowExtent,
                itemCount: end - start,
                itemBuilder: (context, visibleIndex) {
                  final orderedIndex = start + visibleIndex;
                  final index = _reverse
                      ? _chapters.length - 1 - orderedIndex
                      : orderedIndex;
                  final chapter = _chapters[index];
                  final current = chapter.id == widget.currentChapterId;
                  final colors = Theme.of(context).colorScheme;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: _view == PlayerEpisodeView.cover ? 4 : 2,
                    ),
                    child: Material(
                      color: current
                          ? colors.primary.withValues(alpha: .18)
                          : colors.surface.withValues(alpha: .12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: current
                              ? colors.primary
                              : colors.outlineVariant.withValues(alpha: .35),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _busy ? null : () => _select(index),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              if (_view == PlayerEpisodeView.cover) ...[
                                // 竖屏抽屉里的竖屏短剧封面多为 9:16，横着摆会被裁成一条。
                                SizedBox(
                                  width: portraitSheet ? 36 : 94,
                                  height: portraitSheet ? 64 : 56,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child:
                                        widget.artworkBuilder?.call(
                                          context,
                                          chapter,
                                          index,
                                        ) ??
                                        const ColoredBox(
                                          color: Color(0x22222222),
                                          child: Icon(Icons.movie_outlined),
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(
                                  VideoEpisodeCatalog.displayLabel(
                                    chapter,
                                    index,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: current
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: current
                                        ? colors.primary
                                        : colors.onSurface,
                                  ),
                                ),
                              ),
                              if (_pending == index)
                                const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (current)
                                Icon(
                                  Icons.play_arrow_rounded,
                                  color: colors.primary,
                                  semanticLabel: '播放中',
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            }
            _rowExtent = 52;
            return GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisExtent: 44,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: end - start,
              itemBuilder: (context, visibleIndex) {
                final orderedIndex = start + visibleIndex;
                final index = _reverse
                    ? _chapters.length - 1 - orderedIndex
                    : orderedIndex;
                final chapter = _chapters[index];
                final current = chapter.id == widget.currentChapterId;
                return Tooltip(
                  message: chapter.title,
                  child: ChoiceChip(
                    label: SizedBox(
                      width: double.infinity,
                      child: _pending == index
                          ? const Center(
                              child: SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Text(
                              VideoEpisodeCatalog.displayLabel(chapter, index),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    selected: current,
                    showCheckmark: false,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: current
                          ? LumeTheme.onAccentFillOf(context)
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    selectedColor: LumeTheme.accentFillOf(context),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    onSelected: _busy ? null : (_) => _select(index),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _variants() {
    if (widget.qualities.isEmpty) {
      return const Center(child: Text('当前片源未提供多画质选项'));
    }
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('按片源原始名称显示，切换后恢复当前进度', style: TextStyle(fontSize: 13)),
        ),
        for (var i = 0; i < widget.qualities.length; i++)
          ListTile(
            title: Text(widget.qualities[i].label),
            trailing: i == widget.currentIndex ? const Icon(Icons.check) : null,
            enabled: !_busy && widget.onSelectQuality != null,
            onTap: () => _select(i, quality: true),
          ),
      ],
    );
  }

  Widget _buildLines() {
    _lines ??= widget.loadLines?.call();
    return FutureBuilder<List<PlayerSourceLine>>(
      future: _lines,
      builder: (context, snapshot) {
        if (_lines != null &&
            snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => _lines = widget.loadLines?.call()),
              child: const Text('线路加载失败，点击重试'),
            ),
          );
        }
        final lines = snapshot.data ?? const <PlayerSourceLine>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '剧集线路',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              minVerticalPadding: 10,
              subtitle: Text('仅切换到对应集，保留当前进度和暂停状态'),
            ),
            const Divider(height: 20),
            for (final line in lines)
              ListTile(
                minVerticalPadding: 12,
                titleAlignment: ListTileTitleAlignment.center,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  line.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: line.current
                    ? const Text('当前线路')
                    : !line.available
                    ? const Text('没有对应集，请在详情页手动选择')
                    : null,
                enabled: !_busy && line.available,
                trailing: line.current ? const Icon(Icons.check) : null,
                onTap: () => line.current
                    ? Navigator.of(context).pop()
                    : _select(-1, line: line.name),
              ),
            if (lines.isEmpty && widget.onSwitchLine != null)
              ListTile(title: const Text('换线路继续看'), onTap: widget.onSwitchLine)
            else if (lines.isEmpty)
              const ListTile(title: Text('当前视频没有其他剧集线路')),
          ],
        );
      },
    );
  }

  int _chapterCount = 0;
  static const _jumpItem = -1;

  IconData get _viewIcon => switch (_view) {
    PlayerEpisodeView.grid => Icons.grid_view_rounded,
    PlayerEpisodeView.list => Icons.view_list_rounded,
    PlayerEpisodeView.cover => Icons.view_carousel_outlined,
  };

  void _cycleView() {
    final next = PlayerEpisodeView
        .values[(_view.index + 1) % PlayerEpisodeView.values.length];
    setState(() => _view = next);
    widget.onViewChanged?.call(next);
    _locateCurrent();
  }

  String _segmentLabel(int index) {
    final total = _chapterCount;
    final first = _reverse ? total - index * 50 : index * 50 + 1;
    final last = _reverse
        ? (total - index * 50 - 49).clamp(1, total)
        : (index * 50 + 50).clamp(1, total);
    return '$first–$last 集';
  }

  /// 除选集卡片本身，面板里的开关一律收成右上角 34 逻辑像素的小图标。
  Widget _toolIcon(
    IconData icon,
    String tooltip, {
    VoidCallback? onPressed,
    bool selected = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: _busy ? null : onPressed,
      icon: Icon(icon, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      // 走 ButtonStyle 的 IconButton 会忽略 constraints，必须把尺寸写进样式，
      // 否则默认 40×40 会把 8 个图标挤到第二行。
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        maximumSize: const Size(32, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        foregroundColor: selected ? colors.primary : colors.onSurfaceVariant,
        backgroundColor: selected
            ? colors.primary.withValues(alpha: .14)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _pickSegment(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        origin & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        if (_chapterCount > 50)
          for (var i = 0; i < (_chapterCount / 50).ceil(); i++)
            PopupMenuItem(value: i, child: Text(_segmentLabel(i))),
        if (_chapterCount > 50) const PopupMenuDivider(),
        // 跳转集数不再单独占图标，收进这个菜单里。
        const PopupMenuItem<int>(value: _jumpItem, child: Text('跳转到第几集…')),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == _jumpItem) {
      await _jump();
      return;
    }
    setState(() {
      _segment = picked;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// 信息卡走普通居中对话框：复用抽屉框会拉成一整条 40% 宽的白板。
  Future<void> _showPlaybackInfo() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('播放信息'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('播放地址', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          SelectableText(
            widget.address.isEmpty ? '尚未获取地址' : widget.address,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.address.trim().isEmpty
              ? null
              : () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.address.trim()),
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      duration: Duration(seconds: 1),
                      content: Text('已复制播放地址'),
                    ),
                  );
                },
          child: const Text('复制地址'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  /// 一行到底：左边集数，右边全部小图标；标题行与关闭按钮不再占位。
  Widget _buildToolbar() {
    final count =
        !_qualityOnly && _tab == PlayerSourceTab.episodes && _chapterCount > 0;
    return LayoutBuilder(
      builder: (context, box) {
        // 窄面板（最窄的 iPhone 横屏）优先保住一整排图标，集数让位。
        final showCount = count && box.maxWidth >= 320;
        return Row(
          children: [
            if (_qualityOnly)
              const Text(
                '画质',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              )
            else if (showCount)
              Text(
                '共 $_chapterCount 集',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 0,
                children: [
                  if (!_qualityOnly) ...[
                    for (final entry in [
                      (
                        PlayerSourceTab.episodes,
                        Icons.video_library_outlined,
                        '选集',
                      ),
                      (PlayerSourceTab.lines, Icons.alt_route, '线路'),
                      if (widget.includeQualityTab)
                        (PlayerSourceTab.quality, Icons.hd_outlined, '画质'),
                    ])
                      _toolIcon(
                        entry.$2,
                        entry.$3,
                        selected: _tab == entry.$1,
                        onPressed: () => setState(() {
                          _tab = entry.$1;
                          _error = null;
                        }),
                      ),
                    if (_tab == PlayerSourceTab.episodes) ...[
                      _toolIcon(
                        _viewIcon,
                        '视图：${_view.label}',
                        onPressed: _cycleView,
                      ),
                      _toolIcon(
                        Icons.swap_vert,
                        _reverse ? '倒序' : '正序',
                        onPressed: () {
                          setState(() => _reverse = !_reverse);
                          _locateCurrent();
                        },
                      ),
                      _toolIcon(
                        Icons.my_location,
                        '定位当前',
                        onPressed: _chapterCount == 0 ? null : _locateCurrent,
                      ),
                      if (_chapterCount > 0)
                        Builder(
                          builder: (anchor) => _toolIcon(
                            Icons.layers_outlined,
                            _chapterCount > 50
                                ? '分段：${_segmentLabel(_segment)}'
                                : '跳转到第几集',
                            onPressed: () => _pickSegment(anchor),
                          ),
                        ),
                    ],
                  ],
                  _toolIcon(
                    Icons.info_outline,
                    '播放信息',
                    onPressed: _showPlaybackInfo,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: VideoGlassScope.active(context)
        ? Colors.transparent
        : Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        widget.fullBleed ? 0 : 14,
        8,
        widget.fullBleed ? 0 : 16,
        8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.fullBleed ? 14 : 0,
            ),
            child: _buildToolbar(),
          ),
          const SizedBox(height: 4),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: widget.fullBleed ? 14 : 0,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Expanded(
            child: switch (_tab) {
              PlayerSourceTab.episodes => _buildEpisodes(),
              PlayerSourceTab.quality => _variants(),
              PlayerSourceTab.lines => _buildLines(),
            },
          ),
        ],
      ),
    ),
  );
}
