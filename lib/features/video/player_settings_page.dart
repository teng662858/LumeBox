import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'player_kernel_picker.dart';

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
      behindBar: true,
      title: '播放器设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          const _SectionTitle('播放内核', '三套内核运行时可切换：AVPlayer / MPV / MDK（各有独立解码链）'),
          // 与全局设置的逃生入口共用同一份列表（同一个组件，不复制 UI）。
          PlayerKernelPicker(
            selected: _settings.kernel,
            catalog: widget.catalog,
            onChanged: (kernel) => _update(_settings.copyWith(kernel: kernel)),
            // 熔断中的 MPV 显示「重试」：清掉熔断标记后列表当场重新评估，
            // 用户不必为了再给 MPV 一次机会去重启应用。
            retryKernel: PlayerFactory.mpvInitFailed ? PlayerKernel.mpv : null,
            onRetry: _retryBurnedKernel,
          ),
          const SizedBox(height: 24),
          const _SectionTitle('播放倍速', '切换后立即生效，播放中不中断'),
          _buildSpeedPicker(),
          const SizedBox(height: 24),
          const _SectionTitle(
            '字幕',
            '开关 / 字号 / 颜色 / 描边 / 延迟（MPV 内核下字号、颜色、描边真实生效）',
          ),
          _buildSubtitleCard(),
          const SizedBox(height: 24),
          const _SectionTitle(
            '解码',
            '硬件解码（部分设备硬解 HEVC 花屏时可切软解）',
          ),
          _buildDecodingCard(),
        ],
      ),
    );
  }

  /// 硬件解码开关卡片。
  ///
  /// 如实标注「当前内核未开放写通道」：这个开关的状态会落库，但本次运行
  /// 仍按内核默认解码（见 `MpvEngine.setHardwareDecoding` 的说明）。
  /// 标注清楚比让用户以为「关了没效果 = 功能坏了」好。
  Widget _buildDecodingCard() {
    final enabled = _settings.hardwareDecoding;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '硬件解码',
                  style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (value) =>
                    _update(_settings.copyWith(hardwareDecoding: value)),
              ),
            ],
          ),
          Text(
            enabled ? '开启（默认）：优先硬解，省电且流畅' : '关闭：走软解',
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          const SizedBox(height: 6),
          Text(
            '当前内核未开放写解码属性的通道（media_kit 未暴露 libmpv 的 hwdec），'
            '因此本开关目前只记录状态、暂不影响解码；等通道就绪后自动生效。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }

  /// 重试被熔断的内核：清掉熔断标记并刷新列表。
  ///
  /// 只改「可用性」，不自动切换——重试是「允许再次选择它」，选不选由用户决定。
  void _retryBurnedKernel() {
    PlayerFactory.clearMpvInitFailure();
    setState(() {});
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
              Expanded(
                child: Text(
                  '显示字幕',
                  style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
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
          const SizedBox(height: 12),
          _chipRow(
            label: '颜色',
            enabled: enabled,
            children: <Widget>[
              for (final color in SubtitleColor.values)
                ChoiceChip(
                  label: Text(color.label),
                  selected: _settings.subtitleColor == color,
                  onSelected: enabled
                      ? (_) => _update(_settings.copyWith(subtitleColor: color))
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _chipRow(
            label: '描边',
            enabled: enabled,
            children: <Widget>[
              for (final outline in SubtitleOutline.values)
                ChoiceChip(
                  label: Text(outline.label),
                  selected: _settings.subtitleOutline == outline,
                  onSelected: enabled
                      ? (_) =>
                          _update(_settings.copyWith(subtitleOutline: outline))
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '延迟 ${_formatDelay(_settings.subtitleDelay)}',
            style: TextStyle(
              fontSize: 12,
              color: enabled
                  ? LumeTheme.textSecondary
                  : LumeTheme.muted.withValues(alpha: 0.5),
            ),
          ),
          Slider(
            value: _settings.subtitleDelay.inMilliseconds.toDouble(),
            min: PlayerSettings.minSubtitleDelay.inMilliseconds.toDouble(),
            max: PlayerSettings.maxSubtitleDelay.inMilliseconds.toDouble(),
            divisions: 200,
            label: _formatDelay(_settings.subtitleDelay),
            onChanged: enabled
                ? (value) => _update(
                      _settings.copyWith(
                        subtitleDelay: Duration(milliseconds: value.round()),
                      ),
                    )
                : null,
          ),
          Text(
            '字幕开关与字号 / 颜色 / 描边由内核消费（MPV 走 Flutter 字幕层，'
            '三项真实生效；AVPlayer 按系统样式渲染）。延迟与硬件解码当前内核'
            '未开放写通道，设置值会被记下并落库，等有通道时生效。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }

  /// 一行「标签 + 芯片组」。
  Widget _chipRow({
    required String label,
    required bool enabled,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: enabled
                ? LumeTheme.textSecondary
                : LumeTheme.muted.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: children),
      ],
    );
  }

  /// `-1.5s` / `0s` / `+2.0s`：带符号，正负一眼可辨。
  static String _formatDelay(Duration delay) {
    if (delay == Duration.zero) return '0s';
    final seconds = delay.inMilliseconds / 1000.0;
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
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
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }
}
