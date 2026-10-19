part of 'comic_reader_page.dart';

/// Each layer retains its own scroll position while a child menu is open.
class _ReaderMenuStack extends StatefulWidget {
  const _ReaderMenuStack({
    required this.initial,
    required this.title,
    required this.entries,
    required this.surface,
    required this.close,
    this.alignment = Alignment.topRight,
  });

  final String initial;
  final Alignment alignment;
  final String Function(String) title;
  final List<Widget> Function(String, ValueChanged<String>, VoidCallback)
  entries;
  final Widget Function(Widget) surface;
  final VoidCallback close;

  @override
  State<_ReaderMenuStack> createState() => _ReaderMenuStackState();
}

class _ReaderMenuStackState extends State<_ReaderMenuStack>
    with SingleTickerProviderStateMixin {
  late final List<String> _routes = [widget.initial];
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
    value: 1,
  );
  bool _returning = false;
  double _height = 580;
  Offset? _lastTap;
  final _offsets = <double>[0];

  void _open(String route) {
    if (_returning || _routes.contains(route)) return;
    setState(() {
      final minimum = math.min(220.0, _height * .7);
      final top = ((_lastTap?.dy ?? _offsets.last + 56) - 28).clamp(
        _offsets.last + 8,
        math.max(_offsets.last + 8, _height - minimum),
      );
      _routes.add(route);
      _offsets.add(top.toDouble());
    });
    _transition.forward(from: 0);
  }

  Future<void> _back() async {
    if (_returning) return;
    if (_routes.length == 1) {
      widget.close();
      return;
    }
    _returning = true;
    await _transition.reverse();
    if (!mounted) return;
    setState(() {
      _routes.removeLast();
      _offsets.removeLast();
      _returning = false;
      _transition.value = 1;
    });
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _routes.length == 1,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_back());
    },
    child: Listener(
      onPointerDown: (event) => _lastTap = event.localPosition,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _height = constraints.maxHeight;
          return AnimatedBuilder(
            animation: _transition,
            builder: (context, child) => Stack(
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < _routes.length; index++)
                  Positioned(
                    key: ValueKey(_routes[index]),
                    top: _offsets[index],
                    bottom: 0,
                    left: (_routes.length - index - 1) * 6,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: index != _routes.length - 1 || _returning,
                      child: ExcludeFocus(
                        excluding: index != _routes.length - 1,
                        child: ExcludeSemantics(
                          excluding: index != _routes.length - 1,
                          child: TweenAnimationBuilder<double>(
                            duration: const Duration(milliseconds: 180),
                            tween: Tween(
                              begin: 1,
                              end: index == _routes.length - 1 ? 1 : .94,
                            ),
                            builder: (context, scale, child) => Transform.scale(
                              scale: scale,
                              alignment: widget.alignment,
                              child: child,
                            ),
                            child: Opacity(
                              opacity: index == _routes.length - 1
                                  ? Curves.easeOut.transform(_transition.value)
                                  : .52,
                              child: Transform.translate(
                                offset: Offset(
                                  0,
                                  index == _routes.length - 1
                                      ? 14 * (1 - _transition.value)
                                      : 0,
                                ),
                                child: Align(
                                  alignment: widget.alignment,
                                  child: _ReaderMenuLayer(
                                    key: ValueKey('layer.${_routes[index]}'),
                                    active: index == _routes.length - 1,
                                    route: _routes[index],
                                    title: widget.title(_routes[index]),
                                    isRoot: index == 0,
                                    back: _back,
                                    surface: widget.surface,
                                    entries: widget.entries(
                                      _routes[index],
                                      _open,
                                      () => setState(() {}),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _ReaderMenuLayer extends StatefulWidget {
  const _ReaderMenuLayer({
    super.key,
    required this.route,
    required this.active,
    required this.title,
    required this.isRoot,
    required this.back,
    required this.surface,
    required this.entries,
  });
  final String route, title;
  final bool isRoot, active;
  final VoidCallback back;
  final Widget Function(Widget) surface;
  final List<Widget> entries;

  @override
  State<_ReaderMenuLayer> createState() => _ReaderMenuLayerState();
}

class _ReaderMenuLayerState extends State<_ReaderMenuLayer> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.surface(
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isRoot && ['main', 'direction'].contains(widget.route))
          Semantics(
            key: ValueKey(
              widget.active
                  ? 'comic.menu.active'
                  : 'comic.menu.parent.${widget.route}',
            ),
            label: widget.title,
            child: const SizedBox.shrink(),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 10, 12),
            child: Row(
              children: [
                LumeIcon(
                  switch (widget.route) {
                    'flags' => Icons.flag_outlined,
                    'bookmarks' => Icons.bookmark_border,
                    'voices' => Icons.record_voice_over_outlined,
                    'translation' => Icons.translate,
                    'reading' => Icons.vertical_align_bottom,
                    'zones' => Icons.touch_app_outlined,
                    _ => Icons.tune,
                  },
                  slot: 'comic_reader_menu.1',
                  variant: true,
                  size: 23,
                  fallback: widget.route == 'reading'
                      ? const ComicReaderVerticalFlowGlyph()
                      : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.title,
                    key: ValueKey(
                      widget.active
                          ? 'comic.menu.active'
                          : 'comic.menu.parent.${widget.route}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: widget.isRoot ? '关闭' : '返回',
                  onPressed: widget.back,
                  icon: const LumeIcon(
                    Icons.expand_more,
                    slot: 'comic_reader_menu.2',
                    size: 21,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
        ],
        Flexible(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            thickness: 3,
            radius: const Radius.circular(3),
            child: SingleChildScrollView(
              key: ValueKey('comic.menu.scroll.${widget.route}'),
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: widget.entries,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
      ],
    ),
  );
}
