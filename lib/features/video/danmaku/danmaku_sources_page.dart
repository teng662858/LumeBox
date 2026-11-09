import 'danmaku_panel.dart';
import '../player_settings_panel.dart';
import 'builtin_danmaku_service.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import 'dandanplay_client.dart';
import 'danmaku_connection_test.dart';

export 'danmaku_credentials.dart' show DanmakuSourcesStore;

class DanmakuSourcesPage extends StatefulWidget {
  const DanmakuSourcesPage({super.key, this.embedded = false});

  final bool embedded;
  @override
  State<DanmakuSourcesPage> createState() => _DanmakuSourcesPageState();
}

class _DanmakuSourcesPageState extends State<DanmakuSourcesPage> {
  List<Map<String, String>> _sources = [];
  String _active = '';
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    BuiltinDanmakuService.registerLicense();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await DanmakuSourcesStore.read();
      _sources = DanmakuSourcesStore.profiles(data);
      _active = data['activeId'] ?? '';
      // Preserve an already configured legacy endpoint as an editable profile.
      if (!data.containsKey('profilesJson') &&
          _sources.isEmpty &&
          (data['baseUrl'] ?? '').isNotEmpty) {
        _active = data['baseUrl'] == DandanplayCredentials.builtinBase
            ? 'builtin-local'
            : 'legacy';
        _sources = [
          {
            'id': _active,
            'name': '现有弹幕服务',
            'type': data['baseUrl'] == DandanplayCredentials.builtinBase
                ? 'builtin'
                : DandanplayCredentials.isOfficial(
                    Uri.tryParse(data['baseUrl']!),
                  )
                ? 'official'
                : 'logvar',
            'url': data['baseUrl']!,
            'appId': data['appId'] ?? '',
            'appSecret': data['appSecret'] ?? '',
          },
        ];
      }
    } catch (_) {
      _error = '弹幕源存储暂不可用，请在移动端重新打开。';
    }
    _sources = [
      {
        'id': 'builtin-local',
        'type': 'builtin',
        'name': '内置本机服务',
        'url': DandanplayCredentials.builtinBase,
      },
      ..._sources.where((s) => s['type'] != 'builtin'),
    ];
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _persist() async {
    try {
      await DanmakuSourcesStore.save(_sources, _active);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败，未能写入本机安全存储')));
      }
      rethrow;
    }
  }

  Future<void> _showBuiltin() => showPlayerContextSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '内置本机服务',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '无需填写地址。选择此服务后，手机直接联网查询各平台弹幕。首次启动可能稍慢，空闲两分钟自动停止，下次查询自动启动。连接成功不代表当前剧集一定有弹幕。',
            ),
            DanmakuConnectionTest(
              credentials: () => const DandanplayCredentials(
                '',
                '',
                baseUrl: DandanplayCredentials.builtinBase,
              ),
            ),
            TextButton(
              onPressed: () async {
                await BuiltinDanmakuService.instance.stop();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('停止本机服务'),
            ),
            TextButton(
              onPressed: () => showLicensePage(context: context),
              child: const Text('开源许可与组件说明'),
            ),
            const Text(
              '基于 YYDS678/danmu_api（AGPL-3.0），源码与手机适配补丁见 LumeBox 仓库 assets/local_danmaku。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _chooseType() async {
    final type = await showPlayerContextSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                '添加弹幕源',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final choice in const {
              'logvar': '自定义 danmu 服务（兼容弹弹play）',
              'official': '弹弹play 开放平台',
              'plugin': '本机弹幕插件（JS）',
            }.entries)
              ListTile(
                title: Text(choice.value),
                onTap: () => Navigator.pop(context, choice.key),
              ),
          ],
        ),
      ),
    );
    if (!mounted || type == null) return;
    if (type == 'plugin') {
      await showPlayerContextSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            Platform.isIOS
                ? '本机弹幕插件目前仅支持安卓。iPhone 可以使用兼容弹幕服务器与开放平台。'
                : '本机弹幕文件可以在播放页导入。第三方 JS 插件需要匹配其接口格式，不能把任意脚本当成弹幕源运行。',
          ),
        ),
      );
      return;
    }
    await _edit(type: type);
  }

  Future<void> _edit({String? type, Map<String, String>? existing}) async {
    final kind = type ?? existing?['type'] ?? 'logvar';
    final name = TextEditingController(text: existing?['name'] ?? '');
    final url = TextEditingController(
      text:
          existing?['url'] ??
          (kind == 'official' ? DandanplayCredentials.officialBase : ''),
    );
    final id = TextEditingController(text: existing?['appId'] ?? '');
    final secret = TextEditingController(text: existing?['appSecret'] ?? '');
    String? error;
    PageRoute<Map<String, String>>? route;
    try {
      route = MaterialPageRoute<Map<String, String>>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => PlayerSettingsScaffold(
            title: existing == null ? '添加弹幕服务' : '编辑弹幕服务',
            body: ListView(
              key: const ValueKey('danmaku-service-form'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  kind == 'official' ? '弹弹play 开放平台' : '兼容弹弹play服务',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称（可不填）'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                if (kind != 'official') ...[
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '服务地址（保留路径前缀）',
                    ),
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                ],
                if (kind == 'official') ...[
                  TextField(
                    controller: id,
                    decoration: const InputDecoration(labelText: 'AppId'),
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: secret,
                    decoration: const InputDecoration(labelText: 'AppSecret'),
                    obscureText: true,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  kind == 'official'
                      ? '填写审核通过的 AppId / AppSecret。凭据保存在本机安全存储中。'
                      : '填写兼容 /api/v2 的服务地址。地址路径中包含的访问 token 请完整保留。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                DanmakuConnectionTest(
                  credentials: () => DandanplayCredentials(
                    id.text.trim(),
                    secret.text.trim(),
                    baseUrl: url.text.trim(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('保存'),
                  onPressed: () {
                    final uri = Uri.tryParse(url.text.trim());
                    if (uri == null ||
                        !['http', 'https'].contains(uri.scheme) ||
                        uri.host.isEmpty ||
                        uri.hasQuery ||
                        uri.hasFragment ||
                        uri.userInfo.isNotEmpty) {
                      refresh(() => error = '请输入有效服务地址，保留路径，不附查询参数或用户名密码');
                      return;
                    }
                    if (kind == 'official' &&
                        (id.text.trim().isEmpty ||
                            secret.text.trim().isEmpty)) {
                      refresh(() => error = '请填写 AppId 与 AppSecret');
                      return;
                    }
                    Navigator.pop(context, {
                      'id':
                          existing?['id'] ??
                          'source-${DateTime.now().microsecondsSinceEpoch}',
                      'type': kind,
                      'name': name.text.trim().isEmpty
                          ? (kind == 'official' ? '弹弹play 开放平台' : uri.host)
                          : name.text.trim(),
                      'url': url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
                      'appId': id.text.trim(),
                      'appSecret': secret.text.trim(),
                    });
                  },
                ),
              ],
            ),
          ),
        ),
      );
      final result = await Navigator.of(context).push(route);
      if (result == null || !mounted) return;
      final previous = List<Map<String, String>>.of(_sources);
      final previousActive = _active;
      setState(() {
        _sources = [
          for (final s in _sources)
            if (s['id'] != result['id']) s,
          result,
        ];
        _active = result['id']!;
      });
      try {
        await _persist();
      } catch (_) {
        if (mounted) {
          setState(() {
            _sources = previous;
            _active = previousActive;
          });
        }
      }
    } finally {
      await route?.completed;
      name.dispose();
      url.dispose();
      id.dispose();
      secret.dispose();
    }
  }

  Future<void> _select(Map<String, String> source) async {
    final old = _active;
    setState(() => _active = source['id']!);
    try {
      await _persist();
    } catch (_) {
      if (mounted) setState(() => _active = old);
    }
  }

  Future<void> _remove(Map<String, String> source) async {
    final old = List<Map<String, String>>.of(_sources);
    final oldActive = _active;
    setState(() {
      _sources.remove(source);
      if (_active == source['id']) _active = _sources.firstOrNull?['id'] ?? '';
    });
    try {
      await _persist();
    } catch (_) {
      if (mounted) {
        setState(() {
          _sources = old;
          _active = oldActive;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PlayerSettingsScaffold(
    title: '弹幕源',
    embedded: widget.embedded,
    actions: [
      IconButton(
        tooltip: '添加弹幕源',
        onPressed: _chooseType,
        icon: const Icon(Icons.add_rounded, size: 23),
      ),
    ],
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(child: Text(_error!))
        : ListView(
            primary: widget.embedded ? false : null,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  '选择后立即保存，全局设置与播放页共用。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              PlayerSettingsSection(
                title: '可用服务 · ${_sources.length}',
                children: [
                  for (var i = 0; i < _sources.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 12, endIndent: 12),
                    Builder(
                      builder: (context) {
                        final source = _sources[i],
                            active = _active == source['id'];
                        final builtin = source['type'] == 'builtin';
                        return ListTile(
                          title: Text(
                            source['name'] ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            '${active ? '当前 · ' : ''}${builtin
                                ? '本机联网获取，无需地址'
                                : source['type'] == 'official'
                                ? '弹弹play 开放平台'
                                : '兼容弹弹play服务'}',
                            maxLines: 2,
                          ),
                          leading: IconButton(
                            tooltip: builtin ? '使用内置本机服务' : '设为当前弹幕源',
                            icon: Icon(
                              active
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              color: active
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              size: 22,
                            ),
                            onPressed: () => _select(source),
                          ),
                          onTap: () => _select(source),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: builtin ? '测试内置服务' : '编辑弹幕源',
                                onPressed: builtin
                                    ? _showBuiltin
                                    : () => _edit(existing: source),
                                icon: Icon(
                                  builtin
                                      ? Icons.settings_outlined
                                      : Icons.edit_outlined,
                                  size: 20,
                                ),
                              ),
                              if (!builtin)
                                IconButton(
                                  tooltip: '删除弹幕源',
                                  onPressed: () => _remove(source),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
              Text(
                '切换服务后，当前视频会自动重新加载弹幕。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
  );
}
