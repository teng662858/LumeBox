import 'package:flutter/material.dart';

import '../../core/source/source.dart';

Future<List<int>?> selectDownloadChapters(
  BuildContext context,
  List<SourceChapter> chapters, {
  int initial = 0,
}) {
  final selected = <int>{
    if (chapters.isNotEmpty) initial.clamp(0, chapters.length - 1),
  };
  return showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('选择下载章节 / 剧集'),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(
                      () => selected.addAll(
                        List.generate(chapters.length, (i) => i),
                      ),
                    ),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setState(selected.clear),
                    child: const Text('清空'),
                  ),
                  const Spacer(),
                  Text('已选 ${selected.length}'),
                  const SizedBox(width: 16),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: chapters.length,
                  itemBuilder: (context, index) => CheckboxListTile(
                    value: selected.contains(index),
                    title: Text(chapters[index].title),
                    onChanged: (value) => setState(
                      () => value == true
                          ? selected.add(index)
                          : selected.remove(index),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          final result = selected.toList()..sort();
                          Navigator.pop(context, result);
                        },
                  child: const Text('开始下载'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
