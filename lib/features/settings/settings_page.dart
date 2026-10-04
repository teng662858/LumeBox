import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import 'cache_settings_page.dart';
import 'log_report.dart';
import 'log_report_page.dart';
import 'log_viewer_page.dart';
import 'section_cache.dart';

/// 设置：缓存管理、运行日志查看与错误报告导出。
///
/// 平台边界（任务书第 3 条 + 宪法第 1 条）：完整业务只在 iOS；Android /
/// Windows 只保留页面骨架占位——不做缓存统计清理，也不做报告导出。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.runtimeAvailable,
    this.cacheService = const SectionCacheService(),
    this.exporter = const LogExporter(),
  });

  /// 平台是否提供完整业务；为空时取 [LumeSources.runtimeAvailable]。
  final bool? runtimeAvailable;

  /// 分板块缓存服务（测试可注入）。
  final SectionCacheService cacheService;

  /// 报告导出器（测试可注入时钟）。
  final LogExporter exporter;

  bool get _available => runtimeAvailable ?? LumeSources.runtimeAvailable;

  @override
  Widget build(BuildContext context) {
    if (!_available) {
      return GlassScaffold(
        title: '设置',
        child: const SkeletonNotice(),
      );
    }
    return GlassScaffold(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _SettingsEntry(
            icon: Icons.cleaning_services_outlined,
            title: '缓存管理',
            subtitle: '按板块查看与清理缓存（漫画 / 小说 / 自定义视频 / 猫源互相独立）',
            onTap: () => _push(context, CacheSettingsPage(service: cacheService)),
          ),
          const SizedBox(height: 12),
          _SettingsEntry(
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: '查看本次运行的日志：信息 / 警告 / 错误',
            onTap: () => _push(context, LogViewerPage(exporter: exporter)),
          ),
          const SizedBox(height: 12),
          _SettingsEntry(
            icon: Icons.file_upload_outlined,
            title: '错误报告',
            subtitle: '把错误与警告整理成报告，导出文件或复制全文',
            onTap: () => _push(context, LogReportPage(exporter: exporter)),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 22, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: LumeTheme.muted),
        ],
      ),
    );
  }
}
