import 'package:flutter/material.dart';

import '../../../core/theme/lume_theme.dart';
import 'danmaku_models.dart';
import 'danmaku_settings.dart';

/// 弹幕设置面板：开关、透明度、字号、显示区域、速度、描边、同屏上限。
///
/// 与播放器设置分开（文档要求：字幕参数与弹幕参数面板分开）。所有改动即时回调，
/// 播放页直接应用到叠加层——不需要「保存」按钮，所见即所得。
class DanmakuSettingsSheet extends StatefulWidget {
  const DanmakuSettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
    this.danmakuCount,
  });

  final DanmakuSettings settings;

  final ValueChanged<DanmakuSettings> onChanged;

  /// 本集弹幕条数（展示用）；为空时不显示这一行。
  final int? danmakuCount;

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  late DanmakuSettings _settings = widget.settings;

  void _update(DanmakuSettings next) {
    final clamped = next.clamped();
    setState(() => _settings = clamped);
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        '弹幕设置',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (widget.danmakuCount != null)
                      Text(
                        '本集 ${widget.danmakuCount} 条',
                        style: const TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '显示弹幕',
                    style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
                  ),
                  value: _settings.enabled,
                  onChanged: (value) => _update(_settings.copyWith(enabled: value)),
                ),
                _slider(
                  label: '不透明度',
                  value: _settings.opacity,
                  min: DanmakuSettings.minOpacity,
                  max: DanmakuSettings.maxOpacity,
                  display: '${(_settings.opacity * 100).round()}%',
                  onChanged: (value) => _update(_settings.copyWith(opacity: value)),
                ),
                _slider(
                  label: '字号',
                  value: _settings.fontScale,
                  min: DanmakuSettings.minFontScale,
                  max: DanmakuSettings.maxFontScale,
                  display: _settings.fontScale.toStringAsFixed(2),
                  onChanged: (value) => _update(_settings.copyWith(fontScale: value)),
                ),
                _slider(
                  label: '显示区域',
                  value: _settings.displayArea,
                  min: DanmakuSettings.minArea,
                  max: DanmakuSettings.maxArea,
                  display: '${(_settings.displayArea * 100).round()}%',
                  onChanged: (value) =>
                      _update(_settings.copyWith(displayArea: value)),
                ),
                _slider(
                  label: '滚动速度',
                  value: _settings.speedScale,
                  min: DanmakuSettings.minSpeed,
                  max: DanmakuSettings.maxSpeed,
                  display: '${_settings.speedScale.toStringAsFixed(1)}x',
                  onChanged: (value) =>
                      _update(_settings.copyWith(speedScale: value)),
                ),
                _slider(
                  label: '描边',
                  value: _settings.strokeWidth,
                  min: DanmakuSettings.minStroke,
                  max: DanmakuSettings.maxStroke,
                  display: _settings.strokeWidth.toStringAsFixed(1),
                  onChanged: (value) =>
                      _update(_settings.copyWith(strokeWidth: value)),
                ),
                _slider(
                  label: '同屏上限',
                  value: _settings.maxOnScreen.toDouble(),
                  min: DanmakuSettings.minOnScreen.toDouble(),
                  max: DanmakuSettings.maxOnScreenLimit.toDouble(),
                  display: '${_settings.maxOnScreen} 条',
                  divisions: (DanmakuSettings.maxOnScreenLimit -
                          DanmakuSettings.minOnScreen) ~/
                      10,
                  onChanged: (value) =>
                      _update(_settings.copyWith(maxOnScreen: value.round())),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _update(DanmakuSettings.defaults),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
              ),
            ),
            Text(
              display,
              style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions ?? 20,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// 发弹幕的输入弹窗：文本 + 位置（滚动 / 顶部 / 底部）。
///
/// 只把内容交回调用方（播放页负责写进本集弹幕并在屏幕上显示）——本组件不认识
/// 弹幕存储，也不联网。
class DanmakuComposeDialog extends StatefulWidget {
  const DanmakuComposeDialog({super.key});

  @override
  State<DanmakuComposeDialog> createState() => _DanmakuComposeDialogState();
}

class _DanmakuComposeDialogState extends State<DanmakuComposeDialog> {
  final TextEditingController _controller = TextEditingController();
  DanmakuMode _mode = DanmakuMode.scroll;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发一条弹幕'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(
                hintText: '说点什么…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => _submit(value),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final mode in DanmakuMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: _mode == mode,
                    onSelected: (_) => setState(() => _mode = mode),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('发送'),
        ),
      ],
    );
  }

  void _submit(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop((text: value, mode: _mode));
  }
}
