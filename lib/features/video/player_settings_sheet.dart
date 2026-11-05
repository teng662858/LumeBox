import 'intro_settings_page.dart';
import 'player_layout.dart';
import 'presentation_settings_card.dart';
import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/native_glass_controls.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'danmaku/danmaku_panel.dart';
import 'playback_glass.dart';

import 'package:flutter/material.dart';

import '../../core/player/playback_orientation.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_settings_sheet.dart';
import 'player_kernel_picker.dart';

/// 打开播放器设置弹窗（底部 Sheet）。
///
/// 为什么是弹窗而不是整页：播放页上的设置要「改一项看一眼画面」，整页会挡住
/// 画面；而且用户点名「所有功能入口固定在播放页的设置弹窗内」。
Future<void> showPlayerSettingsSheet({
  required BuildContext context,
  required PlayerSettings settings,
  required PlayerCapabilities capabilities,
  required ValueChanged<PlayerSettings> onChanged,
  PlayerKernelCatalog catalog = const PlatformPlayerKernelCatalog(),
  void Function(String message)? onUnsupported,
  VoidCallback? onPickAudioTrack,
  VoidCallback? onPickSubtitleTrack,
  VoidCallback? onPickSubtitleFile,
  PlaybackOrientation? orientation,
  ValueChanged<PlaybackOrientation>? onOrientationChanged,
  DanmakuSettings? danmaku,
  ValueChanged<DanmakuSettings>? onDanmakuChanged,
  int? danmakuCount,
  Widget? introControls,
  Widget? extraControls,
  Widget? audioControls,
  Widget? connectionControls,
  Widget? danmakuControls,
  bool showPlaybackShortcuts = true,
}) {
  final glass = ValueNotifier(settings.playbackGlass);
  return showDanmakuPanel<void>(
    context: context,
    builder: (_) => ValueListenableBuilder<bool>(
      valueListenable: glass,
      builder: (context, enabled, _) => PlaybackGlass(
        enabled: enabled,
        child: PlayerSettingsSheet(
          showDanmakuPanel: false,
          showPlaybackShortcuts: showPlaybackShortcuts,
          settings: settings,
          capabilities: capabilities,
          onChanged: (next) {
            glass.value = next.playbackGlass;
            onChanged(next);
          },
          catalog: catalog,
          onUnsupported: onUnsupported,
          onPickAudioTrack: onPickAudioTrack,
          onPickSubtitleTrack: onPickSubtitleTrack,
          onPickSubtitleFile: onPickSubtitleFile,
          orientation: orientation,
          onOrientationChanged: onOrientationChanged,
          danmaku: danmaku,
          onDanmakuChanged: onDanmakuChanged,
          danmakuCount: danmakuCount,
          introControls: introControls,
          extraControls: extraControls,
          audioControls: audioControls,
          connectionControls: connectionControls,
          danmakuControls: danmakuControls,
        ),
      ),
    ),
  ).whenComplete(glass.dispose);
}

/// 共用播放器偏好面板：播放页按分类显示，全局页保留完整设置。
///
/// 三条硬约束（用户点名）：
/// 1. **控件不随内核变化显隐**——同一个内核支持与否，控件都在原位；
///    不支持的项点了弹统一提示（[PlayerCapabilities.unsupportedMessage]），
///    由 [onUnsupported] 交回宿主展示；
/// 2. **缩放模式 / 倍速 / 字幕设置按内核分别记住**——面板只读写
///    `PlayerSettings` 里「当前内核那一格」，切内核后看到的就是那个内核的值；
/// 3. 受控组件：设置从 [settings] 进来，改动经 [onChanged] 出去（宿主写库并立即
///    应用到正在播放的内核）。
///
/// 同一个面板既做播放页的弹窗（[showPlayerSettingsSheet]），也做全局设置页的
/// 内容（`PlayerSettingsPage`）——两处不各写一套，免得「改了一边忘一边」。
class PlayerSettingsSheet extends StatefulWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.settings,
    required this.capabilities,
    required this.onChanged,
    this.catalog = const PlatformPlayerKernelCatalog(),
    this.onUnsupported,
    this.onPickAudioTrack,
    this.onPickSubtitleTrack,
    this.onPickSubtitleFile,
    this.orientation,
    this.onOrientationChanged,
    this.danmaku,
    this.onDanmakuChanged,
    this.danmakuCount,
    this.showDanmakuPanel = true,
    this.embedded = false,
    this.showPlaybackShortcuts = true,
    this.introControls,
    this.extraControls,
    this.audioControls,
    this.connectionControls,
    this.danmakuControls,
    this.initialCategory,
    this.categoryOnly,
  });
  final String? initialCategory;

  /// When embedded in a settings subpage, render only this category.
  final String? categoryOnly;

  /// 当前设置（受控）。
  final PlayerSettings settings;

  /// 当前内核的能力矩阵：只影响「点了是生效还是提示」。
  final PlayerCapabilities capabilities;

  /// 设置变更回调（完整的一份新设置）。
  final ValueChanged<PlayerSettings> onChanged;

  /// 内核可用性目录（内核切换列表用）。
  final PlayerKernelCatalog catalog;

  /// 点了不支持的项：展示统一提示（为空时面板自己弹 SnackBar）。
  final void Function(String message)? onUnsupported;

  /// 选音轨（点开选择列表由宿主负责）。
  final VoidCallback? onPickAudioTrack;

  /// 选字幕轨（含「关闭字幕」）。
  final VoidCallback? onPickSubtitleTrack;

  /// 选外挂字幕文件。
  final VoidCallback? onPickSubtitleFile;

  /// 方向锁定（自动 / 强制横屏 / 强制竖屏）。为空时不显示这一节。
  ///
  /// 与全局设置里的「横屏播放」是同一份偏好（应用级），因此宿主传进来的就是
  /// 当前值、回调也是写同一处——两处不会各存一份互相打架。
  final PlaybackOrientation? orientation;

  /// 方向锁定变更回调。
  final ValueChanged<PlaybackOrientation>? onOrientationChanged;

  /// 弹幕设置（与播放页的「弹幕设置」弹窗同一份数据）。
  ///
  /// 用户点名「所有功能入口固定在播放页的设置弹窗内」——弹幕也是其中一项，
  /// 因此这里内嵌同一份面板（[DanmakuSettingsPanel]），不另写一套控件。
  final DanmakuSettings? danmaku;
  final bool showDanmakuPanel;

  /// 弹幕设置变更回调。
  final ValueChanged<DanmakuSettings>? onDanmakuChanged;

  /// 本集弹幕条数（展示用）。
  final int? danmakuCount;

  /// 是否作为**内嵌内容**使用（全局设置页）：不画拖拽把手与关闭按钮，
  /// 也不限高（由外层滚动容器负责）。
  final bool embedded;

  /// 播放页已有倍速、选集、弹幕及片头尾入口时，不在设置里重复。
  final bool showPlaybackShortcuts;
  final Widget? introControls;
  final Widget? extraControls,
      audioControls,
      connectionControls,
      danmakuControls;

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  @override
  void initState() {
    super.initState();
    if (widget.embedded && widget.initialCategory != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = _categoryKeys[widget.initialCategory];
        if (target != null) _jumpTo(target);
      });
    }
  }

  /// 面板自己持一份当前设置：弹窗不改宿主的状态树，改了要当场看到效果
  /// （尤其是「切内核后倍速跟着换」——那正是按内核分别记住的证据）。
  late PlayerSettings _settings = widget.settings;

  PlayerCapabilities get capabilities =>
      settings.kernel == widget.settings.kernel
      ? widget.capabilities
      : PlayerCapabilities.of(settings.kernel);

  PlayerKernelCatalog get catalog => widget.catalog;

  /// 改一项：本地立即生效 + 通知宿主（宿主写库并下发给正在播放的内核）。
  void _update(PlayerSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  PlayerSettings get settings => _settings;

  /// 弹幕设置（面板自己持一份，改一项立即回调宿主）。
  late DanmakuSettings? _danmaku = widget.danmaku;

  @override
  void didUpdateWidget(covariant PlayerSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
    if (oldWidget.danmaku != widget.danmaku) _danmaku = widget.danmaku;
  }

  void _updateDanmaku(DanmakuSettings next) {
    setState(() => _danmaku = next);
    widget.onDanmakuChanged?.call(next);
  }

  /// 方向锁定（面板自己持一份，改一项立即回调宿主）。
  late PlaybackOrientation _orientation =
      widget.orientation ?? PlaybackOrientation.fallback;

  void _updateOrientation(PlaybackOrientation next) {
    if (next == _orientation) return;
    setState(() => _orientation = next);
    widget.onOrientationChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[
      _group(
        'playback',
        widget.showPlaybackShortcuts ? '播放与选集' : '播放偏好',
        Icons.play_circle_outline,
        [
          if (widget.showPlaybackShortcuts) ...[
            _section('播放倍速', '0.25x ~ 4x，步长 0.25x；切换立即生效'),
            _speedSlider(context),
            const SizedBox(height: 20),
          ],
          if (widget.extraControls != null) widget.extraControls!,
          _section('清晰度偏好', '起播与切集时使用的画质选择'),
          DropdownButtonFormField<DefaultQuality>(
            isExpanded: true,
            initialValue: settings.defaultQuality,
            decoration: const InputDecoration(labelText: '默认清晰度'),
            items: [
              for (final value in DefaultQuality.values)
                DropdownMenuItem(value: value, child: Text(value.label)),
            ],
            onChanged: (value) {
              if (value != null) {
                _update(settings.copyWith(defaultQuality: value));
              }
            },
          ),
          NativeSwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('记住手动选择的清晰度'),
            subtitle: const Text(
              '下一集优先使用手动选择的同名清晰度；未匹配或关闭时按默认清晰度选择，最后回退至本集最高画质。',
            ),
            value: settings.rememberManualQuality,
            onChanged: (value) =>
                _update(settings.copyWith(rememberManualQuality: value)),
          ),
          const SizedBox(height: 20),
        ],
      ),
      if (widget.showPlaybackShortcuts || widget.introControls != null)
        _group('intro', '片头片尾', Icons.skip_next_outlined, [
          widget.introControls ??
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('片头片尾与同剧记忆'),
                subtitle: const Text('自动识别、手动标记、跳过倒计时与取消'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const IntroSettingsPage(),
                  ),
                ),
              ),
        ]),
      _group('picture', '画面与显示', Icons.aspect_ratio, [
        _section('画面', '缩放 / 旋转 / 镜像（三套内核都支持）'),
        _pictureCard(context),
        const SizedBox(height: 20),
        if (widget.onOrientationChanged != null) ...<Widget>[
          _section(
            '方向锁定',
            '全屏时的屏幕方向：自动 = 按视频比例判断'
                '（竖屏短剧竖屏全屏、横片横屏全屏）',
          ),
          _orientationCard(context),
          const SizedBox(height: 20),
        ],
        PresentationSettingsCard(
          settings: settings,
          onChanged: _update,
          showSubtitles: false,
          showAudio: false,
        ),
      ]),
      _group('audio', '声音与字幕', Icons.subtitles_outlined, [
        if (widget.audioControls != null) widget.audioControls!,
        _section(
          '字幕',
          '开关 / 字号 / 颜色 / 描边 / 底色 / 延迟；'
              '外挂字幕与内置字幕轨；文字叠加字幕不随系统画中画显示',
        ),
        _subtitleCard(context),
        const SizedBox(height: 20),
        _section('音频', '多音轨选择与音频延迟（音画不同步时用）'),
        _audioCard(context),
        PresentationSettingsCard(
          settings: settings,
          onChanged: _update,
          showPicture: false,
        ),
      ]),
      if (_danmaku != null || widget.danmakuControls != null)
        _group('danmaku', '弹幕与匹配', Icons.chat_bubble_outline, [
          if (widget.danmakuControls != null) widget.danmakuControls!,
          NativeSwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('避让底部字幕'),
            value: _danmaku?.avoidSubtitles ?? true,
            onChanged: _danmaku == null
                ? null
                : (value) =>
                      _updateDanmaku(_danmaku!.copyWith(avoidSubtitles: value)),
          ),
          if (_danmaku != null && widget.showDanmakuPanel) ...<Widget>[
            const SizedBox(height: 20),
            _section(
              '弹幕',
              '开关 / 不透明度 / 字号 / 显示区域 / 速度 / 描边 / '
                  '同屏上限 / 屏蔽词',
            ),
            DanmakuSettingsPanel(
              settings: _danmaku!,
              danmakuCount: widget.danmakuCount,
              // 外层已经有「弹幕」这一节标题，面板不再重复。
              showTitle: false,
              showAvoidSubtitles: false,
              onChanged: _updateDanmaku,
            ),
          ],
          const SizedBox(height: 20),
        ]),
      _group('controls', '手势与外观', Icons.touch_app_outlined, [
        _section('按钮样式', '切换立即生效；全屏弹幕、倍速、选集保留文字'),
        SegmentedButton<PlayerControlStyle>(
          segments: const [
            ButtonSegment(value: PlayerControlStyle.text, label: Text('文字')),
            ButtonSegment(value: PlayerControlStyle.icons, label: Text('图标')),
          ],
          selected: {settings.controlStyle},
          onSelectionChanged: (values) =>
              _update(settings.copyWith(controlStyle: values.first)),
        ),
        const SizedBox(height: 20),
        _section('手势', 'AVPlayer / MPV / MDK 共用，横竖屏立即生效；锁屏时停用'),
        NativeSwitchListTile.adaptive(
          title: const Text('启用播放器手势'),
          subtitle: const Text('控制下列滑动和长按手势；不影响按钮与进度条操作'),
          value: settings.gestures.enabled,
          onChanged: (v) => _update(
            settings.copyWith(gestures: settings.gestures.copyWith(enabled: v)),
          ),
        ),
        for (final item in [
          ('左侧上下滑调亮度', settings.gestures.brightness, 'brightness'),
          ('右侧上下滑调音量', settings.gestures.volume, 'volume'),
          ('横向滑动调进度', settings.gestures.seek, 'seek'),
          ('长按临时倍速', settings.gestures.boost, 'boost'),
        ])
          NativeSwitchListTile.adaptive(
            title: Text(item.$1),
            value: item.$2,
            onChanged: !settings.gestures.enabled
                ? null
                : (v) => _update(
                    settings.copyWith(
                      gestures: settings.gestures.copyWith(
                        brightness: item.$3 == 'brightness' ? v : null,
                        volume: item.$3 == 'volume' ? v : null,
                        seek: item.$3 == 'seek' ? v : null,
                        boost: item.$3 == 'boost' ? v : null,
                      ),
                    ),
                  ),
          ),
        _label('上下滑动灵敏度 ${settings.gestureSensitivity.toStringAsFixed(1)}×'),
        NativeGlassSlider(
          value: settings.gestureSensitivity,
          min: PlayerSettings.minGestureSensitivity,
          max: PlayerSettings.maxGestureSensitivity,
          divisions: 6,
          onChanged:
              !settings.gestures.enabled ||
                  !(settings.gestures.brightness || settings.gestures.volume)
              ? null
              : (v) => _update(settings.copyWith(gestureSensitivity: v)),
        ),
        _label('横滑一屏跨度 ${settings.gestures.seekSeconds} 秒'),
        NativeGlassSlider(
          value: settings.gestures.seekSeconds.toDouble(),
          min: 30,
          max: 180,
          divisions: 10,
          onChanged: !settings.gestures.enabled || !settings.gestures.seek
              ? null
              : (v) => _update(
                  settings.copyWith(
                    gestures: settings.gestures.copyWith(
                      seekSeconds: v.round(),
                    ),
                  ),
                ),
        ),
        _label(
          '长按播放速度 ${settings.gestures.boostMultiplier.toStringAsFixed(2)}×',
        ),
        NativeGlassSlider(
          value: settings.gestures.boostMultiplier,
          min: 1.5,
          max: 4,
          divisions: 10,
          onChanged: !settings.gestures.enabled || !settings.gestures.boost
              ? null
              : (v) => _update(
                  settings.copyWith(
                    gestures: settings.gestures.copyWith(boostMultiplier: v),
                  ),
                ),
        ),
        const Text('长按使用所选速度，松手恢复原速度；不会降低当前已设置的更高倍速。亮度不可由系统调整时使用画面遮罩。'),
        const SizedBox(height: 20),
      ]),
      _group('advanced', '内核与网络', Icons.settings_input_component_outlined, [
        _section('播放内核', '切换播放内核；倍速、画面与字幕设置分别保存'),
        PlayerKernelPicker(
          selected: settings.kernel,
          catalog: catalog,
          onChanged: (kernel) => _update(settings.copyWith(kernel: kernel)),
          retryKernel: PlayerFactory.mpvInitFailed ? PlayerKernel.mpv : null,
          onRetry: () {
            PlayerFactory.clearMpvInitFailure();
            // 列表重新评估：宿主在下一帧重建面板。
            _update(settings);
          },
        ),
        const SizedBox(height: 20),
        _section('解码', '硬件解码（部分设备硬解 HEVC 花屏时可切软解）'),
        _decodingCard(context),
        const SizedBox(height: 20),
        if (widget.connectionControls != null) widget.connectionControls!,
        NativeSwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('后台静默校验播放源'),
          value: settings.backgroundSourceValidation,
          onChanged: (value) =>
              _update(settings.copyWith(backgroundSourceValidation: value)),
        ),
        Text(
          '起播后在后台检查链接，失效时提示；不会自动切换线路。关闭后不做后台检查。',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: LumeTypography.descriptionSize,
            height: 1.4,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ]),
    ];
    final children = <Widget>[
      if (widget.embedded && widget.categoryOnly == null) _categoryNavigation(),
      ...groups,
    ];

    // 内嵌模式（全局设置页）：**返回 Column 而不是 ListView**。
    //
    // 真机反馈「全局设置 → 播放器设置，下面的功能拉不上来」：内层再放一个
    // ListView（即使 shrinkWrap）会把滚动手势自己吃掉，外层页面那个 ListView
    // 就再也收不到拖动，于是下半截内容永远看不到。用 Column 让内容自然撑开，
    // 滚动交给外层——这也是「整页只有一个滚动视图」的常规做法。
    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }

    final list = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      key: ValueKey(_selectedCategory),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    final content = SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _handle(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _categoryNavigation(),
            ),
            Flexible(child: list),
          ],
        ),
      ),
    );
    final legacy = ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Material(
        color: VideoGlassScope.active(context)
            ? Colors.transparent
            : LumeTheme.base,
        child: content,
      ),
    );
    return legacy;
  }

  String _selectedCategory = 'playback';

  final _categoryKeys = <String, GlobalKey>{};
  final _navigationKey = GlobalKey();
  static const _categories = [
    ('playback', '播放'),
    ('intro', '片头片尾'),
    ('picture', '画面'),
    ('audio', '音频字幕'),
    ('danmaku', '弹幕'),
    ('controls', '操作外观'),
    ('advanced', '内核网络'),
  ];

  Future<void> _jumpTo(GlobalKey key) async {
    final target = key.currentContext;
    if (target != null) {
      await Scrollable.ensureVisible(
        target,
        duration: PlayerLayout.motion(context, 240),
        alignment: 0,
      );
    }
  }

  Widget _categoryNavigation() {
    final choices = <Widget>[
      for (final category in _categories)
        if ((category.$1 != 'intro' ||
                widget.showPlaybackShortcuts ||
                widget.introControls != null) &&
            (category.$1 != 'danmaku' ||
                _danmaku != null ||
                widget.danmakuControls != null))
          ChoiceChip(
            key: ValueKey('player-category-${category.$1}'),
            label: Text(category.$2),
            selected: !widget.embedded && _selectedCategory == category.$1,
            showCheckmark: false,
            onSelected: (_) {
              if (widget.embedded) {
                _jumpTo(_categoryKeys[category.$1]!);
              } else {
                setState(() => _selectedCategory = category.$1);
              }
            },
          ),
    ];
    return Padding(
      key: _navigationKey,
      padding: const EdgeInsets.only(bottom: 8),
      child: widget.embedded
          ? Wrap(spacing: 6, runSpacing: 6, children: choices)
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final choice in choices)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: choice,
                    ),
                ],
              ),
            ),
    );
  }

  Widget _group(
    String id,
    String title,
    IconData icon,
    List<Widget> children,
  ) =>
      (widget.categoryOnly != null && id != widget.categoryOnly) ||
          (!widget.embedded && id != _selectedCategory)
      ? const SizedBox.shrink()
      : Padding(
          key: _categoryKeys.putIfAbsent(id, GlobalKey.new),
          padding: const EdgeInsets.only(top: 8, bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.categoryOnly == null)
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (widget.embedded)
                      IconButton(
                        tooltip: '回到分类',
                        onPressed: () => _jumpTo(_navigationKey),
                        icon: const Icon(Icons.vertical_align_top, size: 18),
                      ),
                  ],
                ),
              if (widget.categoryOnly == null) const Divider(),
              ...children,
            ],
          ),
        );

  Widget _handle(BuildContext context) {
    // 与选集抽屉保持同一套紧凑头部：小号标题 + 小图标，不再占一整条 AppBar 高度。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '播放器设置',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            icon: const LumeIcon(Icons.close, slot: 'player_settings_sheet.1'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String detail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: LumeTypography.sectionTitleSize,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedSlider(BuildContext context) {
    final speed = settings.speed;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NativeGlassSlider(
            value: speed.clamp(
              PlayerSettings.minSpeed,
              PlayerSettings.maxSpeed,
            ),
            min: PlayerSettings.minSpeed,
            max: PlayerSettings.maxSpeed,
            divisions: PlayerSettings.speeds.length - 1,
            label: _formatSpeed(speed),
            onChanged: (value) => _update(settings.copyWith(speed: value)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final preset in <double>[0.5, 1.0, 1.5, 2.0, 3.0])
                  ChoiceChip(
                    label: Text(_formatSpeed(preset)),
                    selected: speed == preset,
                    onSelected: (_) =>
                        _update(settings.copyWith(speed: preset)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pictureCard(BuildContext context) {
    final prefs = settings.current;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _label('缩放'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final mode in ZoomMode.values)
                ChoiceChip(
                  label: Text(mode.label),
                  selected: prefs.zoom == mode,
                  onSelected: (_) => _update(settings.copyWith(zoom: mode)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _label('旋转'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final mode in RotationMode.values)
                ChoiceChip(
                  label: Text(mode.label),
                  selected: prefs.rotation == mode,
                  onSelected: (_) => _update(settings.copyWith(rotation: mode)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: _label('水平镜像')),
              Switch(
                value: prefs.mirrored,
                onChanged: (value) =>
                    _update(settings.copyWith(mirrored: value)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 方向锁定：三档芯片（与全局设置里的「横屏播放」写的是同一份偏好）。
  Widget _orientationCard(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _label('方向锁定'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final mode in PlaybackOrientation.values)
                ChoiceChip(
                  label: Text(mode.label),
                  selected: _orientation == mode,
                  onSelected: (_) => _updateOrientation(mode),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 自动隐藏开关与方向锁定同组（用户要求）：都在「画面怎么显示」这一类。
          Divider(height: 1, thickness: 1, color: LumeTheme.divider),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '自动隐藏控制栏',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.titleSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Switch(
                value: settings.autoHideControls,
                onChanged: (value) =>
                    _update(settings.copyWith(autoHideControls: value)),
              ),
            ],
          ),
          Text(
            settings.autoHideControls
                ? '全屏 3 秒无操作自动收起，点屏幕唤回（默认开）'
                : '控制栏常显（关闭自动隐藏）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '竖屏短剧上滑切下一集',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.titleSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Switch(
                value: settings.swipeUpNext,
                onChanged: (value) =>
                    _update(settings.copyWith(swipeUpNext: value)),
              ),
            ],
          ),
          Text(
            settings.swipeUpNext
                ? '竖屏时在画面中间上滑即切下一集（左右两侧仍是亮度/音量）'
                : '关闭时画面中间的竖直滑动不做动作',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '快进吸附关键帧（实验）',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.titleSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Switch(
                value: settings.fastSeekSnap,
                onChanged: (value) =>
                    _update(settings.copyWith(fastSeekSnap: value)),
              ),
            ],
          ),
          Text(
            settings.fastSeekSnap
                ? '拖动时直接吸到上一个关键帧（最快档，画面可能按关键帧间隔跳；松手仍精确）'
                : '拖动时用 400ms 容差（较快，误差 ≤0.4 秒）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _orientation == PlaybackOrientation.portrait
                ? '竖屏全屏（竖屏短剧想一直竖着看，或横片也想竖着看时选它）'
                : (_orientation == PlaybackOrientation.landscape
                      ? '全屏一律横屏；全局设置里的「横屏播放」开关就是这一档'
                      : '按视频比例判断：竖屏短剧竖屏全屏，普通横片横屏全屏'),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtitleCard(BuildContext context) {
    final prefs = settings.current;
    final enabled = settings.subtitlesEnabled;
    final style = capabilities.subtitleStyle;
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
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.titleSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (value) =>
                    _update(settings.copyWith(subtitlesEnabled: value)),
              ),
            ],
          ),
          // 内置字幕轨 / 外挂字幕：不支持的项仍然显示，点了弹提示。
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: capabilities.subtitleTracks
                      ? widget.onPickSubtitleTrack
                      : () => _unsupported(context),
                  icon: const LumeIcon(
                    Icons.subtitles_outlined,
                    slot: 'player_settings_sheet.2',
                    size: 18,
                  ),
                  label: const Text('字幕轨'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: capabilities.externalSubtitle
                      ? widget.onPickSubtitleFile
                      : () => _unsupported(context),
                  icon: const LumeIcon(
                    Icons.file_open_outlined,
                    slot: 'player_settings_sheet.3',
                    size: 18,
                  ),
                  label: const Text('外挂字幕'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (settings.kernel == PlayerKernel.mpv &&
              settings.presentation.originalSubtitleStyle)
            const Text('ASS 原始样式优先；需要统一字号、底色与位置时，请关闭「保留 ASS 原始样式」。'),
          _label('字号', dim: !enabled),
          const SizedBox(height: 8),
          _gated(
            context,
            supported: style,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final size in SubtitleSize.values)
                  ChoiceChip(
                    label: Text(size.label),
                    selected: prefs.subtitleSize == size,
                    onSelected: enabled
                        ? (_) => _update(settings.copyWith(subtitleSize: size))
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _label('颜色', dim: !enabled),
          const SizedBox(height: 8),
          _gated(
            context,
            supported: style,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final color in SubtitleColor.values)
                  ChoiceChip(
                    label: Text(color.label),
                    selected: prefs.subtitleColor == color,
                    onSelected: enabled
                        ? (_) =>
                              _update(settings.copyWith(subtitleColor: color))
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _label('描边', dim: !enabled),
          const SizedBox(height: 8),
          _gated(
            context,
            supported: style,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final outline in SubtitleOutline.values)
                  ChoiceChip(
                    label: Text(outline.label),
                    selected: prefs.subtitleOutline == outline,
                    onSelected: enabled
                        ? (_) => _update(
                            settings.copyWith(subtitleOutline: outline),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 字体：**只给系统字体**——思源黑体没有随包内置（iOS / Android 都取不到
          // 这份字体文件），选了会被系统回落，因此这里不列它，也不假装支持。
          _label('字体', dim: !enabled),
          const SizedBox(height: 8),
          _gated(
            context,
            supported: style,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                // 空串 = 跟随系统默认（iOS 上是苹方）。
                for (final font in const <(String, String)>[
                  ('', '系统默认'),
                  ('PingFang SC', '苹方'),
                  ('Heiti SC', '黑体'),
                  ('Songti SC', '宋体'),
                  ('Kaiti SC', '楷体'),
                ])
                  ChoiceChip(
                    label: Text(font.$2),
                    selected: prefs.subtitleFont == font.$1,
                    onSelected: enabled
                        ? (_) =>
                              _update(settings.copyWith(subtitleFont: font.$1))
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _label('阴影 ${(prefs.subtitleShadow * 100).round()}%', dim: !enabled),
          _gated(
            context,
            supported: style,
            child: NativeGlassSlider(
              value: prefs.subtitleShadow,
              divisions: 10,
              label: '${(prefs.subtitleShadow * 100).round()}%',
              onChanged: enabled
                  ? (value) => _update(settings.copyWith(subtitleShadow: value))
                  : null,
            ),
          ),
          _label(
            '垂直偏移 ${(prefs.subtitleOffsetY * 100).round()}',
            dim: !enabled,
          ),
          _gated(
            context,
            supported: style,
            child: NativeGlassSlider(
              value: prefs.subtitleOffsetY,
              min: -1,
              max: 1,
              divisions: 20,
              label: (prefs.subtitleOffsetY * 100).round().toString(),
              onChanged: enabled
                  ? (value) =>
                        _update(settings.copyWith(subtitleOffsetY: value))
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
          _label(
            '底色 ${(prefs.subtitleBackground * 100).round()}%',
            dim: !enabled,
          ),
          _gated(
            context,
            supported: style,
            child: NativeGlassSlider(
              value: prefs.subtitleBackground,
              divisions: 20,
              label: '${(prefs.subtitleBackground * 100).round()}%',
              onChanged: enabled
                  ? (value) =>
                        _update(settings.copyWith(subtitleBackground: value))
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          _label('延迟 ${_formatDelay(settings.subtitleDelay)}', dim: !enabled),
          _gated(
            context,
            supported: capabilities.subtitleDelay,
            child: NativeGlassSlider(
              value: settings.subtitleDelay.inMilliseconds.toDouble(),
              min: PlayerSettings.minSubtitleDelay.inMilliseconds.toDouble(),
              max: PlayerSettings.maxSubtitleDelay.inMilliseconds.toDouble(),
              divisions: 200,
              label: _formatDelay(settings.subtitleDelay),
              onChanged: enabled
                  ? (value) => _update(
                      settings.copyWith(
                        subtitleDelay: Duration(milliseconds: value.round()),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _audioCard(BuildContext context) {
    final prefs = settings.current;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: capabilities.audioTracks
                  ? widget.onPickAudioTrack
                  : () => _unsupported(context),
              icon: const LumeIcon(
                Icons.graphic_eq,
                slot: 'player_settings_sheet.4',
                size: 18,
              ),
              label: const Text('选择音轨'),
            ),
          ),
          const SizedBox(height: 12),
          _label('音频延迟 ${_formatDelay(prefs.audioDelay)}'),
          _gated(
            context,
            supported: capabilities.audioDelay,
            child: NativeGlassSlider(
              value: prefs.audioDelay.inMilliseconds.toDouble(),
              min: PlayerSettings.minSubtitleDelay.inMilliseconds.toDouble(),
              max: PlayerSettings.maxSubtitleDelay.inMilliseconds.toDouble(),
              divisions: 200,
              label: _formatDelay(prefs.audioDelay),
              onChanged: (value) => _update(
                settings.copyWith(
                  audioDelay: Duration(milliseconds: value.round()),
                ),
              ),
            ),
          ),
          Text(
            '正值 = 音频延后出现（画面比声音快时往大调）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _decodingCard(BuildContext context) {
    final enabled = settings.hardwareDecoding;
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
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.titleSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              if (capabilities.hardwareDecoding)
                Switch(
                  value: enabled,
                  onChanged: (value) =>
                      _update(settings.copyWith(hardwareDecoding: value)),
                )
              else
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) => SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('AVPlayer 没有强制软件解码接口。可切换到以下支持解码偏好的内核：'),
                            PlayerKernelPicker(
                              selected: settings.kernel,
                              catalog: catalog,
                              onChanged: (kernel) {
                                Navigator.pop(sheetContext);
                                _update(settings.copyWith(kernel: kernel));
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('不支持'),
                ),
            ],
          ),
          Text(
            capabilities.hardwareDecoding
                ? (enabled
                      ? '开启（默认）：优先硬解，不兼容时允许回落软解；当前播放需要时会重载并保留位置'
                      : '关闭：使用软件解码；可能短暂重载，播放位置保留')
                : '当前内核没有切换解码链的通道（点击看提示与可换的内核）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 不支持的项：控件**照旧显示**，但点它弹统一提示（而不是消失）。
  Widget _gated(
    BuildContext context, {
    required bool supported,
    required Widget child,
  }) {
    if (supported) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _unsupported(context),
      child: IgnorePointer(child: Opacity(opacity: 0.5, child: child)),
    );
  }

  Widget _label(String text, {bool dim = false}) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: LumeTypography.descriptionSize,
        color: dim
            ? Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 统一提示：不支持的项点击后说清原因与出路。
  void _unsupported(BuildContext context) {
    final message = PlayerCapabilities.unsupportedMessage;
    final handler = widget.onUnsupported;
    if (handler != null) {
      handler(message);
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// `15%` / `-1.5s` / `0s`。
  static String _formatDelay(Duration delay) {
    if (delay == Duration.zero) return '0s';
    final seconds = delay.inMilliseconds / 1000.0;
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  /// 1.0 → `1x`，0.75 → `0.75x`：整数倍速不带小数，档位展示更干净。
  static String _formatSpeed(double speed) {
    return speed == speed.roundToDouble()
        ? '${speed.toStringAsFixed(0)}x'
        : '${speed.toString()}x';
  }
}
