import '../../shared/widgets/native_glass_controls.dart';

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
import '../../core/reading/manga_translation_client.dart';
import '../../core/reading/translation_connection_config.dart';
import '../../core/reading/ocr_evaluation.dart';
import '../../core/translation/text_translation.dart';
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
    this.embedded = false,
    this.translation = false,
    this.pickModelFile,
    this.pickTranslationConfig,
  });
  final Future<XFile?> Function()? pickModelFile;
  final Future<XFile?> Function()? pickTranslationConfig;
  static const modelFileTypes = [
    XTypeGroup(
      label: 'waifu2x CoreML',
      extensions: ['mlmodel'],
      // iOS cannot filter by extension alone. Imported data is SHA-256 checked below.
      uniformTypeIdentifiers: ['public.data'],
    ),
  ];
  final bool translation;
  final bool embedded;
  @override
  State<ComicImageToolsSettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<ComicImageToolsSettingsPage> {
  final settings = ComicImageToolsSettings.instance;
  late final endpoint = TextEditingController(text: settings.endpoint);
  late final imageServer = TextEditingController(
    text: settings.imageTranslationEndpoint,
  );
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
  final colorizeKeyInput = TextEditingController();
  late String colorizeProtocol = settings.colorizeProtocol;
  final serverKeyInput = TextEditingController();
  ComicImageTools? probe;
  bool busy = false;
  String? status;
  @override
  void dispose() {
    endpoint.dispose();
    imageServer.dispose();
    model.dispose();
    colorizeEndpoint.dispose();
    colorizeModel.dispose();
    colorizePrompt.dispose();
    keyInput.dispose();
    colorizeKeyInput.dispose();
    serverKeyInput.dispose();
    probe?.dispose();
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

  Future<void> importTranslationConfig() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final file =
          await (widget.pickTranslationConfig?.call() ??
              openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(
                    label: 'LumeBox 翻译配置',
                    extensions: ['json'],
                    uniformTypeIdentifiers: ['public.json'],
                  ),
                ],
              ));
      if (file == null || !mounted) return;
      if (await file.length() > 16384) {
        throw const FormatException('翻译配置文件超过 16KB');
      }
      final config = TranslationConnectionConfig.parse(
        await file.readAsString(),
      );
      await ComicImageTools.channel.invokeMethod<void>('setKey', {
        'key': config.apiKey,
      });
      settings.translationMode = TextTranslationMode.ai;
      settings.serverTranslation = false;
      settings.endpoint = config.endpoint;
      settings.model = config.model;
      settings.target = config.target;
      await settings.save();
      if (!mounted) return;
      endpoint.text = config.endpoint;
      model.text = config.model;
      keyInput.clear();
      setState(() => status = '全局 AI 翻译配置已导入，标题、搜索结果和漫画共用；可点击下方测试按钮检查手机网络');
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              status = error is FormatException ? error.message : '配置导入失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveServer() async {
    MangaTranslationClient.endpoint(imageServer.text);
    if (serverKeyInput.text.trim().isNotEmpty) {
      if (!imageServer.text.trim().startsWith('https://')) {
        throw const FormatException('带密钥的服务器必须使用 HTTPS');
      }
      await ComicImageTools.channel.invokeMethod<void>('setKey', {
        'key': serverKeyInput.text.trim(),
        'slot': 'imageServer',
      });
      serverKeyInput.clear();
    }
    settings.imageTranslationEndpoint = imageServer.text.trim();
    await settings.save();
  }

  Future<void> testTranslation(bool server) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = server ? '正在发送测试图片…' : '正在发送测试文字…';
    });
    final tools = probe = ComicImageTools();
    try {
      if (server) {
        await saveServer();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
        final text = TextPainter(
          text: const TextSpan(
            text: 'Hello',
            style: TextStyle(color: Colors.black, fontSize: 28),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, const Offset(16, 16));
        text.dispose();
        final picture = recorder.endRecording();
        final image = await picture.toImage(160, 80);
        picture.dispose();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await tools.translateImageOnServer(bytes!.buffer.asUint8List());
        if (mounted) setState(() => status = '测试成功：服务器返回了翻译图片');
      } else {
        ComicImageTools.validateEndpoint(endpoint.text);
        if (model.text.trim().isEmpty) throw const FormatException('请填写模型名称');
        if (keyInput.text.trim().isNotEmpty) {
          await ComicImageTools.channel.invokeMethod<void>('setKey', {
            'key': keyInput.text.trim(),
          });
          keyInput.clear();
        }
        settings.endpoint = endpoint.text.trim();
        settings.model = model.text.trim();
        await settings.save();
        final translated = await tools.testAITranslation();
        if (mounted) setState(() => status = '测试成功：Hello → $translated');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status = error is FormatException
              ? error.message
              : error is StateError
              ? error.message.toString()
              : '测试失败，请检查地址、密钥、模型及网络',
        );
      }
    } finally {
      tools.dispose();
      probe = null;
      if (mounted) setState(() => busy = false);
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
              '${ComicImageTools.bundledModelNames.length}），可离线超分',
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
      ComicImageTools.validateColorizeEndpoint(colorizeEndpoint.text);
      if (colorizeModel.text.trim().isEmpty) {
        throw const FormatException('请填写上色模型');
      }
      if (colorizeKeyInput.text.trim().isNotEmpty) {
        await ComicImageTools.channel.invokeMethod<void>('setKey', {
          'key': colorizeKeyInput.text.trim(),
          'slot': colorizeProtocol == 'seedream'
              ? 'colorizeSeedream'
              : 'colorize',
        });
      }
      settings.colorizeEndpoint = colorizeEndpoint.text.trim();
      settings.colorizeProtocol = colorizeProtocol;
      settings.colorizeModel = colorizeModel.text.trim();
      settings.colorizePrompt = colorizePrompt.text.trim().isEmpty
          ? ComicImageToolsSettings.defaultColorizePrompt
          : colorizePrompt.text.trim();
      await settings.save();
      colorizeKeyInput.clear();
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
          () => status = method == 'clearModels'
              ? '已清理编译缓存，下次使用会自动准备模型'
              : '模型已就绪',
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
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final dropdown = DropdownButton<T>(
        value: value,
        isExpanded: true,
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(
                entry.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) {
            setState(() => changed(v));
            save();
          }
        },
      );
      if (MediaQuery.textScalerOf(context).scale(14) > 20) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              DropdownButtonHideUnderline(child: dropdown),
            ],
          ),
        );
      }
      return ListTile(
        title: Text(title),
        trailing: SizedBox(
          width: (constraints.maxWidth * .58).clamp(120, 230),
          child: DropdownButtonHideUnderline(child: dropdown),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final content = GlassScaffold(
      effectModule: widget.translation
          ? GlassModule.settings
          : GlassModule.comic,
      settingsSurface: true,
      embedded: widget.translation ? true : widget.embedded,
      title: widget.translation ? '全局翻译' : 'AI 图片超分与上色',
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.viewPaddingOf(context).bottom + 24,
        ),
        children: widget.translation
            ? [
                const SettingsPageIntro(
                  title: '翻译内容',
                  description: '统一设置标题、搜索结果与漫画文字的翻译方式。',
                ),
                const SettingsGroupTitle('基本设置'),
                SettingsGroupCard(
                  children: [
                    NativeSwitchListTile.adaptive(
                      key: const ValueKey('global-live-translation'),
                      title: const Text('实时翻译'),
                      subtitle: const Text('自动翻译新加载的标题、搜索结果与漫画当前页'),
                      value: settings.liveTranslation,
                      onChanged: (value) {
                        setState(() => settings.liveTranslation = value);
                        save();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SettingsEntryCard(
                  icon: Icons.file_open_rounded,
                  iconColor: const Color(0xFF366AAE),
                  title: '导入翻译配置文件',
                  subtitle: '一次填好接口地址、模型和密钥',
                  onTap: busy ? null : importTranslationConfig,
                ),
                const ExpansionTile(
                  leading: Icon(Icons.help_outline),
                  title: Text('翻译方式与配置说明'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    SelectableText(
                      '设备端：使用 Apple 翻译与系统语言包，不能导入第三方语言包。语言识别不准时，可把“原文语言”改成漫画实际语言。\n\n'
                      '自填 AI 接口：不必自己部署服务器。填写服务商提供的完整 HTTPS Chat Completions 地址（通常以 /v1/chat/completions 结尾）、准确的模型名称和 API Key，保存后返回阅读器开启翻译。此方式先在本机识字，只上传文字；请使用支持结构化 JSON 译文的模型。\n\n'
                      '漫画翻译服务器：需先部署兼容 manga-image-translator 的后端，或使用已有服务。填写 HTTPS 根地址，App 会调用 /translate/with-form/image；后端需先配置 OCR、翻译器密钥、擦字与排版模型。此方式上传整张漫画，返回处理好的图片。\n\n'
                      'Cloudflare：网关支持直接调用 Cloudflare 内置 AI，使用者可导入私人配置文件，无需另申请 AI 服务商密钥。源码在 deploy/translation-worker，完整步骤见项目 docs/漫画翻译与Cloudflare.md。也可配置第三方 AI 转发；整图擦字和排版仍需独立图片后端。\n\n'
                      '圈选翻译：在阅读页圈出一个对话框或区域，只识别并翻译选中部分，适合自动识别遗漏或误识别时补译。',
                    ),
                  ],
                ),
                const SettingsGroupTitle('语言与翻译方式'),
                SettingsGroupCard(
                  children: [
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
                  ],
                ),
                const SettingsFooterNote(
                  '首页标题、搜索结果、漫画对白与圈选文字共用此设置。AI 配置和目标语言只需填写一次。',
                ),
                SettingsGroupCard(
                  children: [
                    choice('全局翻译方式', settings.translationMode, {
                      TextTranslationMode.system: '系统翻译（本地）',
                      TextTranslationMode.ai: 'AI 翻译（联网）',
                      TextTranslationMode.fallback: '系统失败后用 AI 补译',
                    }, (v) => settings.translationMode = v),
                  ],
                ),
                SettingsFooterNote(switch (settings.translationMode) {
                  TextTranslationMode.system =>
                    '本模式在设备上翻译文字，不调用 AI 接口。首次使用可能需要下载系统语言包。',
                  TextTranslationMode.ai => '本模式直接把待翻译文字发送给下方配置的 AI 接口，不先调用系统翻译；成功译文缓存到本机。网络失败时保留原文，可重试未完成条目。',
                  TextTranslationMode.fallback =>
                    '先使用系统翻译；只有失败、不支持或未译出的外文才发送给 AI 补译。成功译文保留，AI 不可用时保留原文。',
                }),
                if (settings.ai || settings.aiFallback)
                  SettingsFooterNote(
                    endpoint.text.trim().isEmpty || model.text.trim().isEmpty
                        ? 'AI 配置未完成：请在下方填写接口地址和模型，保存密钥后测试。'
                        : 'AI 接口与模型已填写；密钥和连接是否可用，请通过下方测试确认。',
                  ),
                const SettingsGroupTitle('漫画图片翻译'),
                SettingsGroupCard(
                  children: [
                    NativeSwitchListTile.adaptive(
                      title: const Text('漫画使用整图翻译服务器'),
                      subtitle: const Text('仅影响漫画图片；关闭时，漫画文字跟随全局翻译方式'),
                      value: settings.serverTranslation,
                      onChanged: (v) {
                        setState(() => settings.serverTranslation = v);
                        save();
                      },
                    ),
                  ],
                ),
                if (settings.serverTranslation) ...[
                  const SettingsFooterNote(
                    '整张图片上传到你填写的 manga-image-translator 服务。服务器负责识别、翻译、擦字与排版；模型和翻译器密钥需预先在服务器配置。',
                  ),
                  TextField(
                    controller: imageServer,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText:
                          'https://服务器地址 或完整 /translate/with-form/image 接口',
                    ),
                  ),
                  TextField(
                    controller: serverKeyInput,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '服务器访问密钥（可选，留空保留）',
                      helperText:
                          '用于 Cloudflare 网关或要求 Bearer Token 的服务器，与 AI Key 分开保存',
                      helperMaxLines: 3,
                    ),
                  ),
                  choice('服务器识别模型', settings.serverOcr, {
                    '48px': '通用漫画 OCR',
                    'mocr': '日文漫画（manga-ocr）',
                  }, (v) => settings.serverOcr = v),
                  choice('服务器翻译器', settings.serverTranslator, {
                    'chatgpt': 'ChatGPT',
                    'deepl': 'DeepL',
                    'youdao': '有道',
                    'baidu': '百度',
                    'sakura': 'Sakura',
                  }, (v) => settings.serverTranslator = v),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            try {
                              await saveServer();
                              if (mounted) {
                                setState(() => status = '图片翻译服务器配置已保存');
                              }
                            } catch (error) {
                              if (mounted) setState(() => status = '$error');
                            }
                          },
                    child: const Text('保存图片翻译服务器'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => testTranslation(true),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('保存并测试图片翻译'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await ComicImageTools.channel.invokeMethod<void>(
                              'setKey',
                              {'key': '', 'slot': 'imageServer'},
                            );
                            serverKeyInput.clear();
                            if (mounted) setState(() => status = '已清除服务器访问密钥');
                          },
                    child: const Text('清除服务器访问密钥'),
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '设备端：iOS 18 及以上，首次使用按系统提示下载语言包。识别与翻译在设备上完成。\nAI：仅把识别出的文字发送到你填写的接口，费用由服务商决定。',
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await TextTranslationService.shared.clear();
                    if (mounted) setState(() => status = '已清理标题、简介与漫画的本机译文缓存');
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清理本机译文缓存'),
                ),
                if (settings.ai || settings.aiFallback) ...[
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
                                await ComicImageTools.channel
                                    .invokeMethod<void>('setKey', {
                                      'key': keyInput.text.trim(),
                                    });
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
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => testTranslation(false),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('保存并测试 AI 翻译'),
                  ),
                ],
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(status!),
                  ),
              ]
            : [
                NativeSwitchListTile.adaptive(
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
                NativeSwitchListTile.adaptive(
                  title: const Text('漫画 / 猫源封面'),
                  subtitle: const Text('书架、探索、详情页与历史记录的封面'),
                  value: settings.upscaleCovers,
                  onChanged: (v) {
                    setState(() => settings.upscaleCovers = v);
                    save();
                  },
                ),
                NativeSwitchListTile.adaptive(
                  title: const Text('视频海报'),
                  subtitle: const Text('视频书架、详情页与搜索结果的海报'),
                  value: settings.upscaleVideoPosters,
                  onChanged: (v) {
                    setState(() => settings.upscaleVideoPosters = v);
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
                  title: Text('内置模型 · 自动准备'),
                  subtitle: Text(
                    '8 个 waifu2x 模型已随 App 提供，无需下载或手动安装。首次超分时自动准备当前模型，之后复用缓存；重新安装 App 后也会自动准备。',
                  ),
                ),
                if (busy) const Center(child: CircularProgressIndicator()),
                const SettingsFooterNote(
                  '设备端超分目前支持 iOS。首次准备在后台进行，可能稍慢；不会在启动 App 时一次编译全部模型。',
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                ),
                ExpansionTile(
                  key: const Key('advanced-image-models'),
                  title: const Text('模型高级管理'),
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => manage('prepareModel'),
                      icon: const LumeIcon(
                        Icons.play_circle_outline,
                        slot: 'comic_image_tools_page.3',
                      ),
                      label: const Text('准备当前模型'),
                    ),
                    TextButton(
                      onPressed: busy ? null : installBundled,
                      child: const Text('重新安装全部内置模型（8 个）'),
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
                  ],
                ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(status!),
                  ),
                const SizedBox(height: 20),
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('AI 上色（实验性 · 云端）'),
                        subtitle: const Text(
                          '需要支持图片编辑的服务（返回 b64_json 图片）。DeepSeek 官方接口不能用于上色，可用于 AI 翻译。'
                          '保存配置后，点击阅读页的「AI 上色当前图片」才会上传并处理，可能产生服务商费用。',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                        child: Column(
                          children: <Widget>[
                            DropdownButtonFormField<String>(
                              initialValue: colorizeProtocol,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '上色服务',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'openai',
                                  child: Text('通用图片编辑（OpenAI 兼容）'),
                                ),
                                DropdownMenuItem(
                                  value: 'seedream',
                                  child: Text('火山方舟 · Seedream（国内）'),
                                ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(() {
                                        colorizeProtocol = value;
                                        colorizeEndpoint.text =
                                            value == 'seedream'
                                            ? 'https://ark.cn-beijing.volces.com/api/v3/images/generations'
                                            : 'https://api.openai.com/v1/images/edits';
                                        colorizeModel.text = value == 'seedream'
                                            ? 'doubao-seedream-5-0-flash-260915'
                                            : 'gpt-image-1-mini';
                                        colorizeKeyInput.clear();
                                      });
                                    },
                            ),
                            const SettingsFooterNote(
                              '选择服务后自动填写接口和模型，再填该服务的 API Key。需要先在服务商控制台开通对应模型；每次上色只请求一张图。',
                            ),
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
                                hintText: '填写图片编辑服务提供的模型名',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: colorizePrompt,
                              minLines: 2,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText: '上色提示词',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: colorizeKeyInput,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: '上色 API Key（留空保留）',
                              ),
                            ),
                            const SettingsFooterNote(
                              '填写所选服务的密钥。Seedream、通用上色和 AI 翻译的密钥分别保存，互不覆盖。通用上色兼容旧版共用的翻译密钥；上色提示词可保留默认内容。',
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: busy ? null : saveColorize,
                              child: const Text('保存上色配置'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SettingsFooterNote(
                  '自动超分默认关闭。漫画版块源内图片按源选择分组使用漫画或照片模型；'
                  '封面 / 视频海报是否处理由上面的范围开关控制。'
                  '手动超分与上色结果可以保存 / 分享，原图与下载文件不会被覆盖。',
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                ),
              ],
      ),
    );
    if (!widget.translation || widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.translation ? '全局翻译' : 'AI 图片超分与上色'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(top: false, bottom: false, child: content),
    );
  }
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
  final referenceText = TextEditingController();
  String? quality;
  late final tools = ComicImageTools(imageStyle: widget.imageStyle);
  Uint8List? original, enhanced, colorized;
  List<ComicTextRegion> regions = [];
  String? measurement;
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
      quality = null;
      measurement = null;
      message = translate ? '正在识别并翻译…' : '正在分块超分…';
    });
    try {
      if (translate && tools.preferences.serverTranslation) {
        final timer = Stopwatch()..start();
        final result = await tools.translateImageOnServer(bytes);
        if (mounted && current == generation) {
          setState(() {
            enhanced = result;
            colorized = null;
            regions = [];
            message = '服务器已完成图片翻译，可切回原图对照';
            measurement =
                '服务器处理与传输 ${(timer.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒';
          });
        }
      } else if (translate) {
        final result = await tools.translate(bytes);
        if (mounted && current == generation) {
          setState(() {
            regions = result;
            enhanced = null;
            colorized = null;
            message = result.isEmpty
                ? '未识别到文字，可尝试切换原文语言'
                : '已翻译 ${result.length} 处文字，可切回原图对照';
            message = tools.lastTranslationWarning ?? message;
            measurement = tools.lastTranslationReport?.summary;
          });
        }
      } else {
        final result = await tools.superResolve(bytes);
        if (mounted && current == generation) {
          setState(() {
            enhanced = result;
            colorized = null;
            regions = [];
            message = tools.lastUpscaleReport?.summary ?? '超分完成，可切回原图对照或保存结果';
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

  Future<void> recognizeOnly() async {
    final bytes = original;
    if (bytes == null || busy) return;
    final current = ++generation;
    final timer = Stopwatch()..start();
    setState(() {
      busy = true;
      quality = null;
      message = '正在识别文字…';
      measurement = null;
    });
    try {
      final result = await tools.recognizeRegions(bytes);
      if (mounted && current == generation) {
        setState(() {
          regions = result;
          enhanced = null;
          colorized = null;
          showOriginal = false;
          message = result.isEmpty
              ? '未识别到文字，可尝试切换原文语言'
              : result.map((r) => r.text).join('\n');
          measurement =
              '设备端 OCR · ${result.length} 处文字 · ${(timer.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒；请与原图对照检查识别质量';
        });
      }
    } catch (error) {
      if (mounted && current == generation) {
        setState(
          () => message = error is PlatformException
              ? error.message
              : '文字识别失败，原图保留',
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
      quality = null;
      measurement = null;
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
      if (context.mounted) {
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
    referenceText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.comic,
    title: 'AI 图片超分 · 上色 · 翻译',
    child: Column(
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy || original == null
                          ? null
                          : () => process(false),
                      child: const Text('AI 超分当前图片'),
                    ),
                    FilledButton.tonal(
                      onPressed: busy || original == null
                          ? null
                          : processColorize,
                      child: const Text('AI 上色当前图片'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          (colorized != null || enhanced != null) && !busy
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
                        onPressed:
                            (colorized != null || enhanced != null) && !busy
                            ? () =>
                                  Navigator.of(context)
                                      .pop(colorized ?? enhanced)
                            : null,
                        icon: const LumeIcon(
                          Icons.check_circle_outline,
                          slot: 'comic_image_tools_page.6',
                          size: 18,
                        ),
                        label: const Text('应用到当前页'),
                      ),
                    FilledButton(
                      onPressed: busy || original == null
                          ? null
                          : () => process(true),
                      child: const Text('翻译当前页'),
                    ),
                    OutlinedButton(
                      onPressed: busy || original == null
                          ? null
                          : recognizeOnly,
                      child: const Text('仅识别文字'),
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
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(message!),
                  ),
                if (measurement != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            measurement!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        IconButton(
                          tooltip: '复制识别与耗时结果',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text:
                                    '$measurement\n${regions.map((r) => '${r.text}\n${r.translation}').join('\n')}',
                              ),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制识别与耗时结果')),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                if (regions.isNotEmpty)
                  ExpansionTile(
                    title: const Text('检查识别质量'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          key: const ValueKey('ocr-reference'),
                          controller: referenceText,
                          maxLines: 3,
                          maxLength: 2000,
                          decoration: const InputDecoration(
                            labelText: '人工核对的原文',
                            helperText: '用于与本页识别结果比较，不会上传',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          try {
                            setState(
                              () => quality = OcrEvaluation.compare(
                                referenceText.text,
                                regions.map((r) => r.text).join(),
                              ).summary,
                            );
                          } on FormatException catch (e) {
                            setState(() => quality = e.message);
                          }
                        },
                        child: const Text('计算字符错误率'),
                      ),
                      if (quality != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(quality!),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
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
