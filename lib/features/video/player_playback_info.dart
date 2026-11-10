import '../../core/player/playback_health.dart';
import '../../core/player/video_disk_cache.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/player_stats.dart';
import 'player_speed_meter.dart';

/// Live playback diagnostics; the diagnostic copy omits signed URLs and headers.
class PlayerPlaybackInfo extends StatelessWidget {
  const PlayerPlaybackInfo({
    super.key,
    required this.address,
    required this.source,
    required this.quality,
    required this.kernel,
    required this.line,
    required this.stats,
    required this.snapshot,
    this.onCopied,
    this.operation,
    this.nextEpisodeStatus,
  });

  final Uri address;
  final String? operation;
  final String Function()? nextEpisodeStatus;
  final String source, quality, kernel;
  final Future<String?> line;
  final ValueListenable<PlayerStats> stats;
  final ValueListenable<PlayerSnapshot> snapshot;
  final ValueChanged<String>? onCopied;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: line,
    builder: (context, route) => ListenableBuilder(
      listenable: Listenable.merge([stats, snapshot, VideoDiskCache.instance]),
      builder: (context, _) {
        final value = stats.value;
        final state = snapshot.value;
        final details = <String, String>{
          '诊断建议': PlaybackHealth.describe(state, value, operation: operation),
          '源': source,
          '线路': route.connectionState == ConnectionState.waiting
              ? '正在读取…'
              : route.data ?? '未提供',
          '画质': quality,
          '实际内核': kernel,
          '播放缓存': VideoDiskCache.instance.status,
          '磁盘占用':
              '${(VideoDiskCache.instance.bytes / 1048576).toStringAsFixed(1)} / ${VideoDiskCache.instance.capacityMb} MiB',
          '缓存命中': '${VideoDiskCache.instance.hits} 次',
          '缓存层读取量':
              '${(VideoDiskCache.instance.downloadedBytes / 1048576).toStringAsFixed(1)} MiB（本次运行，含预载）',
          if (VideoDiskCache.instance.enabled) '速率口径': '缓存代理下的内核输入速率包含磁盘命中数据',
          if (nextEpisodeStatus != null) '下一集预载': nextEpisodeStatus!(),
          '媒体码率':
              '${(value.videoBitrateKbps ?? 0) + (value.audioBitrateKbps ?? 0)} kbps',
          '分辨率': value.resolutionText ?? '未提供',
          '状态': state.error != null
              ? '播放错误'
              : state.buffering
              ? '正在缓冲'
              : state.playing
              ? '播放中'
              : '已暂停或停止',
          '播放位置': '${state.position.inSeconds} / ${state.duration.inSeconds} 秒',
          '已缓冲': value.buffered == null
              ? '未知'
              : '${(value.buffered!.inMilliseconds / 1000).toStringAsFixed(1)} 秒',
          '实时下载': value.downloadBytesPerSecond == null
              ? '当前内核未提供'
              : PlaybackSpeedMeter.describeBytes(value.downloadBytesPerSecond!),
          '媒体域名': address.host.isEmpty ? '本地文件' : address.host,
        };
        return AlertDialog(
          title: const Text('播放信息'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in details.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('${item.key}：${item.value}'),
                  ),
                const Text('播放地址'),
                SelectableText(
                  address.toString(),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: details.entries
                        .map((e) => '${e.key}：${e.value}')
                        .join('\n'),
                  ),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制诊断信息'),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: address.toString()),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制地址'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
