import 'package:flutter/material.dart';

import '../../core/cache/section_memory_cache.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'section_cache.dart';

/// 缓存管理：分板块统计与按板块清理（磁盘缓存 + 内存缓存）。
///
/// 四个板块的缓存互相独立：统计只读本板块目录，清理只删本板块文件；
/// 用户保存的图片（exports）只展示、不参与清理。
///
/// 内存缓存（[SectionMemoryCache]）与磁盘缓存分开管理：它是应用级的
/// 「本次运行」缓存（分类 / 详情 / 章节的读结果），退出应用即消失，
/// 不落盘、不参与过期策略；这里按板块给一个「清空」按钮。
class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key, this.service = const SectionCacheService()});

  final SectionCacheService service;

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  List<SectionCacheStats>? _stats;
  bool _failed = false;

  /// 各板块的缓存策略（容量上限 + 过期天数）。
  final Map<Section, SectionCachePolicy> _policies =
      <Section, SectionCachePolicy>{};

  @override
  void initState() {
    super.initState();
    _reload();
    _loadPolicies();
  }

  /// 读各板块策略：存本板块阅读库，因此逐个板块打开（失败按「不限制」处理）。
  Future<void> _loadPolicies() async {
    for (final section in Section.values) {
      try {
        final library = await ReadingLibrary.open(section);
        final policy = CachePolicyStore(library).load(section);
        if (!mounted) return;
        setState(() => _policies[section] = policy);
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
  }

  /// 改某板块策略：落库并立刻按新策略修剪一次（改了上限就该马上生效）。
  Future<void> _updatePolicy(Section section, SectionCachePolicy policy) async {
    setState(() => _policies[section] = policy);
    try {
      final library = await ReadingLibrary.open(section);
      CachePolicyStore(library).save(section, policy);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('策略保存失败：$error')),
      );
      return;
    }
    final result = await widget.service.prune(section, policy);
    if (!mounted) return;
    if (!result.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('按新策略${result.describe()}')),
      );
    }
    await _reload();
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

  /// 清空一个板块的内存缓存（只影响本板块；其他板块一条不动）。
  ///
  /// 内存缓存是同步的（登记表在应用内存里），因此这里不需要 await——
  /// 清完直接重建页面，占用数字当场归零。
  void _clearMemory(Section section) {
    final removed = SectionMemoryCache.instance.clear(section);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed == 0
              ? '${section.label}的内存缓存已是空的'
              : '已清空${section.label}内存缓存（$removed 项）',
        ),
      ),
    );
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
          _CacheTile(
            stats: item,
            policy: _policies[item.section] ?? SectionCachePolicy.unlimited,
            memory: SectionMemoryCache.instance.usageOf(item.section),
            onClear: () => _clear(item),
            onClearMemory: () => _clearMemory(item.section),
            onPolicyChanged: (policy) => _updatePolicy(item.section, policy),
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          '清理只删除可再生缓存；用户保存的图片、书架信息与阅读进度都不在清理范围。\n'
          '内存缓存只在本次运行有效，退出应用即消失，不落盘。',
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
  const _CacheTile({
    required this.stats,
    required this.policy,
    required this.memory,
    required this.onClear,
    required this.onClearMemory,
    required this.onPolicyChanged,
  });

  final SectionCacheStats stats;

  /// 本板块的缓存策略。
  final SectionCachePolicy policy;

  /// 本板块的内存缓存占用（应用级，跨页面保留）。
  final MemoryCacheUsage memory;

  final VoidCallback onClear;
  final VoidCallback onClearMemory;
  final ValueChanged<SectionCachePolicy> onPolicyChanged;

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
                const SizedBox(height: 4),
                // 策略摘要：点开逐板块配置（文档要求各板块独立配置）。
                InkWell(
                  onTap: () => _openPolicy(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.tune,
                        size: 14,
                        color: LumeTheme.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        policy.describe(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // 内存缓存：应用级、只本次运行有效；按板块清空，别的板块不受影响。
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '内存缓存 ${memory.describe()}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: memory.isEmpty ? null : onClearMemory,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('清空'),
                    ),
                  ],
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

  /// 打开本板块的策略编辑弹窗。
  Future<void> _openPolicy(BuildContext context) async {
    final next = await showDialog<SectionCachePolicy>(
      context: context,
      builder: (_) => _CachePolicyDialog(
        section: stats.section,
        policy: policy,
      ),
    );
    if (next == null) return;
    onPolicyChanged(next);
  }
}

/// 缓存策略弹窗：容量上限 + 过期天数（档位选择，避免手输离谱数字）。
class _CachePolicyDialog extends StatefulWidget {
  const _CachePolicyDialog({required this.section, required this.policy});

  final Section section;
  final SectionCachePolicy policy;

  @override
  State<_CachePolicyDialog> createState() => _CachePolicyDialogState();
}

class _CachePolicyDialogState extends State<_CachePolicyDialog> {
  late int _maxMb =
      widget.policy.maxBytes ~/ (1024 * 1024);
  late int _ageDays = widget.policy.maxAgeDays;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.section.label} · 缓存策略'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '超过上限或过期的缓存会在保存策略时立刻清理一次，之后每次进本页'
                '也会按策略修剪。用户保存的图片、书架与进度不受影响。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 16),
              const Text(
                '容量上限',
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final mb in SectionCachePolicy.capacityOptionsMb)
                    ChoiceChip(
                      label: Text(mb == 0 ? '不限制' : '$mb MB'),
                      selected: _maxMb == mb,
                      onSelected: (_) => setState(() => _maxMb = mb),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '过期天数',
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final days in SectionCachePolicy.ageOptionsDays)
                    ChoiceChip(
                      label: Text(days == 0 ? '不过期' : '$days 天'),
                      selected: _ageDays == days,
                      onSelected: (_) => setState(() => _ageDays = days),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            SectionCachePolicy(
              maxBytes: _maxMb * 1024 * 1024,
              maxAgeDays: _ageDays,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
