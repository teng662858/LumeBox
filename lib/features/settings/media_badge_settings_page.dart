import 'package:flutter/material.dart';

import '../../shared/widgets/media_badges.dart';

class MediaBadgeSettingsPage extends StatelessWidget {
  const MediaBadgeSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MediaBadgeSettings.instance,
    builder: (context, _) {
      final settings = MediaBadgeSettings.instance;
      return Scaffold(
        appBar: AppBar(title: const Text('媒体徽章')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Column(
                children: [
                  for (final entry in const [
                    ('enabled', '启用媒体徽章'),
                    ('card', '在资源卡片中显示'),
                    ('detail', '在详情中显示'),
                    ('player', '在播放器中显示'),
                    ('followControls', '随播放控件显示或隐藏'),
                  ])
                    SwitchListTile(
                      title: Text(entry.$2),
                      value: settings.enabled(entry.$1),
                      onChanged: (value) => settings.set(entry.$1, value),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('图形样式'),
              subtitle: const Text('关闭使用简洁文字，开启增加媒体图标'),
              value: settings.graphic,
              onChanged: (value) => settings.set('graphic', value),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('效果预览 · 演示参数'),
            ),
            for (final entry in const [
              (
                'WEB-DL',
                ['4K', 'Dolby Vision', 'HEVC', '10bit', 'Atmos', '5.1'],
              ),
              ('高清资源', ['720P', 'H.264', 'AAC', '2.0']),
              (
                'BluRay Remux',
                ['4K', 'HDR10', 'HEVC', '10bit', 'TrueHD', '7.1'],
              ),
            ])
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.$1,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      MediaBadges(values: entry.$2, preview: true),
                    ],
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '每类规格一个徽章，卡片最多两个，详情最多八个。真实内容只展示源明确提供或播放器实际读取的参数；未知项自动省略。预览参数不代表当前视频规格。',
              ),
            ),
          ],
        ),
      );
    },
  );
}
