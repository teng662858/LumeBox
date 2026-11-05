import 'package:flutter/material.dart';

import '../../core/reading/image_pipeline.dart';

/// Cover lists load visible tiles first and speculate only near the viewport.
/// Tiles outside the window stay as placeholders until scrolling brings them in.
class CoverViewport extends StatefulWidget {
  const CoverViewport({super.key, required this.child});
  final Widget child;

  static CoverViewportState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CoverViewportScope>()?.owner;

  @override
  State<CoverViewport> createState() => CoverViewportState();
}

class CoverViewportEntry {
  CoverViewportEntry({
    required this.context,
    required this.pipeline,
    required this.url,
    required this.width,
    required this.onVisible,
  });
  final BuildContext context;
  final SectionImagePipeline pipeline;
  final String url;
  final int? width;
  final VoidCallback onVisible;
  bool visible = false;
}

class CoverViewportState extends State<CoverViewport> {
  final _entries = <CoverViewportEntry>{};
  final _groups = <(SectionImagePipeline, int?)>{};
  bool _scheduled = false;
  bool _active = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _active) return;
    _active = active;
    if (!active) {
      for (final entry in _entries) {
        entry.visible = false;
      }
      for (final group in _groups) {
        if (!group.$1.isDisposed) {
          group.$1.replacePreloads(const [], targetWidth: group.$2);
        }
      }
      _groups.clear();
    } else {
      schedule();
    }
  }

  void register(CoverViewportEntry entry) {
    _entries.add(entry);
    schedule();
  }

  void unregister(CoverViewportEntry entry) {
    entry.visible = false;
    _entries.remove(entry);
    schedule();
  }

  void schedule() {
    if (_scheduled || !mounted || !_active) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _updateWindow();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _updateWindow() {
    if (!_active) return;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final visible = Offset.zero & viewport.size;
    final nearby = Rect.fromLTRB(
      visible.left,
      visible.top - visible.height / 2,
      visible.right,
      visible.bottom + visible.height,
    );
    final next = <(SectionImagePipeline, int?), List<String>>{};
    for (final entry in _entries.toList()) {
      final box = entry.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final bounds = MatrixUtils.transformRect(
        box.getTransformTo(viewport),
        Offset.zero & box.size,
      );
      final wasVisible = entry.visible;
      entry.visible = visible.overlaps(bounds);
      if (entry.visible && !wasVisible) entry.onVisible();
      if (nearby.overlaps(bounds) && entry.url.trim().isNotEmpty) {
        next
            .putIfAbsent((entry.pipeline, entry.width), () => [])
            .add(entry.url);
      }
    }
    for (final group in {..._groups, ...next.keys}) {
      if (!group.$1.isDisposed) {
        group.$1.replacePreloads(
          next[group] ?? const [],
          targetWidth: group.$2,
        );
      }
    }
    _groups
      ..clear()
      ..addAll(next.keys);
  }

  @override
  void dispose() {
    for (final group in _groups) {
      if (!group.$1.isDisposed) {
        group.$1.replacePreloads(const [], targetWidth: group.$2);
      }
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(CoverViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    schedule();
  }

  @override
  Widget build(BuildContext context) => _CoverViewportScope(
    owner: this,
    child: NotificationListener<ScrollNotification>(
      onNotification: (_) {
        schedule();
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          schedule();
          return false;
        },
        child: widget.child,
      ),
    ),
  );
}

class _CoverViewportScope extends InheritedWidget {
  const _CoverViewportScope({required this.owner, required super.child});
  final CoverViewportState owner;
  @override
  bool updateShouldNotify(_CoverViewportScope oldWidget) =>
      owner != oldWidget.owner;
}
