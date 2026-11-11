import '../../shared/widgets/number_setting_tile.dart';
import '../../core/session/section_module_settings.dart';

import 'package:flutter/material.dart';

import '../../core/audio_book/audio_book_player.dart';
import '../../core/cache/media_preload.dart';
import '../../core/player/video_disk_cache.dart';
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
  ReadingLibrary? library;
  SectionModuleSettings module = const SectionModuleSettings();
  @override
  void initState() {
    super.initState();
    ReadingLibrary.open(Section.video).then((value) {
      if (!mounted) return;
      setState(() {
        library = value;
        module = SectionModuleSettings.load(value);
      });
    });
  }

  void saveModule(SectionModuleSettings value) {
    final db = library;
    if (db == null) return;
    value.save(db);
    setState(() => module = value);
  }

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

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '预载与清理',
    child: ListenableBuilder(
      listenable: Listenable.merge([policy, VideoDiskCache.instance]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          SettingsGroupCard(
            children: [
              SwitchListTile(
                title: const Text('首页与列表短时缓存'),
                subtitle: const Text(
                  '复用首页、分类、搜索和资料结果；分页、关键词、筛选和源设置分别缓存。下拉刷新强制取新，播放地址不缓存。',
                ),
                value: policy.pages,
                onChanged: busy ? null : (v) => policy.update(pages: v),
              ),
              NumberSettingTile(
                title: '页面缓存保留时长',
                value: policy.pageCacheSeconds,
                min: 15,
                max: 900,
                unit: '秒',
                onChanged: busy
                    ? null
                    : (v) => policy.update(pageCacheSeconds: v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsGroupCard(
            children: [
              SwitchListTile(
                title: const Text('视频磁盘缓冲'),
                subtitle: const Text(
                  '提前读取的视频写入手机存储；空间不足时回退内核内存缓冲。切换后重新加载视频生效。',
                ),
                value: VideoDiskCache.instance.enabled,
                onChanged: busy
                    ? null
                    : (v) async {
                        await VideoDiskCache.instance.configure(enabled: v);
                      },
              ),
              SwitchListTile(
                title: const Text('自动跳过 HLS 插播广告'),
                subtitle: const Text(
                  '跳过有明确 CUE-OUT / CUE-IN 标记的点播广告段；加密、直播及无标记广告保持原样。重新加载生效，也用于新下载。',
                ),
                value: VideoDiskCache.instance.skipHlsAds,
                onChanged: busy
                    ? null
                    : (v) => VideoDiskCache.instance.configure(skipHlsAds: v),
              ),
              NumberSettingTile(
                title: '视频磁盘容量上限',
                value: VideoDiskCache.instance.capacityMb,
                min: 100,
                max: 20480,
                unit: 'MB',
                onChanged: busy
                    ? null
                    : (v) => VideoDiskCache.instance.configure(capacityMb: v),
              ),
              NumberSettingTile(
                title: '当前视频预读时长',
                value: module.bufferSeconds == 0 ? 300 : module.bufferSeconds,
                min: 5,
                max: 3600,
                unit: '秒',
                onChanged: busy || library == null
                    ? null
                    : (v) => saveModule(module.copyWith(bufferSeconds: v)),
              ),
              NumberSettingTile(
                title: '播放内存预算',
                value: module.bufferMiB,
                min: 32,
                max: 1024,
                unit: 'MiB',
                onChanged: busy || library == null
                    ? null
                    : (v) => saveModule(module.copyWith(bufferMiB: v)),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '这些是预读上限，不会等待填满才起播。内核对时长、内存上限的支持不同；AVPlayer 不提供严格内存限额。参数在重新加载时生效。',
                ),
              ),
              ListTile(
                title: const Text('清理视频磁盘缓冲'),
                subtitle: Text(
                  '${(VideoDiskCache.instance.bytes / 1048576).toStringAsFixed(1)} MiB · ${VideoDiskCache.instance.status}',
                ),
                trailing: const Icon(Icons.cleaning_services_outlined),
                onTap: busy
                    ? null
                    : () => clean('清理视频磁盘缓冲', '只清理临时播放数据；不会删除离线下载、收藏或进度。', () async {
                        final bytes = await VideoDiskCache.instance.clear();
                        return '已释放 ${(bytes / 1048576).toStringAsFixed(1)} MiB';
                      }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsGroupCard(
            children: [
              SwitchListTile(
                title: const Text('视频下一集预载'),
                subtitle: Text(
                  '播放到 ${policy.triggerPercent}% 或片尾前指定秒数时准备下一集；当前集优先，至少保有 15 秒缓冲或片尾已全部缓冲才开始',
                ),
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
              NumberSettingTile(
                title: '片尾前刷新预载',
                value: policy.triggerSeconds,
                min: 5,
                max: 1800,
                unit: '秒',
                onChanged: busy
                    ? null
                    : (v) => policy.update(triggerSeconds: v),
              ),
              NumberSettingTile(
                title: '预载触发进度',
                value: policy.triggerPercent,
                min: 50,
                max: 99,
                unit: '%',
                onChanged: busy
                    ? null
                    : (v) => policy.update(triggerPercent: v),
              ),
              NumberSettingTile(
                title: '音视频目标预缓冲',
                value: policy.bufferSeconds,
                min: 3,
                max: 300,
                unit: '秒',
                onChanged: busy ? null : (v) => policy.update(bufferSeconds: v),
              ),
              NumberSettingTile(
                title: '预载容量预算',
                value: policy.capacityMb,
                min: 16,
                max: 2048,
                unit: 'MiB',
                onChanged: busy ? null : (v) => policy.update(capacityMb: v),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '预载预算：图片占一半，音视频各占四分之一。预缓冲时长与容量先达到一项即受限，内核不保证严格字节上限。',
                ),
              ),
              SwitchListTile(
                title: const Text('仅在 Wi-Fi 下额外预读'),
                subtitle: const Text('蜂窝或无法确认网络时暂停视频磁盘预读与下一集预载；正常播放继续。'),
                value: policy.wifiOnly,
                onChanged: busy ? null : (v) => policy.update(wifiOnly: v),
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
