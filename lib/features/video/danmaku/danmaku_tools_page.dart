import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/glass_card.dart';
import '../player_settings_panel.dart';
import 'dandanplay_client.dart';

class DanmakuToolsPage extends StatefulWidget {
  const DanmakuToolsPage({
    super.key,
    required this.title,
    required this.onLoad,
    required this.onAlignment,
    required this.offset,
    required this.scale,
    required this.sourceDuration,
    required this.videoDuration,
  });
  final String title;
  final Future<double> Function({String? id, Uri? url}) onLoad;
  final void Function(double offset, bool scale) onAlignment;
  final double offset, sourceDuration, videoDuration;
  final bool scale;
  @override
  State<DanmakuToolsPage> createState() => _State();
}

class _State extends State<DanmakuToolsPage> {
  late final name = TextEditingController(text: widget.title);
  final url = TextEditingController();
  late final offset = TextEditingController(
    text: widget.offset.toStringAsFixed(1),
  );
  late bool scale = widget.scale;
  late double sourceDuration = widget.sourceDuration;
  DandanplayClient? client;
  DandanplayCredentials? credentials;
  Map<String, dynamic>? favorites;
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    try {
      final config = await DandanplayCredentials.load();
      if (!mounted) return;
      credentials = config;
      client = DandanplayClient(credentials: config);
      if (!config.official) await refreshFavorites();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => message = DandanplayClient.describeError(e));
    }
  }

  Future<void> refreshFavorites() async {
    favorites = await client!.favorites();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
      if (mounted) setState(() => message ??= '操作完成');
    } catch (e) {
      if (mounted) setState(() => message = DandanplayClient.describeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> configureLocal() async {
    final settings = await client!.localSettings();
    if (!mounted) return;
    const fields = {
      'AI_BASE_URL': 'AI 接口地址',
      'AI_MODEL': 'AI 模型',
      'AI_API_KEY': 'AI 密钥（留空保留已有密钥）',
      'TITLE_MAPPING_TABLE_URL': '远程标题映射 URL',
      'AUTO_MATCH_MAPPING_TABLE_URL': '远程季集映射 URL',
    };
    final inputs = {
      for (final key in fields.keys)
        key: TextEditingController(text: '${settings[key] ?? ''}'),
    };
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('本机 AI 与远程映射'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('AI 请求会发送作品名称到所配置的模型服务，可能产生费用。'),
                  for (final field in fields.entries)
                    TextField(
                      controller: inputs[field.key],
                      obscureText: field.key == 'AI_API_KEY',
                      decoration: InputDecoration(labelText: field.value),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (save == true) {
        await client!.localSettings({
          for (final entry in inputs.entries)
            if (entry.key != 'AI_API_KEY' || entry.value.text.trim().isNotEmpty)
              entry.key: entry.value.text.trim(),
        });
      }
    } finally {
      for (final input in inputs.values) {
        input.dispose();
      }
    }
  }

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    offset.dispose();
    client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = credentials;
    final supported = config != null && !config.official;
    return PlayerSettingsScaffold(
      title: '弹幕匹配与对齐',
      body: SettingsSurfaceList(
        children: [
          if (message != null) Text(message!),
          if (busy) const LinearProgressIndicator(),
          if (config == null) const Text('正在读取服务配置…'),
          if (config?.official == true)
            const Text('当前为官方服务，兼容服务器的链接、收藏与服务端 AI 接口不可用。'),
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: '作品／文件名',
              helperText: '可填写 剧名 S01E02，季集映射由服务器处理',
            ),
          ),
          FilledButton(
            onPressed: !supported || busy
                ? null
                : () => run(() async {
                    final match = await client!.match(name.text.trim());
                    if (match == null) {
                      message = '服务器未匹配到本集，请使用手动匹配';
                      return;
                    }
                    sourceDuration = await widget.onLoad(id: match.id);
                    message = '已匹配：${match.title} · ${match.episode}';
                  }),
            child: const Text('服务端自动匹配（含已配置的 AI 与映射）'),
          ),
          TextField(
            controller: url,
            decoration: const InputDecoration(
              labelText: '平台原始视频链接',
              helperText: '使用平台播放页链接，不是播放器的 m3u8 地址',
            ),
          ),
          FilledButton(
            onPressed: !supported || busy
                ? null
                : () => run(() async {
                    sourceDuration = await widget.onLoad(
                      url: Uri.parse(url.text.trim()),
                    );
                  }),
            child: const Text('从视频链接加载弹幕'),
          ),
          Text(
            '弹幕源时长：${sourceDuration > 0 ? '${sourceDuration.toStringAsFixed(1)} 秒' : '未知'}；视频时长：${widget.videoDuration.toStringAsFixed(1)} 秒',
          ),
          TextField(
            controller: offset,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: '本作品偏移（秒）',
              helperText: '正数延后，负数提前；保存后回播放画面预览',
            ),
          ),
          SwitchListTile(
            title: const Text('按两侧时长缩放弹幕时间'),
            subtitle: const Text('仅手动开启；片头删减不同的版本可能不适用'),
            value: scale,
            onChanged: sourceDuration > 0 && widget.videoDuration > 0
                ? (v) => setState(() => scale = v)
                : null,
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    final value = double.tryParse(offset.text);
                    if (value == null ||
                        !value.isFinite ||
                        value.abs() > 3600) {
                      setState(() => message = '偏移须为 -3600 至 3600 秒');
                      return;
                    }
                    widget.onAlignment(value, scale);
                    setState(() => message = '已保存本作品对齐设置，可返回播放画面预览');
                  },
            child: const Text('保存作品对齐设置'),
          ),
          if (supported) ...[
            const Text('服务器收藏'),
            if (favorites?['favoriteSupported'] != true)
              const Text('此服务未确认支持持久化收藏；Cloudflare 通常需配置 Redis。'),
            FilledButton(
              onPressed: busy || favorites?['favoriteSupported'] != true
                  ? null
                  : () => run(() async {
                      await client!.updateFavorite('add', name.text.trim());
                      await refreshFavorites();
                    }),
              child: const Text('收藏当前搜索作品'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => run(refreshFavorites),
              child: const Text('刷新收藏列表'),
            ),
            for (final raw in (favorites?['favorites'] as List? ?? const []))
              if (raw is Map)
                ListTile(
                  title: Text('${raw['keyword'] ?? raw['title'] ?? ''}'),
                  onTap: () => setState(
                    () => name.text = '${raw['keyword'] ?? raw['title'] ?? ''}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '重新搜索并更新收藏',
                        icon: const Icon(Icons.refresh),
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await client!.updateFavorite(
                                  'refresh',
                                  '${raw['keyword']}',
                                );
                                await refreshFavorites();
                              }),
                      ),
                      IconButton(
                        tooltip: '删除服务器收藏',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await client!.updateFavorite(
                                  'remove',
                                  '${raw['keyword']}',
                                );
                                await refreshFavorites();
                              }),
                      ),
                    ],
                  ),
                ),
            if (config.builtin)
              ListTile(
                title: const Text('配置本机 AI 与远程季集映射'),
                trailing: const Icon(Icons.settings),
                onTap: busy ? null : () => run(configureLocal),
              ),
            if (!config.builtin)
              ListTile(
                title: const Text('打开服务管理：AI、远程季集映射'),
                subtitle: const Text('在服务端配置模型和映射订阅；管理操作需要管理员令牌'),
                onTap: () => run(() async {
                  final opened = await const MethodChannel(
                    'lumebox/source_web',
                  ).invokeMethod<bool>('openExternal', {'url': config.baseUrl});
                  if (opened != true) {
                    throw StateError('无法打开服务管理页面');
                  }
                }),
              ),
          ],
        ],
      ),
    );
  }
}
