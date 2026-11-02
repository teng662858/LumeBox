import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_entry_order.dart';

Future<void> showSourceEntryOrder(
  BuildContext context, {
  required Section section,
  required String settingKey,
  required List<(String, String)> entries,
}) async {
  final items = List<(String, String)>.of(entries);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('调整分类顺序 · 拖动后自动保存'),
            ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                onReorderItem: (oldIndex, newIndex) {
                  update(
                    () => items.insert(newIndex, items.removeAt(oldIndex)),
                  );
                  unawaited(
                    SourceEntryOrder.save(
                      section,
                      settingKey,
                      items.map((entry) => entry.$1).toList(),
                    ),
                  );
                },
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(items[index].$1),
                  title: Text(items[index].$2),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    ),
  );
}
