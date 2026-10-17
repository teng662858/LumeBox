import 'package:flutter/material.dart';

class SourceColumnSection {
  const SourceColumnSection({
    required this.id,
    required this.title,
    required this.children,
  });
  final String id, title;
  final List<Widget> children;
}

/// Two physical lanes. Each owns a ListView and never shares its scroll offset
/// with the other lane. A category is assigned whole, never split into cells.
class SourceCategoryColumns extends StatelessWidget {
  const SourceCategoryColumns({
    super.key,
    required this.sections,
    this.keyPrefix = 'picker',
  });
  final List<SourceColumnSection> sections;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    Widget lane(int index) {
      final groups = [
        for (var i = index; i < sections.length; i += 2) sections[i],
      ];
      Widget header(SourceColumnSection group) => Semantics(
        header: true,
        child: Padding(
          key: ValueKey('$keyPrefix-group-${group.id}'),
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
          child: Text(
            group.title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (groups.length == 1) header(groups.single),
          Expanded(
            child: ListView(
              key: PageStorageKey('$keyPrefix-column-$index'),
              primary: false,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final group in groups) ...[
                  if (groups.length != 1) header(group),
                  if (group.children.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '暂无匹配的源',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final child in group.children)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: child,
                    ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Row(
          key: ValueKey('$keyPrefix-category-columns'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: lane(0)),
            const SizedBox(width: 10),
            Expanded(child: lane(1)),
          ],
        ),
      ),
    );
  }
}
