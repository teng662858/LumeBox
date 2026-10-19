import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/intro/intro_backend.dart';
import '../../core/intro/intro_models.dart';
import '../../core/intro/intro_store.dart';
import 'reference_player_help_page.dart';

class IntroSettingsPage extends StatefulWidget {
  const IntroSettingsPage({super.key});
  @override
  State<IntroSettingsPage> createState() => _IntroSettingsPageState();
}

class _IntroSettingsPageState extends State<IntroSettingsPage> {
  IntroStore? _store;
  String? _error;
  bool _installing = false;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final store = await IntroStore.open();
      if (mounted) setState(() => _store = store);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开识别数据库');
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _models({String? type}) async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      if (type == null) {
        await NativeIntroBackend.installBundledModels();
        _store!.update({'videoModelRoot': null, 'audioModelPath': null});
        _message(
          Platform.isIOS
              ? '已准备内置 MobileCLIP-S0 与 YAMNet，首次推理时编译 Core ML'
              : '已准备 YAMNet；MobileCLIP Core ML 在 iPhone 上运行',
        );
      } else {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: type == 'video' ? 'Core ML 模型 ZIP' : 'YAMNet 兼容 TFLite',
              extensions: [type == 'video' ? 'zip' : 'tflite'],
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > 256 * 1024 * 1024) {
          throw const FormatException('模型文件超过 256 MB');
        }
        final root = path.join(
          (await getApplicationSupportDirectory()).path,
          'reference_intro_custom_${DateTime.now().microsecondsSinceEpoch}',
        );
        await Directory(root).create(recursive: true);
        final destination = path.join(
          root,
          type == 'video' ? 'model.zip' : 'audio.tflite',
        );
        await file.saveTo(destination);
        if (type == 'video') {
          await Isolate.run(() {
            final input = InputFileStream(destination);
            try {
              final archive = ZipDecoder().decodeStream(input);
              var bytes = 0;
              for (final entry in archive.files) {
                bytes += entry.size;
                final resolved = path.normalize(path.join(root, entry.name));
                if (entry.isSymbolicLink ||
                    !path.isWithin(root, resolved) ||
                    bytes > 512 * 1024 * 1024) {
                  throw const FormatException('模型 ZIP 路径或解压大小不合法');
                }
              }
              extractArchiveToDisk(archive, root);
            } finally {
              input.closeSync();
            }
          });
          final pair =
              await Directory(path.join(root, 'mobileclip_s0_image.mlpackage'))
                  .exists() &&
              await Directory(path.join(root, 'mobileclip_s0_text.mlpackage'))
                  .exists();
          final classifier =
              await Directory(path.join(root, 'segment_classifier.mlpackage'))
                  .exists() ||
              await File(path.join(root, 'segment_classifier.mlmodel'))
                  .exists();
          if (!pair && !classifier) {
            throw const FormatException(
              '需要 MobileCLIP 图像／文本模型对，或 segment_classifier 模型',
            );
          }
          _store!.update({'videoModelRoot': root});
        } else {
          _store!.update({'audioModelPath': destination});
        }
        _message('已切换模型，下一次空闲预扫描验证输入输出契约');
      }
    } catch (error) {
      _message(
        '模型准备失败：${error is FormatException ? error.message : "请检查文件与可用空间"}',
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _export() async {
    try {
      final text = const JsonEncoder.withIndent('  ')
          .convert(_store!.recentLogs());
      await const MethodChannel('lumebox/configuration').invokeMethod<bool>(
        'export',
        {'name': 'LumeBox-intro-recognition.json', 'text': text},
      );
    } catch (_) {
      _message('日志导出失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('片头片尾识别')),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(_error!),
        ),
      );
    }
    return ValueListenableBuilder<IntroOptions>(
      valueListenable: store,
      builder: (context, options, _) {
        final order = options.order;
        Widget toggle(
          String key,
          String title, {
          bool? value,
          String? subtitle,
        }) => SwitchListTile(
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          value: value ?? options.enabled(key),
          onChanged: (v) => store.update({key: v}),
        );
        Widget slider(
          String key,
          String title,
          int value,
          int min,
          int max,
          String unit,
        ) => ListTile(
          title: Text('$title  $value$unit'),
          subtitle: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            onChanged: (v) => store.update({key: v.round()}),
          ),
        );
        return Scaffold(
          appBar: AppBar(
            title: const Text('片头片尾识别'),
            actions: [
              IconButton(
                tooltip: '使用说明',
                icon: const LumeIcon(
                  Icons.help_outline,
                  slot: 'intro_settings_page.1',
                ),
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReferencePlayerHelpPage(),
                  ),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              toggle('active', '启用识别', value: options.active),
              toggle(
                'autoSkip',
                '倒计时自动跳过',
                value: options.autoSkip,
                subtitle: '每次跳过前提供取消按钮；关闭后仅显示手动跳过',
              ),
              slider('countdown', '提示倒计时', options.countdown, 3, 15, ' 秒'),
              const ListTile(
                title: Text('识别优先级'),
                subtitle: Text('长按拖动排序；某层有可靠结果后停止后续识别。手动标记可移到首位。'),
              ),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: order.length,
                onReorderItem: (old, next) {
                  final sorted = [...order];
                  final stage = sorted.removeAt(old);
                  sorted.insert(next, stage);
                  store.update({'order': sorted.map((s) => s.name).toList()});
                },
                itemBuilder: (context, i) => ListTile(
                  key: ValueKey(order[i]),
                  title: Text('${i + 1}. ${order[i].label}'),
                  trailing: const LumeIcon(
                    Icons.drag_handle,
                    slot: 'intro_settings_page.2',
                  ),
                ),
              ),
              for (final group in <String, List<String>>{
                '社区库': ['theIntroDB', 'introDB'],
                '内置元数据': ['chapters', 'mkvTags', 'subtitles', 'filename'],
                '低算力启发式': ['black', 'silence', 'sceneCuts', 'ocr'],
                '本地指纹自学习': ['phash', 'dhash', 'mfcc', 'joint'],
                '本地 AI': ['videoAI', 'audioAI'],
                '手动兜底': ['manual'],
              }.entries) ...[
                ListTile(
                  title: Text(
                    group.key,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final key in group.value)
                  toggle(
                    key,
                    IntroOptions.switches[key]!,
                    subtitle: introMethodHelp[key],
                  ),
              ],
              toggle(
                'reuseManualSeason',
                '同剧记忆：记一次，后续各集沿用',
                subtitle: '无需作品 ID。片头记结束点，片尾按剩余时长适配后续集；可重新记忆或清除。',
              ),
              toggle('skiprecap', '允许跳过前情回顾'),
              toggle('skippreview', '允许跳过下集预告'),
              const ListTile(
                title: Text('模型管理'),
                subtitle: Text(
                  '内置 MobileCLIP-S0（Core ML，iOS）与 YAMNet（单线程 TFLite）。视频采用零样本语义与连续片段判断，分数未经 OP／ED 专项校准。可替换为四类专用模型。',
                ),
              ),
              ListTile(
                title: Text(_installing ? '正在准备模型…' : '准备／恢复内置模型'),
                trailing: _installing
                    ? const CircularProgressIndicator()
                    : const LumeIcon(
                        Icons.download,
                        slot: 'intro_settings_page.3',
                      ),
                onTap: _installing ? null : _models,
              ),
              ListTile(
                title: const Text('更换视频模型'),
                subtitle: Text(
                  options.values['videoModelRoot'] == null
                      ? '当前：内置 MobileCLIP-S0'
                      : '当前：自定义 Core ML',
                ),
                onTap: _installing ? null : () => _models(type: 'video'),
              ),
              ListTile(
                title: const Text('更换音频模型'),
                subtitle: Text(
                  options.values['audioModelPath'] == null
                      ? '当前：内置 YAMNet'
                      : '当前：自定义 YAMNet 兼容模型',
                ),
                onTap: _installing ? null : () => _models(type: 'audio'),
              ),
              const ListTile(title: Text('资源与置信度')),
              toggle(
                'idleOnly',
                '仅空闲时预扫描',
                value: options.idleOnly,
                subtitle: '默认播放／后台立即停止重计算；暂停且回到前台后继续。iOS 后台不保证执行。',
              ),
              toggle('wifiOnly', '网络媒体预扫描仅用 Wi-Fi', value: options.wifiOnly),
              toggle('chargingOnly', '仅充电时预扫描', value: options.chargingOnly),
              slider(
                'scanSeconds',
                '每轮计算时间上限',
                options.scanSeconds,
                5,
                120,
                ' 秒',
              ),
              slider(
                'sampleEverySeconds',
                '采样间隔',
                options.sampleEverySeconds,
                1,
                10,
                ' 秒',
              ),
              slider('maxSamples', '采样数量上限', options.maxSamples, 10, 240, ' 帧'),
              ListTile(
                title: Text('最低接受置信度 ${(options.threshold * 100).round()}%'),
                subtitle: Slider(
                  value: options.threshold,
                  min: .5,
                  max: 1,
                  divisions: 50,
                  onChanged: (v) => store.update({'threshold': v}),
                ),
              ),
              const ListTile(
                subtitle: Text(
                  '串行解码、32×32 指纹、稀疏 OCR、单线程音频推理；低电量、严重温控或内存不足时停止。首次准备／编译模型的耗时单独计入日志，不承诺固定 CPU 百分比。',
                ),
              ),
              toggle('logs', '记录来源、结果与置信度', value: options.logs),
              ListTile(
                title: const Text('查看识别日志'),
                trailing: const LumeIcon(
                  Icons.chevron_right,
                  slot: 'intro_settings_page.4',
                ),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => IntroLogPage(store: store)),
                ),
              ),
              ListTile(title: const Text('导出识别日志'), onTap: _export),
              ListTile(
                title: const Text('清空日志'),
                onTap: () {
                  store.clearLogs();
                  _message('已清空识别日志');
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class IntroLogPage extends StatelessWidget {
  const IntroLogPage({super.key, required this.store});
  final IntroStore store;
  @override
  Widget build(BuildContext context) {
    final logs = store.recentLogs();
    return Scaffold(
      appBar: AppBar(title: const Text('识别日志')),
      body: logs.isEmpty
          ? const Center(child: Text('暂无记录，先播放或空闲预扫描一集'))
          : ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, i) {
                final item = logs[i];
                return ExpansionTile(
                  title: Text('${item['stage']} · ${item['status']}'),
                  subtitle: Text('${item['elapsedMs']} ms · ${item['at']}'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(item),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
