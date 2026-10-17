import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/player/player_stats.dart';
import 'player_speed_meter.dart';

/// 播放器 HUD：显示当前内核给出的解码与传输参数
/// （编码格式 / 分辨率 / 帧率 / 码率 / 缓冲状态）。
///
/// 只吃 [PlayerStats] 这一份抽象数据——不认识 AVPlayer、也不认识 libmpv，
/// 因此**换内核时这里一行都不用改**（宪法「播放器抽象架构规范」）。内核拿不到
/// 的项由 [PlayerStats.chips] 自动省略；一条都没有时整块不渲染。
class PlayerHud extends StatelessWidget {
  const PlayerHud({
    super.key,
    required this.stats,
    this.networkKbps,
    this.showDetails = true,
    this.showSpeed = true,
  });

  final bool showDetails;
  final bool showSpeed;
  final ValueListenable<PlayerStats> stats;
  final ValueListenable<int?>? networkKbps;

  @override
  Widget build(BuildContext context) {
    if (networkKbps != null) {
      return ValueListenableBuilder<int?>(
        valueListenable: networkKbps!,
        builder: (context, kbps, _) => _buildStats(kbps),
      );
    }
    return _buildStats(null);
  }

  Widget _buildStats(int? kbps) {
    return ValueListenableBuilder<PlayerStats>(
      valueListenable: stats,
      builder: (context, value, _) {
        final chips = <String>[
          if (showDetails && value.resolutionText != null)
            value.resolutionText!,
          if (showDetails && value.codecText != null) value.codecText!,
          if (showDetails && value.fpsText != null) value.fpsText!,
          if (showDetails && value.bitrateText != null) value.bitrateText!,
          // 速率只给数字（用户口径：去掉「网速」两个字）。量不出来时留一个占位，
          // 让这一格在采样前后不会忽然出现 / 消失。
          if (showSpeed) PlayerStatsInline.speedText(value, kbps) ?? '—',
        ];
        if (chips.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[for (final chip in chips) _HudChip(label: chip)],
          ),
        );
      },
    );
  }
}

/// 全屏顶栏后面那一排（用户口径）：分辨率与速率**横排**、落在片名后面，
/// 跟着控制浮层一起出现 / 收起。
///
/// 与左侧 [PlayerHud] 的区别：这里只要这两格，字色走顶栏那一套（白字 + 投影），
/// 因此不再用底色块——压在画面上已经够清楚，块状底会压住片名右侧的空间。
class PlayerStatsInline extends StatelessWidget {
  const PlayerStatsInline({
    super.key,
    required this.stats,
    this.networkKbps,
    this.stacked = false,
  });

  final bool stacked;

  final ValueListenable<PlayerStats> stats;
  final ValueListenable<int?>? networkKbps;

  /// 速率的显示文案：真实下载量优先（内核自己统计到的），其次源测速（本地探测），
  /// 都拿不到时返回 null（由调用方决定占位）。**不带「网速 / 源测速」前缀**。
  static String? speedText(PlayerStats stats, int? kbps) {
    if (stats.downloadBytesPerSecond != null) {
      return PlaybackSpeedMeter.describeBytes(stats.downloadBytesPerSecond!);
    }
    return PlaybackSpeedMeter.describe(kbps);
  }

  @override
  Widget build(BuildContext context) {
    final speed = networkKbps;
    if (speed == null) return _build(null);
    return ValueListenableBuilder<int?>(
      valueListenable: speed,
      builder: (context, kbps, _) => _build(kbps),
    );
  }

  Widget _build(int? kbps) {
    return ValueListenableBuilder<PlayerStats>(
      valueListenable: stats,
      builder: (context, value, _) {
        final labels = <String>[
          if (value.resolutionText != null) value.resolutionText!,
          if (speedText(value, kbps) != null) speedText(value, kbps)!,
        ];
        if (labels.isEmpty) return const SizedBox.shrink();
        final texts = labels
            .map(
              (label) => Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: LumeTypography.captionSize,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF8F8F8),
                  shadows: PlayerHudShadows.control,
                ),
              ),
            )
            .toList();
        if (stacked) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: texts,
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < texts.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Flexible(child: texts[i]),
            ],
          ],
        );
      },
    );
  }
}

/// 压在画面上的文字投影（顶栏与浮层控制共用一套，避免两处各写一份）。
class PlayerHudShadows {
  PlayerHudShadows._();

  static const List<Shadow> control = <Shadow>[
    Shadow(color: Color(0x59000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
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
            fontSize: LumeTypography.captionSize,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
