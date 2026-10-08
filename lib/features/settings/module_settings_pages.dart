import 'package:flutter/material.dart';

import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/session/section_module_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../comic/comic_settings.dart';
import '../novel/novel_typesetting.dart';
import '../shell/shell_dock.dart';
import '../video/video_player_settings.dart';

/// 「各模块独立设置」入口页（全局设置里的一项）：四个板块各一个入口。
///
/// 口径（用户要求）：
/// - **相互隔离**：每个板块的参数存在自己的库里（见 [SectionModuleSettings] 的说明），
///   改其中一个不会动到别的；
/// - **双入口**：阅读页 / 播放页里的就地设置**保留**，与这里读写同一份数据；
/// - 四板块的页面结构一致（同样的五个可折叠分组），只是组内项按媒介裁剪。
class ModuleSettingsHubPage extends StatelessWidget {
  const ModuleSettingsHubPage({super.key});

  static const List<Section> sections = <Section>[
    Section.novel,
    Section.comic,
    Section.video,
    Section.cat,
  ];

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '各模块独立设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(
          EdgeInsets.fromLTRB(
            16,
            12,
            16,
            24 + ShellDockScope.bottomInset(context),
          ),
        ),
        children: <Widget>[
          for (final section in sections) ...<Widget>[
            _ModuleEntry(section: section),
            const SizedBox(height: 10),
          ],
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              '四个模块的参数**各存各的**（各板块自己的库），改一个不会影响另一个。\n'
              '阅读页 / 播放页里的就地设置保留着，和这里改的是同一份数值——'
              '哪边改，另一边立刻就是新值。',
              style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleEntry extends StatelessWidget {
  const _ModuleEntry({required this.section});

  final Section section;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SectionModuleSettingsPage(section: section),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(_iconFor(section), size: 20, color: LumeTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${section.label}设置',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitleFor(section),
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 20, color: LumeTheme.muted),
        ],
      ),
    );
  }

  static IconData _iconFor(Section section) => switch (section) {
        Section.novel => Icons.menu_book_outlined,
        Section.comic => Icons.auto_stories_outlined,
        Section.video => Icons.play_circle_outline_rounded,
        Section.cat => Icons.pets_outlined,
      };

  static String _subtitleFor(Section section) => switch (section) {
        Section.novel => '排版（字号 / 行距）、翻页方式、手势阈值、动画与控件尺寸',
        Section.comic => '阅读模式、边距、背景、点击行为、手势阈值、控件尺寸',
        Section.video => '播放行为（连播 / 倍速）、缓冲、手势灵敏度、控件尺寸',
        Section.cat => '浏览布局、手势阈值、动画与控件尺寸（猫源的播放沿用视频模块设置）',
      };
}

/// 单个板块的设置页：五个**可折叠分组**（用户口径：不要把所有项堆在一页）。
///
/// 组内数值来自各自的现有存储（漫画阅读设置 / 小说排版 / 播放设置 / 模块通用设置），
/// 因此与阅读页、播放页里的就地调整天然同步——同一份数据，两边都只是入口。
class SectionModuleSettingsPage extends StatefulWidget {
  const SectionModuleSettingsPage({super.key, required this.section});

  final Section section;

  @override
  State<SectionModuleSettingsPage> createState() =>
      _SectionModuleSettingsPageState();
}

class _SectionModuleSettingsPageState extends State<SectionModuleSettingsPage> {
  ReadingLibrary? _library;
  SectionModuleSettings _module = const SectionModuleSettings();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final library = await ReadingLibrary.open(widget.section);
      if (!mounted) return;
      setState(() {
        _library = library;
        _module = SectionModuleSettings.load(library);
      });
    } catch (error) {
      // 库打不开：界面照旧显示默认值，只记一条日志（本页是配置页，不该白屏）。
      debugPrint('[settings] ${widget.section.id} 模块设置库打不开：$error');
    }
  }

  void _update(SectionModuleSettings next) {
    setState(() => _module = next);
    _library?.let(next.save);
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    return GlassScaffold(
      behindBar: true,
      title: '${widget.section.label}设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(
          EdgeInsets.fromLTRB(
            16,
            12,
            16,
            24 + ShellDockScope.bottomInset(context),
          ),
        ),
        children: <Widget>[
          _Group(
            icon: Icons.widgets_outlined,
            title: 'UI 与控件',
            subtitle: '预制布局方案 + 控件尺寸 / 间距 / 动画（不开放自定义坐标）',
            children: _uiChildren(),
          ),
          _Group(
            icon: Icons.gesture,
            title: '手势 & 触发灵敏度',
            subtitle: '点击 / 滑动 / 长按的触发阈值',
            children: _gestureChildren(library),
          ),
          _Group(
            icon: Icons.format_shapes,
            title: '内容排版',
            subtitle: _layoutSubtitle(),
            children: _layoutChildren(library),
          ),
          _Group(
            icon: Icons.smart_toy_outlined,
            title: widget.section == Section.video ? '播放行为' : '阅读 / 播放行为',
            subtitle: _behaviorSubtitle(),
            children: _behaviorChildren(library),
          ),
          _Group(
            icon: Icons.tune,
            title: '高级',
            subtitle: '缓冲、预加载与「本地设置入口」说明',
            children: _advancedChildren(library),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 各分组内容

  List<Widget> _uiChildren() => <Widget>[
        _Row(
          label: '布局方案',
          hint: '整套页面布局取开发给的方案，避免自定义坐标把界面弄乱',
          child: SegmentedButton<ModuleLayoutPreset>(
            segments: <ButtonSegment<ModuleLayoutPreset>>[
              for (final preset in ModuleLayoutPreset.values)
                ButtonSegment<ModuleLayoutPreset>(
                  value: preset,
                  label: Text(preset.label, style: const TextStyle(fontSize: 11)),
                ),
            ],
            selected: <ModuleLayoutPreset>{_module.layoutPreset},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) =>
                _update(_module.withPreset(selection.first)),
          ),
        ),
        _Slider(
          label: '控件尺寸',
          value: _module.controlScale,
          min: SectionModuleSettings.minControlScale,
          max: SectionModuleSettings.maxControlScale,
          display: '${(_module.controlScale * 100).round()}%',
          onChanged: (value) => _update(_module.copyWith(controlScale: value)),
        ),
        _Slider(
          label: '间距',
          value: _module.spacingScale,
          min: SectionModuleSettings.minSpacingScale,
          max: SectionModuleSettings.maxSpacingScale,
          display: '${(_module.spacingScale * 100).round()}%',
          onChanged: (value) => _update(_module.copyWith(spacingScale: value)),
        ),
        _Switch(
          label: '界面动画',
          hint: '关掉后翻页 / 面板切换不做过渡动画（弱机更跟手）',
          value: _module.animationEnabled,
          onChanged: (value) =>
              _update(_module.copyWith(animationEnabled: value)),
        ),
      ];

  List<Widget> _gestureChildren(ReadingLibrary? library) => <Widget>[
        _Slider(
          label: '呼出工具栏延时',
          hint: '越大越不容易误触（面板不会一点就弹）',
          value: _module.toolbarToggleDelayMs.toDouble(),
          min: SectionModuleSettings.minToolbarToggleDelayMs.toDouble(),
          max: SectionModuleSettings.maxToolbarToggleDelayMs.toDouble(),
          divisions: 12,
          display: '${_module.toolbarToggleDelayMs}ms',
          onChanged: (value) => _update(
            _module.copyWith(toolbarToggleDelayMs: value.round()),
          ),
        ),
        _Slider(
          label: '双击判定窗口',
          value: _module.doubleTapWindowMs.toDouble(),
          min: SectionModuleSettings.minDoubleTapWindowMs.toDouble(),
          max: SectionModuleSettings.maxDoubleTapWindowMs.toDouble(),
          divisions: 8,
          display: '${_module.doubleTapWindowMs}ms',
          onChanged: (value) =>
              _update(_module.copyWith(doubleTapWindowMs: value.round())),
        ),
        _Slider(
          label: '滑动翻页阈值',
          value: _module.swipeTurnThresholdPx.toDouble(),
          min: SectionModuleSettings.minSwipeTurnThresholdPx.toDouble(),
          max: SectionModuleSettings.maxSwipeTurnThresholdPx.toDouble(),
          divisions: 16,
          display: '${_module.swipeTurnThresholdPx}px',
          onChanged: (value) =>
              _update(_module.copyWith(swipeTurnThresholdPx: value.round())),
        ),
        _Slider(
          label: '长按判定时长',
          value: _module.longPressMs.toDouble(),
          min: SectionModuleSettings.minLongPressMs.toDouble(),
          max: SectionModuleSettings.maxLongPressMs.toDouble(),
          divisions: 10,
          display: '${_module.longPressMs}ms',
          onChanged: (value) =>
              _update(_module.copyWith(longPressMs: value.round())),
        ),
        // 视频模块：播放器自带的手势灵敏度（拖进度 / 亮度 / 音量）也在这里，数据
        // 就是播放设置那一份，和播放页里的入口完全同步。
        if (widget.section == Section.video && library != null)
          _Slider(
            label: '播放手势灵敏度',
            hint: '播放器里左右滑动调亮度 / 音量、拖动进度的灵敏度',
            value: _videoSettings(library).gestureSensitivity,
            min: PlayerSettings.minGestureSensitivity,
            max: PlayerSettings.maxGestureSensitivity,
            display:
                '${_videoSettings(library).gestureSensitivity.toStringAsFixed(1)}×',
            onChanged: (value) => _updatePlayer(
              library,
              _videoSettings(library).copyWith(gestureSensitivity: value),
            ),
          ),
      ];

  String _layoutSubtitle() => switch (widget.section) {
        Section.novel => '字号 / 行距 / 段间距 / 页边距（与阅读器里的排版面板同一份数据）',
        Section.comic => '阅读模式 / 边距 / 背景 / 页间距（与阅读页底部面板同一份数据）',
        _ => '这个模块没有排版项（播放 / 浏览界面用固定排版）',
      };

  List<Widget> _layoutChildren(ReadingLibrary? library) {
    if (library == null) return <Widget>[const _Note('设置库还没就绪，稍后重试。')];
    if (widget.section == Section.novel) {
      final typesetting = NovelTypesetting.decode(
        library.setting(NovelTypesetting.settingKey),
      );
      return <Widget>[
        _Slider(
          label: '字号',
          value: typesetting.fontSize,
          min: NovelTypesetting.minFontSize,
          max: NovelTypesetting.maxFontSize,
          divisions: (NovelTypesetting.maxFontSize - NovelTypesetting.minFontSize)
              .round(),
          display: '${typesetting.fontSize.round()}pt',
          onChanged: (value) => _saveTypesetting(
            library,
            typesetting.copyWith(fontSize: value),
          ),
        ),
        _Slider(
          label: '行距',
          value: typesetting.lineHeight,
          min: NovelTypesetting.minLineHeight,
          max: NovelTypesetting.maxLineHeight,
          display: typesetting.lineHeight.toStringAsFixed(2),
          onChanged: (value) => _saveTypesetting(
            library,
            typesetting.copyWith(lineHeight: value),
          ),
        ),
        _Slider(
          label: '段间距',
          value: typesetting.paragraphSpacing,
          min: NovelTypesetting.minParagraphSpacing,
          max: NovelTypesetting.maxParagraphSpacing,
          display: typesetting.paragraphSpacing.round().toString(),
          onChanged: (value) => _saveTypesetting(
            library,
            typesetting.copyWith(paragraphSpacing: value),
          ),
        ),
        _Slider(
          label: '页边距',
          value: typesetting.margin,
          min: NovelTypesetting.minMargin,
          max: NovelTypesetting.maxMargin,
          display: typesetting.margin.round().toString(),
          onChanged: (value) => _saveTypesetting(
            library,
            typesetting.copyWith(margin: value),
          ),
        ),
      ];
    }
    if (widget.section == Section.comic) {
      final comic = ComicReaderSettings.load(library);
      return <Widget>[
        _Row(
          label: '阅读模式',
          child: SegmentedButton<ComicReadingMode>(
            segments: <ButtonSegment<ComicReadingMode>>[
              for (final mode in ComicReadingMode.values)
                ButtonSegment<ComicReadingMode>(
                  value: mode,
                  label: Text(mode.label, style: const TextStyle(fontSize: 11)),
                ),
            ],
            selected: <ComicReadingMode>{comic.mode},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) => _saveComic(
              library,
              comic.copyWith(mode: selection.first),
            ),
          ),
        ),
        _Slider(
          label: '侧边距',
          value: comic.marginRatio,
          min: 0,
          max: ComicReaderSettings.maxMarginRatio,
          divisions: 10,
          display: '${(comic.marginRatio * 100).round()}%',
          onChanged: (value) =>
              _saveComic(library, comic.copyWith(marginRatio: value)),
        ),
        _Slider(
          label: '页间距',
          value: comic.pageGap,
          min: 0,
          max: ComicReaderSettings.maxPageGap,
          divisions: 12,
          display: comic.pageGap.round().toString(),
          onChanged: (value) =>
              _saveComic(library, comic.copyWith(pageGap: value)),
        ),
        _Row(
          label: '背景',
          child: SegmentedButton<ComicReaderBackground>(
            segments: <ButtonSegment<ComicReaderBackground>>[
              for (final background in ComicReaderBackground.values)
                ButtonSegment<ComicReaderBackground>(
                  value: background,
                  label:
                      Text(background.label, style: const TextStyle(fontSize: 11)),
                ),
            ],
            selected: <ComicReaderBackground>{comic.background},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) => _saveComic(
              library,
              comic.copyWith(background: selection.first),
            ),
          ),
        ),
      ];
    }
    return <Widget>[const _Note('这个模块没有排版项。')];
  }

  String _behaviorSubtitle() => switch (widget.section) {
        Section.novel => '翻页方式、预加载（阅读器里的设置同一份数据）',
        Section.comic => '点击行为、翻页方向、预加载半径（阅读页面板同一份数据）',
        Section.video => '切集连播、倍速、跳过片头片尾（播放页设置同一份数据）',
        Section.cat => '猫源沿用视频模块的播放行为；本页只管浏览与手势',
      };

  List<Widget> _behaviorChildren(ReadingLibrary? library) {
    if (library == null) return <Widget>[const _Note('设置库还没就绪，稍后重试。')];
    if (widget.section == Section.comic) {
      final comic = ComicReaderSettings.load(library);
      return <Widget>[
        _Row(
          label: '点击行为',
          child: SegmentedButton<ComicTapAction>(
            segments: <ButtonSegment<ComicTapAction>>[
              for (final action in ComicTapAction.values)
                ButtonSegment<ComicTapAction>(
                  value: action,
                  label:
                      Text(action.label, style: const TextStyle(fontSize: 11)),
                ),
            ],
            selected: <ComicTapAction>{comic.tapAction},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) => _saveComic(
              library,
              comic.copyWith(tapAction: selection.first),
            ),
          ),
        ),
        _Row(
          label: '翻页方向',
          child: SegmentedButton<ComicReadingDirection>(
            segments: <ButtonSegment<ComicReadingDirection>>[
              for (final direction in ComicReadingDirection.values)
                ButtonSegment<ComicReadingDirection>(
                  value: direction,
                  label:
                      Text(direction.label, style: const TextStyle(fontSize: 11)),
                ),
            ],
            selected: <ComicReadingDirection>{comic.direction},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) => _saveComic(
              library,
              comic.copyWith(direction: selection.first),
            ),
          ),
        ),
        _Slider(
          label: '预加载半径',
          value: comic.preloadRadius.toDouble(),
          min: 0,
          max: ComicReaderSettings.maxPreloadRadius.toDouble(),
          divisions: ComicReaderSettings.maxPreloadRadius,
          display: '${comic.preloadRadius}',
          onChanged: (value) =>
              _saveComic(library, comic.copyWith(preloadRadius: value.round())),
        ),
      ];
    }
    if (widget.section == Section.video) {
      // 播放行为与播放页**同一份数据**：这里只是另一个入口，改哪边都同步。
      final player = _videoSettings(library);
      return <Widget>[
        _Switch(
          label: '自动连播',
          hint: '一集播完自动进下一集（时长未知时不跳）',
          value: player.autoNext,
          onChanged: (value) => _updatePlayer(
            library,
            player.copyWith(autoNext: value),
          ),
        ),
        _Slider(
          label: '默认倍速',
          hint: '按内核分别记住（这里改的是当前内核那一份）',
          value: player.speed,
          min: PlayerSettings.minSpeed,
          max: PlayerSettings.maxSpeed,
          display: '${player.speed.toStringAsFixed(2)}×',
          onChanged: (value) =>
              _updatePlayer(library, player.copyWith(speed: value)),
        ),
      ];
    }
    return <Widget>[const _Note('这个模块没有额外的行为项。')];
  }

  List<Widget> _advancedChildren(ReadingLibrary? library) {
    final children = <Widget>[];
    if (widget.section == Section.video) {
      children.add(
        _Slider(
          label: '前向缓冲',
          hint: '0 = 交给播放内核自动决定（起播最快）',
          value: _module.bufferSeconds.toDouble(),
          min: 0,
          max: SectionModuleSettings.maxBufferSeconds.toDouble(),
          divisions: SectionModuleSettings.maxBufferSeconds,
          display: _module.bufferSeconds == 0
              ? '自动'
              : '${_module.bufferSeconds}s',
          onChanged: (value) =>
              _update(_module.copyWith(bufferSeconds: value.round())),
        ),
      );
    }
    children.add(
      const _Note(
        '阅读页 / 播放页里的就地设置**保留**：那些面板与本页改的是同一份数据，'
        '两边实时同步。页面布局与控件位置只提供预制方案，不开放自由拖拽坐标。',
      ),
    );
    return children;
  }

  // ------------------------------------------------------------ 落库

  void _saveComic(ReadingLibrary library, ComicReaderSettings next) {
    next.save(library);
    setState(() {});
  }

  void _saveTypesetting(ReadingLibrary library, NovelTypesetting next) {
    library.setSetting(NovelTypesetting.settingKey, next.encode());
    setState(() {});
  }

  /// 播放设置走它自己的存储（与播放页共用），不是本页自造的键。
  PlayerSettings _videoSettings(ReadingLibrary library) =>
      VideoPlayerSettingsStore(library).load();

  void _updatePlayer(ReadingLibrary library, PlayerSettings next) {
    VideoPlayerSettingsStore(library).save(next);
    setState(() {});
  }
}

extension on ReadingLibrary {
  /// 小小的语法糖：库非空时写一次设置。
  void let(void Function(ReadingLibrary library) action) => action(this);
}

/// 一个可折叠分组。
class _Group extends StatelessWidget {
  const _Group({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Theme(
        // 去掉 ExpansionTile 默认的分隔线，跟卡片风格一致。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: GlassCard(
          padding: EdgeInsets.zero,
          child: ExpansionTile(
            // 默认**收起**（用户口径：不要把全部设置直接堆在一页）。
            initiallyExpanded: false,
            iconColor: LumeTheme.accent,
            collapsedIconColor: LumeTheme.muted,
            tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            leading: Icon(icon, size: 20, color: LumeTheme.accent),
            title: Text(
              title,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textPrimary,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// 一行：左侧标签（+可选说明），右侧是控件。
class _Row extends StatelessWidget {
  const _Row({required this.label, this.hint, required this.child});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: LumeTheme.textSecondary),
                ),
              ),
              child,
            ],
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              hint!,
              style: TextStyle(fontSize: 11, color: LumeTheme.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
    this.hint,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 108,
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
              ),
            ),
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: display,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                display,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
              ),
            ),
          ],
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(left: 108, bottom: 4),
            child: Text(
              hint!,
              style: TextStyle(fontSize: 11, color: LumeTheme.muted),
            ),
          ),
      ],
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return _Row(
      label: label,
      hint: hint,
      child: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
        ),
      );
}
