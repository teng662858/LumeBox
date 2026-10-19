import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import 'diagnostic_export_tile.dart';
import '../audio_book/audio_book_page.dart';
import '../video/player_choice.dart';
import 'configuration_settings_page.dart';
import 'privacy_settings_page.dart';
import '../comic/comic_image_tools_page.dart';
import 'total_subscription_page.dart';
import 'tmdb_settings_page.dart';
import 'search_settings_page.dart';
import 'content_visibility_page.dart';

import 'dart:async';

import 'icon_library_page.dart';

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
import 'app_icon_settings_page.dart';
import 'cache_settings_page.dart';
import 'display_settings_group.dart';
import 'floating_settings_page.dart';
import 'debug_panel_page.dart';
import 'module_settings_pages.dart';
import 'network_settings_page.dart';
import 'log_report.dart';
import 'log_report_page.dart';
import 'log_viewer_page.dart';
import 'sandbox_settings_page.dart';
import 'bangumi_settings_page.dart';
import 'settings_ui.dart';
import 'tab_bar_settings_page.dart';
import 'section_cache.dart';
import 'usage_guide_page.dart';

/// 设置：按「个性与界面 / 阅读与播放 / 数据与网络 / 存储与安全 / 诊断与关于」
/// 五组组织全部入口。
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
        effectModule: GlassModule.settings,
        behindBar: true,
        title: '设置',
        child: const SkeletonNotice(),
      );
    }
    return GlassScaffold(
      effectModule: GlassModule.settings,
      // behindBar：内容从玻璃顶栏**底下**穿过（滚动时透出磨砂），顶部留给内容的
      // 空间由列表自己的 barInset 让。少了这一句，SafeArea 会先让一次栏高、
      // barInset 再让一次，顶栏高度被算两遍——真机上表现为首卡离顶栏一大截
      // （实测 131pt 空隙，应当是 16pt）。
      behindBar: true,
      title: '设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          const SettingsGroupTitle('个性与界面', topPadding: 0),
          // 外观 / 主题色 / 页面底色收在一张卡里；悬浮模块单独摆到导航栏后，
          // 与用户给的分类顺序一致。
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: DisplaySettingsGroup(
              showTitle: false,
              includeFloating: false,
            ),
          ),
          SettingsEntryCard(
            icon: Icons.apps_outlined,
            title: 'App 图标',
            subtitle: '更换主屏幕图标（7 种配色）',
            onTap: () => _push(context, const AppIconSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.interests_outlined,
            title: '应用图标库',
            subtitle: '逐项换图标 · 长按编辑 · 导入自己的图片和图标包',
            onTap: () => _push(context, const IconLibraryPage()),
          ),
          const GridTitleStyleRow(),
          SettingsEntryCard(
            icon: Icons.dashboard_customize_outlined,
            title: '底部导航栏管理',
            subtitle: '每个页签独立开关 + 拖拽排序（至少保留 1 个；改动立即生效）',
            onTap: () => _push(context, const TabBarSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.tune,
            title: '悬浮模块',
            subtitle: '顶部导航 / 首页 / 底部导航 / 其他面板的位置、透明度与磨砂',
            onTap: () => _push(context, const FloatingSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.visibility_outlined,
            title: '内容分类显示',
            subtitle: '小说 / 听书 / 漫画 / 美图 / 视频 / 影视独立显示或隐藏',
            onTap: () => _push(context, const ContentVisibilityPage()),
          ),

          const SettingsGroupTitle('阅读与播放'),
          SettingsEntryCard(
            icon: Icons.switch_video_outlined,
            title: '播放器方案',
            subtitle: '现有播放器 / 参考播放器（新）· 切换对比，设置独立',
            onTap: () => _push(context, const PlayerChoiceSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.tune,
            title: '各模块独立设置',
            subtitle:
                '小说 / 漫画 / 视频 / 猫源分开配置（各存各的，互不影响；'
                '阅读页与播放页里的就地设置仍然保留）',
            onTap: () => _push(context, const ModuleSettingsHubPage()),
          ),
          SettingsEntryCard(
            icon: Icons.headphones_outlined,
            title: '有声小说播放器',
            subtitle: '纯音频播放 · 播放器选择 · 后台与锁屏控制',
            onTap: () => _push(context, const AudioBookSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.auto_fix_high_outlined,
            title: 'AI 图片超分与上色',
            subtitle: '漫画 / 美图 AI 超分 · AI 上色 · waifu2x 模型管理',
            onTap: () => _push(context, const ComicImageToolsSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.translate,
            title: '漫画翻译',
            subtitle: '设备端免费翻译 · 自填 AI 接口 · 目标语言',
            onTap: () => _push(
              context,
              const ComicImageToolsSettingsPage(translation: true),
            ),
          ),

          const SettingsGroupTitle('数据与网络'),
          SettingsEntryCard(
            icon: Icons.subscriptions_outlined,
            title: '总订阅导入导出',
            subtitle: '小说、漫画、视频订阅一键导入，或导出订阅地址',
            onTap: () => _push(context, const TotalSubscriptionPage()),
          ),
          SettingsEntryCard(
            icon: Icons.tune,
            title: '源总管理',
            subtitle: '四个板块的源总览与批量管理（小说 / 漫画 / 视频 / 猫源互相独立）',
            onTap: () => _push(context, const GlobalSourcePage()),
          ),
          SettingsEntryCard(
            icon: Icons.wifi_tethering,
            title: '网络设置',
            subtitle: '全局并发、单域名并发、UA、代理、超时与重试（四板块共用）',
            onTap: () => _push(context, const NetworkSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.movie_outlined,
            title: 'TMDB配置',
            subtitle: '海报样式 / API Key / 接口与图片代理',
            onTap: () => _push(context, const TmdbSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.search,
            title: '搜索',
            subtitle: '搜索自动繁转简 / 精确搜索',
            onTap: () => _push(context, const SearchSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.live_tv_outlined,
            title: 'Bangumi 追番同步',
            subtitle: '账号绑定 · 视频看到第几集自动同步到 Bangumi',
            onTap: () => _push(context, const BangumiSettingsPage()),
          ),

          const SettingsGroupTitle('存储与安全'),
          SettingsEntryCard(
            icon: Icons.cleaning_services_outlined,
            title: '缓存管理',
            subtitle: '按板块清理磁盘缓存与内存缓存（漫画板块的图片缓存已关闭）',
            onTap: () =>
                _push(context, CacheSettingsPage(service: cacheService)),
          ),
          SettingsEntryCard(
            icon: Icons.privacy_tip_outlined,
            title: '隐私（应用锁）',
            subtitle: '应用锁 · 面容 / 锁屏密码 · 成人内容显示',
            onTap: () => _push(context, const PrivacySettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.backup_outlined,
            title: '配置备份',
            subtitle: '导出 / 恢复 / 自动备份 · 触感反馈 · 后台播放',
            onTap: () => _push(context, const ConfigurationSettingsPage()),
          ),

          const SettingsGroupTitle('诊断与关于'),
          SettingsEntryCard(
            icon: Icons.menu_book_outlined,
            title: '使用说明',
            subtitle: '源导入、听书与在线接口、漫画翻译与超分、播放器、备份与隐私',
            onTap: () => _push(context, const UsageGuidePage()),
          ),
          SettingsEntryCard(
            icon: Icons.hourglass_bottom_outlined,
            title: '沙箱设置',
            subtitle: 'JS 脚本执行超时（3–10 秒，默认 10，四板块共用）；其余安全上限不可调',
            onTap: () => _push(context, const SandboxSettingsPage()),
          ),
          SettingsEntryCard(
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: '查看本次运行的日志：信息 / 警告 / 错误',
            onTap: () => _push(context, LogViewerPage(exporter: exporter)),
          ),
          SettingsEntryCard(
            icon: Icons.file_upload_outlined,
            title: '错误报告',
            subtitle: '把错误与警告整理成报告，导出文件或复制全文',
            onTap: () => _push(context, LogReportPage(exporter: exporter)),
          ),
          SettingsEntryCard(
            icon: Icons.bug_report_outlined,
            title: '调试面板',
            subtitle: '请求抓包（方法 / 状态 / 耗时 / 来源）与 JS 上下文统计；抓包默认关闭',
            onTap: () => _push(context, const DebugPanelPage()),
          ),
          // 额外的诊断工具：放在用户点名的四项之后，不打断「沙箱 → 日志 →
          // 错误报告 → 调试面板 → 关于」的顺序。
          const DiagnosticExportTile(),
          const _BuildInfoRow(),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
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
      builder: (context, _) => SettingsEntryCard(
        icon: Icons.title_outlined,
        title: '网格标题',
        subtitle: settings.gridTitleStyle == GridTitleStyle.below
            ? '封面不画遮罩，标题放在图片下方（黑字）'
            : '标题压在封面底部的深色渐变上（白字）',
        trailingValue: settings.gridTitleStyle.label,
        onTap: () async {
          final picked = await showLumeBottomSheet<GridTitleStyle>(
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
      final build = info.buildNumber.trim().isEmpty
          ? '未知'
          : info.buildNumber.trim();
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
    return SettingsEntryCard(
      icon: Icons.info_outline,
      title: '关于 LumeBox',
      subtitle: _line,
      showChevron: false,
      marginBottom: 0,
      trailing: LumeIcon(
        Icons.copy_rounded,
        slot: 'settings_page.1',
        size: 18,
        color: LumeTheme.muted,
      ),
      // 这一行不需要「进入下一页」：点一下复制版本信息。
      onTap: () async {
        await Clipboard.setData(
          ClipboardData(text: '${LumeTheme.appName} · $_line'),
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制版本信息')));
      },
    );
  }
}
