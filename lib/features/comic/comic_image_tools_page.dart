import 'package:lume_box/core/theme/lume_typography.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reading/comic_image_tools.dart';
import '../../shared/widgets/glass_card.dart';

class ComicImageToolsSettingsPage extends StatefulWidget {
  const ComicImageToolsSettingsPage({
    super.key,
    this.translation = false,
    this.pickModelFile,
  });
  final Future<XFile?> Function()? pickModelFile;
  static const modelFileTypes = [
    XTypeGroup(
      label: 'waifu2x CoreML',
      extensions: ['mlmodel'],
      // iOS cannot filter by extension alone. Imported data is SHA-256 checked below.
      uniformTypeIdentifiers: ['public.data'],
    ),
  ];
  final bool translation;
  @override
  State<ComicImageToolsSettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<ComicImageToolsSettingsPage> {
  final settings = ComicImageToolsSettings.instance;
  late final endpoint = TextEditingController(text: settings.endpoint);
  late final model = TextEditingController(text: settings.model);
  final keyInput = TextEditingController();
  bool busy = false;
  String? status;
  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    keyInput.dispose();
    super.dispose();
  }

  Future<void> save() async {
    try {
      await settings.save();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('配置保存失败，请重试')));
      }
    }
  }

  Future<void> manage(String method) async {
    setState(() => busy = true);
    try {
      await ComicImageTools.channel.invokeMethod<void>(method, {
        'noise': settings.noise,
        'imageStyle': settings.imageStyle,
      });
      if (mounted) {
        setState(
          () => status = method == 'clearModels' ? '已清理编译缓存，原始模型保留' : '模型已就绪',
        );
      }
    } catch (_) {
      if (mounted) setState(() => status = '设备端图片处理需要 iOS；模型准备失败时可重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> importModel() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '正在打开文件选择器…';
    });
    try {
      final picked =
          await (widget.pickModelFile?.call() ??
              openFile(
                acceptedTypeGroups: ComicImageToolsSettingsPage.modelFileTypes,
              ));
      if (!mounted) return;
      if (picked == null) {
        setState(() => status = '已取消选择模型');
        return;
      }
      setState(() => status = '正在校验并安装模型…');
      if (await picked.length() > 3 * 1024 * 1024) {
        throw const FormatException('模型文件过大');
      }
      final bytes = await picked.readAsBytes();
      final origin = jsonDecode(
        await rootBundle.loadString('assets/models/waifu2x/ORIGIN.json'),
      ) as Map<String, dynamic>;
      final hashes = origin['sha256'] as Map<String, dynamic>;
      final hash = sha256.convert(bytes).toString();
      final matches = hashes.entries.where((entry) => entry.value == hash);
      if (matches.isEmpty) throw const FormatException('不是受支持的官方 waifu2x 模型');
      await ComicImageTools.channel.invokeMethod<void>('importModel', {
        'name': matches.first.key,
        'bytes': bytes,
      });
      if (mounted) {
        setState(() => status = '已安装 ${matches.first.key}，请选择对应类型和降噪级别');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status = error is FormatException
              ? error.message
              : '无法打开文件选择器或安装模型，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget choice<T>(
    String title,
    T value,
    Map<T, String> options,
    ValueChanged<T> changed,
  ) => ListTile(
    title: Text(title),
    trailing: DropdownButton<T>(
      value: value,
      items: [
        for (final entry in options.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (v) {
        if (v != null) {
          setState(() => changed(v));
          save();
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.comic,
    title: widget.translation ? '漫画翻译' : 'AI 图片超分辨率',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: widget.translation
          ? [
              choice(
                '翻译为',
                settings.target,
                ComicImageToolsSettings.languages,
                (v) => settings.target = v,
              ),
              choice('原文语言', settings.source, {
                'auto': '自动识别',
                ...ComicImageToolsSettings.languages,
              }, (v) => settings.source = v),
              choice('翻译方式', settings.ai, {
                false: '设备端（免费）',
                true: '自填 AI 接口',
              }, (v) => settings.ai = v),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '设备端：iOS 18 及以上，首次使用按系统提示下载语言包。识别与翻译在设备上完成。\nAI：仅把识别出的文字发送到你填写的接口，费用由服务商决定。',
                ),
              ),
              if (settings.ai) ...[
                TextField(
                  controller: endpoint,
                  decoration: const InputDecoration(
                    labelText: '完整 Chat Completions HTTPS 地址',
                    hintText: 'https://…/v1/chat/completions',
                  ),
                ),
                TextField(
                  controller: model,
                  decoration: const InputDecoration(labelText: '模型名称'),
                ),
                TextField(
                  controller: keyInput,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'API Key（留空保留已保存的密钥）',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            ComicImageTools.validateEndpoint(endpoint.text);
                            if (model.text.trim().isEmpty) {
                              throw const FormatException('请填写模型名称');
                            }
                            if (keyInput.text.trim().isNotEmpty) {
                              await ComicImageTools.channel.invokeMethod<void>(
                                'setKey',
                                {'key': keyInput.text.trim()},
                              );
                            }
                            settings.endpoint = endpoint.text.trim();
                            settings.model = model.text.trim();
                            await settings.save();
                            keyInput.clear();
                            if (mounted) {
                              setState(
                                () => status = 'AI 配置已保存，密钥保存在系统钥匙串，不进入备份',
                              );
                            }
                          } catch (error) {
                            if (mounted) {
                              setState(
                                () => status = error is FormatException
                                    ? error.message
                                    : '保存失败，请检查设备支持与配置',
                              );
                            }
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: const Text('保存 AI 配置'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            await ComicImageTools.channel.invokeMethod<void>(
                              'setKey',
                              {'key': ''},
                            );
                            keyInput.clear();
                            if (mounted) setState(() => status = '已清除密钥');
                          } catch (_) {
                            if (mounted) setState(() => status = '清除失败，请重试');
                          }
                        },
                  child: const Text('清除已保存的密钥'),
                ),
              ],
              if (status != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(status!),
                ),
            ]
          : [
              SwitchListTile.adaptive(
                title: const Text('自动超分'),
                subtitle: const Text('漫画 / 美图源正文自动处理；失败保留原图，不改写下载文件'),
                value: settings.automatic,
                onChanged: (v) {
                  setState(() => settings.automatic = v);
                  save();
                },
              ),
              choice('图片宽度阈值', settings.threshold, {
                720: '< 720px',
                1080: '< 1080px',
                1440: '< 1440px',
                2160: '< 2160px',
              }, (v) => settings.threshold = v),
              const ListTile(
                title: Text('并发数量'),
                subtitle: Text('移动设备固定为 1，逐张处理，控制内存与发热'),
                trailing: Text('1'),
              ),
              choice('AI 超分模型类型', settings.imageStyle, {
                'anime': '漫画 / 动漫 · 2 倍',
                'photo': '美图 / 照片 · 2 倍',
              }, (v) => settings.imageStyle = v),
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('选择本地图片进行 AI 超分'),
                subtitle: const Text('支持漫画与美图；仅本机处理，可对比原图'),
                onTap: () async {
                  final file = await openFile(
                    acceptedTypeGroups: const [
                      XTypeGroup(
                        label: '图片',
                        extensions: ['png', 'jpg', 'jpeg', 'webp', 'heic'],
                        uniformTypeIdentifiers: ['public.image'],
                      ),
                    ],
                  );
                  if (file == null || !context.mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ComicImageToolsPage(loadOriginal: file.readAsBytes),
                    ),
                  );
                },
              ),
              choice('降噪级别', settings.noise, {
                0: '降噪 0',
                1: '降噪 1',
                2: '降噪 2',
                3: '降噪 3',
              }, (v) => settings.noise = v),
              const ListTile(
                title: Text('分块信息'),
                subtitle: Text('内容块 142 × 142，输入 156 × 156（每侧 7px 镜像边距）'),
              ),
              const ListTile(
                title: Text('模型管理'),
                subtitle: Text(
                  'waifu2x 一个 AI 模型系列，漫画和照片两种类型各含降噪 0–3，共 8 份模型；首次使用在设备上编译，无需上传图片',
                ),
              ),
              if (busy) const Center(child: CircularProgressIndicator()),
              FilledButton(
                onPressed: busy ? null : () => manage('prepareModel'),
                child: const Text('加载当前已安装模型'),
              ),
              TextButton.icon(
                key: const Key('import-super-resolution-model'),
                onPressed: busy ? null : importModel,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('从本地安装超分模型'),
              ),
              TextButton(
                onPressed: busy ? null : () => manage('clearModels'),
                child: const Text('清理模型编译缓存'),
              ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(status!),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '自动超分默认关闭。漫画版块源内图片按源选择分组使用漫画或照片模型，当前页也可手动超分；本地图片使用本页选择的模型类型。过大的长图会保留原图。',
                ),
              ),
            ],
    ),
  );
}

class ComicImageToolsPage extends StatefulWidget {
  const ComicImageToolsPage({
    super.key,
    required this.loadOriginal,
    this.imageStyle,
  });
  final String? imageStyle;
  final Future<Uint8List?> Function() loadOriginal;
  @override
  State<ComicImageToolsPage> createState() => _ImageToolsState();
}

class _ImageToolsState extends State<ComicImageToolsPage> {
  late final tools = ComicImageTools(imageStyle: widget.imageStyle);
  Uint8List? original, enhanced;
  List<ComicTextRegion> regions = [];
  double ratio = 1;
  bool busy = true, showOriginal = false;
  String? message;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final bytes = await widget.loadOriginal();
      if (bytes == null) throw StateError('原图加载失败');
      final descriptor = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final image = await ui.ImageDescriptor.encoded(descriptor);
        try {
          if (mounted) {
            setState(() {
              original = bytes;
              ratio = image.width / image.height;
            });
          }
        } finally {
          image.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => message = '原图加载失败，请返回后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> process(bool translate) async {
    final bytes = original;
    if (bytes == null || busy) return;
    final current = ++generation;
    setState(() {
      busy = true;
      message = translate ? '正在识别并翻译…' : '正在分块超分…';
    });
    try {
      if (translate) {
        final result = await tools.translate(bytes);
        if (mounted && current == generation) {
          setState(() {
            regions = result;
            enhanced = null;
            message = result.isEmpty
                ? '未识别到文字，可尝试切换原文语言'
                : '已翻译 ${result.length} 处文字，可切回原图对照';
          });
        }
      } else {
        final result = await tools.superResolve(bytes);
        if (mounted && current == generation) {
          setState(() {
            enhanced = result;
            regions = [];
            message = '超分完成，可切回原图对照';
          });
        }
      }
      if (mounted && current == generation) {
        setState(() => showOriginal = false);
      }
    } catch (error) {
      if (mounted && current == generation) {
        setState(
          () => message = error is FormatException
              ? error.message
              : error is PlatformException
              ? error.message ?? '处理失败，原图保留'
              : '处理失败，原图保留；请检查系统版本、语言包或 AI 配置',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    tools.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.comic,
    title: 'AI 图片超分与翻译',
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: busy || original == null ? null : () => process(false),
              child: const Text('AI 超分当前图片'),
            ),
            FilledButton(
              onPressed: busy || original == null ? null : () => process(true),
              child: const Text('翻译当前页'),
            ),
            IconButton(
              tooltip: '图片处理设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const ComicImageToolsSettingsPage(translation: true),
                ),
              ),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('显示原图'),
          value: showOriginal,
          onChanged: (v) => setState(() => showOriginal = v),
        ),
        if (busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
        Expanded(
          child: original == null
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: LayoutBuilder(
                        builder: (context, size) => Stack(
                          children: [
                            Positioned.fill(
                              child: Image.memory(
                                showOriginal
                                    ? original!
                                    : enhanced ?? original!,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                            ),
                            if (!showOriginal)
                              for (final region in regions.where(
                                (r) =>
                                    r.x < 1 &&
                                    r.y < 1 &&
                                    r.width > 0 &&
                                    r.height > 0,
                              ))
                                Positioned(
                                  left: region.x * size.maxWidth,
                                  top: region.y * size.maxHeight,
                                  width: (region.width * size.maxWidth).clamp(
                                    0,
                                    size.maxWidth * (1 - region.x),
                                  ),
                                  height: (region.height * size.maxHeight)
                                      .clamp(
                                        0,
                                        size.maxHeight * (1 - region.y),
                                      ),
                                  child: Tooltip(
                                    message:
                                        '${region.text}\n${region.translation}',
                                    child: ColoredBox(
                                      color: Colors.white,
                                      child: Padding(
                                        padding: const EdgeInsets.all(1),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            region.translation,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black,
                                              fontSize:
                                                  LumeTypography.titleSize,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}
