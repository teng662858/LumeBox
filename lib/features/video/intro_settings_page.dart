import 'player_settings_panel.dart';
import '../../shared/widgets/native_glass_controls.dart';
import 'danmaku/danmaku_panel.dart';

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

const introMethodHelp = <String, String>{
  'theIntroDB': '先在视频的“片头片尾”中填写 TMDB 作品 ID、季号；集号随当前选集。查询不到或版本时长不符会继续其他方案。',
  'introDB': '需要填写 IMDb 作品 ID（tt 开头）。与 TheIntroDB 独立查询，可只开启其中一个。',
  'chapters': '读取视频自带的 OP、ED、前情回顾等章节时间；文件没有章节时会继续其他方案。',
  'mkvTags': '读取 MKV 章节关联标签及显式片头片尾时间。网络文件需要支持分段读取；没有明确时间的标签不会自动跳转。',
  'subtitles': '从内嵌字幕的关键词与时间寻找片头片尾。当前使用 iOS 原生解析，容器或字幕格式不支持时会继续降级。',
  'filename': '读取文件名中的 OP、ED 等词和明确时间范围，例如 OP[00:05-01:35]。只有名称、没有时间时不会推测整段长度。',
  'black': '在头尾区域采样黑屏、亮度和淡入淡出边界；与其他证据组合，单独一帧黑屏不会触发跳过。',
  'silence': '寻找头尾区域的音频静默边界。建议与黑屏或场景切换同时开启，静默本身不等于片头片尾。',
  'sceneCuts': '通过相邻画面的变化频率辅助定位片头；采用稀疏采样，需要与边界信号配合。',
  'ocr': '识别片尾演职员文字及连续画面中文字上移的趋势；静止字幕不会单独作为滚动片尾证据。',
  'phash': '用图像整体结构匹配同剧同季已经学到的片段，能容忍部分亮度变化；首次没有模板时不会命中。',
  'dhash': '用画面明暗梯度匹配同季片段；需要多个时间点连续吻合，平坦黑帧不会作为模板锚点。',
  'mfcc': '用声音频谱特征匹配同季已学习片段；需要有声样本，静音不会当作可复用的音频指纹。',
  'joint': '要求音频和图像在同一时间偏移下共同吻合。证据更充分，但音轨或片头画面被替换时可能无法匹配。',
  'videoAI':
      '在 iPhone 上使用 MobileCLIP 判断前情回顾、片头、正片和片尾，再检查连续片段。属于实验性零样本分类，准确率尚待样片验证。',
  'audioAI': '使用 YAMNet 区分人声与音乐，辅助视频 AI 判断。单独开启只分析音频，不能仅凭音乐生成可靠跳过范围。',
  'manual':
      '在视频的“片头片尾”中点“记住当前位置：片头结束”或“片尾开始”，同剧后续各集自动沿用。无需作品 ID；也可展开高级选项精确调整四个起止时间。',
};

class IntroSettingsPage extends StatefulWidget {
  const IntroSettingsPage({super.key, this.store, this.embedded = false});
  final bool embedded;
  final IntroStore? store;
  @override
  State<IntroSettingsPage> createState() => _IntroSettingsPageState();
}

class _IntroSettingsPageState extends State<IntroSettingsPage> {
  IntroStore? _store;
  String? _error;
  bool _installing = false;
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final store = widget.store ?? await IntroStore.open();
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
      return PlayerSettingsScaffold(
        embedded: widget.embedded,
        title: '片头片尾识别',
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
        ) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: const TextStyle(fontSize: 14)),
                  ),
                  Text(
                    '$value$unit',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              NativeGlassSlider(
                value: value.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                onChanged: (v) => store.update({
                  key: key == 'threshold' ? v / 100 : v.round(),
                }),
              ),
            ],
          ),
        );
        final content = <Widget>[];
        if (_tab == 0) {
          content.addAll([
            PlayerSettingsSection(
              title: '跳过方式',
              children: [
                toggle('active', '启用识别', value: options.active),
                toggle(
                  'autoSkip',
                  '倒计时自动跳过',
                  value: options.autoSkip,
                  subtitle: '跳过前可取消；关闭后仅显示手动跳过',
                ),
                slider(
                  'countdown',
                  '提示倒计时（0 秒不显示）',
                  options.countdown,
                  0,
                  5,
                  ' 秒',
                ),
              ],
            ),
            PlayerSettingsSection(
              title: '同剧与特殊片段',
              children: [
                toggle(
                  'reuseManualSeason',
                  '同剧记忆',
                  subtitle: '记住片头结束或片尾开始，后续集数沿用',
                ),
                toggle('skiprecap', '允许跳过前情回顾'),
                toggle('skippreview', '允许跳过下集预告'),
              ],
            ),
          ]);
        }
        if (_tab == 1) {
          final order = options.order;
          content.addAll([
            PlayerSettingsSection(
              title: '识别优先级',
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '拖动右侧把手排序；得到可靠结果后停止后续识别。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: order.length,
                  onReorderItem: (old, next) {
                    final sorted = [...order];
                    final stage = sorted.removeAt(old);
                    sorted.insert(next, stage);
                    store.update({'order': sorted.map((s) => s.name).toList()});
                  },
                  itemBuilder: (context, i) => ListTile(
                    key: ValueKey(order[i]),
                    title: Text(order[i].label),
                    leading: CircleAvatar(
                      radius: 13,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_handle_rounded, size: 21),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            for (final group in <String, List<String>>{
              '社区库': ['theIntroDB', 'introDB'],
              '内置元数据': ['chapters', 'mkvTags', 'subtitles', 'filename'],
              '低算力启发式': ['black', 'silence', 'sceneCuts', 'ocr'],
              '本地指纹自学习': ['phash', 'dhash', 'mfcc', 'joint'],
              '本地 AI': ['videoAI', 'audioAI'],
              '手动兜底': ['manual'],
            }.entries)
              PlayerSettingsSection(
                children: [
                  ExpansionTile(
                    key: PageStorageKey('intro-group-${group.key}'),
                    title: Text(
                      group.key,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      '已开启 ${group.value.where(options.enabled).length} / ${group.value.length}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    children: [
                      for (final key in group.value)
                        toggle(
                          key,
                          IntroOptions.switches[key]!,
                          subtitle: introMethodHelp[key],
                        ),
                    ],
                  ),
                ],
              ),
          ]);
        }
        if (_tab == 2) {
          content.addAll([
            PlayerSettingsSection(
              title: '识别模型',
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '内置 MobileCLIP-S0 与 YAMNet。识别为实验性辅助结果，可替换兼容模型。',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
                ListTile(
                  title: Text(_installing ? '正在准备模型…' : '准备／恢复内置模型'),
                  trailing: _installing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined, size: 20),
                  onTap: _installing ? null : _models,
                ),
                ListTile(
                  title: const Text('更换视频模型'),
                  subtitle: Text(
                    options.values['videoModelRoot'] == null
                        ? '当前：内置 MobileCLIP-S0'
                        : '当前：自定义 Core ML',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: _installing ? null : () => _models(type: 'video'),
                ),
                ListTile(
                  title: const Text('更换音频模型'),
                  subtitle: Text(
                    options.values['audioModelPath'] == null
                        ? '当前：内置 YAMNet'
                        : '当前：自定义 YAMNet 兼容模型',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: _installing ? null : () => _models(type: 'audio'),
                ),
              ],
            ),
            PlayerSettingsSection(
              title: '计算与网络',
              children: [
                toggle(
                  'idleOnly',
                  '仅空闲时预扫描',
                  value: options.idleOnly,
                  subtitle: '播放或进入后台时停止；暂停且在前台时继续',
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
                slider(
                  'maxSamples',
                  '采样数量上限',
                  options.maxSamples,
                  10,
                  240,
                  ' 帧',
                ),
                slider(
                  'threshold',
                  '最低接受置信度',
                  (options.threshold * 100).round(),
                  50,
                  100,
                  '%',
                ),
              ],
            ),
            const Text(
              '低电量、严重温控或内存不足时会停止。模型准备、编译耗时单独计入日志。',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ]);
        }
        if (_tab == 3) {
          content.add(
            PlayerSettingsSection(
              title: '诊断记录',
              children: [
                toggle('logs', '记录来源、结果与置信度', value: options.logs),
                ListTile(
                  title: const Text('查看识别日志'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => IntroLogPage(store: store),
                    ),
                  ),
                ),
                ListTile(
                  title: const Text('导出识别日志'),
                  leading: const Icon(Icons.ios_share_rounded, size: 20),
                  onTap: _export,
                ),
                ListTile(
                  title: const Text('清空日志'),
                  leading: const Icon(Icons.delete_outline_rounded, size: 20),
                  onTap: () {
                    store.clearLogs();
                    _message('已清空识别日志');
                  },
                ),
              ],
            ),
          );
        }
        return PlayerSettingsScaffold(
          embedded: widget.embedded,
          title: '片头片尾识别',
          actions: [
            IconButton(
              tooltip: '使用说明',
              icon: const Icon(Icons.help_outline_rounded, size: 21),
              onPressed: () => showPlayerDialog<void>(
                context: context,
                onlyInPlayer: true,
                useRootNavigator: false,
                builder: (context) => AlertDialog(
                  title: const Text('片头片尾识别'),
                  content: const SingleChildScrollView(
                    child: Text(
                      '在播放页记住片头结束或片尾开始的位置，同一作品后续集数会沿用。\n\n识别结果可手动确认，自动跳过前可以取消。识别策略、模型和日志在上方分类中调整。',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          body: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: ChoiceChip(
                          label: Text(const ['基础', '识别策略', '模型与资源', '记录'][i]),
                          selected: _tab == i,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _tab = i),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: ValueKey('intro-tab-$_tab'),
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
                  children: content,
                ),
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
    return PlayerSettingsScaffold(
      title: '识别日志',
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
