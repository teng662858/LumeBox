import 'danmaku_models.dart';
import '../../../shared/widgets/native_glass_controls.dart';
import 'danmaku_panel.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';
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
    this.onTools,
    this.videoTitle,
    this.episodeTitle,
    this.serviceLabel,
    this.matchLabel,
    this.sourceCount = 0,
    this.publicCount = 0,
    this.loading = false,
    this.onClearMatch,
    this.preview = const [],
  });

  final DanmakuSettings settings;

  final ValueChanged<DanmakuSettings> onChanged;

  /// 本集弹幕条数（展示用）；为空时不显示这一行。
  final int? danmakuCount;
  final String? status;
  final VoidCallback? onMatch;
  final VoidCallback? onConfigureService;
  final VoidCallback? onReload, onClearMatch, onTools;
  final String? videoTitle, episodeTitle, serviceLabel, matchLabel;
  final int sourceCount, publicCount;
  final List<DanmakuItem> preview;
  final bool loading;

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  static const _hint = '连接成功只表示服务可访问；作品、集数和弹幕数量以本集加载结果为准。';

  Widget _sourcePanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final buttonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 42)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
      visualDensity: VisualDensity.compact,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '本集 ${widget.danmakuCount ?? 0} 条',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '源弹幕 ${widget.sourceCount} · 公共弹幕 ${widget.publicCount}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (widget.status?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Tooltip(
                      message: widget.status!,
                      child: Text(
                        widget.status!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                if (widget.matchLabel?.isNotEmpty == true)
                  Tooltip(
                    message: widget.matchLabel!,
                    child: Text(
                      '已关联：${widget.matchLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            if (widget.onMatch != null)
              Expanded(
                child: FilledButton.icon(
                  style: buttonStyle,
                  onPressed: widget.onMatch,
                  icon: const LumeIcon(
                    Icons.search,
                    slot: 'danmaku.match',
                    size: 16,
                  ),
                  label: const Text(
                    '匹配公共弹幕',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            if (widget.onMatch != null && widget.onReload != null)
              const SizedBox(width: 8),
            if (widget.onReload != null)
              Expanded(
                child: OutlinedButton.icon(
                  style: buttonStyle,
                  onPressed: widget.loading ? null : widget.onReload,
                  icon: const LumeIcon(
                    Icons.refresh,
                    slot: 'danmaku.reload',
                    size: 16,
                  ),
                  label: const Text(
                    '重新加载本集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
        if (widget.onTools != null)
          ListTile(
            title: const Text('自动匹配、链接、收藏与时间对齐'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onTools,
          ),
        ListTile(
          dense: true,
          minTileHeight: 52,
          minVerticalPadding: 0,
          contentPadding: EdgeInsets.zero,
          minLeadingWidth: 20,
          horizontalTitleGap: 8,
          leading: const LumeIcon(
            Icons.dns_outlined,
            slot: 'danmaku.service',
            size: 20,
          ),
          title: const Text('弹幕服务', style: TextStyle(fontSize: 15)),
          subtitle: Text(
            widget.serviceLabel ?? '选择官方或自定义 danmu 服务',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          trailing: const LumeIcon(
            Icons.chevron_right,
            slot: 'danmaku.service.next',
            size: 18,
          ),
          onTap: widget.onConfigureService,
        ),
        if (widget.onClearMatch != null &&
            widget.matchLabel?.isNotEmpty == true)
          TextButton(
            style: buttonStyle,
            onPressed: widget.onClearMatch,
            child: const Text('清除本集关联，重新匹配'),
          ),
        Text(
          _hint,
          style: TextStyle(
            fontSize: 12,
            height: 1.2,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DecoratedBox(
          key: const ValueKey('danmaku-episode-preview'),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '本集弹幕预览',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (widget.preview.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      widget.loading
                          ? '正在读取本集弹幕…'
                          : '本集暂无可预览的弹幕，可尝试手动匹配或更换弹幕服务。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                else
                  for (final item in widget.preview.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${item.time.inMinutes.toString().padLeft(2, '0')}:${(item.time.inSeconds % 60).toString().padLeft(2, '0')}  ${item.text}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '弹幕',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.videoTitle?.isNotEmpty == true)
                      Text(
                        [
                          widget.videoTitle!,
                          if (widget.episodeTitle?.isNotEmpty == true)
                            widget.episodeTitle!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: widget.settings.enabled,
                onChanged: (value) =>
                    widget.onChanged(widget.settings.copyWith(enabled: value)),
              ),
              IconButton(
                tooltip: '返回播放',
                onPressed: () => Navigator.pop(context),
                icon: const LumeIcon(
                  Icons.close,
                  slot: 'danmaku.close',
                  size: 22,
                ),
              ),
            ],
          ),
        ),
        const TabBar(
          labelPadding: EdgeInsets.symmetric(horizontal: 12),
          tabs: [
            Tab(height: 40, text: '来源与匹配'),
            Tab(height: 40, text: '显示样式'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _sourcePanel(context),
              SingleChildScrollView(
                child: DanmakuSettingsPanel(
                  settings: widget.settings,
                  onChanged: widget.onChanged,
                  showTitle: false,
                  showEnabled: false,
                  compact: true,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
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
    this.showEnabled = true,
    this.compact = false,
  });

  final DanmakuSettings settings;
  final ValueChanged<DanmakuSettings> onChanged;

  /// 本集弹幕条数（展示用）；为空时不显示这一行。
  final int? danmakuCount;

  /// 是否显示面板自己的标题（内嵌到播放器设置里时可以关掉，避免两级标题）。
  final bool showTitle;
  final bool showAvoidSubtitles;
  final bool showEnabled;
  final bool compact;

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
    final result = await showPlayerDialog<String>(
      context: context,
      onlyInPlayer: true,
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
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (result != null && mounted) {
      _update(_settings.copyWith(blockedWords: result.split('\n')));
    }
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: widget.compact,
        visualDensity: widget.compact
            ? VisualDensity.compact
            : VisualDensity.standard,
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
      padding: widget.compact
          ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
          : const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (widget.danmakuCount != null)
                  Text(
                    '本集 ${widget.danmakuCount} 条',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.descriptionSize,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (widget.showEnabled)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '显示弹幕',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.titleSize,
                  color: Theme.of(context).colorScheme.onSurface,
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
            '画中画显示弹幕（自动精简字号与密度）',
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
          Text(
            '排数控制轨道数量；每秒上限控制密度。滚动弹幕会在同一轨道保持间隔连续进入。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
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
            icon: const LumeIcon(
              Icons.restart_alt,
              slot: 'danmaku_settings_sheet.6',
              size: 18,
            ),
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
    if (widget.compact) {
      return SizedBox(
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: NativeGlassSlider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions ?? 20,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                display,
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }
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
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            Text(
              display,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        NativeGlassSlider(
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
