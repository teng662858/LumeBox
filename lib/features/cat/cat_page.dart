import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/column_list.dart';
import '../../shared/widgets/cat_site_tile.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../core/reading/browse_layout.dart';
import '../../core/reading/comic_image_tools.dart';
import '../../core/session/privacy_settings.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_swipe_tile.dart';
import '../../shared/widgets/subscription_status_icon.dart';
import '../reading/source_search_dialog.dart';
import '../reading/history_privacy.dart';
import '../reading/history_sheet.dart';
import '../reading/favorite_folder_dialogs.dart';
import '../../core/reading/favorite_folders.dart';
import '../../core/source/source_order.dart';
import '../../core/search/search_settings.dart';
import '../reading/collection_panel.dart';
import '../../core/source/source_preferences.dart';
import '../source/source_preferences_page.dart';
import '../source/video_source_scope.dart';
import '../../shared/widgets/missing_cover.dart';
import '../../core/source/home_browse_mode.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cat/cat_service.dart';
import '../../core/cat/cat_data_source.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/source_switch_button.dart';
import '../reading/poster_card.dart';
import '../reading/browse_layout_button.dart';
import '../reading/section_image.dart';
import '../reading/browse_choice_access.dart';
import '../comic/comic_detail_page.dart';
import '../novel/novel_detail_page.dart';
import '../shell/shell_dock.dart';
import 'cat_subscription_page.dart';
import 'cat_detail_page.dart';
import 'cat_web_page.dart';
import 'cat_preloader.dart';

class CatPage extends StatefulWidget {
  const CatPage({super.key, this.requestedSite});
  final CatSite? requestedSite;
  @override
  State<CatPage> createState() => _CatPageState();
}

class _CatPageState extends State<CatPage> with WidgetsBindingObserver {
  final service = CatService.instance;
  final scroll = ScrollController();
  ReadingLibrary? library;
  SectionImagePipeline? pipeline;
  CatDataSource? source;
  List<SourceCategory> categories = [];
  List<SourceFilterGroup> groups = [];
  List<SourceItem> items = [];
  Map<String, String> filters = {};
  String? category, error;
  String query = '';
  String? browseMode;
  bool loading = true, more = false, loadingMore = false;
  int page = 1, sequence = 0;
  StreamSubscription<Map<String, dynamic>>? messages;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service.addListener(changed);
    BrowseLayoutSettings.instance.addListener(changed);
    scroll.addListener(loadMore);
    messages = service.messages.stream.listen(hostMessage);
    unawaited(boot());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final site = widget.requestedSite;
    if (site != null &&
        site.id != oldWidget.requestedSite?.id &&
        library != null) {
      unawaited(selectSite(site));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    service.removeListener(changed);
    BrowseLayoutSettings.instance.removeListener(changed);
    messages?.cancel();
    scroll.dispose();
    pipeline?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        service.resume().catchError((Object error) {
          toast('猫源恢复失败，请刷新站点');
        }),
      );
    }
  }

  Future<void> boot() async {
    try {
      await service.boot();
      library = await ReadingLibrary.open(Section.cat);
      if (!mounted) return;
      pipeline = SectionImagePipeline(
        cacheDir: library!.imageCacheDir,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        maxConcurrent: SectionImagePipeline.coverConcurrency,
        decodeTransform: (bytes) =>
            automaticUpscale(bytes, UpscaleSurface.cover),
      );
      await service.checkUpdates();
      final requested = widget.requestedSite;
      if (requested == null) {
        await restoreSite();
      } else {
        await selectSite(requested);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  Future<void> restoreSite() async {
    if (service.needsSiteSelection) {
      if (mounted) {
        setState(() {
          source = null;
          loading = false;
          error = service.recoveryMessage;
        });
      }
      return;
    }
    final warm = await CatPreloader.take(service);
    if (!mounted) return;
    if (warm != null) {
      setState(() {
        source = warm.source;
        categories = warm.categories;
        groups = warm.groups;
        items = warm.list.items;
        more = warm.list.hasMore;
        page = 1;
        loading = false;
      });
      _preloadCovers(items);
      return;
    }
    final records = service.subscriptions.where((s) => s.enabled).toList();
    if (records.isEmpty) {
      if (mounted) {
        setState(() {
          source = null;
          loading = false;
        });
      }
      return;
    }
    final cached = records
        .expand((s) => s.sites)
        .where((site) => site.id == service.selectedSiteId)
        .firstOrNull;
    final record = cached == null
        ? records.first
        : records.firstWhere((r) => r.id == cached.subscriptionId);
    await service.activate(record);
    final selected =
        record.sites
            .where((site) => site.id == service.selectedSiteId)
            .firstOrNull ??
        record.sites
            .where(
              (site) => !RegExp(
                'config|setting|website|version|calendar|about|配置|我的网盘|日历|日期|更新日志|免责声明|公告|^\\d{4}-\\d{2}-\\d{2}',
                caseSensitive: false,
              ).hasMatch(site.key + site.name),
            )
            .firstOrNull ??
        record.sites.firstOrNull;
    if (!mounted) return;
    if (selected == null) {
      setState(() {
        loading = false;
        error = '订阅包没有返回站点，请打开源配置中心检查';
      });
      return;
    }
    await selectSite(selected);
  }

  Future<void> selectSite(CatSite site) async {
    if (!mounted) return;
    setState(() {
      source = CatDataSource(service, site);
      categories = [];
      groups = [];
      filters = {};
      category = null;
      browseMode = null;
      query = '';
    });
    await service.select(site);
    await refresh();
  }

  Future<void> refresh() async {
    CatPreloader.discard();
    final current = source;
    if (current == null) return;
    final token = ++sequence;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await current.homeData(force: true);
      final nextCategories = await current.categories();
      final nextGroups = await current.filtersFor(categoryId: category);
      final results = query.isEmpty && category == null && filters.isEmpty
          ? await current.homeList()
          : await current.list(
              categoryId: category,
              keyword: SearchSettings.instance.prepare(query),
              filters: filters,
            );
      if (!mounted || token != sequence) return;
      setState(() {
        categories = nextCategories;
        groups = nextGroups;
        items = results.items
            .where((item) => SearchSettings.instance.accepts(item.title, query))
            .toList();
        more = results.hasMore;
        page = 1;
        loading = false;
      });
      _preloadCovers(results.items);
      if (scroll.hasClients && scroll.offset > 0) scroll.jumpTo(0);
    } catch (failure) {
      if (mounted && token == sequence) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  void _preloadCovers(List<SourceItem> entries) {
    final images = pipeline;
    if (images == null) return;
    final covers = entries
        .where((e) => e.cover?.isNotEmpty == true)
        .take(12)
        .toList();
    for (final item in covers) {
      images.configureImageHeaders({item.cover!: item.coverHeaders});
    }
    images.preload(covers.map((e) => e.cover!), targetWidth: 360);
  }

  void loadMore() {
    if (!scroll.hasClients ||
        scroll.position.extentAfter > 400 ||
        !more ||
        loading ||
        loadingMore) {
      return;
    }
    unawaited(nextPage());
  }

  Future<void> nextPage() async {
    final current = source;
    if (current == null) return;
    final token = sequence;
    setState(() => loadingMore = true);
    try {
      final result = await current.list(
        categoryId: category,
        keyword: SearchSettings.instance.prepare(query),
        filters: filters,
        page: page + 1,
      );
      if (!mounted || token != sequence) return;
      setState(() {
        final ids = items.map((item) => item.id).toSet();
        items.addAll(
          result.items.where(
            (item) =>
                ids.add(item.id) &&
                SearchSettings.instance.accepts(item.title, query),
          ),
        );
        page++;
        more = result.hasMore;
      });
    } catch (failure) {
      if (mounted) toast('$failure');
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  void toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> hostMessage(Map<String, dynamic> message) async {
    if (!mounted) return;
    if (message['action'] == 'openInternalWebview') {
      final uri = Uri.tryParse(catText(message['url'] ?? message['address']));
      if (uri != null && ['http', 'https'].contains(uri.scheme)) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => CatWebPage(url: uri)),
        );
      }
    } else {
      final text = catText(
        message['message'] ?? message['text'] ?? message['content'],
      );
      if (text.isNotEmpty) toast(text);
    }
  }

  Future<void> subscriptions() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const CatSubscriptionPage()),
    );
    if (!mounted) return;
    try {
      await restoreSite();
    } catch (failure) {
      setState(() {
        loading = false;
        error = '$failure';
      });
    }
  }

  void selectBrowseMode(String mode) {
    final target = homeBrowseTarget(mode, categories, groups);
    if (target == null) {
      toast('当前站点未提供$mode分类或排序');
      return;
    }
    setState(() {
      browseMode = mode;
      if (target.category != null) {
        category = target.category;
        filters = {};
      } else {
        filters = Map.of(filters)..[target.group!] = target.option!;
      }
      query = '';
    });
    unawaited(refresh());
  }

  Widget _reorderSite(
    CatSubscription record,
    CatSite site,
    VoidCallback changed,
    Widget child,
  ) => SourceDragTile(
    id: site.id,
    name: site.name,
    accepts: (id) => record.sites.any((entry) => entry.id == id),
    onMove: (from, to) async {
      final all = record.sites.map((entry) => entry.id).toList()
        ..sort(
          (a, b) => SourceOrder.compare(
            Section.cat,
            a,
            b,
            record.sites.map((entry) => entry.id).toList(),
          ),
        );
      await SourceOrder.move(
        Section.cat,
        all,
        all,
        all.indexOf(from),
        all.indexOf(to),
      );
      if (mounted) changed();
    },
    child: child,
  );

  /// 打开单个猫源站点的设置页（原右侧三点菜单的动作）。
  ///
  /// 现在入口在卡片的**左滑菜单**里：列表行不再常驻三点按钮，名字可以完整居中。
  Future<void> _editSite(
    BuildContext context,
    CatSubscription record,
    CatSite site,
    VoidCallback refresh,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SourcePreferencesPage(
          section: Section.cat,
          sourceId: site.id,
          name: site.name,
          siteUrl: site.siteUrl,
          showChapterOrder: site.kind == 'novel' || site.kind == 'comic',
          onNetwork: () async {
            final url = await service.configurationUrl(record);
            if (!context.mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => CatWebPage(url: url)),
            );
            await service.refreshSites(record);
          },
        ),
      ),
    );
    if (context.mounted) refresh();
  }

  Future<void> sitePicker() async {
    final videoScope = VideoSourceScope.maybeOf(context);
    if (videoScope != null) {
      await videoScope.openPicker(context);
      return;
    }
    await ReadingLibrary.open(Section.cat);
    if (!mounted) return;
    String pickerQuery = '';
    String? sourceGroup;
    List<CatSite> choices(CatSubscription record) {
      final rows = record.sites
          .where(
            (site) =>
                PrivacySettings.instance.allowsSource(site.id, site.name) &&
                (pickerQuery.isEmpty ||
                    '${site.name} ${site.key} ${record.name}'
                        .toLowerCase()
                        .contains(pickerQuery.toLowerCase())),
          )
          .toList();
      rows.sort((a, b) {
        final pa = SourcePreferences.read(Section.cat, a.id).pinned,
            pb = SourcePreferences.read(Section.cat, b.id).pinned;
        return pa == pb
            ? SourceOrder.compare(
                Section.cat,
                a.id,
                b.id,
                record.sites.map((site) => site.id).toList(),
              )
            : pa
            ? -1
            : 1;
      });
      return rows;
    }

    final selected = await showLumeBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, pickerSetState) => ListenableBuilder(
          listenable: service,
          builder: (context, _) => SafeArea(
            child: SizedBox(
              height: DrawerGeometry.height(context),
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    ListTile(
                      title: const Text('选择站点'),
                      trailing: SegmentedButton<int>(
                        segments: [
                          for (final count in [1, 2])
                            ButtonSegment(
                              value: count,
                              label: Text(count == 1 ? '单列列表' : '双列列表'),
                            ),
                        ],
                        selected: {service.siteColumns.clamp(1, 2)},
                        showSelectedIcon: false,
                        onSelectionChanged: (values) =>
                            unawaited(service.setSiteColumns(values.first)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        onChanged: (value) =>
                            pickerSetState(() => pickerQuery = value),
                        decoration: const InputDecoration(
                          prefixIcon: LumeIcon(
                            Icons.search,
                            slot: 'cat_page.1',
                          ),
                          hintText: '搜索站点或订阅',
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: sourceGroup ?? '__all__',
                        items: [
                          const DropdownMenuItem(
                            value: '__all__',
                            child: Text('总分组（全部）'),
                          ),
                          for (final record in service.subscriptions.where(
                            (record) => record.enabled,
                          ))
                            DropdownMenuItem(
                              value: record.id,
                              child: Text(record.name),
                            ),
                        ],
                        onChanged: (value) => pickerSetState(
                          () => sourceGroup = value == '__all__' ? null : value,
                        ),
                      ),
                    ),
                    for (final record in service.subscriptions.where(
                      (s) =>
                          s.enabled &&
                          (sourceGroup == null || sourceGroup == s.id),
                    )) ...[
                      ListTile(
                        title: Text(
                          record.name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        subtitle: const Text('加载或刷新包内站点'),
                        trailing: const LumeIcon(
                          Icons.refresh,
                          slot: 'cat_page.2',
                        ),
                        onTap: () => Navigator.pop(context, record),
                      ),
                      CatGroupedSourceList(
                        columns: service.siteColumns.clamp(1, 2),
                        sites: choices(record),
                        itemBuilder: (context, site) {
                          final selected =
                              site.id ==
                              (source?.site.id ?? service.selectedSiteId);
                          // 单列 / 双列统一 51：与其它三个板块完全同高。
                          final cardHeight = CatSiteTile.compactHeight;
                          // 猫源专用行：无左侧图标、无右侧三点、文字单行居中。
                          // 长按整行拖拽排序；左滑露出「设置」菜单。
                          return _reorderSite(
                            record,
                            site,
                            () => pickerSetState(() {}),
                            SourceSwipeTile(
                              height: cardHeight,
                              actions: <SourceSwipeAction>[
                                SourceSwipeAction(
                                  label: '设置',
                                  color: LumeTheme.accent,
                                  onTap: () => unawaited(
                                    _editSite(
                                      context,
                                      record,
                                      site,
                                      () => pickerSetState(() {}),
                                    ),
                                  ),
                                ),
                              ],
                              child: CatSiteTile(
                                height: cardHeight,
                                label: site.name,
                                selected: selected,
                                onTap: () => Navigator.pop(context, site),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                    ListTile(
                      leading: const LumeIcon(Icons.add, slot: 'cat_page.3'),
                      title: const Text('猫源配置中心'),
                      onTap: () => Navigator.pop(context, 'subscriptions'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    try {
      if (selected is CatSite) await selectSite(selected);
      if (selected is CatSubscription) {
        await service.activate(selected);
        if (mounted) await sitePicker();
      }
      if (selected == 'subscriptions') await subscriptions();
      if (!mounted) return;
    } catch (failure) {
      toast('$failure');
    }
  }

  Future<void> search() async {
    final lib = library;
    if (lib == null) return;
    final value = await showDialog<String>(
      context: context,
      builder: (_) =>
          SourceSearchDialog(source: source, library: lib, initialQuery: query),
    );
    if (value != null && mounted) {
      setState(() => query = value);
      await refresh();
    }
  }

  Map<String, dynamic> record(SourceItem item) => {
    'id': item.id,
    'title': item.title,
    'cover': item.cover,
    'headers': item.coverHeaders,
    'subtitle': item.subtitle,
  };
  Future<void> openItem(SourceItem item, {CatSite? site}) async {
    final current = source;
    if (site == null && current != null && current.isFolder(item.id)) {
      setState(() {
        category = current.rawItemId(item.id);
        filters = {};
        query = '';
      });
      await refresh();
      return;
    }
    final selected = site ?? source?.site;
    final lib = library;
    if (selected == null || lib == null) return;
    try {
      if (lib.setting('history.incognito') != 'true') {
        await service.remember(selected, record(item));
      }
      if (!mounted) return;
      final manager = CatSourceManager(service, selected);
      final target = ReadingTarget(
        sourceId: selected.id,
        itemId: item.id,
        title: item.title,
        cover: item.cover,
        subtitle: item.subtitle,
      );
      final Widget detail = selected.kind == 'comic'
          ? ComicDetailPage(
              library: lib,
              manager: manager,
              target: target,
              runtimeAvailable: true,
            )
          : selected.kind == 'novel'
          ? NovelDetailPage(library: lib, manager: manager, target: target)
          : CatDetailPage(
              source: CatDataSource(service, selected),
              item: item,
              library: lib,
            );
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => detail),
      );
      if (!mounted) return;
      // 从详情/阅读/播放返回：猫源历史由 service 在打开时写入，阅读进度
      // 由 lib 落库；两边都主动通知一次，列表无需切页签就会刷新。
      lib.refresh();
      setState(() {});
    } catch (failure) {
      toast('$failure');
    }
  }

  Future<void> collection(bool favorites) async {
    final lib = library;
    if (lib == null) return;
    if (!favorites && !await HistoryPrivacy.unlock(context, lib)) return;
    if (!mounted) return;
    var collectionQuery = '';
    var checking = false;
    var initialCheckStarted = false;
    var showSearch = false;
    String? folder;
    final folders = FavoriteFolders(lib);
    List<Map<String, dynamic>> records() => favorites
        ? service.favoriteItems
        : service.history.where(service.collectionAllowed).toList();
    final chosen = await showLumeBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final entries = records()
              .where(
                (entry) =>
                    catText(entry['title'])
                        .toLowerCase()
                        .contains(collectionQuery.toLowerCase()) &&
                    (folder == null ||
                        (folders.load()[folder] ?? []).contains(
                          '${entry['site']}|${entry['id']}',
                        )),
              )
              .toList();
          String id(Map<String, dynamic> entry) =>
              '${entry['site']}|${entry['id']}';
          DateTime? rawTime(Map<String, dynamic> entry) {
            final value = entry['time'];
            if (value is num) {
              return DateTime.fromMillisecondsSinceEpoch(value.toInt());
            }
            final text = catText(value).trim();
            if (text.isEmpty) return null;
            final parsed = DateTime.tryParse(text);
            if (parsed != null) return parsed;
            final millis = int.tryParse(text);
            return millis == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(millis);
          }

          /// 收藏在旧版本里没有时间戳：依次回退到同一条历史、阅读进度与
          /// 书架行，实在没有才用当前时间（只影响这一条的时间文案）。
          DateTime entryTime(Map<String, dynamic> entry) {
            final direct = rawTime(entry);
            if (direct != null) return direct;
            final key = id(entry);
            final historyMatch = service.history
                .where((old) => id(old) == key)
                .firstOrNull;
            final fromHistory = historyMatch == null
                ? null
                : rawTime(historyMatch);
            if (fromHistory != null) return fromHistory;
            final itemId = catText(entry['id']);
            return lib.progress(itemId)?.updatedAt ??
                lib.item(itemId)?.updatedAt ??
                DateTime.now();
          }

          entries.sort((a, b) => entryTime(b).compareTo(entryTime(a)));

          /// 猫源集合记录 → 共享历史卡片所需的 [LibraryItem]。
          ///
          /// 只为渲染服务：收藏状态与删除仍由 [CatService] 负责，这里不写库。
          LibraryItem libraryItem(Map<String, dynamic> entry) {
            final itemId = catText(entry['id']);
            final saved = lib.item(itemId);
            final time = entryTime(entry);
            return LibraryItem(
              section: Section.cat,
              itemId: itemId,
              sourceId: catText(entry['site']),
              title: catText(entry['title']),
              cover: entry['cover'] as String?,
              subtitle: entry['subtitle'] == null
                  ? null
                  : catText(entry['subtitle']),
              chapterCount: saved?.chapterCount ?? 0,
              readChapterIndex: saved?.readChapterIndex ?? -1,
              addedAt: time,
              updatedAt: time,
            );
          }

          Map<String, String> coverHeaders(Map<String, dynamic> entry) =>
              catMap(entry['headers'])
                  .map((key, value) => MapEntry(key, catText(value)));

          Future<void> moveToFolder(Map<String, dynamic> entry) async {
            if (!favorites) return;
            await chooseFavoriteFolder(context, folders, id(entry));
            if (context.mounted) update(() {});
          }

          void removeEntry(Map<String, dynamic> entry) {
            final itemId = catText(entry['id']);
            if (favorites) {
              lib.removeFavorite(itemId);
            } else {
              lib.removeHistory(itemId);
            }
            unawaited(
              service.removeCollection({id(entry)}, favorites: favorites),
            );
            update(() {});
          }

          final now = DateTime.now();
          Future<void> checkFavorites({bool quiet = false}) async {
            if (checking || !context.mounted) return;
            lib.setSetting(
              'cat.favorites.lastCheck',
              DateTime.now().toIso8601String(),
            );

            update(() => checking = true);
            var changed = 0, failures = 0;
            for (final entry in records()) {
              try {
                final site = service.subscriptions
                    .expand((subscription) => subscription.sites)
                    .where((site) => site.id == entry['site'])
                    .firstOrNull;
                if (site == null) {
                  failures++;
                  continue;
                }
                final chapters = await CatDataSource(
                  service,
                  site,
                ).chapters(catText(entry['id']));
                final old = int.tryParse(
                  lib.setting('cat.favorite.count.${id(entry)}') ?? '',
                );
                if (old != null && chapters.length > old) {
                  lib.setSetting('cat.favorite.updated.${id(entry)}', 'true');
                  changed++;
                }
                lib.setSetting(
                  'cat.favorite.count.${id(entry)}',
                  '${chapters.length}',
                );
              } catch (_) {
                failures++;
              }
              if (!context.mounted) return;
            }
            if (context.mounted) {
              update(() => checking = false);
              if (!quiet) {
                toast(
                  '发现 $changed 部更新${failures == 0 ? '' : '，$failures 部暂时无法检查'}',
                );
              }
            }
          }

          if (favorites && !initialCheckStarted) {
            initialCheckStarted = true;
            final last = DateTime.tryParse(
              lib.setting('cat.favorites.lastCheck') ?? '',
            );
            if (last == null ||
                DateTime.now().difference(last) >=
                    const Duration(minutes: 10)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) unawaited(checkFavorites(quiet: true));
              });
            }
          }
          return HistoryPrivacyGuard(
            library: lib,
            enabled: !favorites,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                key: const Key('history-drawer-frame'),
                height: DrawerGeometry.height(context),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  child: Material(
                    color: LumeTheme.base,
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: double.infinity,
                        child: Column(
                          children: [
                            ListTile(
                              title: Text(favorites ? '猫源 · 收藏' : '猫源 · 历史'),
                              subtitle: Text('${entries.length} 条 · 最近在前'),
                              trailing: IconButton(
                                tooltip: '关闭',
                                icon: const LumeIcon(
                                  Icons.close,
                                  slot: 'cat_page.4',
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (favorites)
                                  IconButton(
                                    tooltip: '管理收藏夹',
                                    icon: const LumeIcon(
                                      Icons.create_new_folder_outlined,
                                      slot: 'cat_page.5',
                                    ),
                                    onPressed: () async {
                                      await showFavoriteFolderManager(
                                        context,
                                        folders,
                                      );
                                      if (context.mounted) {
                                        update(() {
                                          if (!folders.load().containsKey(
                                            folder,
                                          )) {
                                            folder = null;
                                          }
                                        });
                                      }
                                    },
                                  ),
                                if (favorites)
                                  IconButton(
                                    tooltip: '检查收藏更新',
                                    icon: checking
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Badge(
                                            isLabelVisible: records().any(
                                              (entry) =>
                                                  lib.setting(
                                                    'cat.favorite.updated.${id(entry)}',
                                                  ) ==
                                                  'true',
                                            ),
                                            child: const LumeIcon(
                                              Icons.notifications_outlined,
                                              slot: 'cat_page.6',
                                            ),
                                          ),
                                    onPressed: checking
                                        ? null
                                        : () => checkFavorites(),
                                  ),
                                IconButton(
                                  tooltip: '搜索记录',
                                  icon: const LumeIcon(
                                    Icons.search,
                                    slot: 'cat_page.7',
                                  ),
                                  onPressed: () =>
                                      update(() => showSearch = !showSearch),
                                ),
                                if (!favorites) ...[
                                  IconButton(
                                    tooltip: '历史记录锁',
                                    icon: LumeIcon(
                                      (lib.setting(HistoryPrivacy.lockKey) ??
                                                  '')
                                              .isEmpty
                                          ? Icons.lock_open
                                          : Icons.lock,
                                      slot: 'cat_page.8',
                                      variant: true,
                                    ),
                                    onPressed: () async {
                                      await HistoryPrivacy.toggleLock(
                                        context,
                                        lib,
                                      );
                                      if (context.mounted) update(() {});
                                    },
                                  ),
                                  IconButton(
                                    tooltip: '无痕模式',
                                    isSelected:
                                        lib.setting('history.incognito') ==
                                        'true',
                                    icon: const LumeIcon(
                                      Icons.visibility_off_outlined,
                                      slot: 'cat_page.9',
                                    ),
                                    selectedIcon: const LumeIcon(
                                      Icons.visibility_off,
                                      slot: 'cat_page.10',
                                    ),
                                    onPressed: () {
                                      lib.setSetting(
                                        'history.incognito',
                                        '${lib.setting('history.incognito') != 'true'}',
                                      );
                                      update(() {});
                                    },
                                  ),
                                ],
                              ],
                            ),
                            if (favorites && folders.load().isNotEmpty)
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    ChoiceChip(
                                      label: const Text('全部收藏'),
                                      selected: folder == null,
                                      onSelected: (_) =>
                                          update(() => folder = null),
                                    ),
                                    for (final name in folders.load().keys)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8),
                                        child: ChoiceChip(
                                          label: Text(name),
                                          selected: folder == name,
                                          onSelected: (_) =>
                                              update(() => folder = name),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            if (showSearch)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: TextField(
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    hintText: '搜索标题',
                                  ),
                                  onChanged: (value) =>
                                      update(() => collectionQuery = value),
                                ),
                              ),
                            Expanded(
                              child: CollectionPanel(
                                title: favorites ? '收藏' : '历史',
                                library: library,
                                storageKey:
                                    'collection.${favorites ? 'favorites' : 'history'}.layout',
                                ids: entries.map(id).toList(),
                                onDelete: (ids) async {
                                  for (final entry in entries.where(
                                    (entry) => ids.contains(id(entry)),
                                  )) {
                                    if (favorites) {
                                      library?.removeFavorite(
                                        catText(entry['id']),
                                      );
                                    } else {
                                      library?.removeHistory(
                                        catText(entry['id']),
                                      );
                                    }
                                  }
                                  await service.removeCollection(
                                    ids,
                                    favorites: favorites,
                                  );
                                  update(() {});
                                },
                                itemBuilder: (index) {
                                  final entry = entries[index];
                                  final item = libraryItem(entry);
                                  return GestureDetector(
                                    onLongPress: favorites
                                        ? () => moveToFolder(entry)
                                        : null,
                                    child: HistoryEntryTile(
                                      pipeline: pipeline,
                                      headers: coverHeaders(entry),
                                      updated:
                                          lib.setting(
                                            'cat.favorite.updated.${id(entry)}',
                                          ) ==
                                          'true',
                                      item: item,
                                      progress: lib.progress(item.itemId),
                                      now: now,
                                      removeLabel: favorites ? '取消收藏' : '删除记录',
                                      onRemove: () => removeEntry(entry),
                                      onResume: () =>
                                          Navigator.pop(context, entry),
                                    ),
                                  );
                                },
                                gridBuilder: (index) {
                                  final entry = entries[index];
                                  final item = libraryItem(entry);
                                  return GestureDetector(
                                    onLongPress: favorites
                                        ? () => moveToFolder(entry)
                                        : null,
                                    child: HistoryGridTile(
                                      item: item,
                                      progress: lib.progress(item.itemId),
                                      pipeline: pipeline,
                                      headers: coverHeaders(entry),
                                      updated:
                                          lib.setting(
                                            'cat.favorite.updated.${id(entry)}',
                                          ) ==
                                          'true',
                                      onTap: () =>
                                          Navigator.pop(context, entry),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (chosen == null || !mounted) return;
    lib.setSetting(
      'cat.favorite.updated.${chosen['site']}|${chosen['id']}',
      'false',
    );
    final site = service.subscriptions
        .expand((s) => s.sites)
        .where((site) => site.id == chosen['site'])
        .firstOrNull;
    if (site == null) {
      toast('这个站点的订阅已被移除');
      return;
    }
    await openItem(
      SourceItem(
        id: catText(chosen['id']),
        title: catText(chosen['title']),
        cover: chosen['cover'] as String?,
        coverHeaders: catMap(chosen['headers'])
            .map((key, value) => MapEntry(key, catText(value))),
      ),
      site: site,
    );
  }

  Widget row(List<Widget> chips) => SizedBox(
    height: 34,
    child: ListView(scrollDirection: Axis.horizontal, children: chips),
  );
  Widget chip(String text, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        backgroundColor: selected
            ? LumeTheme.accent.withValues(alpha: .12)
            : Colors.transparent,
        foregroundColor: selected ? LumeTheme.accent : LumeTheme.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 30),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: LumeTypography.bodySize,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w600,
        ),
      ),
    ),
  );
  Future<void> combinedFilters() async {
    final selected = await showBrowseFilters(
      context: context,
      categories: categories,
      groups: groups,
      category: category,
      filters: filters,
    );
    if (!mounted || selected == null) return;
    setState(() {
      browseMode = null;
      category = selected.category;
      filters = selected.filters;
      query = '';
    });
    await refresh();
  }

  Widget header() => GlassPanel(
    module: FloatingModule.home,
    radius: HomePanelLayout.radius,
    padding: HomePanelLayout.padding,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 36,
          child: IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: VideoSourceScope.maybeOf(context) != null
                              ? null
                              : service.busy
                              ? null
                              : sitePicker,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  VideoSourceScope.maybeOf(context) != null
                                      ? '视频'
                                      : '猫源',
                                  style: TextStyle(
                                    fontSize: LumeTypography.sectionTitleSize,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (VideoSourceScope.maybeOf(context) == null)
                                  const LumeIcon(
                                    Icons.expand_more,
                                    slot: 'cat_page.11',
                                    size: 16,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '历史',
                  onPressed: () => collection(false),
                  icon: const LumeIcon(Icons.history, slot: 'cat_page.12'),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: '收藏',
                  onPressed: () => collection(true),
                  icon: const LumeIcon(
                    Icons.bookmark_outline,
                    slot: 'cat_page.13',
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: '源管理',
                  onPressed: sitePicker,
                  icon: const LumeIcon(Icons.dns_outlined, slot: 'cat_page.14'),
                ),
                const SizedBox(width: 2),
                Tooltip(
                  message: '订阅',
                  child: IconButton(
                    onPressed: subscriptions,
                    icon: const SubscriptionStatusIcon(section: Section.cat),
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                child: SourceSwitchButton(
                  key: const ValueKey('open-cat-source-picker'),
                  onPressed: service.busy ? null : sitePicker,
                  iconSlot: 'cat_page.15',
                  name:
                      source?.name ??
                      (service.needsSiteSelection
                          ? '选择站点'
                          : CatPreloader.selectedSite(service)?.name ?? '选择站点'),
                ),
              ),
            ),
            BrowseLayoutButton(
              mode: _layout,
              onChanged: (mode) => unawaited(
                BrowseLayoutSettings.instance.setMode(Section.cat, mode),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: source == null ? null : search,
              icon: const LumeIcon(Icons.search, slot: 'cat_page.17'),
            ),
          ],
        ),
        if (categories.isNotEmpty)
          BrowseChoiceAccess(
            choices: categories,
            onOpen: combinedFilters,
            selectedId: category,
            onSelected: (id) {
              setState(() {
                browseMode = null;
                category = id;
                filters = {};
                query = '';
              });
              unawaited(refresh());
            },
            child: row([
              chip('全部', category == null, () {
                setState(() {
                  browseMode = null;
                  category = null;
                  filters = {};
                  query = '';
                });
                unawaited(refresh());
              }),
              for (final entry in categories)
                chip(entry.title, category == entry.id, () {
                  setState(() {
                    browseMode = null;
                    category = entry.id;
                    filters = {};
                    query = '';
                  });
                  unawaited(refresh());
                }),
            ]),
          ),
        for (final group in groups)
          row([
            if (!group.options.any((option) => option.title == '全部'))
              chip('全部', !filters.containsKey(group.id), () {
                setState(() {
                  browseMode = null;
                  filters.remove(group.id);
                });
                unawaited(refresh());
              }),
            for (final option in group.options)
              chip(
                option.title,
                (filters[group.id] ??
                        (group.options
                            .where((o) => o.title == '全部')
                            .firstOrNull
                            ?.id)) ==
                    option.id,
                () {
                  setState(() {
                    browseMode = null;
                    filters[group.id] = option.id;
                  });
                  unawaited(refresh());
                },
              ),
          ]),
        if (query.isNotEmpty) Text('搜索：$query'),
      ],
    ),
  );
  BrowseLayoutMode get _layout =>
      BrowseLayoutSettings.instance.modeFor(Section.cat) ??
      BrowseLayoutMode.grid3;
  Widget browseItem(BuildContext context, int index) {
    final item = items[index];
    if (_layout == BrowseLayoutMode.list || _layout == BrowseLayoutMode.list2) {
      return TwoColumnSourceItemTile(
        item: item,
        pipeline: pipeline,
        onTap: () => openItem(item),
      );
    }
    if (_layout == BrowseLayoutMode.grid3) {
      return PosterTile(
        compactGrid: true,
        item: item,
        pipeline: pipeline,
        onTap: () => openItem(item),
      );
    }
    return PosterCard(
      footnoteBelow: true,
      onTap: () => openItem(item),
      footnote: SizedBox(
        height: LumeTypography.descriptionSize * 1.25 * 2,
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LumeTheme.textPrimary,
              fontSize: LumeTypography.descriptionSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      child: pipeline == null
          ? const SizedBox()
          : SectionImage(
              pipeline: pipeline!,
              url: item.cover ?? '',
              placeholder: MissingCover(
                title: item.title,
                section: pipeline!.section,
              ),
              headers: item.coverHeaders,
              targetWidth: 300,
              fit: BoxFit.cover,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: LumeTheme.base,
    body: SafeArea(
      top: false,
      bottom: false,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                HomePanelLayout.sidePadding,
                trimmedTopInset(MediaQuery.paddingOf(context).top),
                HomePanelLayout.sidePadding,
                HomePanelLayout.contentGap,
              ),
              sliver: SliverToBoxAdapter(child: header()),
            ),
            if (service.busy)
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    Text(service.status),
                  ],
                ),
              ),
            if (loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (error != null)
              SliverToBoxAdapter(
                child: GlassCard(
                  child: Column(
                    children: [
                      Text(error!),
                      TextButton(
                        onPressed: source == null ? boot : refresh,
                        child: const Text('重试'),
                      ),
                      TextButton(
                        onPressed: subscriptions,
                        child: const Text('管理订阅'),
                      ),
                    ],
                  ),
                ),
              )
            else if (source == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      const Text('添加猫源订阅后，选择包内站点即可浏览。'),
                      FilledButton.icon(
                        onPressed: subscriptions,
                        icon: const SubscriptionStatusIcon(
                          section: Section.cat,
                        ),
                        label: const Text('添加订阅'),
                      ),
                    ],
                  ),
                ),
              )
            else if (items.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: Text('暂无内容，请选择分类或其他站点')),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: _layout == BrowseLayoutMode.grid3
                      ? ThreeColumnPosterLayout.sidePadding
                      : TwoColumnSourceLayout.sidePadding,
                ),
                sliver: _layout == BrowseLayoutMode.list
                    ? SliverList.separated(
                        itemCount: items.length,
                        itemBuilder: browseItem,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(0xFFE5E5EA),
                        ),
                      )
                    : SliverLayoutBuilder(
                        builder: (context, constraints) => SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: _layout.columns,
                                childAspectRatio: _layout.tileAspectRatio,
                                mainAxisExtent:
                                    _layout == BrowseLayoutMode.list2
                                    ? TwoColumnSourceLayout.itemExtent(
                                        context,
                                        (constraints.crossAxisExtent -
                                                TwoColumnSourceLayout.spacing) /
                                            2,
                                      )
                                    : null,
                                crossAxisSpacing:
                                    _layout == BrowseLayoutMode.grid3
                                    ? ThreeColumnPosterLayout.spacing
                                    : _layout == BrowseLayoutMode.list2
                                    ? TwoColumnSourceLayout.spacing
                                    : 12,
                                mainAxisSpacing:
                                    _layout == BrowseLayoutMode.grid3
                                    ? ThreeColumnPosterLayout.rowSpacing
                                    : _layout == BrowseLayoutMode.list2
                                    ? TwoColumnSourceLayout.rowSpacing
                                    : 12,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            browseItem,
                            childCount: items.length,
                          ),
                        ),
                      ),
              ),
            if (loadingMore)
              const SliverToBoxAdapter(
                child: Center(child: CircularProgressIndicator()),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: ShellDockScope.bottomInset(context) + 24),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One continuous cat-site panel. Kinds do not create headings or scroll lanes.
/// The caller retains subscription controls and owns the only scroll view.
class CatGroupedSourceList extends StatelessWidget {
  const CatGroupedSourceList({
    super.key,
    required this.columns,
    required this.sites,
    required this.itemBuilder,
  });
  final int columns;
  final List<CatSite> sites;
  final Widget Function(BuildContext, CatSite) itemBuilder;

  @override
  Widget build(BuildContext context) {
    Widget card(CatSite site) => Material(
      // 卡片底色与描边由 CatSiteTile 自己画：外层透明，避免在圆角处
      // 露出一圈灰色底、把 1px 描边衬成两层。
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: ListTileTheme.merge(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        horizontalTitleGap: 6,
        minLeadingWidth: 24,
        minVerticalPadding: 2,
        minTileHeight: 44,
        visualDensity: const VisualDensity(vertical: -2),
        child: itemBuilder(context, site),
      ),
    );
    return Padding(
      // 与上方「加载或刷新包内站点」的 ListTile 文本基线对齐（默认 16）；
      // 之前 28 让卡片整体缩进 12，左右看起来空一大截。
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sites.length; i += columns.clamp(1, 2))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: card(sites[i])),
                  if (columns > 1) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: i + 1 < sites.length
                          ? card(sites[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CatSourceList extends StatelessWidget {
  const CatSourceList({
    super.key,
    required this.columns,
    required this.children,
    required this.shrinkWrap,
    required this.physics,
    required this.padding,
  });
  final int columns;
  final List<Widget> children;
  final bool shrinkWrap;
  final ScrollPhysics physics;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => ColumnList(
    columns: columns,
    itemCount: children.length,
    itemBuilder: (_, index) => children[index],
    padding: padding,
    shrinkWrap: shrinkWrap,
    physics: physics,
  );
}
