// Run only as an explicit Android preview target. Production platform gates stay unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:lume_box/core/js/tvbox_source_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/tvbox_config.dart';
import 'package:lume_box/features/source/tvbox_import_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: TvBoxPreview()),
  );
}

class PreviewManager extends ChangeNotifier implements SourceManager {
  final scripts = <String, String>{};
  @override
  bool get runtimeAvailable => true;
  @override
  Future<List<SourceDescriptor>> list() async => [
    for (final script in scripts.values)
      if (TvBoxEntry.fromScript(script) case final entry?)
        SourceDescriptor(
          id: entry.id,
          name: entry.name,
          version: '1.0.0',
          enabled: true,
        ),
  ];
  @override
  Future<SourceImportResult> importScript(
    String script, {
    String originUrl = '',
  }) async {
    final entry = TvBoxEntry.fromScript(script);
    if (entry == null) {
      return const SourceImportResult.failure('预览仅接收 TVBox 配置条目');
    }
    if (entry.kind == TvBoxKind.python) {
      return const SourceImportResult.failure(
        'Android 预览未内置 CPython，请在 iPhone 版本验证此 Python 源',
      );
    }
    final engine = TvBoxSourceEngine(LumeHttp());
    final loaded = await engine.loadScript(script);
    engine.dispose();
    if (!loaded) return const SourceImportResult.failure('源描述无法加载');
    scripts[entry.id] = script;
    final root = await getApplicationSupportDirectory();
    await File('${root.path}/tvbox_preview_sources.json')
        .writeAsString(jsonEncode(scripts));
    notifyListeners();
    return SourceImportResult.success(
      SourceDescriptor(
        id: entry.id,
        name: entry.name,
        version: '1.0.0',
        enabled: true,
      ),
    );
  }

  Future<void> restore() async {
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/tvbox_preview_sources.json',
    );
    if (await file.exists()) {
      scripts.addAll(
        Map<String, String>.from(jsonDecode(await file.readAsString()) as Map),
      );
    }
    notifyListeners();
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('预览入口只提供聚合导入和实际接口浏览');
}

class TvBoxPreview extends StatefulWidget {
  const TvBoxPreview({super.key});
  @override
  State<TvBoxPreview> createState() => _TvBoxPreviewState();
}

class _TvBoxPreviewState extends State<TvBoxPreview> {
  final manager = PreviewManager();
  var index = 0;
  @override
  void initState() {
    super.initState();
    manager.addListener(_changed);
    manager.restore();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(
          child: IndexedStack(
            index: index,
            children: [
              TvBoxImportPage(manager: manager),
              Scaffold(
                appBar: AppBar(title: Text('已导入源 ${manager.scripts.length}')),
                body: ListView(
                  children: [
                    for (final entry in manager.scripts.entries)
                      ListTile(
                        title: Text(TvBoxEntry.fromScript(entry.value)!.name),
                        subtitle: Text(TvBoxEntry.fromScript(entry.value)!.api),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => PreviewBrowse(script: entry.value),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
    bottomNavigationBar: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            '真实采集/直播接口 · Python 运行需 iOS',
            style: TextStyle(fontSize: 12),
          ),
        ),
        NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (value) => setState(() => index = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.playlist_add),
              label: '聚合导入',
            ),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              label: '浏览已导入源',
            ),
          ],
        ),
      ],
    ),
  );
}

class PreviewBrowse extends StatefulWidget {
  const PreviewBrowse({super.key, required this.script});
  final String script;
  @override
  State<PreviewBrowse> createState() => _PreviewBrowseState();
}

class _PreviewBrowseState extends State<PreviewBrowse> {
  late final engine = TvBoxSourceEngine(LumeHttp());
  final search = TextEditingController();
  List<Map> categories = [], items = [];
  String? category;
  String error = '';
  bool busy = true, more = false;
  int page = 1;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Object?> call(String method, [Map? args]) async {
    final result = await engine.callResult(method, args);
    if (!result.isOk) throw FormatException(result.error!.message);
    return result.value;
  }

  Future<void> _load() async {
    try {
      await engine.loadScript(widget.script);
      categories = ((await call('categories')) as List).cast<Map>();
      category = '';
      await _list();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> _list({int next = 1}) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await call('list', {
        'categoryId': category,
        'keyword': search.text,
        'page': next,
      }) as Map;
      if (mounted) {
        setState(() {
          items = (result['items'] as List).cast<Map>();
          more = result['hasMore'] == true;
          page = next;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    engine.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(TvBoxEntry.fromScript(widget.script)!.name)),
    body: Column(
      children: [
        if (categories.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<String>(
              isExpanded: true,
              value: category,
              items: [
                const DropdownMenuItem(value: '', child: Text('全部内容')),
                for (final row in categories)
                  DropdownMenuItem(
                    value: '${row['id']}',
                    child: Text('${row['title']}'),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      category = value;
                      _list();
                    },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              labelText: '搜索片名或频道',
              suffixIcon: Icon(Icons.search),
            ),
            onSubmitted: (_) => _list(),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error),
          ),
        if (!busy && error.isEmpty && items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('此分类暂无内容，可切换分类或搜索'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final row = items[i];
              return ListTile(
                leading: '${row['cover'] ?? ''}'.isEmpty
                    ? const Icon(Icons.movie_outlined)
                    : Image.network(
                        '${row['cover']}',
                        width: 48,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, e, s) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                title: Text('${row['title']}'),
                subtitle: Text('${row['description'] ?? ''}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PreviewDetail(
                      script: widget.script,
                      id: '${row['id']}',
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: busy || page <= 1 ? null : () => _list(next: page - 1),
              child: const Text('上一页'),
            ),
            Text('第 $page 页'),
            TextButton(
              onPressed: busy || !more ? null : () => _list(next: page + 1),
              child: const Text('下一页'),
            ),
          ],
        ),
      ],
    ),
  );
}

class PreviewDetail extends StatefulWidget {
  const PreviewDetail({super.key, required this.script, required this.id});
  final String script, id;
  @override
  State<PreviewDetail> createState() => _PreviewDetailState();
}

class _PreviewDetailState extends State<PreviewDetail> {
  late final engine = TvBoxSourceEngine(LumeHttp());
  VideoPlayerController? player;
  List<Map> chapters = [];
  String title = '', error = '';
  bool busy = true;
  Future<Object?> call(String method, Map args) async {
    final result = await engine.callResult(method, args);
    if (!result.isOk) throw FormatException(result.error!.message);
    return result.value;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await engine.loadScript(widget.script);
      final detail = await call('detail', {'id': widget.id}) as Map?;
      chapters = (await call('chapters', {'id': widget.id}) as List)
          .cast<Map>();
      title = '${detail?['title'] ?? ''}';
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _play(String chapter) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final content =
          await call('content', {'id': widget.id, 'chapterId': chapter}) as Map;
      if (content['kind'] != 'video') {
        throw FormatException('此线路需要网页播放器，请在 iOS 正式入口使用。\n${content['url']}');
      }
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('${content['url']}'),
        httpHeaders: (content['headers'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', '$v'),
        ),
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await player?.dispose();
      player = controller;
      await controller.play();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    engine.dispose();
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title.isEmpty ? '详情与线路' : title)),
    body: ListView(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error),
          ),
        if (player case final controller?) ...[
          AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          TextButton(
            onPressed: () => setState(() {
              controller.value.isPlaying
                  ? controller.pause()
                  : controller.play();
            }),
            child: const Text('播放 / 暂停'),
          ),
        ],
        for (final chapter in chapters)
          ListTile(
            title: Text('${chapter['title']}'),
            trailing: const Icon(Icons.play_circle_outline),
            onTap: busy ? null : () => _play('${chapter['id']}'),
          ),
      ],
    ),
  );
}
