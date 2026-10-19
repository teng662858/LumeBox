import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/reading/favorite_folders.dart';

Future<void> showFavoriteFolderManager(
  BuildContext context,
  FavoriteFolders folders,
) async {
  var typed = '';
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('管理收藏夹'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in folders.load().entries)
                  ListTile(
                    title: Text(entry.key),
                    subtitle: Text('${entry.value.length} 条收藏'),
                    trailing: IconButton(
                      tooltip: '删除文件夹（保留收藏）',
                      icon: const LumeIcon(
                        Icons.delete_outline,
                        slot: 'favorite_folder_dialogs.1',
                      ),
                      onPressed: () {
                        folders.remove(entry.key);
                        update(() {});
                      },
                    ),
                  ),
                TextField(
                  maxLength: 40,
                  onChanged: (value) => typed = value,
                  decoration: InputDecoration(
                    hintText: '新建文件夹名称',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
          FilledButton(
            onPressed: () {
              update(
                () => error = folders.create(typed) ? null : '请输入不重复的文件夹名称',
              );
            },
            child: const Text('新建文件夹'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> chooseFavoriteFolder(
  BuildContext context,
  FavoriteFolders folders,
  String itemId,
) async {
  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('移动到收藏夹'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('未分组'),
        ),
        for (final name in folders.load().keys)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, name),
            child: Text(name),
          ),
      ],
    ),
  );
  if (chosen == null) return false;
  folders.move(itemId, chosen.isEmpty ? null : chosen);
  return true;
}
