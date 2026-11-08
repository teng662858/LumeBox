import 'package:flutter/material.dart';

import '../../core/audio_book/audio_book_player.dart';
import '../../core/cache/media_preload.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source_favicon.dart';
import '../../core/tmdb/tmdb.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class PreloadSettingsPage extends StatefulWidget {
  const PreloadSettingsPage({super.key});
  @override
  State<PreloadSettingsPage> createState() => _PreloadSettingsPageState();
}

class _PreloadSettingsPageState extends State<PreloadSettingsPage> {
  final policy = MediaPreload.instance;
  bool busy = false;

  Future<void> clean(
    String title,
    String detail,
    Future<String> Function() action,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final message = await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未全部完成，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget slider(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text('$label · $value 秒'),
      ),
      Slider(
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max - min,
        label: '$value 秒',
        onChanged: busy ? null : (value) => update(value.round()),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '预载与清理',
    child: ListenableBuilder(
      listenable: policy,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          SettingsGroupCard(
            children: [
              SwitchListTile(
                title: const Text('视频下一集预载'),
                subtitle: const Text('当前播放稳定后准备下一集，临近片尾刷新较旧的预载'),
                value: policy.video,
                onChanged: busy ? null : (v) => policy.update(video: v),
              ),
              SwitchListTile(
                title: const Text('图片预载'),
                subtitle: const Text('提前读取列表封面和阅读器附近图片；关闭后仍正常加载可见图片'),
                value: policy.images,
                onChanged: busy ? null : (v) => policy.update(images: v),
              ),
              SwitchListTile(
                title: const Text('音频预载'),
                subtitle: const Text('允许内核提前准备后续音频；开关在下一次加载音频时生效'),
                value: policy.audio,
                onChanged: busy ? null : (v) => policy.update(audio: v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsGroupCard(
            children: [
              slider(
                '片尾前刷新预载',
                policy.triggerSeconds,
                10,
                120,
                (v) => policy.update(triggerSeconds: v),
              ),
              slider(
                '音视频目标预缓冲',
                policy.bufferSeconds,
                3,
                60,
                (v) => policy.update(bufferSeconds: v),
              ),
              ListTile(
                title: const Text('预载容量预算'),
                subtitle: const Text(
                  '图片磁盘缓存占一半，音视频各分配四分之一预算；内核不保证严格字节上限。音频参数在重新加载资源时生效。',
                ),
                trailing: DropdownButton<int>(
                  value: policy.capacityMb,
                  items: [
                    for (final mb in {
                      16,
                      32,
                      64,
                      128,
                      256,
                      policy.capacityMb,
                    }.toList()..sort())
                      DropdownMenuItem(value: mb, child: Text('$mb MB')),
                  ],
                  onChanged: busy
                      ? null
                      : (v) {
                          if (v != null) policy.update(capacityMb: v);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsGroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text('清理预载缓存'),
                subtitle: Text(
                  '图片预载 ${(policy.diskBytes / 1048576).toStringAsFixed(1)} MB · 释放未播放的准备实例',
                ),
                enabled: !busy,
                onTap: () => clean('清理预载缓存', '清理自动预读的图片和下一集准备实例。音频会保留当前进度，可能短暂重新缓冲；普通缓存、收藏与历史不删除。', () async {
                  final bytes = await policy.clear();
                  return '已释放预载实例并清理 ${(bytes / 1048576).toStringAsFixed(1)} MB 图片预载';
                }),
              ),
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: const Text('清理 TMDB 缓存'),
                subtitle: const Text('清除资料、选图和图片内存缓存，保留 API Key 和代理设置'),
                enabled: !busy,
                onTap: () => clean(
                  '清理 TMDB 缓存',
                  '下次打开详情需要重新获取资料；手动匹配和选图结果也会移除。',
                  () async {
                    final count = await TmdbSettings.instance
                        .clearMetadataCache();
                    return '已清理 $count 条 TMDB 资料';
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('清理源图标缓存'),
                subtitle: const Text('保留图标设置，下次显示源列表时重新获取站点图标'),
                enabled: !busy,
                onTap: () => clean(
                  '清理源图标缓存',
                  '删除自动下载的站点图标，不删除源脚本或自定义图标包。',
                  () async {
                    final bytes = await SourceFavicon.instance.clearDiskCache();
                    return '已清理 ${(bytes / 1024).round()} KB 源图标';
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('清空观看与阅读历史'),
              subtitle: const Text('所有板块的历史与续播进度，保留收藏和源'),
              enabled: !busy,
              onTap: () => clean(
                '清空观看与阅读历史',
                '删除所有板块的观看、阅读和听书进度，包括隐藏条目。收藏、已下载文件和源不删除。正在播放会继续产生新的进度记录。',
                () async {
                  var count = 0;
                  for (final section in Section.values) {
                    count += (await ReadingLibrary.open(section))
                        .clearHistory();
                  }
                  final audio = AudioBookSettings.instance;
                  await audio.load();
                  audio.positions.clear();
                  audio.chapterIds.clear();
                  await audio.save();
                  return '已清空历史与续播记录（$count 项）';
                },
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}
