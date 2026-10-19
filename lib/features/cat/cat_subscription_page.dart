import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/source_update_badge.dart';
import '../../core/reading/reading_library.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/session/section.dart';
import '../../core/source/source_preferences.dart';
import '../../shared/widgets/source_icon.dart';
import '../source/source_preferences_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cat/cat_service.dart';
import '../../shared/widgets/glass_card.dart';
import 'cat_web_page.dart';

const catSubscriptionPresets = <String, String>{
  '牛二': 'https://9280.kstore.vip/cat/index.js.md5',
  '豆儿': 'https://catpaw.douer.me/index.js.md5',
  'lmentor': 'https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/lmentor/index.js.md5',
  '神秘猫源': 'https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/smdl/index.js.md5',
  '兔佬猫源': 'https://raw.githubusercontent.com/xiaobaitulele/xptv/refs/heads/main/jstv/index.js.md5',
  'Y佬猫源': 'https://raw.githubusercontent.com/Yswag/xptv-extensions/refs/heads/jstv/index.js.md5',
  '泥潭源': 'https://ghfast.top/https://raw.githubusercontent.com/nitan-tv/nitan/refs/heads/main/js/index.js.md5',
  '18+': 'https://raw.githubusercontent.com/fangkuia/XPTV/refs/heads/main/dist/index.js.md5',
};

class CatSubscriptionPage extends StatefulWidget {
  const CatSubscriptionPage({super.key});
  @override
  State<CatSubscriptionPage> createState() => _CatSubscriptionPageState();
}

class _CatSubscriptionPageState extends State<CatSubscriptionPage> {
  final service = CatService.instance;
  String? error;
  bool working = false;
  String sourceQuery = '';
  bool enabledOnly = false;
  @override
  void initState() {
    super.initState();
    ReadingLibrary.open(Section.cat).then((_) {
      if (mounted) setState(() {});
    });
  }

  List<CatSubscription> get visibleSubscriptions {
    final list = service.subscriptions
        .where(
          (s) =>
              (!enabledOnly || s.enabled) &&
              (sourceQuery.isEmpty ||
                  s.name.toLowerCase().contains(sourceQuery.toLowerCase())),
        )
        .toList();
    list.sort((a, b) {
      final pa = SourcePreferences.read(Section.cat, a.id).pinned,
          pb = SourcePreferences.read(Section.cat, b.id).pinned;
      return pa == pb
          ? a.name.compareTo(b.name)
          : pa
          ? -1
          : 1;
    });
    return list;
  }

  Future<void> run(Future<void> Function() operation) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await operation();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> add({String name = '', String url = ''}) async {
    final label = TextEditingController(text: name);
    final address = TextEditingController(text: url);
    final username = TextEditingController();
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加猫源订阅'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'index.js.md5 订阅链接',
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('订阅认证（可选）'),
                children: [
                  TextField(
                    controller: username,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                ],
              ),
              const Text('保存后自动检查更新，无需再次粘贴链接。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存并导入'),
          ),
        ],
      ),
    );
    final savedName = label.text;
    var savedUrl = address.text.trim();
    if (username.text.isNotEmpty) {
      final parsed = Uri.tryParse(savedUrl);
      if (parsed != null) {
        savedUrl = parsed
            .replace(
              userInfo:
                  '${Uri.encodeComponent(username.text)}:${Uri.encodeComponent(password.text)}',
            )
            .toString();
      }
    }
    label.dispose();
    address.dispose();
    username.dispose();
    password.dispose();
    if (accepted == true && mounted) {
      await run(() async {
        final record = await service.add(savedName, savedUrl);
        if (record.enabled) await service.refreshSites(record);
      });
    }
  }

  Future<void> configure(CatSubscription record) => run(() async {
    if (!record.enabled) {
      record.enabled = true;
      await service.save();
    }
    if (!await service.hasBundle(record)) await service.update(record);
    await service.refreshSites(record);
    final url = await service.configurationUrl(record);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => CatWebPage(url: url)),
    );
    await service.refreshSites(record);
  });

  Future<void> more(CatSubscription record, String action) => run(() async {
    if (action == 'pin') {
      final prefs = SourcePreferences.read(Section.cat, record.id);
      await prefs.copyWith(pinned: !prefs.pinned).save(Section.cat, record.id);
    }
    if (action == 'preferences' && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SourcePreferencesPage(
            section: Section.cat,
            sourceId: record.id,
            name: record.name,
            onNetwork: () => configure(record),
          ),
        ),
      );
    }
    if (action == 'update') {
      await service.update(record);
      if (record.enabled) await service.refreshSites(record);
    }
    if (action == 'auth') await add(name: record.name, url: record.url);
    if (action == 'automatic') {
      record.automatic = !record.automatic;
      await service.save();
    }
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: record.url));
    }
    if (action == 'remove') await service.remove(record);
    if (action == 'info' && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(record.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('订阅地址'),
                SelectableText(record.url),
                const SizedBox(height: 12),
                Text(
                  record.error.isEmpty
                      ? '订阅正常，${record.automatic ? '自动更新已开启' : '自动更新已关闭'}'
                      : record.error,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }
  });

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.cat,
    title: '猫源配置中心',
    actions: [
      IconButton(
        tooltip: '添加订阅',
        icon: const LumeIcon(Icons.add, slot: 'cat_subscription_page.1'),
        onPressed: working ? null : () => add(),
      ),
    ],
    child: ListenableBuilder(
      listenable: service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ValueListenableBuilder<int>(
            valueListenable: SourceSubscriptionSync.changeCount(Section.cat),
            builder: (_, count, _) => count == 0
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const LumeIcon(
                      Icons.notifications_active_outlined,
                      slot: 'cat_subscription_page.2',
                    ),
                    title: Text('猫源订阅已变动 $count 条'),
                    subtitle: Text(
                      SourceSubscriptionSync.notices(Section.cat)
                          .map(
                            (entry) => '${entry['name']} · ${entry['status']}',
                          )
                          .join('\n'),
                    ),
                    trailing: TextButton(
                      onPressed: () =>
                          SourceSubscriptionSync.changeCount(Section.cat)
                                  .value =
                              0,
                      child: const Text('知道了'),
                    ),
                  ),
          ),
          FilledButton.icon(
            icon: const LumeIcon(
              Icons.system_update_alt,
              slot: 'cat_subscription_page.3',
            ),
            label: const Text('一键更新全部订阅'),
            onPressed: working
                ? null
                : () async {
                    setState(() => working = true);
                    var failed = 0;
                    for (final record
                        in service.subscriptions
                            .where((record) => record.enabled)
                            .toList()) {
                      try {
                        await service.update(record);
                      } catch (_) {
                        failed++;
                      }
                    }
                    if (mounted) {
                      setState(() {
                        working = false;
                        error = failed == 0 ? null : '$failed 个订阅更新失败，已保留旧版本';
                      });
                    }
                  },
          ),
          TextField(
            onChanged: (value) => setState(() => sourceQuery = value),
            decoration: const InputDecoration(
              prefixIcon: LumeIcon(
                Icons.search,
                slot: 'cat_subscription_page.4',
              ),
              hintText: '搜索猫源订阅',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('只显示已启用'),
            value: enabledOnly,
            onChanged: (value) => setState(() => enabledOnly = value),
          ),

          if (working || service.busy) ...[
            const LinearProgressIndicator(),
            Text(service.status),
          ],
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          for (final record in visibleSubscriptions)
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SourceIcon(
                      name: record.name,
                      iconUrl: SourcePreferences.read(
                        Section.cat,
                        record.id,
                      ).iconUrl,
                      section: Section.cat,
                      sourceId: record.id,
                    ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SourceUpdateBadge(
                          section: Section.cat,
                          sourceId: record.id,
                        ),
                      ],
                    ),
                    subtitle: Text(
                      '${record.hash.isEmpty
                          ? (record.error.contains('401') ? '需要作者授权' : '未下载')
                          : record.sites.isEmpty
                          ? '站点尚未读取'
                          : '${record.sites.length} 个站点'} · ${record.enabled ? '已启用' : '已停用'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: record.enabled,
                          onChanged: working || service.busy
                              ? null
                              : (value) => run(() async {
                                  record.enabled = value;
                                  await service.save();
                                  if (value) {
                                    if (record.hash.isEmpty) {
                                      await service.update(record);
                                    }
                                    await service.refreshSites(record);
                                  }
                                }),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多',
                          enabled: !working && !service.busy,
                          onSelected: (action) => more(record, action),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'pin',
                              child: Text(
                                SourcePreferences.read(
                                      Section.cat,
                                      record.id,
                                    ).pinned
                                    ? '取消置顶'
                                    : '置顶此源',
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'preferences',
                              child: Text('源设置'),
                            ),

                            const PopupMenuItem(
                              value: 'update',
                              child: Text('立即更新'),
                            ),
                            CheckedPopupMenuItem(
                              value: 'automatic',
                              checked: record.automatic,
                              child: const Text('自动更新'),
                            ),
                            const PopupMenuItem(
                              value: 'auth',
                              child: Text('编辑地址 / 授权'),
                            ),
                            const PopupMenuItem(
                              value: 'info',
                              child: Text('订阅信息'),
                            ),
                            const PopupMenuItem(
                              value: 'copy',
                              child: Text('复制订阅链接'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('移除订阅'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (record.error.isNotEmpty)
                    Text(
                      record.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (record.error.contains('401'))
                    TextButton.icon(
                      onPressed: working
                          ? null
                          : () => add(name: record.name, url: record.url),
                      icon: const LumeIcon(
                        Icons.key_outlined,
                        slot: 'cat_subscription_page.5',
                      ),
                      label: const Text('填写作者提供的订阅授权'),
                    )
                  else if (record.hash.isEmpty || record.sites.isEmpty)
                    TextButton.icon(
                      onPressed: working || service.busy
                          ? null
                          : () => run(() async {
                              record.enabled = true;
                              await service.save();
                              await service.refreshSites(record);
                            }),
                      icon: const LumeIcon(
                        Icons.refresh,
                        slot: 'cat_subscription_page.6',
                      ),
                      label: Text(record.hash.isEmpty ? '下载并读取站点' : '重新读取站点'),
                    ),
                  TextButton.icon(
                    onPressed: working || service.busy
                        ? null
                        : () => configure(record),
                    icon: const LumeIcon(
                      Icons.cloud_outlined,
                      slot: 'cat_subscription_page.7',
                    ),
                    label: Text(record.enabled ? '网盘登录 · 站点配置' : '启用并打开配置'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          ExpansionTile(
            title: const Text('添加常用订阅'),
            initiallyExpanded: service.subscriptions.isEmpty,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final preset in catSubscriptionPresets.entries)
                    ActionChip(
                      label: Text(preset.key),
                      onPressed: working
                          ? null
                          : () => add(name: preset.key, url: preset.value),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
