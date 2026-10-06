import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

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
    return Column(
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: available ? onTap : null,
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
                      color: available ? LumeTheme.textPrimary : LumeTheme.muted,
                    ),
                  ),
                  if (reason != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      reason!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (retryable)
              TextButton(
                onPressed: onRetry,
                child: const Text('重试', style: TextStyle(fontSize: 13)),
              )
            else if (selected)
              const Icon(Icons.check_circle, size: 20, color: LumeTheme.textPrimary)
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
}
