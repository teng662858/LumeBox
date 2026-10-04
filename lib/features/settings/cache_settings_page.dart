import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'section_cache.dart';

/// 缓存管理：分板块统计与按板块清理。
///
/// 四个板块的缓存互相独立：统计只读本板块目录，清理只删本板块文件；
/// 用户保存的图片（exports）只展示、不参与清理。
class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key, this.service = const SectionCacheService()});

  final SectionCacheService service;

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  List<SectionCacheStats>? _stats;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final stats = await widget.service.inspectAll();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _failed = false;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _clear(SectionCacheStats stats) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清理${stats.section.label}缓存'),
        content: Text(
          '将清理 ${_formatBytes(stats.cacheBytes)} 缓存（${stats.cacheFiles} 个文件）。\n'
          '已保存的图片、书架与阅读进度都不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final freed = await widget.service.clear(stats.section);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已清理 ${stats.section.label} ${_formatBytes(freed)} 缓存'),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: '缓存管理',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: _reload,
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_failed) {
      return const NoticeCard(
        title: '缓存统计不可用',
        subtitle: '板块目录打不开，请重启应用后重试',
      );
    }
    final stats = _stats;
    if (stats == null) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    final totalCache = stats.fold<int>(0, (sum, item) => sum + item.cacheBytes);
    final totalSaved = stats.fold<int>(0, (sum, item) => sum + item.savedBytes);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          '合计缓存 ${_formatBytes(totalCache)}'
          '${totalSaved > 0 ? ' · 已保存图片 ${_formatBytes(totalSaved)}' : ''}',
          style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
        ),
        const SizedBox(height: 12),
        for (final item in stats) ...<Widget>[
          _CacheTile(stats: item, onClear: () => _clear(item)),
          const SizedBox(height: 12),
        ],
        const Text(
          '清理只删除可再生缓存；用户保存的图片、书架信息与阅读进度都不在清理范围。',
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _CacheTile extends StatelessWidget {
  const _CacheTile({required this.stats, required this.onClear});

  final SectionCacheStats stats;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  stats.section.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '缓存 ${_CacheSettingsPageState._formatBytes(stats.cacheBytes)}'
                  '（${stats.cacheFiles} 个文件）',
                  style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                if (stats.savedBytes > 0)
                  Text(
                    '已保存图片 '
                    '${_CacheSettingsPageState._formatBytes(stats.savedBytes)}'
                    '（不参与清理）',
                    style: const TextStyle(
                      fontSize: 12,
                      color: LumeTheme.muted,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: stats.hasCache ? onClear : null,
            child: const Text('清理'),
          ),
        ],
      ),
    );
  }
}
