import 'package:flutter/material.dart';

import '../../shared/widgets/media_badges.dart';

class MediaBadgeSettingsPage extends StatelessWidget {
  const MediaBadgeSettingsPage({super.key});
  static const _sample = [
    '4K',
    'Dolby Vision',
    'HEVC',
    '10bit',
    'Atmos',
    '5.1',
    '24FPS',
    '中文',
  ];
  Widget _scene(BuildContext context, String title, Widget child) => Card(
    margin: const EdgeInsets.only(top: 8, bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
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
            const SizedBox(height: 16),
            const Text('显示方式'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const [
                  ('text', '纯文字'),
                  ('compact', '紧凑徽章'),
                  ('graphic', '图文徽章'),
                ])
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: settings.style == entry.$1,
                    onSelected: (_) => settings.setStyle(entry.$1),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('效果预览 · 演示参数'),
            ),
            _scene(
              context,
              '海报角标 · 最多两个',
              Container(
                height: 150,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF233D49), Color(0xFF73758F)],
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                  ),
                ),
                padding: const EdgeInsets.all(12),
                child: const Stack(
                  children: [
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Text(
                        '山海之间',
                        style: TextStyle(color: Colors.white, fontSize: 22),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topRight,
                      child: MediaBadges(
                        values: _sample,
                        location: 'card',
                        overlay: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _scene(
              context,
              '详情规格 · 完整信息',
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '山海之间 · WEB-DL',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 10),
                  MediaBadges(values: _sample),
                ],
              ),
            ),
            _scene(
              context,
              '播放器 · 只保留关键规格',
              Container(
                padding: const EdgeInsets.all(16),
                color: const Color(0xFF171E25),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('第1集', style: TextStyle(color: Colors.white)),
                    SizedBox(height: 8),
                    MediaBadges(
                      values: _sample,
                      location: 'player',
                      overlay: true,
                    ),
                    SizedBox(height: 32),
                    LinearProgressIndicator(value: .35),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('显示哪些规格'),
              subtitle: const Text('每一类都可以单独关闭'),
              children: [
                for (final kind in MediaBadgeKind.values)
                  SwitchListTile(
                    secondary: Icon(kind.icon),
                    title: Text(kind.label),
                    value: settings.enabled('kind.${kind.name}'),
                    onChanged: (value) =>
                        settings.set('kind.${kind.name}', value),
                  ),
              ],
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
