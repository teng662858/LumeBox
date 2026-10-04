import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 播放器设置页：内核切换、倍速、字幕基础配置。
///
/// 受控页面：设置从 [settings] 进来，改动经 [onChanged] 出去（由视频页写库并
/// 立即应用到正在播放的内核）。页面自己不认识存储与平台——内核可用性问
/// [catalog]，因此注入替身即可在非 iOS 平台完整驱动这套交互。
class PlayerSettingsPage extends StatefulWidget {
  const PlayerSettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.catalog = const PlatformPlayerKernelCatalog(),
  });

  /// 进入页面时的当前设置。
  final PlayerSettings settings;

  /// 设置变更回调：每改一项调用一次，参数是完整的下一份设置。
  final ValueChanged<PlayerSettings> onChanged;

  /// 内核可用性目录。
  final PlayerKernelCatalog catalog;

  @override
  State<PlayerSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<PlayerSettingsPage> {
  late PlayerSettings _settings = widget.settings;

  void _update(PlayerSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: '播放器设置',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const _SectionTitle('播放内核', 'AVPlayer 与 MPV 运行时可切换；MDK 只预留接口（不可选）'),
          for (final kernel in PlayerKernel.values) _buildKernelTile(kernel),
          const SizedBox(height: 24),
          const _SectionTitle('播放倍速', '切换后立即生效，播放中不中断'),
          _buildSpeedPicker(),
          const SizedBox(height: 24),
          const _SectionTitle('字幕', '字幕基础配置（开关与字号）'),
          _buildSubtitleCard(),
        ],
      ),
    );
  }

  Widget _buildKernelTile(PlayerKernel kernel) {
    final available = widget.catalog.isAvailable(kernel);
    final reason = widget.catalog.unavailableReason(kernel);
    final selected = _settings.kernel == kernel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: available ? () => _update(_settings.copyWith(kernel: kernel)) : null,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    kernel.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: available ? Colors.white : LumeTheme.muted,
                    ),
                  ),
                  if (reason != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      reason,
                      style: const TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 20, color: Colors.white)
            else if (available)
              const Icon(
                Icons.radio_button_unchecked,
                size: 20,
                color: LumeTheme.muted,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final speed in PlayerSettings.speeds)
          ChoiceChip(
            label: Text('${_formatSpeed(speed)}x'),
            selected: _settings.speed == speed,
            onSelected: (_) => _update(_settings.copyWith(speed: speed)),
          ),
      ],
    );
  }

  Widget _buildSubtitleCard() {
    final enabled = _settings.subtitlesEnabled;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '显示字幕',
                  style: TextStyle(fontSize: 14, color: Colors.white),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (value) =>
                    _update(_settings.copyWith(subtitlesEnabled: value)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '字号',
            style: TextStyle(
              fontSize: 12,
              color: enabled ? LumeTheme.muted : LumeTheme.muted.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final size in SubtitleSize.values)
                ChoiceChip(
                  label: Text(size.label),
                  selected: _settings.subtitleSize == size,
                  onSelected: enabled
                      ? (_) => _update(_settings.copyWith(subtitleSize: size))
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '字幕开关由内核消费（MPV 走轨道选择，AVPlayer 按系统样式渲染）；'
            '字号仍待自研字幕层。',
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }

  /// 1.0 → `1`，0.75 → `0.75`：整数倍速不带小数，档位展示更干净。
  static String _formatSpeed(double speed) {
    return speed == speed.roundToDouble()
        ? speed.toStringAsFixed(0)
        : speed.toString();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.detail);

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }
}
