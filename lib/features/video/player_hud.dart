import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/player/player_stats.dart';

/// 播放器 HUD：显示当前内核给出的解码与传输参数
/// （编码格式 / 分辨率 / 帧率 / 码率 / 缓冲状态）。
///
/// 只吃 [PlayerStats] 这一份抽象数据——不认识 AVPlayer、也不认识 libmpv，
/// 因此**换内核时这里一行都不用改**（宪法「播放器抽象架构规范」）。内核拿不到
/// 的项由 [PlayerStats.chips] 自动省略；一条都没有时整块不渲染。
class PlayerHud extends StatelessWidget {
  const PlayerHud({super.key, required this.stats});

  final ValueListenable<PlayerStats> stats;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerStats>(
      valueListenable: stats,
      builder: (context, value, _) {
        final chips = value.chips;
        if (chips.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final chip in chips) _HudChip(label: chip),
            ],
          ),
        );
      },
    );
  }
}

/// 单个参数片段：半透明底 + 细描边，压在画面上不抢戏。
class _HudChip extends StatelessWidget {
  const _HudChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
