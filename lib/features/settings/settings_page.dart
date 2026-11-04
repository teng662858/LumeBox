import '../reading/continue_activity_page.dart';
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
import '../source/tvbox_import_page.dart';
import '../source/source_subscription_page.dart';
import '../cat/cat_subscription_page.dart';
import '../../core/session/section.dart';
import 'app_icon_settings_page.dart';
import 'cache_settings_page.dart';
import 'display_settings_group.dart';
import 'navigation_settings_page.dart';
import 'experience_settings_card.dart';
import 'novel_settings_page.dart';
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
      '阅读与播放': '小说、漫画、播放器与共用体验',
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
                ? '触感反馈 触感强度 后台播放 字号 行距 朗读 漫画 图片工具 音频 内核 弹幕'
                : '',
          ),
        );
      } else {
        groups.last.children.add(entry);
      }
    }
    const priority = [
      '阅读与播放',
      '内容与订阅',
      '个性与界面',
      '导航与首页',
      '存储与安全',
      '网络与服务',
      '诊断与关于',
    ];
    groups.sort(
      (a, b) => priority.indexOf(a.title).compareTo(priority.indexOf(b.title)),
    );
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
    SettingsEntryCard(
      icon: Icons.menu_book_outlined,
      title: '小说设置',
      subtitle: '字号、行距、阅读主题与朗读',
      searchTargets: {
        '小说字号': () => _push(context, const NovelSettingsPage(focus: 'font')),
        '小说行距': () => _push(context, const NovelSettingsPage(focus: 'height')),
        '小说朗读': () => _push(context, const NovelSettingsPage(focus: 'speech')),
      },
      onTap: () => _push(context, const NovelSettingsPage()),
    ),
    SettingsEntryCard(
      icon: Icons.auto_stories_outlined,
      title: '漫画设置',
      subtitle: '阅读器、图片处理与 AI 图片工具',
      searchTargets: {
        '漫画阅读器设置': () => _push(context, const ComicReaderSettingsHost()),
        '漫画翻页': () => _push(context, const ComicReaderSettingsHost()),
        'AI 图片超分与上色': () => _push(context, const ComicImageToolsSettingsPage()),
      },
      onTap: () => _push(
        context,
        SettingsCategoryPage(
          category: SettingsCategory(
            '漫画设置',
            '阅读与图片处理',
            Icons.auto_stories_outlined,
            [
              SettingsEntryCard(
                icon: Icons.auto_stories_outlined,
                title: '漫画阅读器设置',
                subtitle: '布局、翻页、自动阅读与图片翻译',
                onTap: () => _push(context, const ComicReaderSettingsHost()),
              ),
              SettingsEntryCard(
                icon: Icons.auto_fix_high_outlined,
                title: 'AI 图片超分与上色',
                subtitle: '漫画 / 美图 AI 超分、上色与模型管理',
                onTap: () =>
                    _push(context, const ComicImageToolsSettingsPage()),
              ),
            ],
          ),
        ),
      ),
    ),
    SettingsEntryCard(
      icon: Icons.play_circle_outline,
      title: '播放器设置',
      subtitle: '视频、音频、字幕、弹幕与后台播放',
      searchTargets: {
        '视频播放器': () => _push(context, const PlayerSettingsHost()),
        '播放倍速': () =>
            _push(context, const PlayerSettingsHost(focusCategory: 'playback')),
        '音频播放器': () => _push(context, const AudioPlaybackSettingsPage()),
        '字幕': () =>
            _push(context, const PlayerSettingsHost(focusCategory: 'audio')),
        '弹幕': () =>
            _push(context, const PlayerSettingsHost(focusCategory: 'danmaku')),
        '后台播放': () => _push(context, const PlayerSettingsHost()),
      },
      onTap: () => _push(context, const PlayerSettingsHost()),
    ),
    SettingsEntryCard(
      icon: Icons.history,
      title: '继续看／读／听',
      subtitle: '汇总视频、漫画、小说与听书进度',
      onTap: () => _push(context, const ContinueActivityPage()),
    ),
    const ExperienceSettingsCard(),
    const SizedBox(height: 12),
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
      icon: Icons.tune,
      title: '源管理',
      subtitle: '添加源、管理订阅、更新与检测',
      searchTargets: {
        '源总管理': () => _push(context, const GlobalSourcePage()),
        '总订阅导入导出': () => _push(context, const TotalSubscriptionPage()),
        'TVBox 聚合配置导入': () => _push(context, const TvBoxImportPage()),
        'GitHub 仓库源管理': () => _push(context, const SourceRepositoryPage()),
        '一键同步全部订阅': () => _push(context, const SubscriptionSyncPage()),
      },
      onTap: () => _push(
        context,
        SettingsCategoryPage(
          category: SettingsCategory('源管理', '添加、检查和更新站点与订阅', Icons.tune, [
            SettingsEntryCard(
              icon: Icons.playlist_add,
              title: '添加与管理源',
              subtitle: '添加源、批量检测和管理漫画与视频站点',
              onTap: () => _push(context, const GlobalSourcePage()),
            ),
            for (final section in [Section.comic, Section.video])
              SettingsEntryCard(
                icon: Icons.subscriptions_outlined,
                title: '${section.label}订阅',
                subtitle: '添加、选择安装及更新订阅源',
                onTap: () =>
                    _push(context, SourceSubscriptionPage(section: section)),
              ),
            SettingsEntryCard(
              icon: Icons.pets_outlined,
              title: '猫源订阅',
              subtitle: '管理猫源订阅和站点',
              onTap: () => _push(context, const CatSubscriptionPage()),
            ),
            SettingsEntryCard(
              icon: Icons.sync,
              title: '一键同步全部订阅',
              subtitle: '更新漫画、视频和猫源订阅',
              onTap: () => _push(context, const SubscriptionSyncPage()),
            ),
            SettingsEntryCard(
              icon: Icons.settings_outlined,
              title: '高级导入与仓库',
              subtitle: '总订阅、TVBox 与 GitHub 仓库',
              onTap: () => _push(
                context,
                SettingsCategoryPage(
                  category: SettingsCategory(
                    '高级导入与仓库',
                    '导入配置和管理仓库',
                    Icons.settings_outlined,
                    [
                      SettingsEntryCard(
                        icon: Icons.subscriptions_outlined,
                        title: '总订阅导入导出',
                        onTap: () =>
                            _push(context, const TotalSubscriptionPage()),
                      ),
                      SettingsEntryCard(
                        icon: Icons.playlist_add,
                        title: 'TVBox 聚合配置导入',
                        onTap: () => _push(context, const TvBoxImportPage()),
                      ),
                      SettingsEntryCard(
                        icon: Icons.cloud_upload_outlined,
                        title: 'GitHub 仓库源管理',
                        onTap: () =>
                            _push(context, const SourceRepositoryPage()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
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
      searchTargets: {
        '下载路径与文件': () => _push(context, const DownloadCenterPage()),
      },
      onTap: () => _push(context, const DownloadCenterPage()),
    ),
    SettingsEntryCard(
      icon: Icons.storage_outlined,
      title: '存储与缓存',
      subtitle: '预加载策略 · 空间占用 · 缓存清理',
      searchTargets: {
        '预载与清理': () => _push(context, const PreloadSettingsPage()),
        '缓存管理': () => _push(context, CacheSettingsPage(service: cacheService)),
      },
      onTap: () => _push(
        context,
        SettingsCategoryPage(
          category: SettingsCategory(
            '存储与缓存',
            '按需调整预载，查看和清理占用',
            Icons.storage_outlined,
            [
              SettingsEntryCard(
                icon: Icons.downloading_outlined,
                title: '预载与清理',
                subtitle: '视频 / 图片 / 音频预载与自动清理策略',
                onTap: () => _push(context, const PreloadSettingsPage()),
              ),
              SettingsEntryCard(
                icon: Icons.cleaning_services_outlined,
                title: '缓存管理',
                subtitle: '按板块统计和清理，不删除收藏及已保存内容',
                onTap: () =>
                    _push(context, CacheSettingsPage(service: cacheService)),
              ),
            ],
          ),
        ),
      ),
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
      icon: Icons.troubleshoot,
      title: '问题排查',
      subtitle: '加载耗时 · 流畅度 · 日志 · 导出诊断包',
      searchTargets: {
        '流畅度采集': () => _push(context, const PerformancePage()),
        '运行日志': () => _push(context, LogViewerPage(exporter: exporter)),
        '错误报告': () => _push(context, LogReportPage(exporter: exporter)),
        '诊断包': () => _push(context, _diagnostics(context)),
      },
      onTap: () => _push(context, _diagnostics(context)),
    ),
    SettingsEntryCard(
      icon: Icons.menu_book_outlined,
      title: '使用说明',
      subtitle: '源导入、听书与在线接口、漫画翻译与超分、播放器、备份与隐私',
      onTap: () => _push(context, const UsageGuidePage()),
    ),
    SettingsEntryCard(
      icon: Icons.tune,
      title: '高级设置',
      subtitle: '沙箱执行限制 · 请求抓包 · JS 上下文统计',
      searchTargets: {
        '沙箱设置': () => _push(context, const SandboxSettingsPage()),
        '调试面板': () => _push(context, const DebugPanelPage()),
      },
      onTap: () => _push(
        context,
        SettingsCategoryPage(
          category: SettingsCategory('高级设置', '脚本执行与开发排查工具', Icons.tune, [
            SettingsEntryCard(
              icon: Icons.hourglass_bottom_outlined,
              title: '沙箱设置',
              subtitle: '脚本执行超时与运行限制',
              onTap: () => _push(context, const SandboxSettingsPage()),
            ),
            SettingsEntryCard(
              icon: Icons.bug_report_outlined,
              title: '调试面板',
              subtitle: '请求抓包与 JS 上下文统计；抓包默认关闭',
              onTap: () => _push(context, const DebugPanelPage()),
            ),
          ]),
        ),
      ),
    ),
    const _BuildInfoRow(),
  ];

  Widget _diagnostics(BuildContext context) => SettingsCategoryPage(
    category: SettingsCategory('问题排查', '先查看加载耗时，必要时导出诊断包', Icons.troubleshoot, [
      SettingsEntryCard(
        icon: Icons.speed,
        title: '流畅度采集',
        subtitle: '源加载耗时与帧耗时报告',
        onTap: () => _push(context, const PerformancePage()),
      ),
      SettingsEntryCard(
        icon: Icons.receipt_long_outlined,
        title: '运行日志',
        subtitle: '本次与上次会话记录',
        onTap: () => _push(context, LogViewerPage(exporter: exporter)),
      ),
      SettingsEntryCard(
        icon: Icons.file_upload_outlined,
        title: '错误报告',
        subtitle: '整理错误与警告并导出',
        onTap: () => _push(context, LogReportPage(exporter: exporter)),
      ),
      const DiagnosticExportTile(),
    ]),
  );

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
