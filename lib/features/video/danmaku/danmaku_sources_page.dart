import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dandanplay_client.dart';

/// The collection and credentials share the existing native secure channel.
/// iOS uses Keychain, Android uses Keystore encryption in noBackupFilesDir.
class DanmakuSourcesStore {
  static const channel = MethodChannel('lumebox/reference_danmaku_credentials');
  static Future<Map<String, String>> read() async =>
      await channel.invokeMapMethod<String, String>('read') ?? {};
  static Future<void> save(
    List<Map<String, String>> sources,
    String active,
  ) async {
    final selected = sources.where((s) => s['id'] == active).firstOrNull;
    await channel.invokeMethod<void>('write', {
      'profilesJson': jsonEncode(sources),
      'activeId': active,
      'baseUrl': selected?['url'] ?? DandanplayCredentials.defaultBase,
      'appId': selected?['appId'] ?? '',
      'appSecret': selected?['appSecret'] ?? '',
    });
  }
}

class DanmakuSourcesPage extends StatefulWidget {
  const DanmakuSourcesPage({super.key});
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
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await DanmakuSourcesStore.read();
      final raw = jsonDecode(data['profilesJson'] ?? '[]');
      _sources = raw is List
          ? [
              for (final row in raw)
                if (row is Map)
                  {
                    for (final entry in row.entries)
                      if (entry.key is String && entry.value is String)
                        entry.key as String: entry.value as String,
                  },
            ]
          : [];
      _active = data['activeId'] ?? '';
      // Preserve an already configured legacy endpoint as an editable profile.
      if (_sources.isEmpty && (data['baseUrl'] ?? '').isNotEmpty) {
        _active = 'legacy';
        _sources = [
          {
            'id': _active,
            'name': '现有弹幕服务',
            'type': 'logvar',
            'url': data['baseUrl']!,
            'appId': data['appId'] ?? '',
            'appSecret': data['appSecret'] ?? '',
          },
        ];
      }
    } catch (_) {
      _error = '弹幕源存储暂不可用，请在移动端重新打开。';
    }
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

  Future<void> _chooseType() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '添加弹幕源',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final choice in const {
              'logvar': 'LogVar 弹幕服务器',
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
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            Platform.isIOS
                ? '参考播放器的本机弹幕插件目前仅支持安卓。iPhone 可以使用兼容弹幕服务器与开放平台。'
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
    bool saving = false;
    try {
      final result = await showModalBottomSheet<Map<String, String>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          kind == 'official' ? '弹弹play 开放平台' : '添加弹幕服务器',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const LumeIcon(
                          CupertinoIcons.xmark_circle_fill,
                          slot: 'danmaku_sources_page.1',
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称（可不填）'),
                  ),
                  if (kind != 'official')
                    TextField(
                      controller: url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '服务地址（保留路径前缀）',
                      ),
                      autocorrect: false,
                    ),
                  if (kind == 'official') ...[
                    TextField(
                      controller: id,
                      decoration: const InputDecoration(labelText: 'AppId'),
                      autocorrect: false,
                    ),
                    TextField(
                      controller: secret,
                      decoration: const InputDecoration(labelText: 'AppSecret'),
                      obscureText: true,
                      autocorrect: false,
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      kind == 'official'
                          ? '开放平台需要申请并审核通过的 AppId / AppSecret。凭据仅保存在本机安全存储中。'
                          : '使用兼容弹弹play /api/v2 接口的服务。若访问 token 位于地址路径中，请完整保留。',
                    ),
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  FilledButton(
                    onPressed: saving
                        ? null
                        : () async {
                            final uri = Uri.tryParse(url.text.trim());
                            if (uri == null ||
                                !['http', 'https'].contains(uri.scheme) ||
                                uri.host.isEmpty ||
                                uri.hasQuery ||
                                uri.hasFragment ||
                                uri.userInfo.isNotEmpty) {
                              refresh(
                                () => error = '请输入有效服务地址，保留路径，不附查询参数或用户名密码',
                              );
                              return;
                            }
                            if (kind == 'official' &&
                                (id.text.trim().isEmpty ||
                                    secret.text.trim().isEmpty)) {
                              refresh(() => error = '请填写 AppId 与 AppSecret');
                              return;
                            }
                            refresh(() => saving = true);
                            Navigator.pop(context, {
                              'id':
                                  existing?['id'] ??
                                  'source-${DateTime.now().microsecondsSinceEpoch}',
                              'type': kind,
                              'name': name.text.trim().isEmpty
                                  ? (kind == 'official'
                                        ? '弹弹play 开放平台'
                                        : uri.host)
                                  : name.text.trim(),
                              'url': url.text.trim().replaceFirst(
                                RegExp(r'/+$'),
                                '',
                              ),
                              'appId': id.text.trim(),
                              'appSecret': secret.text.trim(),
                            });
                          },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
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
      name.dispose();
      url.dispose();
      id.dispose();
      secret.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF171719)
        : const Color(0xFFF0F2ED),
    appBar: AppBar(
      title: const Text('弹幕源'),
      backgroundColor: Colors.transparent,
      actions: [
        IconButton(
          tooltip: '添加弹幕源',
          onPressed: _chooseType,
          icon: const LumeIcon(
            CupertinoIcons.add,
            slot: 'danmaku_sources_page.2',
          ),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(child: Text(_error!))
        : _sources.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LumeIcon(
                    CupertinoIcons.chat_bubble_text,
                    slot: 'danmaku_sources_page.3',
                    size: 46,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '还没有弹幕源',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text('可以填写兼容服务器地址，或配置弹弹play开放平台。播放页也保留源弹幕与本地弹幕入口。'),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _chooseType,
                    child: const Text('添加弹幕源'),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final source in _sources)
                Card(
                  child: ListTile(
                    title: Text(source['name'] ?? ''),
                    subtitle: Text(
                      source['type'] == 'official'
                          ? '弹弹play 开放平台'
                          : 'LogVar / 弹弹play兼容服务',
                    ),
                    leading: IconButton(
                      tooltip: '设为当前弹幕源',
                      icon: LumeIcon(
                        _active == source['id']
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        slot: 'danmaku_sources_page.4',
                        variant: true,
                      ),
                      onPressed: () async {
                        final old = _active;
                        setState(() => _active = source['id']!);
                        try {
                          await _persist();
                        } catch (_) {
                          if (mounted) setState(() => _active = old);
                        }
                      },
                    ),
                    onTap: () => _edit(existing: source),
                    trailing: IconButton(
                      tooltip: '删除弹幕源',
                      icon: const LumeIcon(
                        CupertinoIcons.trash,
                        slot: 'danmaku_sources_page.5',
                      ),
                      onPressed: () async {
                        final old = List<Map<String, String>>.of(_sources);
                        final oldActive = _active;
                        setState(() {
                          _sources.remove(source);
                          if (_active == source['id']) {
                            _active = _sources.firstOrNull?['id'] ?? '';
                          }
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
                      },
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('勾选的服务供新打开的视频使用。长地址和凭据不展示在列表中。'),
              ),
            ],
          ),
  );
}
