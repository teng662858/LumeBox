import 'performance_page.dart';
import '../comic/download_center_page.dart';
import '../video/player_settings_host.dart';
import '../comic/comic_reader_settings_host.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'diagnostic_export_tile.dart';
import 'configuration_settings_page.dart';
import 'privacy_settings_page.dart';
import '../comic/comic_image_tools_page.dart';
import 'total_subscription_page.dart';
import 'subscription_sync_page.dart';
import 'tmdb_settings_page.dart';
import 'preload_settings_page.dart';
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
import '../source/source_repository_page.dart';
import 'app_icon_settings_page.dart';
import 'cache_settings_page.dart';
import 'display_settings_group.dart';
import 'navigation_settings_page.dart';
import 'experience_settings_card.dart';
import 'debug_panel_page.dart';
import 'network_settings_page.dart';
import 'log_report.dart';
import 'log_report_page.dart';
import 'log_viewer_page.dart';
import 'sandbox_settings_page.dart';
import 'bangumi_settings_page.dart';
import 'settings_ui.dart';
import 'translation_languages_page.dart';

import 'section_cache.dart';
import 'usage_guide_page.dart';
import '../media/audio_player_page.dart';

/// 设置按外观、导航、播放、来源、网络、存储与诊断七组组织入口。
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
    final entries = _entries(context);
    final descriptions = <String, String>{
      '个性与界面': '外观、配色与图标',
      '导航与首页': '首页布局、导航与液态玻璃',
      '阅读与播放': '播放、图片工具与使用体验',
      '内容与订阅': '订阅、源与搜索偏好',
      '网络与服务': '网络连接与第三方服务',
      '存储与安全': '缓存、备份与隐私保护',
      '诊断与关于': '使用帮助、诊断与版本信息',
    };
    final icons = [
      Icons.palette_outlined,
      Icons.dashboard_outlined,
      Icons.play_circle_outline,
      Icons.subscriptions_outlined,
      Icons.wifi_outlined,
      Icons.shield_outlined,
      Icons.info_outline,
    ];
    final groups = <SettingsCategory>[];
    for (final entry in entries) {
      if (entry is SettingsGroupTitle) {
        groups.add(
          SettingsCategory(
            entry.text,
            descriptions[entry.text]!,
            icons[groups.length],
            [],
            keywords: entry.text == '个性与界面'
                ? '外观 主题色 页面底色 App 图标 应用图标库'
                : entry.text == '阅读与播放'
                ? '触感反馈 触感强度 后台播放'
                : '',
          ),
        );
      } else {
        groups.last.children.add(entry);
      }
    }
    return GlassScaffold(
      effectModule: GlassModule.settings,
      behindBar: true,
      title: '设置',
      child: SettingsHome(categories: groups),
    );
  }

  List<Widget> _entries(BuildContext context) => <Widget>[
    const SettingsGroupTitle('个性与界面', topPadding: 0),
    // Feature widgets are mounted only after opening their category.
    const Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: DisplaySettingsGroup(showTitle: false, includeFloating: false),
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
    const SettingsGroupTitle('导航与首页'),
    const AdaptiveColorSetting(),
    const SizedBox(height: 12),
    const GridTitleStyleRow(),
    SettingsEntryCard(
      icon: Icons.navigation_outlined,
      title: '原生系统导航',
      subtitle: '顶部与底部透明度、胶囊高度与图标样式',
      onTap: () => _push(context, const NavigationPreferencesPage()),
    ),
    SettingsEntryCard(
      icon: Icons.visibility_outlined,
      title: '内容分类显示',
      subtitle: '选择首页可见的内容类型',
      onTap: () => _push(context, const ContentVisibilityPage()),
    ),

    const SettingsGroupTitle('阅读与播放'),
    const ExperienceSettingsCard(),
    const SizedBox(height: 12),
    SettingsEntryCard(
      icon: Icons.auto_stories_outlined,
      title: '漫画阅读器设置',
      subtitle: '布局、音量键翻页、自动阅读与图片翻译 · 与阅读页同步',
      onTap: () => _push(context, const ComicReaderSettingsHost()),
    ),
    SettingsEntryCard(
      icon: Icons.play_circle_outline,
      title: '播放器设置',
      subtitle: '内核、倍速、字幕与弹幕',
      onTap: () => _push(context, const PlayerSettingsHost()),
    ),
    SettingsEntryCard(
      icon: Icons.headphones_outlined,
      title: '音频播放器',
      subtitle: '独立音频内核 · 后台与锁屏控制',
      onTap: () => _push(context, const AudioPlaybackSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.auto_fix_high_outlined,
      title: 'AI 图片超分与上色',
      subtitle: '漫画 / 美图 AI 超分 · AI 上色 · waifu2x 模型管理',
      onTap: () => _push(context, const ComicImageToolsSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.translate,
      title: '翻译语言包',
      subtitle: '一次下载所有可用语言包 · 各个源共用',
      onTap: () => _push(context, const TranslationLanguagesPage()),
    ),
    SettingsEntryCard(
      icon: Icons.translate,
      title: '全局翻译',
      subtitle: '标题、搜索与漫画共用 · 系统 / AI / 自动补译',
      onTap: () =>
          _push(context, const ComicImageToolsSettingsPage(translation: true)),
    ),

    const SettingsGroupTitle('内容与订阅'),
    SettingsEntryCard(
      icon: Icons.cloud_upload_outlined,
      title: 'GitHub 仓库源管理',
      subtitle: '授权后直接新增或删除远端源文件，更新公共订阅',
      onTap: () => _push(context, const SourceRepositoryPage()),
    ),
    SettingsEntryCard(
      icon: Icons.sync,
      title: '一键同步全部订阅',
      subtitle: '立即更新漫画、视频和猫源订阅 · 查看逐项结果',
      onTap: () => _push(context, const SubscriptionSyncPage()),
    ),
    SettingsEntryCard(
      icon: Icons.subscriptions_outlined,
      title: '总订阅导入导出',
      subtitle: '漫画、视频订阅一键导入，或导出订阅地址',
      onTap: () => _push(context, const TotalSubscriptionPage()),
    ),
    SettingsEntryCard(
      icon: Icons.tune,
      title: '源总管理',
      subtitle: '漫画 / 视频 / 猫源的源总览与批量管理',
      onTap: () => _push(context, const GlobalSourcePage()),
    ),
    SettingsEntryCard(
      icon: Icons.search,
      title: '搜索',
      subtitle: '搜索自动繁转简 / 精确搜索',
      onTap: () => _push(context, const SearchSettingsPage()),
    ),
    const SettingsGroupTitle('网络与服务'),
    SettingsEntryCard(
      icon: Icons.wifi_tethering,
      title: '网络设置',
      subtitle: '并发 · UA · 代理 · 超时与重试',
      onTap: () => _push(context, const NetworkSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.movie_outlined,
      title: 'TMDB配置',
      searchTargets: {
        for (final entry in const {
          '背景亮度': 'backgroundBrightness',
          '背景色彩 饱和度': 'backgroundSaturation',
          '海报亮度': 'posterBrightness',
          '渐变强度': 'fadeStrength',
          'TMDB标识大小 Logo': 'logoScale',
        }.entries)
          entry.key: () =>
              _push(context, TmdbSettingsPage(focusAppearance: entry.value)),
      },
      subtitle: '海报样式 / API Key / 接口与图片代理',
      onTap: () => _push(context, const TmdbSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.live_tv_outlined,
      title: 'Bangumi 追番同步',
      subtitle: '账号绑定 · 视频看到第几集自动同步到 Bangumi',
      onTap: () => _push(context, const BangumiSettingsPage()),
    ),

    const SettingsGroupTitle('存储与安全'),
    SettingsEntryCard(
      icon: Icons.download_outlined,
      title: '下载中心',
      subtitle: '暂停、继续、失败重试与重开恢复',
      onTap: () => _push(context, const DownloadCenterPage()),
    ),
    SettingsEntryCard(
      icon: Icons.downloading_outlined,
      title: '预载与清理',
      subtitle: '视频 / 图片 / 音频预载 · TMDB · 源图标 · 历史',
      onTap: () => _push(context, const PreloadSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.cleaning_services_outlined,
      title: '缓存管理',
      subtitle: '按板块清理磁盘缓存与内存缓存（漫画板块的图片缓存已关闭）',
      onTap: () => _push(context, CacheSettingsPage(service: cacheService)),
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
      subtitle: '导出、恢复与自动备份',
      onTap: () => _push(context, const ConfigurationSettingsPage()),
    ),

    const SettingsGroupTitle('诊断与关于'),
    SettingsEntryCard(
      icon: Icons.speed,
      title: '流畅度采集',
      subtitle: '长列表、翻页、切集与清理的帧耗时报告',
      onTap: () => _push(context, const PerformancePage()),
    ),
    SettingsEntryCard(
      icon: Icons.menu_book_outlined,
      title: '使用说明',
      subtitle: '源导入、听书与在线接口、漫画翻译与超分、播放器、备份与隐私',
      onTap: () => _push(context, const UsageGuidePage()),
    ),
    SettingsEntryCard(
      icon: Icons.hourglass_bottom_outlined,
      title: '沙箱设置',
      subtitle: '脚本执行超时与运行限制',
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
  ];

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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('网格标题', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('选择封面标题的位置，立即应用到内容网格。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final style in GridTitleStyle.values)
                    ChoiceChip(
                      label: Text(style.label),
                      selected: settings.gridTitleStyle == style,
                      onSelected: (_) => settings.setGridTitleStyle(style),
                    ),
                ],
              ),
            ],
          ),
        ),
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
