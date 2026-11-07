import 'package:flutter/material.dart';

import '../../core/experience/content_center.dart';

Future<void> saveContentClip(
  BuildContext context,
  ContentRef ref, {
  String text = '',
  int? chapter,
  int? seconds,
  int? page,
}) async {
  final note = TextEditingController(text: text),
      folder = TextEditingController(text: '默认');
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('保存到统一摘录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ref.title),
            TextField(
              controller: folder,
              decoration: const InputDecoration(labelText: '收藏夹'),
            ),
            TextField(
              controller: note,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(labelText: '摘录或备注'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (saved == true) {
    ContentCenter.instance.clip(
      ref,
      text: note.text,
      folder: folder.text,
      chapter: chapter,
      seconds: seconds,
      page: page,
    );
  }
  Future<void>.delayed(const Duration(seconds: 1), () {
    note.dispose();
    folder.dispose();
  });
}
