import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../source/global_source_page.dart';
import '../video/player_kernel_section.dart';
import '../video/player_settings_host.dart';
import 'cache_settings_page.dart';
import 'network_settings_page.dart';
import 'log_report.dart';
import 'log_report_page.dart';
import 'log_viewer_page.dart';
import 'section_cache.dart';
import 'source_generator_page.dart';

/// 设置：图源总管理、缓存管理、运行日志查看与错误报告导出。
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
        behindBar: true,
        title: '设置',
        child: const SkeletonNotice(),
      );
    }
    return GlassScaffold(
      title: '设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          _SettingsEntry(
            icon: Icons.tune,
            title: '源总管理',
            subtitle: '四个板块的源总览与批量管理（小说 / 漫画 / 视频 / 猫源互相独立）',
            onTap: () => _push(context, const GlobalSourcePage()),
          ),
          const SizedBox(height: 12),
          // 播放器设置（内核 / 倍速 / 字幕）：从视频板块右上角迁到这里——
          // 板块页右上角只留「图源管理」，两件事不再抢同一个按钮。
          _SettingsEntry(
            icon: Icons.play_circle_outline_rounded,
            title: '播放器设置',
            subtitle: '播放内核、倍速、字幕基础配置（写视频板块自己的设置库）',
            onTap: () => _push(context, const PlayerSettingsHost()),
          ),
          const SizedBox(height: 12),
          // 故障逃生入口：内核选择列表**内嵌**在设置页里（点得最少、最稳），
          // 与视频板块的快捷入口共用同一份列表组件。
          const PlayerKernelSection(),
          const SizedBox(height: 12),
          _SettingsEntry(
            icon: Icons.wifi_tethering,
            title: '网络设置',
            subtitle: '全局并发、单域名并发、UA、代理、超时与重试（四板块共用）',
            onTap: () => _push(context, const NetworkSettingsPage()),
          ),
          const SizedBox(height: 12),
          _SettingsEntry(
            icon: Icons.cleaning_services_outlined,
            title: '缓存管理',
            subtitle: '按板块清理磁盘缓存与内存缓存（漫画 / 小说 / 视频 / 猫源互相独立）',
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
          const SizedBox(height: 12),
          // 预留扩展项（Phase2 收尾）：只搭 UI 骨架，所有按钮弹「功能开发中」。
          // 放设置页而不是新增底部 Tab —— 生成器是工具附属功能、不是主阅读板块，
          // 底部 5 个主 Tab（小说 / 漫画 / 视频 / 猫源 / 设置）保持不变。
          _SettingsEntry(
            icon: Icons.auto_fix_high_outlined,
            title: '图源生成器（开发中）',
            subtitle: '可视化爬虫：配置网址与规则后生成图源脚本（预留功能，尚未实现）',
            onTap: () => _push(context, const SourceGeneratorPage()),
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
          Icon(icon, size: 22, color: LumeTheme.textSecondary),
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
                    color: LumeTheme.textPrimary,
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
