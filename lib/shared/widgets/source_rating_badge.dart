import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

class SourceRatingBadge extends StatelessWidget {
  const SourceRatingBadge({super.key, this.compact = false});

  /// 紧凑模式：10px 的「18」小角标，跟在版本号后面，不单独占一行。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const message = '含成人内容 · 18+';
    if (!compact) {
      return const Tooltip(
        message: message,
        child: LumeIcon(
          Icons.eighteen_up_rating_outlined,
          slot: 'source_rating_badge.1',
          size: 18,
        ),
      );
    }
    return Tooltip(
      message: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: .5),
        decoration: BoxDecoration(
          border: Border.all(color: LumeTheme.inputBorder),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          '18',
          style: TextStyle(
            fontSize: 10,
            height: 1.15,
            fontWeight: FontWeight.w600,
            color: LumeTheme.muted,
          ),
        ),
      ),
    );
  }
}
