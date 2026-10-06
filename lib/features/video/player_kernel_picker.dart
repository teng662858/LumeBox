import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 播放内核选择列表。
///
/// **视频板块的右上角快捷菜单与全局设置的逃生入口共用这一份 UI**——两处显示与
/// 交互完全一致，避免"逃生口看到的和常用的不是同一套"这种坑。
class PlayerKernelPicker extends StatelessWidget {
  const PlayerKernelPicker({
    super.key,
    required this.selected,
    required this.catalog,
    required this.onChanged,
  });

  /// 当前选中的内核。
  final PlayerKernel selected;

  /// 内核可用性目录（测试注入替身即可在非 iOS 平台驱动这套交互）。
  final PlayerKernelCatalog catalog;

  /// 选中某个可用内核时回调。
  final ValueChanged<PlayerKernel> onChanged;

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
  });

  final PlayerKernel kernel;
  final bool available;
  final String? reason;
  final bool selected;
  final VoidCallback onTap;

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
            if (selected)
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
