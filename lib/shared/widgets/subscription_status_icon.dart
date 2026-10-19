import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_subscription_sync.dart';

class SubscriptionStatusIcon extends StatelessWidget {
  const SubscriptionStatusIcon({super.key, required this.section});
  final Section section;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: SourceSubscriptionSync.changeCount(section),
    builder: (context, count, _) => Badge(
      isLabelVisible: count > 0,
      // 顶栏只有 36 高：角标压到 14 高、10px 字，并向右下收一点，
      // 两三位数都留在工具栏边界内。
      largeSize: 14,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      offset: const Offset(-4, -2),
      // 在主题字型上只改字号，保留字体族与字距。
      textStyle: Theme.of(context).textTheme.labelSmall
          ?.copyWith(fontSize: 10, height: 1.1, fontWeight: FontWeight.w600),
      label: Text(count > 99 ? '99+' : '$count'),
      child: const LumeIcon(Icons.rss_feed, slot: 'subscription_status_icon.1'),
    ),
  );
}
