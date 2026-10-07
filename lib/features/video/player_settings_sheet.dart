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
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => PlayerSettingsSheet(
      settings: settings,
      capabilities: capabilities,
      onChanged: onChanged,
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
    ),
  );
}

/// 播放器设置面板：**所有功能入口都固定在这里**（用户点名）。
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
    this.embedded = false,
  });

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

  /// 弹幕设置变更回调。
  final ValueChanged<DanmakuSettings>? onDanmakuChanged;

  /// 本集弹幕条数（展示用）。
  final int? danmakuCount;

  /// 是否作为**内嵌内容**使用（全局设置页）：不画拖拽把手与关闭按钮，
  /// 也不限高（由外层滚动容器负责）。
  final bool embedded;

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  /// 面板自己持一份当前设置：弹窗不改宿主的状态树，改了要当场看到效果
  /// （尤其是「切内核后倍速跟着换」——那正是按内核分别记住的证据）。
  late PlayerSettings _settings = widget.settings;

  PlayerCapabilities get capabilities => widget.capabilities;

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
    final list = ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: <Widget>[
                      _section(
                        '播放内核',
                        '三套内核运行时可切换（各有独立解码链）；'
                        '倍速、画面与字幕设置**按内核分别记住**',
                      ),
                      PlayerKernelPicker(
                        selected: settings.kernel,
                        catalog: catalog,
                        onChanged: (kernel) =>
                            _update(settings.copyWith(kernel: kernel)),
                        retryKernel: PlayerFactory.mpvInitFailed
                            ? PlayerKernel.mpv
                            : null,
                        onRetry: () {
                          PlayerFactory.clearMpvInitFailure();
                          // 列表重新评估：宿主在下一帧重建面板。
                          _update(settings);
                        },
                      ),
                      const SizedBox(height: 20),
                      _section('播放倍速', '0.25x ~ 4x，步长 0.25x；切换立即生效'),
                      _speedSlider(context),
                      const SizedBox(height: 20),
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
                      _section(
                        '字幕',
                        '开关 / 字号 / 颜色 / 描边 / 底色 / 延迟；'
                        '外挂字幕与内置字幕轨',
                      ),
                      _subtitleCard(context),
                      const SizedBox(height: 20),
                      _section('音频', '多音轨选择与音频延迟（音画不同步时用）'),
                      _audioCard(context),
                      if (_danmaku != null) ...<Widget>[
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
                          onChanged: _updateDanmaku,
                        ),
                      ],
                      const SizedBox(height: 20),
                      _section('解码', '硬件解码（部分设备硬解 HEVC 花屏时可切软解）'),
                      _decodingCard(context),
      ],
    );

    // 内嵌模式（全局设置页）：只管内容，外壳由外层给。
    if (widget.embedded) return list;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _handle(context),
                Flexible(child: list),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _handle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '播放器设置',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
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
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(detail, style: TextStyle(fontSize: 12, color: LumeTheme.muted)),
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
          Slider(
            value: speed.clamp(PlayerSettings.minSpeed, PlayerSettings.maxSpeed),
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
                  onSelected: (_) =>
                      _update(settings.copyWith(rotation: mode)),
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
          const SizedBox(height: 8),
          Text(
            _orientation == PlaybackOrientation.portrait
                ? '竖屏全屏（竖屏短剧想一直竖着看，或横片也想竖着看时选它）'
                : (_orientation == PlaybackOrientation.landscape
                    ? '全屏一律横屏；全局设置里的「横屏播放」开关就是这一档'
                    : '按视频比例判断：竖屏短剧竖屏全屏，普通横片横屏全屏'),
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
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
                  style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
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
                  icon: const Icon(Icons.subtitles_outlined, size: 18),
                  label: const Text('字幕轨'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: capabilities.externalSubtitle
                      ? widget.onPickSubtitleFile
                      : () => _unsupported(context),
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('外挂字幕'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
          _label('底色 ${(prefs.subtitleBackground * 100).round()}%', dim: !enabled),
          _gated(
            context,
            supported: style,
            child: Slider(
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
          _label('延迟 ${_formatDelay(settings.subtitleDelay)}',
              dim: !enabled),
          _gated(
            context,
            supported: capabilities.subtitleDelay,
            child: Slider(
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
              icon: const Icon(Icons.graphic_eq, size: 18),
              label: const Text('选择音轨'),
            ),
          ),
          const SizedBox(height: 12),
          _label('音频延迟 ${_formatDelay(prefs.audioDelay)}'),
          _gated(
            context,
            supported: capabilities.audioDelay,
            child: Slider(
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
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
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
                  style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
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
                  onPressed: () => _unsupported(context),
                  child: const Text('不支持'),
                ),
            ],
          ),
          Text(
            capabilities.hardwareDecoding
                ? (enabled
                    ? '开启（默认）：优先硬解，省电且流畅；对随后打开的媒体生效'
                    : '关闭：走软解；对随后打开的媒体生效')
                : '当前内核没有切换解码链的通道（点击看提示与可换的内核）',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
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
        fontSize: 12,
        color: dim ? LumeTheme.muted.withValues(alpha: 0.5) : LumeTheme.textSecondary,
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
