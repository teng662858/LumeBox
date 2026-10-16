
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_subscription_sync.dart';

class SubscriptionStatusIcon extends StatelessWidget {
  const SubscriptionStatusIcon({super.key, required this.section});
  final Section section;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: SourceSubscriptionSync.changeCount(section),
    builder: (_, count, _) => Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: const Icon(Icons.rss_feed),
    ),
  );
}
