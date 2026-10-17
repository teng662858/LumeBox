import 'package:flutter/material.dart';

import '../../../core/theme/lume_theme.dart';
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
    this.status,
    this.onMatch,
    this.onConfigureService,
    this.onReload,
  });

  final DanmakuSettings settings;

  final ValueChanged<DanmakuSettings> onChanged;

  /// 本集弹幕条数（展示用）；为空时不显示这一行。
  final int? danmakuCount;
  final String? status;
  final VoidCallback? onMatch;
  final VoidCallback? onConfigureService;
  final VoidCallback? onReload;

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          // 面板内容与「播放器设置 → 弹幕」共用同一份（[DanmakuSettingsPanel]），
          // 两处不各写一套控件，免得改了这边忘了那边。
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: IconButton(
                    tooltip: '返回播放',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  title: const Text('弹幕设置'),
                  trailing: IconButton(
                    tooltip: '关闭弹幕设置',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.status != null)
                          ListTile(title: Text(widget.status!)),
                        if (widget.onMatch != null)
                          ListTile(
                            leading: const Icon(Icons.search),
                            title: const Text('匹配公共弹幕'),
                            onTap: widget.onMatch,
                          ),
                        if (widget.onConfigureService != null)
                          ListTile(
                            leading: const Icon(Icons.cloud_outlined),
                            title: const Text('弹幕服务地址'),
                            onTap: widget.onConfigureService,
                          ),
                        if (widget.onReload != null)
                          ListTile(
                            leading: const Icon(Icons.refresh),
                            title: const Text('重新加载弹幕'),
                            onTap: widget.onReload,
                          ),
                        DanmakuSettingsPanel(
                          settings: widget.settings,
                          onChanged: widget.onChanged,
                          danmakuCount: widget.danmakuCount,
                          showTitle: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹幕设置面板（可内嵌）：标题 + 开关 + 各项滑杆 + 屏蔽词。
///
/// 自持一份设置：改一项立即生效并回调宿主（宿主写库）。
class DanmakuSettingsPanel extends StatefulWidget {
  const DanmakuSettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.danmakuCount,
    this.showTitle = true,
    this.showAvoidSubtitles = true,
  });

  final DanmakuSettings settings;
  final ValueChanged<DanmakuSettings> onChanged;

  /// 本集弹幕条数（展示用）；为空时不显示这一行。
  final int? danmakuCount;

  /// 是否显示面板自己的标题（内嵌到播放器设置里时可以关掉，避免两级标题）。
  final bool showTitle;
  final bool showAvoidSubtitles;

  @override
  State<DanmakuSettingsPanel> createState() => _DanmakuSettingsPanelState();
}

class _DanmakuSettingsPanelState extends State<DanmakuSettingsPanel> {
  late DanmakuSettings _settings = widget.settings;

  @override
  void didUpdateWidget(covariant DanmakuSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
  }

  Future<void> _editBlockedWords() async {
    final controller = TextEditingController(
      text: _settings.blockedWords.join('\n'),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关键词屏蔽'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '每行一个词，包含该词的弹幕不显示'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && mounted) {
      _update(_settings.copyWith(blockedWords: result.split('\n')));
    }
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: LumeTypography.titleSize,
          ),
        ),
        value: value,
        onChanged: onChanged,
      );

  void _update(DanmakuSettings next) {
    final clamped = next.clamped();
    setState(() => _settings = clamped);
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.showTitle) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '弹幕设置',
                    style: TextStyle(
                      fontSize: LumeTypography.sectionTitleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ),
                if (widget.danmakuCount != null)
                  Text(
                    '本集 ${widget.danmakuCount} 条',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.descriptionSize,
                      color: LumeTheme.descriptionColor,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
          ] else if (widget.danmakuCount != null) ...<Widget>[
            Text(
              '本集 ${widget.danmakuCount} 条',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
            const SizedBox(height: 4),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '显示弹幕',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.titleSize,
                color: LumeTheme.textPrimary,
              ),
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
            display:
                '${(DanmakuStyle.baseFontSize * _settings.fontScale).round()} 号',
            onChanged: (value) => _update(_settings.copyWith(fontScale: value)),
          ),
          const Text(
            '显示范围',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.titleSize,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final rows in [1, 2, 3, 4, 5])
                ChoiceChip(
                  label: Text('$rows排'),
                  selected: _settings.rows == rows,
                  onSelected: (_) => _update(_settings.copyWith(rows: rows)),
                ),
              ChoiceChip(
                label: const Text('半屏'),
                selected: _settings.rows == 0 && _settings.displayArea == .5,
                onSelected: (_) =>
                    _update(_settings.copyWith(rows: 0, displayArea: .5)),
              ),
              ChoiceChip(
                label: const Text('全屏'),
                selected: _settings.rows == 0 && _settings.displayArea == 1,
                onSelected: (_) =>
                    _update(_settings.copyWith(rows: 0, displayArea: 1)),
              ),
            ],
          ),
          if (widget.showAvoidSubtitles)
            _switch(
              '避让底部字幕',
              _settings.avoidSubtitles,
              (value) => _update(_settings.copyWith(avoidSubtitles: value)),
            ),
          _switch(
            '画中画显示弹幕',
            _settings.pipEnabled,
            (value) => _update(_settings.copyWith(pipEnabled: value)),
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
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              '高级设置',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.titleSize,
              ),
            ),
            children: [
              _switch(
                '彩色弹幕',
                _settings.allowColored,
                (value) => _update(_settings.copyWith(allowColored: value)),
              ),
              _switch(
                '字体加粗',
                _settings.bold,
                (value) => _update(_settings.copyWith(bold: value)),
              ),
              _switch(
                '显示滚动弹幕',
                _settings.showScroll,
                (value) => _update(_settings.copyWith(showScroll: value)),
              ),
              _switch(
                '显示顶部弹幕',
                _settings.showTop,
                (value) => _update(_settings.copyWith(showTop: value)),
              ),
              _switch(
                '显示底部弹幕',
                _settings.showBottom,
                (value) => _update(_settings.copyWith(showBottom: value)),
              ),
              _switch(
                '合并重复弹幕',
                _settings.mergeDuplicates,
                (value) => _update(_settings.copyWith(mergeDuplicates: value)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('关键词屏蔽'),
                trailing: Text('${_settings.blockedWords.length} 个'),
                onTap: _editBlockedWords,
              ),
              _slider(
                label: '行间距',
                value: _settings.lineSpacing,
                min: 1,
                max: 3,
                display: _settings.lineSpacing.toStringAsFixed(2),
                onChanged: (value) =>
                    _update(_settings.copyWith(lineSpacing: value)),
              ),
              _slider(
                label: '每秒上限',
                value: _settings.maxPerSecond.toDouble(),
                min: 1,
                max: 30,
                divisions: 29,
                display: '${_settings.maxPerSecond} 条/秒',
                onChanged: (value) =>
                    _update(_settings.copyWith(maxPerSecond: value.round())),
              ),
              _slider(
                label: '时间校准',
                value: _settings.delayMs / 1000,
                min: -10,
                max: 10,
                divisions: 40,
                display: '${(_settings.delayMs / 1000).toStringAsFixed(1)} 秒',
                onChanged: (value) => _update(
                  _settings.copyWith(delayMs: (value * 1000).round()),
                ),
              ),
              const Text(
                '正值延后，负值提前',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.descriptionSize,
                ),
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
                divisions:
                    (DanmakuSettings.maxOnScreenLimit -
                        DanmakuSettings.minOnScreen) ~/
                    10,
                onChanged: (value) =>
                    _update(_settings.copyWith(maxOnScreen: value.round())),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _update(DanmakuSettings.defaults),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认'),
          ),
        ],
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
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.titleSize,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            Text(
              display,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                color: LumeTheme.muted,
              ),
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
