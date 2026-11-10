import '../../core/player/player_stats.dart';
import '../../core/player/playback_health.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';

/// A brief stall does not flash chrome; a sustained stall always has an exit.
class PlayerWaitingOverlay extends StatefulWidget {
  const PlayerWaitingOverlay({
    super.key,
    required this.snapshot,
    required this.onRetry,
    required this.onSwitchLine,
    this.operation,
    this.stats = PlayerStats.empty,
    this.locked = false,
  });

  final PlayerSnapshot snapshot;
  final PlayerStats stats;
  final String? operation;
  final bool locked;
  final VoidCallback onRetry, onSwitchLine;

  @override
  State<PlayerWaitingOverlay> createState() => _PlayerWaitingOverlayState();
}

class _PlayerWaitingOverlayState extends State<PlayerWaitingOverlay> {
  Timer? _delay, _stalled;
  bool _visible = false, _longWait = false;
  bool get _waiting =>
      widget.operation != null ||
      (widget.snapshot.buffering && widget.snapshot.error == null);

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant PlayerWaitingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operation != widget.operation ||
        oldWidget.snapshot.buffering != widget.snapshot.buffering ||
        oldWidget.snapshot.error != widget.snapshot.error) {
      _update();
    }
  }

  void _update() {
    _delay?.cancel();
    _stalled?.cancel();
    if (!_waiting) {
      _visible = _longWait = false;
      return;
    }
    _visible = widget.operation != null;
    _longWait = false;
    _delay = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _visible = true);
    });
    _stalled = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _longWait = true);
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _stalled?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_waiting || !_visible) return const SizedBox.shrink();
    return Center(
      child: Material(
        key: const Key('player-buffering-notice'),
        color: const Color(0xE61A2025),
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    widget.operation ??
                        (widget.snapshot.position == Duration.zero
                            ? '正在打开视频'
                            : '缓冲中'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                if (_longWait) ...[
                  const SizedBox(height: 8),
                  Text(
                    PlaybackHealth.describe(
                      widget.snapshot,
                      widget.stats,
                      operation: widget.operation,
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (widget.stats.buffered != null)
                    Text(
                      '已缓冲 ${(widget.stats.buffered!.inMilliseconds / 1000).toStringAsFixed(1)} 秒',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                const SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
                if (_longWait && !widget.locked) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '重试会保留当前进度，也可换线恢复',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        onPressed: widget.onRetry,
                        child: const Text(
                          '重试',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      TextButton(
                        onPressed: widget.onSwitchLine,
                        child: const Text(
                          '换线路',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
