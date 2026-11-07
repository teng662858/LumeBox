import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/video_glass_surface.dart';

/// 与倍速入口相同的锚点小菜单，点击选项后立即收起。
class PlayerKernelButton extends StatefulWidget {
  const PlayerKernelButton({
    super.key,
    required this.selected,
    required this.catalog,
    required this.onChanged,
    required this.builder,
    this.onOpen,
    this.onClose,
  });
  final PlayerKernel selected;
  final PlayerKernelCatalog catalog;
  final ValueChanged<PlayerKernel> onChanged;
  final Widget Function(VoidCallback open) builder;
  final VoidCallback? onOpen, onClose;
  @override
  State<PlayerKernelButton> createState() => _PlayerKernelButtonState();
}

class _PlayerKernelButtonState extends State<PlayerKernelButton> {
  final menu = MenuController();
  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: menu,
    consumeOutsideTap: true,
    onOpen: widget.onOpen,
    onClose: widget.onClose,
    style: MenuStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    menuChildren: [
      SizedBox(
        key: const Key('player-kernel-menu'),
        width: 256,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('播放内核'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final kernel in PlayerKernel.values)
                  Tooltip(
                    message:
                        widget.catalog.unavailableReason(kernel) ??
                        kernel.label,
                    child: ChoiceChip(
                      label: Text(kernel.label),
                      selected: widget.selected == kernel,
                      showCheckmark: false,
                      onSelected: widget.catalog.isAvailable(kernel)
                          ? (_) {
                              menu.close();
                              widget.onChanged(kernel);
                            }
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ],
    builder: (context, controller, child) => widget.builder(
      () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

/// 播放内核选择列表。
///
/// **视频板块的右上角快捷菜单与全局设置的逃生入口共用这一份 UI**——两处显示与
/// 交互完全一致，避免"逃生口看到的和常用的不是同一套"这种坑。
///
/// 熔断后的重试：MPV 初始化失败会在本次运行内被熔断（不再放行），此时列表里
/// 它显示为不可选 + 原因。[retryKernel] / [onRetry] 用来给这种「失败但可以再试」
/// 的内核挂一个「重试」按钮——否则用户只能重启 App 才能再给它一次机会。
class PlayerKernelPicker extends StatelessWidget {
  const PlayerKernelPicker({
    super.key,
    required this.selected,
    required this.catalog,
    required this.onChanged,
    this.retryKernel,
    this.onRetry,
  });

  /// 当前选中的内核。
  final PlayerKernel selected;

  /// 内核可用性目录（测试注入替身即可在非 iOS 平台驱动这套交互）。
  final PlayerKernelCatalog catalog;

  /// 选中某个可用内核时回调。
  final ValueChanged<PlayerKernel> onChanged;

  /// 可重试的内核（例如熔断中的 MPV）；为空表示没有可重试项。
  final PlayerKernel? retryKernel;

  /// 重试动作：调用方负责解除熔断并刷新列表。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VideoGlassScope.active(context)
          ? Colors.white.withValues(alpha: .22)
          : Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final kernel in PlayerKernel.values)
            _KernelTile(
              kernel: kernel,
              available: catalog.isAvailable(kernel),
              reason: catalog.unavailableReason(kernel),
              selected: selected == kernel,
              retryable: retryKernel == kernel && onRetry != null,
              onRetry: onRetry,
              onTap: () => onChanged(kernel),
            ),
        ],
      ),
    );
  }
}

class _KernelTile extends StatelessWidget {
  const _KernelTile({
    required this.kernel,
    required this.available,
    required this.reason,
    required this.selected,
    required this.onTap,
    this.retryable = false,
    this.onRetry,
  });

  final PlayerKernel kernel;
  final bool available;
  final String? reason;
  final bool selected;
  final VoidCallback onTap;

  /// 是否显示「重试」按钮。
  final bool retryable;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: available ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                        fontSize: LumeTypography.bodySize,
                        fontWeight: FontWeight.w600,
                        color: available
                            ? LumeTheme.textPrimary
                            : LumeTheme.muted,
                      ),
                    ),
                    if (reason != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        reason!,
                        style: TextStyle(
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                          fontSize: LumeTypography.descriptionSize,
                          color: LumeTheme.descriptionColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (retryable)
                TextButton(
                  onPressed: onRetry,
                  child: const Text(
                    '重试',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.bodySize,
                    ),
                  ),
                )
              else if (selected)
                LumeIcon(
                  Icons.check_circle,
                  slot: 'player_kernel_picker.1',
                  size: 20,
                  color: LumeTheme.textPrimary,
                )
              else if (available)
                LumeIcon(
                  Icons.radio_button_unchecked,
                  slot: 'player_kernel_picker.2',
                  size: 20,
                  color: LumeTheme.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
