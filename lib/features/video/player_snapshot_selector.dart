import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/player/abstract_player.dart';

/// Rebuild controls only when their selected state changes, keeping progress local.
class PlayerSnapshotSelector<S> extends StatefulWidget {
  const PlayerSnapshotSelector({
    super.key,
    required this.snapshot,
    required this.select,
    required this.builder,
  });
  final ValueListenable<PlayerSnapshot> snapshot;
  final S Function(PlayerSnapshot) select;
  final Widget Function(BuildContext, PlayerSnapshot) builder;
  @override
  State<PlayerSnapshotSelector<S>> createState() =>
      _PlayerSnapshotSelectorState<S>();
}

class _PlayerSnapshotSelectorState<S> extends State<PlayerSnapshotSelector<S>> {
  late S _selected;
  void _changed() {
    final next = widget.select(widget.snapshot.value);
    if (next != _selected) setState(() => _selected = next);
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.select(widget.snapshot.value);
    widget.snapshot.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant PlayerSnapshotSelector<S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      oldWidget.snapshot.removeListener(_changed);
      widget.snapshot.addListener(_changed);
    }
    _selected = widget.select(widget.snapshot.value);
  }

  @override
  void dispose() {
    widget.snapshot.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.snapshot.value);
}
