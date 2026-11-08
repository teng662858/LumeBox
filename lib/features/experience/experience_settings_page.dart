import '../../shared/widgets/glass_card.dart';

import 'package:flutter/material.dart';

import '../../core/experience/content_center.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_capability_history.dart';
import '../source/source_health_page.dart';
import 'content_center_page.dart';
import 'subtitle_center_page.dart';

class ExperienceSettingsPage extends StatelessWidget {
  const ExperienceSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ContentCenter.instance,
    builder: (context, _) {
      final center = ContentCenter.instance;
      void open(Widget page) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => page),
      );
      return GlassScaffold(
        effectModule: GlassModule.settings,
        title: '内容与播放增强',
        child: SettingsSurfaceList(
          children: [
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text('内容中心'),
              subtitle: const Text('继续、追更、作品版本和摘录'),
              onTap: () => open(const ContentCenterPage()),
            ),
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: const Text('字幕中心'),
              subtitle: const Text('在线搜索、语言优先级与本地双语合并'),
              onTap: () => open(const SubtitleCenterPage()),
            ),
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: const Text('源能力档案'),
              onTap: () => open(const SourceProfilesPage()),
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('回到前台自动检查更新'),
              subtitle: const Text('每六小时最多一次，不保证 iOS 后台持续检查'),
              value: center.enabled('autoChecks'),
              onChanged: (v) => center.put('autoChecks', v),
            ),
            SwitchListTile(
              title: const Text('自动清理已看完的离线剧集'),
              subtitle: const Text('只清理已播放完成、文件保存超过七天的 App 内视频；已导出副本保留'),
              value: center.enabled('cleanupWatched'),
              onChanged: (value) => center.put('cleanupWatched', value),
            ),
            SwitchListTile(
              title: const Text('更新时跳过持续异常的源'),
              subtitle: const Text('源停用或连续失败达到三次时不自动请求'),
              value: center.enabled('skipUnhealthy'),
              onChanged: (v) => center.put('skipUnhealthy', v),
            ),
            for (final entry in const [
              ('autoRecover', '播放失败自动尝试备用线路', '只尝试同作品的其他线路；登录或授权失败不自动重试'),
              (
                'autoReadDownloads',
                '阅读时下载后续章节',
                '漫画加入离线任务，小说正文保存到本机；与 Wi-Fi 和空间策略联动',
              ),
              ('autoNextDownloads', '观看时缓存后续剧集', '当前线路接下来几集；不会重复下载已有文件'),
              ('wifiOnly', '仅在 Wi-Fi 下开始下载', '无法确认网络时暂停，避免误用移动流量'),
              ('pauseDuringPlayback', '播放时暂停启动下载', '已有下载在分片或数据块检查点暂停'),
              ('downloadUpdates', '追更后下载新章节', '视频加入离线队列；漫画和小说遵循阅读预下载开关'),
            ])
              SwitchListTile(
                title: Text(entry.$2),
                subtitle: Text(entry.$3),
                value: center.enabled(entry.$1),
                onChanged: (v) => center.put(entry.$1, v),
              ),
            ListTile(
              title: Text('预下载数量：${center.number('nextDownloads', 2)} 集'),
              subtitle: Slider(
                value: center.number('nextDownloads', 2).clamp(1, 5).toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: (v) => center.put('nextDownloads', v.round()),
              ),
            ),
            ListTile(
              title: Text('保留空间：${center.number('reserveMB', 0)} MB'),
              subtitle: Slider(
                value: center.number('reserveMB', 0).clamp(0, 4096).toDouble(),
                min: 0,
                max: 4096,
                divisions: 8,
                onChanged: (v) => center.put('reserveMB', v.round()),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class SourceProfilesPage extends StatefulWidget {
  const SourceProfilesPage({super.key});
  @override
  State<SourceProfilesPage> createState() => _SourceProfilesPageState();
}

class _SourceProfilesPageState extends State<SourceProfilesPage> {
  final records =
      <
        ({
          ReadingLibrary library,
          SourceManager manager,
          SourceDescriptor source,
        })
      >[];
  String error = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    records.clear();
    for (final section in Section.values) {
      try {
        final lib = await ReadingLibrary.open(section);
        final manager = LumeSources.manager(section);
        for (final source in await manager.list()) {
          records.add((library: lib, manager: manager, source: source));
        }
      } catch (_) {
        error = '部分板块读取失败';
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '源能力档案',
    actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    child: SettingsSurfaceList(
      children: [
        if (error.isNotEmpty) Text(error),
        for (final record in records)
          ListTile(
            title: Text(
              '${record.source.name} · ${record.library.section.label}',
            ),
            subtitle: Text(
              SourceCapabilityHistory.summary(
                record.library,
                record.source.id,
                record.source.version,
              ),
            ),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SourceHealthPage(
                    section: record.library.section,
                    manager: record.manager,
                    source: record.source,
                  ),
                ),
              );
              load();
            },
          ),
      ],
    ),
  );
}
