import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_subscription_sync.dart';

/// Persistent per-site subscription change, shared by list and grid rows.
class SourceUpdateBadge extends StatelessWidget {
  const SourceUpdateBadge({
    super.key,
    required this.section,
    required this.sourceId,
  });
  final Section section;
  final String sourceId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      SourceSubscriptionSync.changeCount(section),
      SourceSubscriptionSync.revision(section),
    ]),
    builder: (context, _) {
      final entry = SourceSubscriptionSync.notice(section, sourceId);
      if (entry == null) return const SizedBox.shrink();
      return Text(
        entry['status'] ?? '已更新',
        key: ValueKey('source-update-$sourceId'),
        style: TextStyle(
          fontSize: LumeTypography.descriptionSize,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    },
  );
}
