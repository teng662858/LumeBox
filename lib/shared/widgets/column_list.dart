import 'package:flutter/material.dart';

class ColumnList extends StatelessWidget {
  const ColumnList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.columns = 2,
    this.padding = EdgeInsets.zero,
    this.spacing = 8,
    this.shrinkWrap = false,
    this.physics,
  });
  final int itemCount, columns;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double spacing;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: padding,
    shrinkWrap: shrinkWrap,
    physics: physics,
    itemCount: (itemCount / columns).ceil(),
    separatorBuilder: (_, _) => SizedBox(height: spacing),
    itemBuilder: (context, row) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var column = 0; column < columns; column++) ...[
          if (column > 0) SizedBox(width: spacing),
          Expanded(
            child: row * columns + column < itemCount
                ? ListTileTheme.merge(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    horizontalTitleGap: 6,
                    minLeadingWidth: 24,
                    child: itemBuilder(context, row * columns + column),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ],
    ),
  );
}
