import 'package:flutter/material.dart';

import '../../core/search/search_source_filter.dart';
import '../../core/source/data_source.dart';

class SearchSourceFilters extends StatelessWidget {
  const SearchSourceFilters({
    super.key,
    required this.sources,
    required this.value,
    required this.onChanged,
  });
  final List<SourceDescriptor> sources;
  final SearchSourceFilter value;
  final ValueChanged<SearchSourceFilter> onChanged;

  Widget row(BuildContext context, String label, List<Widget> chips) =>
      SizedBox(
        height: 40 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: chips),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final groups = [
      for (final source in sources)
        (
          content: SearchSourceFilter.contentOf(source),
          kind: SearchSourceFilter.kindOf(source),
        ),
    ];
    int contentCount(SearchContentGroup c) => groups
        .where(
          (g) =>
              (c == SearchContentGroup.all || g.content == c) &&
              (value.kind == SearchSourceKind.all || g.kind == value.kind),
        )
        .length;
    int kindCount(SearchSourceKind k) => groups
        .where(
          (g) =>
              (k == SearchSourceKind.all || g.kind == k) &&
              (value.content == SearchContentGroup.all ||
                  g.content == value.content),
        )
        .length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(context, '内容', [
          for (final group in SearchContentGroup.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                key: ValueKey('search-content-${group.name}'),
                label: Text('${group.label} ${contentCount(group)}'),
                selected: value.content == group,
                onSelected: (_) => onChanged(value.copyWith(content: group)),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ]),
        row(context, '类型', [
          for (final group in SearchSourceKind.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                key: ValueKey('search-kind-${group.name}'),
                label: Text('${group.label} ${kindCount(group)}'),
                selected: value.kind == group,
                onSelected: (_) => onChanged(value.copyWith(kind: group)),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ]),
      ],
    );
  }
}
