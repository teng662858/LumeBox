import 'package:flutter/material.dart';

import '../../core/speech/speech.dart';

/// 听书面板：朗读控制 + 语速 / 音调 / 音量 + 跟读开关。
///
/// 面板只做「展示 + 回传意图」，不持有会话、不改设置存储——朗读状态与设置都在
/// 阅读器里（面板重建不影响朗读），这样切页签、换主题都不会打断朗读。
///
/// 不支持语音的平台（Android / Windows / 原生未接入）显示占位说明而不是
/// 隐藏入口：用户至少知道这个功能为什么用不了。
class NovelSpeechPanel extends StatelessWidget {
  const NovelSpeechPanel({
    super.key,
    required this.state,
    required this.settings,
    required this.chromeText,
    required this.secondary,
    required this.supported,
    required this.segmentIndex,
    required this.segmentCount,
    this.unavailableReason,
    required this.onToggle,
    required this.onStop,
    required this.onSeekSegment,
    required this.onSettingsChanged,
  });

  /// 当前朗读状态。
  final SpeechState state;

  /// 当前设置。
  final SpeechSettings settings;

  /// 面板文字色（跟随阅读主题，保证深色 / 浅色主题下都清楚）。
  final Color chromeText;
  final Color secondary;

  /// 平台是否支持朗读。
  final bool supported;

  /// 不支持时的原因（原生未接入 / 平台不支持）。
  final String? unavailableReason;

  /// 当前片段进度。
  final int segmentIndex;
  final int segmentCount;

  final VoidCallback onToggle;
  final VoidCallback onStop;
  final ValueChanged<int> onSeekSegment;
  final ValueChanged<SpeechSettings> onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    if (!supported) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.record_voice_over_outlined, size: 30, color: secondary),
            const SizedBox(height: 10),
            Text(
              unavailableReason ?? '当前平台不支持语音朗读',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: secondary),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      children: <Widget>[
        _buildTransport(),
        if (segmentCount > 0) _buildSegmentProgress(),
        const Divider(height: 20),
        _SliderRow(
          label: '语速',
          value: settings.rate,
          min: SpeechSettings.minRate,
          max: SpeechSettings.maxRate,
          display: '${settings.rate.toStringAsFixed(2)}x',
          chromeText: chromeText,
          secondary: secondary,
          onChanged: (value) =>
              onSettingsChanged(settings.copyWith(rate: value)),
        ),
        _SliderRow(
          label: '音调',
          value: settings.pitch,
          min: SpeechSettings.minPitch,
          max: SpeechSettings.maxPitch,
          display: settings.pitch.toStringAsFixed(2),
          chromeText: chromeText,
          secondary: secondary,
          onChanged: (value) =>
              onSettingsChanged(settings.copyWith(pitch: value)),
        ),
        _SliderRow(
          label: '音量',
          value: settings.volume,
          min: SpeechSettings.minVolume,
          max: SpeechSettings.maxVolume,
          display: '${(settings.volume * 100).round()}%',
          chromeText: chromeText,
          secondary: secondary,
          onChanged: (value) =>
              onSettingsChanged(settings.copyWith(volume: value)),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            '跟读翻页',
            style: TextStyle(fontSize: 13, color: chromeText),
          ),
          subtitle: Text(
            '朗读时自动翻到正在读的那一页',
            style: TextStyle(fontSize: 11, color: secondary),
          ),
          value: settings.followAlong,
          onChanged: (value) =>
              onSettingsChanged(settings.copyWith(followAlong: value)),
        ),
      ],
    );
  }

  /// 播放控制：开始 / 暂停 / 继续 + 停止。
  Widget _buildTransport() {
    final active = state == SpeechState.speaking || state == SpeechState.pausing;
    final paused = state == SpeechState.paused;
    final label = active
        ? '暂停'
        : paused
            ? '继续'
            : '开始朗读';
    final icon = active
        ? Icons.pause_circle_filled
        : paused
            ? Icons.play_circle_filled
            : Icons.play_circle_outline;

    return Row(
      children: <Widget>[
        FilledButton.icon(
          onPressed: onToggle,
          icon: Icon(icon, size: 20),
          label: Text(label),
        ),
        const SizedBox(width: 10),
        if (active || paused)
          OutlinedButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('停止'),
          ),
        const Spacer(),
        Text(
          state.label,
          style: TextStyle(fontSize: 12, color: secondary),
        ),
      ],
    );
  }

  /// 朗读进度：当前第几片 / 共几片，可拖动跳转。
  Widget _buildSegmentProgress() {
    final max = (segmentCount - 1).clamp(0, segmentCount).toDouble();
    return Row(
      children: <Widget>[
        Text('进度', style: TextStyle(fontSize: 12, color: secondary)),
        Expanded(
          child: Slider(
            value: segmentIndex.clamp(0, segmentCount - 1).toDouble(),
            min: 0,
            max: max <= 0 ? 1 : max,
            divisions: max <= 0 ? null : max.round(),
            onChanged: max <= 0
                ? null
                : (value) => onSeekSegment(value.round()),
          ),
        ),
        Text(
          '${segmentIndex + 1}/$segmentCount',
          style: TextStyle(fontSize: 12, color: secondary),
        ),
      ],
    );
  }
}

/// 一行滑杆：左标签、中滑杆、右数值。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.chromeText,
    required this.secondary,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final Color chromeText;
  final Color secondary;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: chromeText),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: secondary),
          ),
        ),
      ],
    );
  }
}

/// 朗读状态指示条：压在正文底部，显示「朗读中 · 第 n/m 片」与停止按钮。
///
/// 只在朗读 / 暂停时出现（不朗读时不占版面）。它只占自己那一小块：
/// [Align] 会把子项定位到底部中间，子项之外的触摸照常落到翻页手势上——
/// 因此读着书仍然能翻页（面板上的按钮除外）。
class NovelSpeechIndicator extends StatelessWidget {
  const NovelSpeechIndicator({
    super.key,
    required this.state,
    required this.segmentIndex,
    required this.segmentCount,
    required this.chromeSurface,
    required this.chromeText,
    required this.secondary,
    required this.onStop,
  });

  final SpeechState state;
  final int segmentIndex;
  final int segmentCount;
  final Color chromeSurface;
  final Color chromeText;
  final Color secondary;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (state != SpeechState.speaking &&
        state != SpeechState.pausing &&
        state != SpeechState.paused) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Material(
          color: chromeSurface,
          borderRadius: BorderRadius.circular(20),
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  state == SpeechState.paused
                      ? Icons.pause_circle_outline
                      : Icons.graphic_eq,
                  size: 16,
                  color: secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  state == SpeechState.paused
                      ? '已暂停'
                      : '朗读中 ${segmentIndex + 1}/$segmentCount',
                  style: TextStyle(fontSize: 12, color: chromeText),
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '停止朗读',
                  icon: Icon(Icons.close, size: 16, color: chromeText),
                  onPressed: onStop,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 听书入口图标：控制栏上的一个按钮。
IconData get novelSpeechIcon => Icons.headphones_outlined;

/// 阅读主题下的听书面板标题。
String get novelSpeechPanelTitle => '听书';
