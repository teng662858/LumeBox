import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';
import '../../shared/widgets/glass_card.dart';

class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({super.key});
  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  final settings = TmdbSettings.instance;
  late final keyText = TextEditingController(text: settings.apiKey);
  late final api = TextEditingController(text: settings.apiProxy);
  late final image = TextEditingController(text: settings.imageProxy);
  bool testing = false;
  void save() {
    settings.apiKey = keyText.text;
    settings.apiProxy = api.text;
    settings.imageProxy = image.text;
    settings.save();
  }

  @override
  void dispose() {
    keyText.dispose();
    api.dispose();
    image.dispose();
    super.dispose();
  }

  Future<void> test(bool isApi) async {
    save();
    setState(() => testing = true);
    final client = TmdbClient(settings);
    var message = '测试成功';
    try {
      if (isApi) {
        await client.testApi();
      } else {
        final bytes = await client.testImage();
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        codec.dispose();
      }
    } catch (_) {
      message = '测试失败：请检查启用状态、Key、代理地址和网络连接。';
    } finally {
      client.dispose();
      if (mounted) setState(() => testing = false);
    }
    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(isApi ? '测试 API 代理' : '测试 图片代理'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> disconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('清除本机保存的 API Key 和两个代理地址，并关闭 TMDB？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await settings.disconnect();
    keyText.clear();
    api.clear();
    image.clear();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: 'TMDB配置',
    child: ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile.adaptive(
            title: const Text('启用 TMDB'),
            value: settings.enabled,
            onChanged: (value) {
              settings.enabled = value;
              save();
            },
          ),
          const SizedBox(height: 16),
          const Text('海报展示样式'),
          const SizedBox(height: 10),
          SegmentedButton<TmdbPosterStyle>(
            segments: const [
              ButtonSegment(value: TmdbPosterStyle.fixed, label: Text('固定')),
              ButtonSegment(value: TmdbPosterStyle.random, label: Text('随机')),
              ButtonSegment(value: TmdbPosterStyle.carousel, label: Text('轮播')),
            ],
            selected: {settings.posterStyle},
            onSelectionChanged: (values) {
              settings.posterStyle = values.first;
              save();
            },
          ),
          const SizedBox(height: 24),
          Text('图片', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final kind in TmdbImageKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                key: ValueKey('tmdb-image-${kind.name}'),
                initialValue: settings.imageSize(kind),
                decoration: InputDecoration(labelText: kind.label),
                items: [
                  for (final size in kind.sizes)
                    DropdownMenuItem(value: size, child: Text(size)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  settings.setImageSize(kind, value);
                  save();
                },
              ),
            ),
          const Text('仅调整下载图片的文件大小，不改变图片在页面中的显示方式。'),
          const SizedBox(height: 24),
          TextField(
            controller: keyText,
            maxLines: 1,
            autocorrect: false,
            onChanged: (_) => save(),
            decoration: InputDecoration(
              labelText: 'API Key',
              suffixIcon: IconButton(
                tooltip: '清除 API Key',
                icon: const Icon(Icons.cancel),
                onPressed: () {
                  keyText.clear();
                  save();
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: api,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              labelText: 'API代理地址',
              hintText: '例如 shturl.cc/yyIaR0vTjCGrkbxM，留空使用官方地址',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: image,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              labelText: '图片代理地址',
              hintText: '例如 https://image.tmdb.org/t/p/，留空使用官方图片地址',
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.configured
                      ? null
                      : () => test(true),
                  child: const Text('测试 API 代理'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.enabled
                      ? null
                      : () => test(false),
                  child: const Text('测试 图片代理'),
                ),
              ),
            ],
          ),
          if (testing) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          const Text('配置仅保存在本机。请求时使用所配置的 TMDB／代理服务；不会上传至项目服务器。关闭 TMDB 后不发起请求。'),
          const SizedBox(height: 20),
          TextButton(
            onPressed: testing ? null : disconnect,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('断开连接'),
          ),
        ],
      ),
    ),
  );
}
