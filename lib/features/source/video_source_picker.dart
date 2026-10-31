import '../../shared/widgets/native_glass_surfaces.dart';
import '../../shared/widgets/source_picker_card.dart';
import '../../shared/widgets/source_picker_header.dart';
import '../../shared/widgets/source_picker_scroll_list.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/cat/cat_service.dart';
import '../../core/reading/reading_library.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_media_hints.dart';
import '../../core/source/kazumi_rule.dart';
import '../../core/source/source_content_visibility.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_preferences.dart';
import '../../core/source/source_subscription_catalog.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/web/web_home_sources.dart';
import '../../core/web/html_home_import.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/lume_icon.dart';
import '../../shared/widgets/source_card_metrics.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_icon.dart';
import '../../shared/widgets/source_rating_badge.dart';
import '../../core/source/source_content_rating.dart';
import '../../core/source/source_content_category.dart';
import '../cat/cat_subscription_page.dart';
import 'source_import_dialog.dart';
import 'source_preferences_page.dart';
import 'source_section_page.dart';
import 'source_maintenance.dart';
import '../settings/subscription_sync_page.dart';
import '../../shared/widgets/source_swipe_tile.dart';

enum _VideoImportAction { kazumi }

enum VideoSourceType {
  all('全部'),
  ordinary('JS 源'),
  cat('猫源'),
  python('PY'),
  audio('有声小说'),
  kazumi('Kazumi'),
  module('模块'),
  web('网页');

  const VideoSourceType(this.label);
  final String label;

  static VideoSourceType forSource(SourceDescriptor source) => source.isAudio
      ? audio
      : source.isKazumi
      ? kazumi
      : switch (source.runtimeKind) {
          'python' => python,
          'module' => module,
          _ => ordinary,
        };
  bool accepts(SourceDescriptor source) =>
      this == all || forSource(source) == this;
}

class VideoSourceChoice {
  const VideoSourceChoice.ordinary(this.sourceId) : site = null, webHome = null;
  const VideoSourceChoice.cat(this.site) : sourceId = null, webHome = null;
  const VideoSourceChoice.web(WebHomeSource this.webHome)
    : sourceId = null,
      site = null;
  final String? sourceId;
  final CatSite? site;
  final WebHomeSource? webHome;
}

Future<VideoSourceChoice?> showVideoSourcePicker({
  required BuildContext context,
  required SourceManager manager,
  String? currentCatId,
  String? currentWebId,
  bool showingCat = false,
}) => showLumeBottomSheet<VideoSourceChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  builder: (_) => VideoSourcePicker(
    manager: manager,
    currentCatId: currentCatId,
    currentWebId: currentWebId,
    showingCat: showingCat,
  ),
);

/// Type tabs belong only to the drawer. Subscriptions are headings, not another
/// home-page selector. IDs and playback continue to use their original stores.
class VideoSourcePicker extends StatefulWidget {
  static const contentFilterKey = 'video.sourcePicker.contentCategory';
  const VideoSourcePicker({
    super.key,
    required this.manager,
    this.currentCatId,
    this.currentWebId,
    this.showingCat = false,
    this.service,
  });
  final SourceManager manager;
  final String? currentCatId;
  final String? currentWebId;
  final bool showingCat;
  final CatService? service;

  @override
  State<VideoSourcePicker> createState() => _VideoSourcePickerState();
}

class _VideoSourcePickerState extends State<VideoSourcePicker> {
  late final service = widget.service ?? CatService.instance;
  VideoSourceType type = VideoSourceType.all;
  SourceContentCategory content = SourceContentCategory.movie;
  bool _contentChosen = false;
  String query = '';
  List<SourceDescriptor> sources = [];
  String? currentId, error;
  bool loading = true;
  final busy = <String>{};
  WebHomeStore? _webStore;
  List<WebHomeSource> webHomes = const [];
  bool _importingHtml = false;
  final _currentSourceKey = GlobalKey();
  final _tabKeys = {
    for (final kind in VideoSourceType.values) kind: GlobalKey(),
  };

  void _revealSelectedType() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = _tabKeys[type]?.currentContext;
        if (target != null) {
          unawaited(
            Scrollable.ensureVisible(
              target,
              alignment: .5,
              duration: const Duration(milliseconds: 220),
            ),
          );
        }
      });

  bool _locateCurrent = true, _initialTypeChosen = false;

  bool _ordinarySelected(String id) =>
      !widget.showingCat && widget.currentWebId == null && currentId == id;

  void _chooseInitialType() {
    if (_initialTypeChosen) return;
    _initialTypeChosen = true;
    if (!_locateCurrent) return;
    if (widget.currentWebId != null) {
      if (webHomes.any((home) => home.id == widget.currentWebId)) {
        final home = webHomes.firstWhere((h) => h.id == widget.currentWebId);
        type = SourceMediaHints.audioLabel(home.name)
            ? VideoSourceType.audio
            : VideoSourceType.web;
      }
    } else if (widget.showingCat) {
      if (service.subscriptions
          .where((record) => record.enabled)
          .any(
            (record) => record.sites.any(
              (site) =>
                  site.id == widget.currentCatId &&
                  PrivacySettings.instance.allowsSource(site.id, site.name),
            ),
          )) {
        final site = service.subscriptions
            .expand((s) => s.sites)
            .firstWhere((s) => s.id == widget.currentCatId);
        type =
            SourceMediaHints.audioLabel('${site.name} ${site.key} ${site.kind}')
            ? VideoSourceType.audio
            : VideoSourceType.cat;
      }
    } else {
      final current = sources
          .where(
            (source) =>
                source.id == currentId &&
                source.enabled &&
                SourceContentVisibility.instance.allows(Section.video, source),
          )
          .firstOrNull;
      if (current != null) {
        type = VideoSourceType.forSource(current);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    service.addListener(changed);
    SourceContentVisibility.instance.addListener(changed);
    PrivacySettings.instance.addListener(changed);
    unawaited(load());
  }

  void changed() {
    if (mounted) {
      setState(() {
        webHomes = _webStore?.items ?? webHomes;
        if (!PrivacySettings.instance.showAdult &&
            content == SourceContentCategory.adult) {
          content = SourceContentCategory.movie;
        }
      });
    }
  }

  @override
  void dispose() {
    service.removeListener(changed);
    SourceContentVisibility.instance.removeListener(changed);
    PrivacySettings.instance.removeListener(changed);
    _webStore?.removeListener(changed);
    super.dispose();
  }

  Future<void> load() async {
    try {
      await ReadingLibrary.open(Section.video);
      await ReadingLibrary.open(Section.cat);
      await service.boot();
      final webStore = await WebHomeStore.open();
      final rows = await widget.manager.list();
      final current = await widget.manager.current();
      if (!mounted) return;
      if (!identical(webStore, _webStore)) {
        _webStore?.removeListener(changed);
        webStore.addListener(changed);
        _webStore = webStore;
      }
      setState(() {
        sources = rows;
        currentId = current?.id;
        webHomes = webStore.items;
        _chooseInitialType();
        if (!_contentChosen) {
          _contentChosen = true;
          final saved =
              ReadingLibrary.find(Section.video)
                  ?.setting(VideoSourcePicker.contentFilterKey) ??
              '';
          final active = sources
              .where((source) => source.id == currentId)
              .firstOrNull;
          final available = SourceContentCategory.groups.where(
            (category) => sources.any(
              (source) =>
                  source.enabled &&
                  SourceContentCategories.appliesTo(source) &&
                  SourceContentVisibility.instance.allows(
                    Section.video,
                    source,
                  ) &&
                  SourceContentCategories.forSource(source) == category,
            ),
          );
          content =
              SourceContentCategory.fromId(saved) ??
              (active != null && SourceContentCategories.appliesTo(active)
                  ? SourceContentCategories.forSource(active)
                  : available.firstOrNull ?? SourceContentCategory.movie);
          if (!PrivacySettings.instance.showAdult &&
              content == SourceContentCategory.adult) {
            content = SourceContentCategory.movie;
          }
        }
        _revealSelectedType();
        loading = false;
        error = null;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  bool matches(String text) => text.toLowerCase().contains(query);

  void selectContent(SourceContentCategory value) {
    setState(() {
      content = value;
      _locateCurrent = false;
    });
    ReadingLibrary.find(Section.video)
        ?.setSetting(VideoSourcePicker.contentFilterKey, value.id);
  }

  Future<void> edit(
    Section section,
    String id,
    String name,
    String url, {
    bool widgetParameters = false,
    SourceDescriptor? descriptor,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcePreferencesPage(
          section: section,
          sourceId: id,
          name: name,
          siteUrl: url,
          showWidgetParameters: widgetParameters,
          descriptor: descriptor,
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> add() async {
    final target = await showGlassModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  '添加视频源',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: const LumeIcon(
                  Icons.live_tv,
                  slot: 'video_source_picker.add_kazumi',
                ),
                title: const Text('Kazumi 源'),
                subtitle: const Text('导入规则 JSON 或订阅，已填入官方源地址'),
                onTap: () => Navigator.pop(context, _VideoImportAction.kazumi),
              ),
              for (final row in [
                (
                  VideoSourceType.ordinary,
                  Icons.code,
                  '普通视频源',
                  '导入 JS 文件或订阅链接',
                ),
                (
                  VideoSourceType.cat,
                  Icons.pets_outlined,
                  '猫源订阅',
                  '管理订阅包与包内站点',
                ),
                (
                  VideoSourceType.python,
                  Icons.terminal,
                  'Python 源',
                  '导入 Spider 脚本、ZIP 源包或订阅链接',
                ),
                (
                  VideoSourceType.audio,
                  Icons.headphones,
                  '有声小说源',
                  '导入听书源，已填入有声小说订阅地址',
                ),
                (
                  VideoSourceType.module,
                  Icons.extension_outlined,
                  '模块源',
                  '导入 ESM / CommonJS、ZIP 源包或远程 Spider',
                ),
                (
                  VideoSourceType.web,
                  Icons.language,
                  '网页主页',
                  '添加网页地址或导入 HTML 文件',
                ),
              ])
                ListTile(
                  leading: LumeIcon(
                    row.$2,
                    slot: 'video_source_picker.add',
                    variant: true,
                  ),
                  title: Text(row.$3),
                  subtitle: Text(row.$4),
                  onTap: () => Navigator.pop(context, row.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || target == null) return;
    if (target == _VideoImportAction.kazumi) {
      await runSourceImport(
        context,
        section: Section.video,
        manager: widget.manager,
        initialSubscription: KazumiRule.officialIndex,
        title: '导入 Kazumi 源',
        helpText: '支持规则 JSON 和索引订阅。导入后可搜索作品、选择剧集播放，部分规则没有首页推荐。',
      );
      if (!mounted) return;
      setState(() => type = VideoSourceType.kazumi);
      await load();
      return;
    }
    if (target is! VideoSourceType) return;
    if ([
      VideoSourceType.ordinary,
      VideoSourceType.python,
      VideoSourceType.module,
      VideoSourceType.audio,
    ].contains(target)) {
      await runSourceImport(
        context,
        section: Section.video,
        manager: widget.manager,
        initialSubscription: target == VideoSourceType.audio
            ? SubscriptionCatalog.audiobooksUrl
            : null,
        title: target == VideoSourceType.audio ? '导入有声小说源' : null,
        initialContentCategory:
            target == VideoSourceType.ordinary &&
                content != SourceContentCategory.all
            ? content.id
            : '',
        helpText: target == VideoSourceType.audio
            ? '支持听书 JS、音频源包和订阅链接，导入后显示在有声小说标签。'
            : null,
      );
      if (mounted) setState(() => type = target);
    } else if (target == VideoSourceType.cat) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const CatSubscriptionPage()),
      );
    } else if (target == VideoSourceType.web) {
      await _addWebHome();
      return;
    } else {
      setState(() => type = target);
      return;
    }
    if (mounted) await load();
  }

  Future<void> _addWebHome() async {
    final kind = await showGlassModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('web-home-add-url'),
              leading: const Icon(Icons.language),
              title: const Text('添加网页地址'),
              onTap: () => Navigator.pop(sheetContext, 'url'),
            ),
            ListTile(
              key: const ValueKey('web-home-import-html'),
              leading: const Icon(Icons.upload_file),
              title: const Text('导入 HTML 文件'),
              subtitle: const Text('可一次选择多个 .html / .htm 文件'),
              onTap: () => Navigator.pop(sheetContext, 'html'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || kind == null) return;
    if (kind == 'html') {
      await _importHtmlHomes();
      return;
    }
    final store = await WebHomeStore.open();
    if (!mounted) return;
    final source = await _webHomeDialog(store: store);
    if (source == null) return;
    store.upsert(source);
    if (!mounted) return;
    setState(() => type = VideoSourceType.web);
    await load();
  }

  Future<void> _importHtmlHomes() async {
    if (_importingHtml) return;
    setState(() => _importingHtml = true);
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'HTML 网页',
            extensions: ['html', 'htm'],
            // Files providers sometimes expose downloaded HTML as plain text
            // or generic data; HtmlHomeImport validates the actual contents.
            uniformTypeIdentifiers: [
              'public.html',
              'public.plain-text',
              'public.data',
            ],
            mimeTypes: ['text/html'],
          ),
        ],
      );
      if (!mounted || files.isEmpty) return;
      final store = await WebHomeStore.open();
      var imported = 0, repeated = 0;
      final failures = <String>[];
      for (final file in files) {
        try {
          if (await file.length() > HtmlHomeImport.maxBytes) {
            throw const FormatException('文件不能超过 2 MB');
          }
          final source = HtmlHomeImport.decode(
            file.name,
            await file.readAsBytes(),
          );
          if (!mounted) return;
          if (store.byId(source.id) != null) {
            repeated++;
            continue;
          }
          store.upsert(source);
          imported++;
        } catch (error) {
          failures.add(
            '${file.name}：${error is FormatException ? error.message : error}',
          );
        }
      }
      if (!mounted) return;
      setState(() => type = VideoSourceType.web);
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导入 $imported 个网页${repeated > 0 ? '，跳过 $repeated 个重复文件' : ''}',
          ),
        ),
      );
      if (failures.isNotEmpty) {
        await showGlassDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('部分文件未导入'),
            content: SingleChildScrollView(child: Text(failures.join('\n'))),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _importingHtml = false);
    }
  }

  Future<void> _editWebHome(WebHomeSource source) async {
    final store = await WebHomeStore.open();
    if (!mounted) return;
    final updated = await _webHomeDialog(store: store, existing: source);
    if (updated != null) store.upsert(updated);
    if (mounted) await load();
  }

  Future<WebHomeSource?> _webHomeDialog({
    required WebHomeStore store,
    WebHomeSource? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.url ?? '');
    String? error;
    final route = DialogRoute<WebHomeSource>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加网页主页' : '编辑网页主页'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：影视主页',
                ),
              ),
              const SizedBox(height: 12),
              if (existing?.isLocal == true)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('本地 HTML 已保存在 App 内，可以修改名称或删除。'),
                )
              else
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '主页地址',
                    hintText: 'https://example.com',
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  store.remove(existing.id);
                  Navigator.pop(dialogContext);
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                var url = urlController.text.trim();
                if (!url.contains('://')) url = 'https://$url';
                if (name.isEmpty) {
                  setDialogState(() => error = '请填写名称');
                  return;
                }
                if (existing?.isLocal == true) {
                  Navigator.pop(dialogContext, existing!.copyWith(name: name));
                  return;
                }
                if (!isValidWebHomeUrl(url)) {
                  setDialogState(() => error = '请输入有效的 http(s) 地址');
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  WebHomeSource(
                    id: existing?.id ?? store.nextId(),
                    name: name,
                    url: url,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    // TextFields remain mounted while the dialog's exit transition runs.
    await route.completed;
    nameController.dispose();
    urlController.dispose();
    return result;
  }

  Future<void> _deleteEntry(
    String id,
    String name,
    Future<void> Function() remove,
  ) async {
    if (busy.contains(id)) return;
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除「$name」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: LumeTheme.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy.add(id));
    try {
      await remove();
      if (mounted) await load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  Future<void> _deleteOrdinary(SourceDescriptor source) =>
      _deleteEntry(source.id, source.name, () async {
        final result = await SourceMaintenance(
          section: Section.video,
          manager: widget.manager,
        ).remove([source]);
        if (result.errors.isNotEmpty) throw StateError('删除未完成');
      });

  Future<void> refresh(CatSubscription record) async {
    if (busy.contains(record.id)) return;
    setState(() => busy.add(record.id));
    try {
      await service.refreshSites(record);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$failure')));
      }
    } finally {
      if (mounted) setState(() => busy.remove(record.id));
    }
  }

  Widget card({
    required String id,
    required String name,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onMore,
    required VoidCallback onDelete,
    SourceDescriptor? descriptor,
    Section section = Section.video,
    String siteUrl = '',
  }) {
    final prefs = SourcePreferences.read(section, id);
    final js =
        descriptor != null && SourceContentCategories.appliesTo(descriptor);
    return SourceSwipeTile(
      key: ValueKey('video-picker-swipe-$id'),
      height: SourceCardMetrics.height,
      actions: [
        SourceSwipeAction(
          label: '删除',
          color: LumeTheme.danger,
          onTap: onDelete,
        ),
      ],
      child: SourcePickerCard(
        key: selected ? _currentSourceKey : null,
        tapKey: ValueKey('video-picker-source-$id'),
        title: name,
        titleMaxLines: js ? 2 : 1,
        height: SourceCardMetrics.height,
        subtitle: Row(
          children: [
            Flexible(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (SourceContentRating.isAdult(id, name) ||
                (js &&
                    SourceContentCategories.forSource(descriptor) ==
                        SourceContentCategory.adult))
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: SourceRatingBadge(compact: true),
              ),
            if (prefs.pinned)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: LumeIcon(
                  Icons.push_pin,
                  slot: 'source_picker_sheet.2',
                  size: 11,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        selected: selected,
        onTap: onTap,
        onMore: onMore,
        moreTooltip: '$name的设置',
        icon: SourceIcon(
          name: name,
          siteUrl: descriptor?.siteUrl ?? siteUrl,
          iconUrl: prefs.iconUrl.trim().isEmpty
              ? descriptor?.iconUrl ?? ''
              : prefs.iconUrl,
          size: SourceCardMetrics.iconSize,
          radius: 8,
          section: section,
          sourceId: id,
        ),
      ),
    );
  }

  Widget grid(List<Widget> cards) => Column(
    children: [
      for (var i = 0; i < cards.length; i += 2)
        Padding(
          padding: const EdgeInsets.only(bottom: SourceCardMetrics.rowGap),
          child: Row(
            children: [
              Expanded(child: cards[i]),
              const SizedBox(width: SourceCardMetrics.columnGap),
              Expanded(
                child: i + 1 < cards.length
                    ? cards[i + 1]
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
    ],
  );

  Widget heading(String title, int count, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Text('$count', style: TextStyle(fontSize: 12, color: LumeTheme.muted)),
        ?trailing,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ordinary = sources
        .where(
          (s) =>
              s.enabled &&
              type.accepts(s) &&
              SourceContentVisibility.instance.allows(Section.video, s) &&
              matches('${s.name} ${s.id} ${s.group}'),
        )
        .toList();
    final contentCounts = {
      for (final category in SourceContentCategory.groups)
        category: ordinary
            .where(
              (source) =>
                  SourceContentCategories.appliesTo(source) &&
                  SourceContentCategories.forSource(source) == category,
            )
            .length,
    };
    if (type == VideoSourceType.ordinary &&
        content != SourceContentCategory.all) {
      ordinary.removeWhere(
        (source) => SourceContentCategories.forSource(source) != content,
      );
    }
    final originalOrder = sources.map((s) => s.id).toList();
    final compareOrder = SourceOrder.comparator(Section.video, originalOrder);
    final pinned = {
      for (final source in ordinary)
        source.id: SourcePreferences.read(Section.video, source.id).pinned,
    };
    ordinary.sort((a, b) {
      final pa = pinned[a.id]!;
      final pb = pinned[b.id]!;
      return pa != pb ? (pa ? -1 : 1) : compareOrder(a.id, b.id);
    });
    final records = service.subscriptions.where((s) => s.enabled).toList();
    final groups = <(CatSubscription, List<CatSite>)>[];
    for (final record in records) {
      final sites = record.sites
          .where(
            (s) =>
                PrivacySettings.instance.allowsSource(s.id, s.name) &&
                (type == VideoSourceType.all ||
                    (type == VideoSourceType.audio) ==
                        SourceMediaHints.audioLabel(
                          '${s.name} ${s.key} ${s.kind}',
                        )) &&
                matches('${record.name} ${s.name} ${s.key}'),
          )
          .toList();
      final order = record.sites.map((s) => s.id).toList();
      final compareSites = SourceOrder.comparator(Section.cat, order);
      sites.sort((a, b) => compareSites(a.id, b.id));
      if (sites.isNotEmpty ||
          (type != VideoSourceType.audio &&
              record.sites.isEmpty &&
              record.removedSiteIds.isEmpty &&
              matches(record.name))) {
        groups.add((record, sites));
      }
    }
    final filteredWeb = webHomes
        .where(
          (home) =>
              (type == VideoSourceType.all ||
                  (type == VideoSourceType.audio) ==
                      SourceMediaHints.audioLabel(home.name)) &&
              matches('${home.name} ${home.url}'),
        )
        .toList();
    final showOrdinary = [
      VideoSourceType.all,
      VideoSourceType.ordinary,
      VideoSourceType.python,
      VideoSourceType.module,
      VideoSourceType.kazumi,
      VideoSourceType.audio,
    ].contains(type);
    final showCat = [
      VideoSourceType.all,
      VideoSourceType.cat,
      VideoSourceType.audio,
    ].contains(type);
    final showWeb = [
      VideoSourceType.all,
      VideoSourceType.web,
      VideoSourceType.audio,
    ].contains(type);
    var initialOffset = 0.0;
    bool hasFocus = false;
    if ([VideoSourceType.cat, VideoSourceType.audio].contains(type) &&
        widget.showingCat) {
      initialOffset = 44;
      for (final (_, sites) in groups) {
        final index = sites.indexWhere(
          (site) => site.id == widget.currentCatId,
        );
        if (index >= 0) {
          initialOffset +=
              72 +
              (index ~/ 2) *
                  (SourceCardMetrics.height + SourceCardMetrics.rowGap);
          hasFocus = true;
          break;
        }
        initialOffset +=
            72 +
            ((sites.length + 1) ~/ 2) *
                (SourceCardMetrics.height + SourceCardMetrics.rowGap);
      }
    } else if (type == VideoSourceType.web ||
        (type == VideoSourceType.audio && widget.currentWebId != null)) {
      final index = filteredWeb.indexWhere(
        (home) => home.id == widget.currentWebId,
      );
      hasFocus = index >= 0;
      initialOffset =
          72 +
          (index < 0 ? 0 : index ~/ 2) *
              (SourceCardMetrics.height + SourceCardMetrics.rowGap);
    } else {
      final index = ordinary.indexWhere(
        (source) => _ordinarySelected(source.id),
      );
      hasFocus = index >= 0;
      initialOffset =
          44 +
          (index < 0 ? 0 : index ~/ 2) *
              (SourceCardMetrics.height + SourceCardMetrics.rowGap);
    }
    final empty =
        (!showOrdinary || ordinary.isEmpty) &&
        (!showCat || groups.isEmpty) &&
        (!showWeb || filteredWeb.isEmpty);
    Widget sourceGrid(List<SourceDescriptor> entries, VideoSourceType kind) =>
        grid([
          for (final s in entries)
            SourceDragTile(
              key: ValueKey('video-picker-drag-${s.id}'),
              id: s.id,
              name: s.name,
              accepts: (id) => entries.any((s) => s.id == id),
              onMove: (from, to) async {
                final ids = entries.map((s) => s.id).toList();
                await SourceOrder.move(
                  Section.video,
                  originalOrder,
                  ids,
                  ids.indexOf(from),
                  ids.indexOf(to),
                );
                changed();
              },
              child: card(
                id: s.id,
                name: s.name,
                subtitle: _ordinarySelected(s.id)
                    ? '当前使用'
                    : kind == VideoSourceType.ordinary
                    ? (SourcePreferences.read(Section.video, s.id).pinned
                          ? '已置顶'
                          : SourceContentCategories.forSource(s).label)
                    : '${s.isAudio
                          ? '音频'
                          : s.isKazumi
                          ? 'Kazumi'
                          : s.runtimeKind == 'python'
                          ? 'PY'
                          : s.runtimeKind == 'module'
                          ? '模块'
                          : 'JS'} · ${s.version}',
                descriptor: s,
                selected: _ordinarySelected(s.id),
                onTap: () =>
                    Navigator.pop(context, VideoSourceChoice.ordinary(s.id)),
                onDelete: () => _deleteOrdinary(s),
                onMore: () => edit(
                  Section.video,
                  s.id,
                  s.name,
                  s.siteUrl,
                  widgetParameters: s.runtimeKind == 'module',
                  descriptor: s,
                ),
              ),
            ),
        ]);
    Widget runtimeGroup(VideoSourceType kind) {
      final entries = ordinary.where((source) => kind.accepts(source)).toList();
      if (entries.isEmpty) return const SizedBox.shrink();
      final title = switch (kind) {
        VideoSourceType.python => 'PY · Python 源',
        VideoSourceType.module => '模块 · ESM / CommonJS',
        VideoSourceType.kazumi => 'Kazumi · 动漫规则源',
        VideoSourceType.audio => '有声小说 · 音频源',
        _ => 'JS 源',
      };
      return Column(
        key: ValueKey('video-source-group-${kind.name}'),
        children: kind != VideoSourceType.ordinary
            ? [heading(title, entries.length), sourceGrid(entries, kind)]
            : [
                if (type == VideoSourceType.all) heading(title, entries.length),
                for (final category in SourceContentCategory.groups)
                  if (entries.any(
                    (source) =>
                        SourceContentCategories.forSource(source) == category,
                  )) ...[
                    if (type == VideoSourceType.all ||
                        content == SourceContentCategory.all)
                      KeyedSubtree(
                        key: ValueKey(
                          'video-source-content-heading-${category.id}',
                        ),
                        child: heading(
                          category.label,
                          entries
                              .where(
                                (source) =>
                                    SourceContentCategories.forSource(source) ==
                                    category,
                              )
                              .length,
                        ),
                      ),
                    sourceGrid(
                      entries
                          .where(
                            (source) =>
                                SourceContentCategories.forSource(source) ==
                                category,
                          )
                          .toList(),
                      kind,
                    ),
                  ],
              ],
      );
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: LumeTheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: DrawerGeometry.height(context),
              child: Column(
                children: [
                  SourcePickerHeader(
                    onSync: () async {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SubscriptionSyncPage(
                            section: Section.video,
                          ),
                        ),
                      );
                      if (mounted) await load();
                    },
                    title: '选择视频源',
                    onManage: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => SourceSectionPage(
                            section: Section.video,
                            manager: widget.manager,
                          ),
                        ),
                      );
                      if (mounted) await load();
                    },
                    addAction: IconButton(
                      tooltip: '添加视频源',
                      onPressed: add,
                      icon: const LumeIcon(
                        Icons.add,
                        slot: 'video_source_picker.add_button',
                      ),
                    ),
                    onQueryChanged: (value) => setState(() {
                      _locateCurrent = false;
                      query = value.trim().toLowerCase();
                    }),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final item in VideoSourceType.values)
                          Padding(
                            key: _tabKeys[item],
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('video-source-type-${item.name}'),
                              label: Text(item.label),
                              selected: type == item,
                              showCheckmark: false,
                              onSelected: (_) => setState(() {
                                _locateCurrent = false;
                                type = item;
                                _revealSelectedType();
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (type == VideoSourceType.ordinary)
                    Padding(
                      key: const ValueKey('video-source-content-filter'),
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: LumeTheme.surfaceAlt,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final categories = SourceContentCategory.values
                                  .where(
                                    (category) =>
                                        category !=
                                            SourceContentCategory.adult ||
                                        PrivacySettings.instance.showAdult,
                                  )
                                  .toList();
                              final minWidth =
                                  MediaQuery.textScalerOf(context).scale(13) *
                                      3 +
                                  MediaQuery.textScalerOf(context).scale(11) *
                                      2 +
                                  12;
                              final columns =
                                  constraints.maxWidth / categories.length >=
                                      minWidth
                                  ? categories.length
                                  : 2;
                              return Wrap(
                                children: [
                                  for (final category in categories)
                                    SizedBox(
                                      width: constraints.maxWidth / columns,
                                      child: Semantics(
                                        selected: content == category,
                                        child: TextButton(
                                          key: ValueKey(
                                            'video-source-content-${category.id}',
                                          ),
                                          onPressed: () =>
                                              selectContent(category),
                                          style: TextButton.styleFrom(
                                            minimumSize: const Size(0, 30),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 2,
                                              vertical: 4,
                                            ),
                                            foregroundColor: content == category
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                : LumeTheme.muted,
                                            backgroundColor: content == category
                                                ? LumeTheme.surface
                                                : Colors.transparent,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                category.label,
                                                maxLines: 1,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                '${category == SourceContentCategory.all ? contentCounts.values.fold<int>(0, (sum, value) => sum + value) : contentCounts[category] ?? 0}',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : error != null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('源列表加载失败'),
                                  TextButton(
                                    onPressed: load,
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            )
                          : SourcePickerScrollList(
                              key: ValueKey(
                                'video-picker-list-${type.name}-${type == VideoSourceType.ordinary ? content.id : ''}-$query',
                              ),
                              focusKey: _locateCurrent && hasFocus
                                  ? _currentSourceKey
                                  : null,
                              estimatedOffset: initialOffset,
                              padding: const EdgeInsets.fromLTRB(
                                SourceCardMetrics.horizontalPadding,
                                0,
                                SourceCardMetrics.horizontalPadding,
                                24,
                              ),
                              children: [
                                if (empty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 48,
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          query.isNotEmpty
                                              ? '没有匹配的源'
                                              : type ==
                                                        VideoSourceType
                                                            .ordinary &&
                                                    content !=
                                                        SourceContentCategory
                                                            .all
                                              ? '「${content.label}」里还没有源'
                                              : '还没有可用的源',
                                        ),
                                        if (query.isEmpty)
                                          TextButton(
                                            onPressed: add,
                                            child: const Text('添加源'),
                                          ),
                                      ],
                                    ),
                                  ),
                                if (showOrdinary &&
                                    (type != VideoSourceType.all ||
                                        ordinary.any(
                                          (s) => VideoSourceType.ordinary
                                              .accepts(s),
                                        )))
                                  runtimeGroup(
                                    type == VideoSourceType.all
                                        ? VideoSourceType.ordinary
                                        : type,
                                  ),
                                if (showCat && groups.isNotEmpty)
                                  KeyedSubtree(
                                    key: const ValueKey(
                                      'video-source-group-cat',
                                    ),
                                    child: heading(
                                      '猫源',
                                      groups.fold<int>(
                                        0,
                                        (count, group) =>
                                            count + group.$2.length,
                                      ),
                                    ),
                                  ),
                                if (showCat)
                                  for (final (record, sites) in groups) ...[
                                    heading(
                                      record.name,
                                      sites.length,
                                      trailing: IconButton(
                                        tooltip: '刷新${record.name}站点',
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        icon: busy.contains(record.id)
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const LumeIcon(
                                                Icons.refresh,
                                                size: 20,
                                                slot: 'video_source_picker.refresh',
                                              ),
                                      ),
                                    ),
                                    if (sites.isEmpty)
                                      TextButton(
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        child: const Text('加载包内站点'),
                                      ),
                                    grid([
                                      for (final s in sites)
                                        SourceDragTile(
                                          key: ValueKey(
                                            'video-picker-drag-${s.id}',
                                          ),
                                          id: s.id,
                                          name: s.name,
                                          accepts: (id) =>
                                              sites.any((s) => s.id == id),
                                          onMove: (from, to) async {
                                            final ids = sites
                                                .map((s) => s.id)
                                                .toList();
                                            await SourceOrder.move(
                                              Section.cat,
                                              record.sites
                                                  .map((s) => s.id)
                                                  .toList(),
                                              ids,
                                              ids.indexOf(from),
                                              ids.indexOf(to),
                                            );
                                            changed();
                                          },
                                          child: card(
                                            id: s.id,
                                            name: s.name,
                                            section: Section.cat,
                                            siteUrl: s.siteUrl,
                                            subtitle:
                                                widget.currentCatId == s.id
                                                ? '当前使用'
                                                : '猫源',
                                            selected:
                                                widget.currentCatId == s.id,
                                            onTap: () => Navigator.pop(
                                              context,
                                              VideoSourceChoice.cat(s),
                                            ),
                                            onDelete: () => _deleteEntry(
                                              s.id,
                                              s.name,
                                              () => service.removeSite(s),
                                            ),
                                            onMore: () => edit(
                                              Section.cat,
                                              s.id,
                                              s.name,
                                              s.siteUrl,
                                            ),
                                          ),
                                        ),
                                    ]),
                                  ],
                                if (type == VideoSourceType.all) ...[
                                  runtimeGroup(VideoSourceType.python),
                                  runtimeGroup(VideoSourceType.audio),
                                  runtimeGroup(VideoSourceType.kazumi),
                                  runtimeGroup(VideoSourceType.module),
                                ],
                                if (showWeb) ...[
                                  KeyedSubtree(
                                    key: const ValueKey(
                                      'video-source-group-web',
                                    ),
                                    child: heading(
                                      '网页主页',
                                      filteredWeb.length,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            key: const ValueKey(
                                              'video-import-html',
                                            ),
                                            tooltip: '导入 HTML 文件',
                                            onPressed: _importingHtml
                                                ? null
                                                : _importHtmlHomes,
                                            icon: const Icon(
                                              Icons.upload_file,
                                              size: 20,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: '添加网页主页',
                                            onPressed: _addWebHome,
                                            icon: const LumeIcon(
                                              Icons.add,
                                              size: 20,
                                              slot:
                                                  'video_source_picker.add_web',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (filteredWeb.isEmpty)
                                    TextButton.icon(
                                      onPressed: _addWebHome,
                                      icon: const LumeIcon(
                                        Icons.language,
                                        size: 20,
                                        slot: 'video_source_picker.web_empty',
                                      ),
                                      label: const Text('添加网页主页 / HTML'),
                                    )
                                  else
                                    grid([
                                      for (final home in filteredWeb)
                                        SourceDragTile(
                                          key: ValueKey(
                                            'web-picker-drag-${home.id}',
                                          ),
                                          id: home.id,
                                          name: home.name,
                                          accepts: (id) => filteredWeb.any(
                                            (row) => row.id == id,
                                          ),
                                          onMove: (from, to) async {
                                            final store = _webStore;
                                            if (store == null) return;
                                            store.moveVisible(
                                              filteredWeb
                                                  .map((row) => row.id)
                                                  .toList(),
                                              from,
                                              to,
                                            );
                                          },
                                          child: card(
                                            id: home.id,
                                            name: home.name,
                                            siteUrl: home.url,
                                            subtitle:
                                                widget.currentWebId == home.id
                                                ? '当前使用'
                                                : home.isLocal
                                                ? '本地 HTML'
                                                : home.url,
                                            selected:
                                                widget.currentWebId == home.id,
                                            onTap: () => Navigator.pop(
                                              context,
                                              VideoSourceChoice.web(home),
                                            ),
                                            onDelete: () => _deleteEntry(
                                              home.id,
                                              home.name,
                                              () async {
                                                _webStore?.remove(home.id);
                                              },
                                            ),
                                            onMore: () => _editWebHome(home),
                                          ),
                                        ),
                                    ]),
                                ],
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
