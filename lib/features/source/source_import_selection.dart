import 'package:flutter/material.dart';

import 'source_import_flow.dart';

Future<List<SourceImportItem>?> chooseSourceImports(
  BuildContext context,
  List<SourceImportItem> items,
) async {
  final selected = <int>{};
  return showDialog<List<SourceImportItem>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text('选择导入 · ${items.length} 个源'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              CheckboxListTile(
                title: const Text('全选'),
                value: selected.length == items.length,
                onChanged: (value) => update(() {
                  selected.clear();
                  if (value == true) {
                    selected.addAll(List.generate(items.length, (i) => i));
                  }
                }),
              ),
              for (var i = 0; i < items.length; i++)
                CheckboxListTile(
                  title: Text(items[i].label),
                  subtitle: Text(
                    items[i].originUrl.isEmpty ? '本地源' : items[i].originUrl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: selected.contains(i),
                  onChanged: (value) => update(() {
                    if (value == true) {
                      selected.add(i);
                    } else {
                      selected.remove(i);
                    }
                  }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, [
                    for (var i = 0; i < items.length; i++)
                      if (selected.contains(i)) items[i],
                  ]),
            child: Text('导入 ${selected.length} 个'),
          ),
        ],
      ),
    ),
  );
}
