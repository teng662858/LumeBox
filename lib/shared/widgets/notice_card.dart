import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import 'glass_card.dart';

/// 页面提示卡：标题 + 说明 + 可选动作。
///
/// 板块页与业务页共用同一套提示样式（空态、存储不可用、Phase1 骨架），
/// 避免每个页面各写一份。
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;

  /// 可选动作按钮，例如「图源管理」。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Phase1 平台骨架提示：没有图源运行时的平台统一使用。
class SkeletonNotice extends StatelessWidget {
  const SkeletonNotice({super.key});

  @override
  Widget build(BuildContext context) => const NoticeCard(
        title: LumeTheme.appName,
        subtitle: '当前平台在 Phase1 仅保留页面骨架',
      );
}
