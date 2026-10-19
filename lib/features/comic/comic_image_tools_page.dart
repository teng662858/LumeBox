import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:lume_box/core/theme/lume_typography.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reading/comic_image_tools.dart';
import '../../shared/widgets/glass_card.dart';
import '../settings/settings_ui.dart';

/// 把手动处理结果交给系统保存 / 分享。
///
/// iOS 走已有的 configuration 通道（系统分享单，可存照片或文件）；其它平台
/// 用文件保存对话框。超分/上色结果都是 PNG。
Future<bool> exportProcessedImage(Uint8List bytes, String name) async {
  if (!Platform.isIOS) {
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await XFile.fromData(
      bytes,
      mimeType: 'image/png',
      name: name,
    ).saveTo(location.path);
    return true;
  }
  return await const MethodChannel('lumebox/configuration')
          .invokeMethod<bool>('share', {'bytes': bytes, 'name': name}) ??
      false;
}

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
  late final colorizeEndpoint = TextEditingController(
    text: settings.colorizeEndpoint,
  );
  late final colorizeModel = TextEditingController(
    text: settings.colorizeModel,
  );
  late final colorizePrompt = TextEditingController(
    text: settings.colorizePrompt,
  );
  final keyInput = TextEditingController();
  bool busy = false;
  String? status;
  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    colorizeEndpoint.dispose();
    colorizeModel.dispose();
    colorizePrompt.dispose();
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

  Future<void> installBundled() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '正在安装内置模型 0/${ComicImageTools.bundledModelNames.length}…';
    });
    final tools = ComicImageTools();
    try {
      await tools.installBundledModels(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => status = '正在安装内置模型 $done/$total…');
        },
      );
      if (mounted) {
        setState(
          () => status =
              '内置模型已安装完成（${ComicImageTools.bundledModelNames.length}/'
              '${ComicImageTools.bundledModelNames.length}），首次使用会自动编译',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status =
              '内置模型安装失败：$error\n'
              '设备端超分目前仅支持 iOS；也可以继续用「从本地安装超分模型」。',
        );
      }
    } finally {
      tools.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveColorize() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      ComicImageTools.validateEndpoint(colorizeEndpoint.text);
      if (colorizeModel.text.trim().isEmpty) {
        throw const FormatException('请填写上色模型');
      }
      if (keyInput.text.trim().isNotEmpty) {
        await ComicImageTools.channel.invokeMethod<void>('setKey', {
          'key': keyInput.text.trim(),
        });
      }
      settings.colorizeEndpoint = colorizeEndpoint.text.trim();
      settings.colorizeModel = colorizeModel.text.trim();
      settings.colorizePrompt = colorizePrompt.text.trim().isEmpty
          ? ComicImageToolsSettings.defaultColorizePrompt
          : colorizePrompt.text.trim();
      await settings.save();
      keyInput.clear();
      if (mounted) {
        setState(() => status = '上色配置已保存；图片会上传到该接口，费用由服务商决定');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status = error is FormatException
              ? error.message
              : '上色配置保存失败：$error',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
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
    title: widget.translation ? '漫画翻译' : 'AI 图片超分与上色',
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
              choice('并发数量', settings.concurrency, {
                1: '1（推荐）',
                2: '2',
                3: '3',
                4: '4',
              }, (v) => settings.concurrency = v),
              const SettingsFooterNote(
                '1 最稳；2–4 只建议在高性能设备使用，会增加内存与发热。',
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              ),
              choice('AI 超分模型类型', settings.imageStyle, {
                'anime': '漫画 / 动漫 · 2 倍',
                'photo': '美图 / 照片 · 2 倍',
              }, (v) => settings.imageStyle = v),
              ListTile(
                leading: const LumeIcon(
                  Icons.auto_awesome,
                  slot: 'comic_image_tools_page.1',
                ),
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
              const Divider(height: 24),
              const ListTile(
                title: Text('自动超分的额外范围'),
                subtitle: Text('以下开关只在「自动超分」开启时生效；阅读器正文始终处理'),
              ),
              SwitchListTile.adaptive(
                title: const Text('漫画 / 猫源封面'),
                subtitle: const Text('书架、探索、详情页与历史记录的封面'),
                value: settings.upscaleCovers,
                onChanged: (v) {
                  setState(() => settings.upscaleCovers = v);
                  save();
                },
              ),
              SwitchListTile.adaptive(
                title: const Text('视频海报'),
                subtitle: const Text('视频书架、详情页与搜索结果的海报'),
                value: settings.upscaleVideoPosters,
                onChanged: (v) {
                  setState(() => settings.upscaleVideoPosters = v);
                  save();
                },
              ),
              SwitchListTile.adaptive(
                title: const Text('小说封面 / 插图'),
                subtitle: const Text('小说书架与详情页封面；小说阅读器目前是纯文本排版，没有正文插图'),
                value: settings.upscaleNovelIllustrations,
                onChanged: (v) {
                  setState(() => settings.upscaleNovelIllustrations = v);
                  save();
                },
              ),
              const SettingsFooterNote(
                '以上范围使用上面选择的模型类型与降噪级别。封面 / 海报数量多，'
                '开启后首次加载会更慢、更热；原图、下载文件与磁盘缓存不会被改写。',
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              ),
              const Divider(height: 24),
              const ListTile(
                title: Text('模型管理'),
                subtitle: Text(
                  '内置 waifu2x：漫画 / 照片两种类型 × 降噪 0–3，共 8 份模型，随 App 提供，无需联网下载。',
                ),
              ),
              if (busy) const Center(child: CircularProgressIndicator()),
              FilledButton.icon(
                onPressed: busy ? null : installBundled,
                icon: const LumeIcon(
                  Icons.download_done,
                  slot: 'comic_image_tools_page.2',
                ),
                label: const Text('安装内置模型（8 个）'),
              ),
              const SettingsFooterNote(
                '首次安装会在设备上编译，约再占一份同量级缓存；安装后即可离线超分。',
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => manage('prepareModel'),
                icon: const LumeIcon(
                  Icons.play_circle_outline,
                  slot: 'comic_image_tools_page.3',
                ),
                label: const Text('加载当前已安装模型'),
              ),
              TextButton.icon(
                key: const Key('import-super-resolution-model'),
                onPressed: busy ? null : importModel,
                icon: const LumeIcon(
                  Icons.file_open_outlined,
                  slot: 'comic_image_tools_page.4',
                ),
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
              const Divider(height: 32),
              ListTile(
                title: const Text('AI 上色（实验性 · 云端）'),
                subtitle: const Text(
                  '仓库没有内置设备端上色模型；这里使用你自填的 OpenAI 兼容图片编辑接口（需返回 b64_json）。'
                  '图片会上传到该服务，费用由服务商决定。',
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: colorizeEndpoint,
                      decoration: const InputDecoration(
                        labelText: '图片编辑接口（HTTPS）',
                        hintText: 'https://…/v1/images/edits',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: colorizeModel,
                      decoration: const InputDecoration(
                        labelText: '上色模型',
                        hintText: '例如 gpt-image-1',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: colorizePrompt,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: '上色提示词'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: keyInput,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'API Key（与 AI 翻译共用，留空保留）',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy ? null : saveColorize,
                      child: const Text('保存上色配置'),
                    ),
                  ],
                ),
              ),
              const SettingsFooterNote(
                '自动超分默认关闭。漫画版块源内图片按源选择分组使用漫画或照片模型；'
                '封面 / 视频海报 / 小说封面是否处理由上面的三个范围开关控制。'
                '手动超分与上色结果可以保存 / 分享，原图与下载文件不会被覆盖。',
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
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
    this.allowApply = false,
  });
  final String? imageStyle;
  final Future<Uint8List?> Function() loadOriginal;

  /// 阅读器入口为 true：允许把结果「应用到当前页（仅本次阅读）」。
  final bool allowApply;
  @override
  State<ComicImageToolsPage> createState() => _ImageToolsState();
}

class _ImageToolsState extends State<ComicImageToolsPage> {
  late final tools = ComicImageTools(imageStyle: widget.imageStyle);
  Uint8List? original, enhanced, colorized;
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
            colorized = null;
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
            colorized = null;
            regions = [];
            message = '超分完成，可切回原图对照或保存结果';
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

  Future<void> processColorize() async {
    final bytes = original;
    if (bytes == null || busy) return;
    if (tools.preferences.colorizeEndpoint.trim().isEmpty ||
        tools.preferences.colorizeModel.trim().isEmpty) {
      setState(() => message = '请先在设置 → AI 图片超分与上色里配置 AI 上色接口与模型');
      return;
    }
    final current = ++generation;
    setState(() {
      busy = true;
      message = '正在上传并上色…';
    });
    try {
      final result = await tools.colorize(bytes);
      if (mounted && current == generation) {
        setState(() {
          colorized = result;
          enhanced = null;
          regions = [];
          message = '上色完成，可切回原图对照或保存结果';
        });
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
              ? error.message ?? '上色失败，原图保留'
              : '上色失败，原图保留；请检查接口、模型与网络',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> exportResult() async {
    final bytes = colorized ?? enhanced;
    if (bytes == null || busy) return;
    setState(() => busy = true);
    try {
      final name =
          'LumeBox-${colorized != null ? 'color' : 'ai2x'}-'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      final ok = await exportProcessedImage(bytes, name);
      if (mounted) {
        setState(() => message = ok ? '已保存 / 分享 $name' : '已取消保存');
      }
    } catch (error) {
      if (mounted) setState(() => message = '保存失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
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
    title: 'AI 图片超分 · 上色 · 翻译',
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: busy || original == null ? null : () => process(false),
              child: const Text('AI 超分当前图片'),
            ),
            FilledButton.tonal(
              onPressed: busy || original == null ? null : processColorize,
              child: const Text('AI 上色当前图片'),
            ),
            OutlinedButton.icon(
              onPressed: (colorized != null || enhanced != null) && !busy
                  ? exportResult
                  : null,
              icon: const LumeIcon(
                Icons.ios_share,
                slot: 'comic_image_tools_page.5',
                size: 18,
              ),
              label: const Text('保存 / 分享结果'),
            ),
            if (widget.allowApply)
              OutlinedButton.icon(
                onPressed: (colorized != null || enhanced != null) && !busy
                    ? () => Navigator.of(context).pop(colorized ?? enhanced)
                    : null,
                icon: const LumeIcon(
                  Icons.check_circle_outline,
                  slot: 'comic_image_tools_page.6',
                  size: 18,
                ),
                label: const Text('应用到当前页'),
              ),
            FilledButton(
              onPressed: busy || original == null ? null : () => process(true),
              child: const Text('翻译当前页'),
            ),
            IconButton(
              tooltip: '图片处理设置',
              icon: const LumeIcon(
                Icons.settings_outlined,
                slot: 'comic_image_tools_page.7',
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const ComicImageToolsSettingsPage(),
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
                                    : colorized ?? enhanced ?? original!,
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
