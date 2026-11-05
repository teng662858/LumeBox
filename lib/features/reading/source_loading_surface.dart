import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/session/section.dart';

class SourceLoadingSurface extends StatelessWidget {
  const SourceLoadingSurface({
    super.key,
    required this.section,
    this.label = '正在加载内容…',
    this.topInset = 16,
  });
  final Section section;
  final String label;
  final double topInset;
  @override
  Widget build(BuildContext context) {
    final mode =
        BrowseLayoutSettings.instance.modeFor(section) ??
        BrowseLayoutMode.grid3;
    final columns = mode == BrowseLayoutMode.list ? 1 : mode.columns;
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, topInset, 16, 12),
          child: Text(label),
        ),
        const LinearProgressIndicator(),
        Expanded(
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: columns * 3,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: columns == 1 ? 108 : 180,
              crossAxisSpacing: 10,
              mainAxisSpacing: 12,
            ),
            itemBuilder: (_, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
