import 'dart:convert';

import 'source_action_dialogs.dart';
import '../../core/source/source_manager.dart';
import '../../core/source/lume_sources.dart';
import 'source_login_page.dart';
import '../../core/source/source_favicon.dart';
import '../../shared/widgets/source_icon.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../core/source/source_picker_groups.dart';
import '../../core/source/source_content_category.dart';
import '../../core/source/data_source.dart';
import '../../core/cache/section_memory_cache.dart';
import '../shell/section_preloader.dart';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_preferences.dart';
import '../../shared/widgets/glass_card.dart';
import 'rex_widget_parameters.dart';

class SourcePreferencesPage extends StatefulWidget {
  const SourcePreferencesPage({
    super.key,
    required this.section,
    required this.sourceId,
    required this.name,
    this.siteUrl = '',
    this.onNetwork,
    this.showChapterOrder,
    this.showWidgetParameters = false,
    this.descriptor,
    this.manager,
    this.favicon,
  });
  final Section section;
  final String sourceId, name, siteUrl;
  final Future<void> Function()? onNetwork;
  final bool? showChapterOrder;
  final bool showWidgetParameters;
  final SourceDescriptor? descriptor;
  final SourceManager? manager;
  final SourceFavicon? favicon;
  @override
  State<SourcePreferencesPage> createState() => _SourcePreferencesPageState();
}

class _SourcePreferencesPageState extends State<SourcePreferencesPage> {
  bool get _unifiedSite =>
      widget.descriptor != null && widget.section != Section.cat;
  bool get _jsContent =>
      widget.section == Section.video &&
      widget.descriptor != null &&
      SourceContentCategories.appliesTo(widget.descriptor!);
  late SourcePreferences prefs = SourcePreferences.read(
    widget.section,
    widget.sourceId,
  );
  late final icon = TextEditingController(text: prefs.iconUrl);
  late final original = TextEditingController(
    text: prefs.originalOrigin.isEmpty ? widget.siteUrl : prefs.originalOrigin,
  );
  late final custom = TextEditingController(text: prefs.customOrigin);
  String? error;
  bool _saving = false;
  bool _fetchingIcon = false;
  String? _iconStatus;
  String? _fetchedIconData;
  late String _iconOrigin = widget.siteUrl;
  int _iconRevision = 0;
  final _siteEditor = GlobalKey<SourceNetworkDialogState>();
  SourceManager get _manager =>
      widget.manager ?? LumeSources.manager(widget.section);
  final _widgetParameters = GlobalKey<RexWidgetParametersState>();
  @override
  void dispose() {
    icon.dispose();
    original.dispose();
    custom.dispose();
    super.dispose();
  }

  Future<String> _activeAddress() async {
    if (_unifiedSite) {
      final draft = _siteEditor.currentState?.draftSite.resolvedDomain;
      if (draft != null && draft.isNotEmpty) return draft;
      final fresh = (await _manager.list())
          .where((s) => s.id == widget.sourceId)
          .firstOrNull;
      final site = fresh ?? widget.descriptor!;
      if (site.siteConfig.resolvedDomain.isNotEmpty) {
        return site.siteConfig.resolvedDomain;
      }
      if (site.siteUrl.isNotEmpty) return site.siteUrl;
    }
    return custom.text.trim().isNotEmpty ? custom.text.trim() : widget.siteUrl;
  }

  Future<void> _getSiteIcon() async {
    if (_fetchingIcon) return;
    setState(() {
      _fetchingIcon = true;
      _iconStatus = null;
    });
    try {
      final address = await _activeAddress();
      final uri = Uri.tryParse(address);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException('源还没有站点地址，请先填写站点地址');
      }
      final bytes = await (widget.favicon ?? SourceFavicon.instance).loadBest(
        origin: uri.origin,
        explicit: [
          if (widget.descriptor?.iconUrl.isNotEmpty == true)
            widget.descriptor!.iconUrl,
        ],
        section: widget.section,
        sourceId: widget.sourceId,
      );
      if (!mounted) return;
      if (bytes == null) {
        setState(() => _iconStatus = '暂未找到可用图标，已保留原设置；留空时会显示默认字母图标');
      } else {
        icon.clear();
        _fetchedIconData = base64Encode(bytes);
        setState(() {
          _iconOrigin = uri.origin;
          _iconRevision++;
          _iconStatus = '图标已准备好，点右上角「保存」后使用';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _iconStatus = e is FormatException
              ? e.message
              : '图标获取失败，原设置已保留，请稍后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _fetchingIcon = false);
    }
  }

  Future<void> save() async {
    if (_saving) return;
    final domain = custom.text.trim(),
        from = original.text.trim(),
        url = icon.text.trim();
    if (!_unifiedSite &&
        domain.isNotEmpty &&
        (!SourcePreferences.validOrigin(domain) ||
            !SourcePreferences.validOrigin(from))) {
      setState(() => error = '请填写完整站点地址，如 https://example.com，不含路径或账号密码');
      return;
    }
    if (url.isNotEmpty) {
      final u = Uri.tryParse(url);
      if (u == null ||
          u.scheme != 'https' ||
          u.host.isEmpty ||
          u.userInfo.isNotEmpty) {
        setState(() => error = '图标请使用不含账号密码的 HTTPS 图片地址');
        return;
      }
    }
    try {
      await _widgetParameters.currentState?.save();
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    if (!mounted) return;
    final site = _siteEditor.currentState?.readResult();
    if (_unifiedSite && site == null) {
      setState(() => error = '请检查站点地址、资源线路与参数');
      final editorContext = _siteEditor.currentContext;
      if (editorContext != null && editorContext.mounted) {
        await Scrollable.ensureVisible(editorContext);
      }
      return;
    }
    setState(() {
      _saving = true;
      error = null;
    });
    try {
      if (site != null) {
        await _manager.setNetwork(
          widget.sourceId,
          userAgent: site.network.userAgent,
          cookie: site.network.cookie,
          proxy: site.network.proxy,
          bridge: site.network.bridge,
          allowBadCertificate: site.network.allowBadCertificate,
        );
        await _manager.setSiteConfig(widget.sourceId, site.site);
      }
      final current = SourcePreferences.read(widget.section, widget.sourceId);
      final updated = prefs.copyWith(
        iconUrl: url,
        iconData: url.isEmpty ? (_fetchedIconData ?? prefs.iconData) : '',
        originalOrigin: _unifiedSite ? current.originalOrigin : from,
        customOrigin: _unifiedSite ? current.customOrigin : domain,
      );
      await updated.save(widget.section, widget.sourceId);
      final legacyOriginChanged =
          !_unifiedSite &&
          (current.originalOrigin != updated.originalOrigin ||
              current.customOrigin != updated.customOrigin);
      if (site != null || legacyOriginChanged) {
        // Unified setters release on write; the legacy origin editor persists
        // separately and needs an explicit runtime reset here.
        if (legacyOriginChanged) {
          await _manager.invalidateRuntime(widget.sourceId);
        }
        SectionPreloader.discard(widget.section);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.sources,
    title: '${widget.name} · 源设置',
    actions: [
      TextButton(
        onPressed: _saving ? null : save,
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
    child: ListTileTheme(
      dense: true,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        children: [
          if (widget.descriptor != null)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text('版本 ${widget.descriptor!.version}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('置顶'),
                  Switch(
                    value: prefs.pinned,
                    onChanged: (v) =>
                        setState(() => prefs = prefs.copyWith(pinned: v)),
                  ),
                ],
              ),
              subtitle: Text(_networkHint(widget.descriptor!.networkMode)),
            ),
          if (!_unifiedSite && widget.siteUrl.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('登录站点'),
              subtitle: const Text('登录后自动同步，完成后直接返回'),
              onTap: () async {
                final address = await _activeAddress();
                if (!context.mounted) return;
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourceLoginPage(
                      section: widget.section,
                      sourceId: widget.sourceId,
                      name: widget.name,
                      url: address,
                    ),
                  ),
                );
              },
            ),

          if (_unifiedSite)
            SourceNetworkDialog(
              key: _siteEditor,
              source: widget.descriptor!,
              embedded: true,
            )
          else if (widget.onNetwork != null)
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('站点设置与账号配置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onNetwork,
            ),
          if (_jsContent)
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('内容分类'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final group in [
                        ('', '自动'),
                        for (final category in SourceContentCategory.groups)
                          (category.id, category.label),
                      ])
                        ChoiceChip(
                          key: ValueKey('source-content-setting-${group.$1}'),
                          visualDensity: VisualDensity.compact,
                          label: Text(group.$2),
                          selected: prefs.contentCategory == group.$1,
                          onSelected: (_) => setState(
                            () => prefs = prefs.copyWith(
                              contentCategory: group.$1,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '自动：${SourceContentCategories.automatic(widget.descriptor!).label}',
                  ),
                ],
              ),
            ),
          if (widget.section != Section.cat && !_jsContent)
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('源抽屉分类'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final group in [
                        ('', '自动'),
                        ...SourcePickerGroups.forSection(widget.section),
                      ])
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(group.$2),
                          selected: prefs.pickerGroup == group.$1,
                          onSelected: (_) => setState(
                            () => prefs = prefs.copyWith(pickerGroup: group.$1),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

          if (widget.descriptor == null ||
              (widget.showChapterOrder ?? widget.section == Section.comic))
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (widget.descriptor == null)
                    SwitchListTile(
                      title: const Text('置顶此源'),
                      value: prefs.pinned,
                      onChanged: (v) =>
                          setState(() => prefs = prefs.copyWith(pinned: v)),
                    ),
                  if (widget.showChapterOrder ??
                      (widget.section == Section.comic))
                    SwitchListTile(
                      title: const Text('新章节在前'),
                      subtitle: const Text('只改变目录的展示顺序'),
                      value: prefs.newestFirst,
                      onChanged: (v) => setState(
                        () => prefs = prefs.copyWith(newestFirst: v),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('图标与外观'),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '一键获取会比较网页、Apple Touch、manifest 和 favicon，优先高清版本。部分源已内置图标备用；站点没有可用图标时使用本地源标识，避免只显示首字。自定义图标需点右上角保存。',
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: icon,
                builder: (_, value, _) => Row(
                  children: [
                    SourceIcon(
                      key: ValueKey('icon-preview-$_iconRevision'),
                      name: widget.name,
                      siteUrl: _iconOrigin,
                      iconUrl: value.text,
                      siteIcon: widget.descriptor?.iconUrl ?? '',
                      size: 33,
                      section: widget.section,
                      sourceId: widget.sourceId,
                      favicon: widget.favicon,
                      iconData: value.text.trim().isEmpty
                          ? (_fetchedIconData ?? prefs.iconData)
                          : '',
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _fetchingIcon ? null : _getSiteIcon,
                      child: Text(_fetchingIcon ? '正在获取…' : '一键获取站点图标'),
                    ),
                  ],
                ),
              ),
              TextField(
                controller: icon,
                decoration: const InputDecoration(
                  labelText: '自定义源图标',
                  hintText: '可留空，无需填写',
                ),
              ),
              if (_iconStatus != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_iconStatus!),
                ),
              if (widget.section != Section.cat && !_unifiedSite)
                TextField(
                  controller: original,
                  decoration: const InputDecoration(labelText: '原站点地址'),
                ),
              if (widget.section != Section.cat && !_unifiedSite)
                TextField(
                  controller: custom,
                  decoration: const InputDecoration(
                    labelText: '自定义站点地址',
                    hintText: '留空沿用源脚本',
                  ),
                ),
              if (widget.section != Section.cat && !_unifiedSite)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('地址替换只作用于这个站点；独立图床与播放 CDN 保持原地址。'),
                ),
            ],
          ),
          if (widget.section == Section.video && widget.showWidgetParameters)
            RexWidgetParametersEditor(
              key: _widgetParameters,
              section: widget.section,
              sourceId: widget.sourceId,
            ),
          ListTile(
            leading: const LumeIcon(
              Icons.cleaning_services_outlined,
              slot: 'source_preferences_page.3',
            ),
            title: const Text('清理此源的浏览缓存'),
            subtitle: const Text('保留下载内容、书架与阅读进度'),
            onTap: () {
              final count = SectionMemoryCache.instance.removeSource(
                widget.section,
                widget.sourceId,
              );
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('已清理 $count 条浏览缓存')));
            },
          ),
          if (widget.siteUrl.isNotEmpty)
            ListTile(
              leading: const LumeIcon(
                Icons.copy_outlined,
                slot: 'source_preferences_page.4',
              ),
              title: const Text('复制站点地址'),
              onTap: () async {
                final address = await _activeAddress();
                await Clipboard.setData(ClipboardData(text: address));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('站点地址已复制')));
                }
              },
            ),
          ListTile(
            leading: const LumeIcon(
              Icons.restart_alt,
              slot: 'source_preferences_page.5',
            ),
            title: const Text('恢复默认源设置'),
            onTap: () {
              setState(() {
                prefs = const SourcePreferences();
                _fetchedIconData = null;
                icon.clear();
                custom.clear();
                original.text = widget.siteUrl;
                error = null;
                _widgetParameters.currentState?.reset();
                _siteEditor.currentState?.reset();
              });
            },
          ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        ],
      ),
    ),
  );
}

/// 脚本自报的网络要求 → 设置页提示文案。
String _networkHint(String mode) {
  switch (mode.trim().toLowerCase()) {
    case 'direct':
      return '直连可访问（无需代理）';
    case 'proxy':
      return '需要代理（走全局代理 / Clash 等）';
    case 'webview':
      return '含 Cloudflare 挑战，播放走内嵌浏览器';
    default:
      return '未标注（按全局网络设置）';
  }
}
