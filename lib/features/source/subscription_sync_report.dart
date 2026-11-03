import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/session/section.dart';
import '../../core/source/source_subscription_sync.dart';

class SubscriptionSyncReport extends StatelessWidget {
  const SubscriptionSyncReport({super.key, required this.results});
  final Map<Section, SubscriptionSyncResult> results;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('导入结果\n“已存在”表示手机里已有相同版本，不会重复添加。只有成功导入且已启用、未隐藏的源才会出现在源选择中。'),
      ),
      for (final entry in results.entries)
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '新增 ${entry.value.added} · 更新 ${entry.value.updated} · 已存在 ${entry.value.unchanged} · 移除 ${entry.value.removed}',
                    ),
                    Text(
                      '已检查 ${entry.value.checked} 个订阅${entry.value.skipped == 0 ? '' : ' · ${entry.value.skipped} 个尚未到检查时间'}',
                    ),
                    if (entry.value.message.isNotEmpty)
                      Text(entry.value.message),
                    if (entry.value.errors.isNotEmpty)
                      Text('${entry.value.errors.length} 项待处理；成功导入的源仍然保留。'),
                  ],
                ),
              ),
              if (entry.value.errors.isNotEmpty)
                ExpansionTile(
                  title: const Text('查看未导入原因'),
                  children: [
                    for (final error in entry.value.errors)
                      ListTile(
                        title: Text(_name(error)),
                        subtitle: Text(
                          _reason(error),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(_name(error)),
                            content: SingleChildScrollView(
                              child: SelectableText(error),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: entry.value.errors.join('\n')),
                      ),
                      child: const Text('复制完整诊断信息'),
                    ),
                  ],
                ),
            ],
          ),
        ),
    ],
  );

  static String _name(String error) {
    final split = error.indexOf(': ');
    final uri = Uri.tryParse(split < 0 ? error : error.substring(0, split));
    if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
      final file = uri.pathSegments.last;
      return file.endsWith('.txt') || file.endsWith('.json')
          ? '订阅清单：$file'
          : file.replaceFirst(RegExp(r'\.(js|py)$'), '');
    }
    return '导入未完成';
  }

  static String _reason(String error) {
    if (error.contains('跨板块')) return '源的分类与导入板块不一致，未写入；原有源已保留。';
    if (error.contains('清单未完整同步')) return '部分源未能导入，已保留此订阅的旧源。';
    final split = error.indexOf(': ');
    return split < 0 ? error : error.substring(split + 2);
  }
}
