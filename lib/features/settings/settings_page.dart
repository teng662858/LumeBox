import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/source/source.dart';
import '../../core/reading/browse_layout.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../source/global_source_page.dart';
import '../video/player_kernel_section.dart';
import '../video/player_settings_host.dart';
import 'cache_settings_page.dart';
import 'display_settings_group.dart';
import 'debug_panel_page.dart';
import 'network_settings_page.dart';
import 'playback_settings_group.dart';
import 'log_report.dart';
import 'log_report_page.dart';
import 'log_viewer_page.dart';
import 'sandbox_settings_page.dart';
import 'tab_bar_settings_page.dart';
import 'section_cache.dart';

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
      // behindBar：内容从玻璃顶栏**底下**穿过（滚动时透出磨砂），顶部留给内容的
      // 空间由列表自己的 barInset 让。少了这一句，SafeArea 会先让一次栏高、
      // barInset 再让一次，顶栏高度被算两遍——真机上表现为首卡离顶栏一大截
      // （实测 131pt 空隙，应当是 16pt）。
      behindBar: true,
      title: '设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          // 分组标题只是视觉归类：每块一张卡，条目按「用户要改什么」摆放
          //（真机反馈「设置太乱」后按此口径重排）。
          const _GroupTitle('界面'),
          const DisplaySettingsGroup(showTitle: false), // 外观 + 主题色
          const SizedBox(height: 10),
          const GridTitleStyleRow(), // 网格标题：遮罩内置 / 外置独立
          const SizedBox(height: 10),
          _SettingsEntry(
            icon: Icons.dashboard_customize_outlined,
            title: '底部导航栏管理',
            subtitle: '每个页签独立开关 + 拖拽排序（至少保留 1 个；改动立即生效）',
            onTap: () => _push(context, const TabBarSettingsPage()),
          ),
          const SizedBox(height: 20),
          const _GroupTitle('播放'),
          // 方向偏好（横屏播放）+ 播放器设置 + 内核逃生入口都归到这一组：
          // 它们都是「播放怎么进行」的设置，散在三处最难找。
          const PlaybackSettingsGroup(showTitle: false),
          const SizedBox(height: 10),
          _SettingsEntry(
            icon: Icons.play_circle_outline_rounded,
            title: '播放器设置',
            subtitle: '播放内核、倍速、字幕、方向锁定（写视频板块自己的设置库）',
            onTap: () => _push(context, const PlayerSettingsHost()),
          ),
          const SizedBox(height: 10),
          // 故障逃生入口：内核选择列表**内嵌**在设置页里（点得最少、最稳），
          // 与视频板块的快捷入口共用同一份列表组件。播放器设置库打不开时，
          // 这里是唯一还能换内核的地方，因此独立成卡而不是并进上面那一行。
          const PlayerKernelSection(),
          const SizedBox(height: 20),
          const _GroupTitle('源与网络'),
          _SettingsEntry(
            icon: Icons.tune,
            title: '源总管理',
            subtitle: '四个板块的源总览与批量管理（小说 / 漫画 / 视频 / 猫源互相独立）',
            onTap: () => _push(context, const GlobalSourcePage()),
          ),
          const SizedBox(height: 10),
          _SettingsEntry(
            icon: Icons.wifi_tethering,
            title: '网络设置',
            subtitle: '全局并发、单域名并发、UA、代理、超时与重试（四板块共用）',
            onTap: () => _push(context, const NetworkSettingsPage()),
          ),
          const SizedBox(height: 20),
          const _GroupTitle('存储与安全'),
          _SettingsEntry(
            icon: Icons.cleaning_services_outlined,
            title: '缓存管理',
            subtitle: '按板块清理磁盘缓存与内存缓存（漫画板块的图片缓存已关闭）',
            onTap: () => _push(context, CacheSettingsPage(service: cacheService)),
          ),
          const SizedBox(height: 10),
          // 文档第 4 条点名的全局参数之一：JS 沙箱超时（四板块共用）。
          _SettingsEntry(
            icon: Icons.hourglass_bottom_outlined,
            title: '沙箱设置',
            subtitle: 'JS 脚本执行超时（3–5 秒，四板块共用）；其余安全上限不可调',
            onTap: () => _push(context, const SandboxSettingsPage()),
          ),
          const SizedBox(height: 20),
          const _GroupTitle('诊断'),
          _SettingsEntry(
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: '查看本次运行的日志：信息 / 警告 / 错误',
            onTap: () => _push(context, LogViewerPage(exporter: exporter)),
          ),
          const SizedBox(height: 10),
          _SettingsEntry(
            icon: Icons.file_upload_outlined,
            title: '错误报告',
            subtitle: '把错误与警告整理成报告，导出文件或复制全文',
            onTap: () => _push(context, LogReportPage(exporter: exporter)),
          ),
          const SizedBox(height: 10),
          // 调试面板（文档「调试日志规范」）：请求抓包 + JS 上下文统计。
          // 抓包默认关闭、只留内存、不导出——见 DebugPanelPage 的说明。
          _SettingsEntry(
            icon: Icons.bug_report_outlined,
            title: '调试面板',
            subtitle: '请求抓包（方法 / 状态 / 耗时 / 来源）与 JS 上下文统计；抓包默认关闭',
            onTap: () => _push(context, const DebugPanelPage()),
          ),
          const SizedBox(height: 20),
          const _GroupTitle('关于'),
          // **装的是哪一版**：CI 每个构建都会带上构建号（见 build-ios.yml 的
          // `--build-name/--build-number`），这里直接显示出来。以前所有包的
          // 版本号都是 1.0.0，装上旧包看不出来——排查「代码改了但界面没变」
          // 时第一句话就得能回答这个问题（真机踩过一次）。
          const _BuildInfoRow(),
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
    this.trailingValue,
  });

  /// 行尾的当前值（可空；为空时只显示箭头）。
  final String? trailingValue;

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
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
            ),
          ),
          if (trailingValue != null) ...<Widget>[
            Text(
              trailingValue!,
              style: TextStyle(fontSize: 13, color: LumeTheme.textSecondary),
            ),
            const SizedBox(width: 2),
          ],
          Icon(Icons.chevron_right, color: LumeTheme.muted),
        ],
      ),
    );
  }
}

/// 分组标题：设置页的五个分区（界面 / 播放 / 源与网络 / 存储与安全 / 诊断）。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: LumeTheme.textSecondary,
        ),
      ),
    );
  }
}

/// 「网格标题」设置行：遮罩内置标题 / 外置独立标题（用户要求）。
///
/// 与布局档位同一份偏好（`browse_layout.json`），三个板块同时生效。
class GridTitleStyleRow extends StatelessWidget {
  const GridTitleStyleRow({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = BrowseLayoutSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => _SettingsEntry(
        icon: Icons.title_outlined,
        title: '网格标题',
        subtitle: settings.gridTitleStyle == GridTitleStyle.below
            ? '外置独立标题：封面不画遮罩，标题在图片下方（黑字）'
            : '遮罩内置标题：标题压在封面底部的深色渐变上',
        trailingValue: settings.gridTitleStyle.label,
        onTap: () async {
          final picked = await showModalBottomSheet<GridTitleStyle>(
            context: context,
            backgroundColor: Colors.transparent,
            builder: (_) => OptionSheet<GridTitleStyle>(
              title: '网格标题',
              current: settings.gridTitleStyle,
              options: GridTitleStyle.values,
              labelOf: (style) => style.label,
            ),
          );
          if (picked == null) return;
          await settings.setGridTitleStyle(picked);
        },
      ),
    );
  }
}

/// 「关于」里的一行：应用名 + 版本 + 构建号（CI 每次构建都会刷新构建号）。
///
/// 平台信息读不到时如实显示「未知」，不猜：这一行的作用就是让用户与排查者
/// 一眼确认「装的是哪一版」，猜一个数字比空着更糟。
class _BuildInfoRow extends StatefulWidget {
  const _BuildInfoRow();

  @override
  State<_BuildInfoRow> createState() => _BuildInfoRowState();
}

class _BuildInfoRowState extends State<_BuildInfoRow> {
  String _line = '正在读取版本…';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim().isEmpty ? '未知' : info.version.trim();
      final build = info.buildNumber.trim().isEmpty ? '未知' : info.buildNumber.trim();
      if (!mounted) return;
      setState(() => _line = '版本 $version（构建 $build）');
    } catch (error) {
      LumeLog.warn('[settings] 读取版本信息失败：$error');
      if (!mounted) return;
      setState(() => _line = '版本信息不可用（当前平台不支持）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsEntry(
      icon: Icons.info_outline,
      title: LumeTheme.appName,
      subtitle: _line,
      // 这一行不需要「进入下一页」：它本身就是答案。
      onTap: () async {
        await Clipboard.setData(
          ClipboardData(text: '${LumeTheme.appName} · $_line'),
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制版本信息')),
        );
      },
    );
  }
}
