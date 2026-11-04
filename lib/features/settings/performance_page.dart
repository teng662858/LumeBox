import '../../core/util/source_load_profile.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/util/frame_profile.dart';
import '../../shared/widgets/glass_card.dart';

class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key});
  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  final profile = FrameProfile.instance;
  late String scene = profile.recording ? profile.scene : '长列表滑动';
  @override
  void initState() {
    super.initState();
    profile.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '流畅度采集',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ExpansionTile(
          title: const Text('本次源加载耗时'),
          subtitle: const Text('仅记录本次运行最近 30 次，不含站点地址'),
          children: [
            ValueListenableBuilder<List<String>>(
              valueListenable: SourceLoadProfile.entries,
              builder: (_, entries, _) => Column(
                children: [
                  if (entries.isEmpty)
                    const ListTile(title: Text('暂无记录，打开板块首页后再查看')),
                  for (final entry in entries) ListTile(title: Text(entry)),
                ],
              ),
            ),
          ],
        ),
        const Text(
          '选择场景后开始采集，返回对应页面操作，再回来结束。报告包含帧耗时与采集前后进程内存；不估算耗电。建议在 iPhone 的 Profile 构建上验收。',
        ),
        DropdownButton<String>(
          value: scene,
          isExpanded: true,
          items: [
            for (final value in {
              '长列表滑动',
              '漫画连续翻页',
              '视频切集',
              '大缓存清理',
              '冷启动后浏览',
              '多源聚合搜索',
              '长时间阅读',
              '视频连续播放',
              '前后台切换',
              if (profile.recording) profile.scene,
            })
              DropdownMenuItem(value: value, child: Text(value)),
          ],
          onChanged: profile.recording
              ? null
              : (v) => setState(() => scene = v!),
        ),
        FilledButton(
          onPressed: () async {
            if (profile.recording) {
              profile.stop();
              try {
                await profile.save();
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('报告未能写入磁盘，仍可复制本次结果')),
                  );
                }
              }
            } else {
              profile.start(
                scene,
                refreshRate: View.of(context).display.refreshRate,
              );
            }
            if (mounted) setState(() {});
          },
          child: Text(profile.recording ? '结束并保存报告' : '开始采集'),
        ),
        if (profile.recording) const Text('正在采集，可返回 App 继续操作。'),
        if (profile.lastReport != null) ...[
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(profile.lastReport),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: jsonEncode(profile.lastReport)),
            ),
            child: const Text('复制报告'),
          ),
        ],
      ],
    ),
  );
}
