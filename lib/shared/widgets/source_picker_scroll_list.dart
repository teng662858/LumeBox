import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'source_card_metrics.dart';

/// Locates the active source once when a drawer opens. The estimated offset
/// materializes lazy children; the render viewport supplies the exact position.
class SourcePickerScrollList extends StatefulWidget {
  const SourcePickerScrollList({
    super.key,
    this.children = const [],
    this.itemBuilder,
    this.itemCount,
    this.focusKey,
    this.estimatedOffset = 0,
    this.padding = const EdgeInsets.only(bottom: 16),
  });
  final List<Widget> children;
  final IndexedWidgetBuilder? itemBuilder;
  final int? itemCount;
  final GlobalKey? focusKey;
  final double estimatedOffset;
  final EdgeInsets padding;

  @override
  State<SourcePickerScrollList> createState() => _SourcePickerScrollListState();
}

class _SourcePickerScrollListState extends State<SourcePickerScrollList> {
  late final _controller = ScrollController(
    keepScrollOffset: false,
    initialScrollOffset: widget.focusKey == null ? 0 : widget.estimatedOffset,
  );
  bool _pending = true, _scheduled = false;
  int _attempts = 0;

  void _scheduleFocus() {
    if (!_pending || _scheduled || widget.focusKey == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          !_pending ||
          widget.focusKey == null ||
          !_controller.hasClients) {
        return;
      }
      final target = widget.focusKey!.currentContext?.findRenderObject();
      if (target is RenderBox && target.attached && target.hasSize) {
        _pending = false;
        Scrollable.ensureVisible(
          widget.focusKey!.currentContext!,
          alignment: 0,
        );
        return;
      }
      if (++_attempts < 3) {
        _controller.jumpTo(
          widget.estimatedOffset.clamp(
            0.0,
            _controller.position.maxScrollExtent,
          ),
        );
        _scheduleFocus();
      } else {
        _pending = false;
      }
    });
  }

  @override
  void didUpdateWidget(covariant SourcePickerScrollList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusKey == null) _pending = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFocus();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Enough trailing space to put even the final source in the first row.
        final bottom = widget.focusKey == null
            ? widget.padding.bottom
            : math.max(
                widget.padding.bottom,
                constraints.maxHeight - SourceCardMetrics.height,
              );
        return NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null) _pending = false;
            return false;
          },
          child: ListView.builder(
            controller: _controller,
            primary: false,
            physics: const BouncingScrollPhysics(),
            padding: widget.padding.copyWith(bottom: bottom),
            itemCount: widget.itemCount ?? widget.children.length,
            itemBuilder: widget.itemBuilder ?? (_, i) => widget.children[i],
          ),
        );
      },
    );
  }
}
