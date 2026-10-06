import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter/services.dart' show rootBundle;

import '../../core/js/source_script.dart';
import '../../core/net/lume_http.dart';
import '../../core/net/source_import_input.dart';
import '../../core/net/source_subscription.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import 'source_import_flow.dart';

/// 一次导入请求：目标板块 + 待导入条目 + 没能进链路的条目 + 过程说明。
class SourceImportRequest {
  const SourceImportRequest({
    required this.section,
    required this.items,
    this.skipped = const <SourceImportSkip>[],
    this.notes = const <String>[],
  });

  /// 目标板块（图源只写这里）。
  final Section section;

  final List<SourceImportItem> items;

  /// 识别不出 / 是备份 / 是裸校验值的条目（仍进结果，如实报给用户）。
  final List<SourceImportSkip> skipped;

  /// 过程说明（清单被截断、文件数超上限等）。
  final List<String> notes;
}

/// 打开「添加源」弹窗并执行导入；返回是否至少成功导入一条。
///
/// 覆盖确认、逐条导入与结果反馈都在 [importSources] 里，本函数只负责
/// 「弹窗 → 请求」这一段。
Future<bool> runSourceImport(
  BuildContext context, {
  required Section section,
  required SourceManager manager,
  Future<List<({String name, String text})>> Function()? readLocalScripts,
  Future<SourceFetchResult> Function(String url)? fetchSubscription,
}) async {
  final request = await showDialog<SourceImportRequest>(
    context: context,
    builder: (_) => SourceImportDialog(
      section: section,
      readLocalScripts: readLocalScripts,
      fetchSubscription: fetchSubscription,
    ),
  );
  if (request == null || !context.mounted) return false;
  return importSources(
    context,
    manager: manager,
    items: request.items,
    skipped: request.skipped,
    notes: request.notes,
  );
}

/// 添加源弹窗：本地文件 / 订阅链接 / 剪贴板三条通道，导入的源归属目标板块。
///
/// 三条通道最后都汇到同一步：用 [SourceImportInput] 认出「这是脚本、还是地址
/// 清单、还是认不出」，因此两个输入框互相粘错也不会白跑一趟。
///
/// 剪贴板是**点了才读**：iOS 16+ 读剪贴板会弹系统「允许粘贴？」授权条，静默读
/// 会让用户不明所以地被弹一次；由用户主动点，系统提示才有上下文。
///
/// 隔离：弹窗只产出「要导入什么」，写库仍走目标板块的端口，不提供任何跨板块路径。
class SourceImportDialog extends StatefulWidget {
  const SourceImportDialog({
    super.key,
    this.section,
    this.sections,
    this.initialSection,
    this.readLocalScripts,
    this.fetchSubscription,
    this.maxScripts = 20,
    this.maxLocalFiles = 50,
  });

  /// 固定目标板块（板块页 / 板块入口用）。
  final Section? section;

  /// 可选目标板块清单（总管理页用）；非空时弹窗顶部出现板块选择器。
  final List<Section>? sections;

  /// 板块选择器的初始选中项（总管理页从某个板块点进来时带上下文）。
  final Section? initialSection;

  /// 本地文件读取端口（测试注入）；为空时弹系统文件选择器（可多选）。
  final Future<List<({String name, String text})>> Function()? readLocalScripts;

  /// 订阅拉取端口（测试注入）；为空时经 [LumeHttp]（宿主网络层）拉取。
  final Future<SourceFetchResult> Function(String url)? fetchSubscription;

  /// 单次订阅最多解析出的脚本条数（与既有口径一致，防地址清单无限展开）。
  final int maxScripts;

  /// 单次最多接收的本地文件数（防误选一整个目录把导入变成不可控的批量）。
  final int maxLocalFiles;

  @override
  State<SourceImportDialog> createState() => _SourceImportDialogState();
}

enum _ImportMode { local, subscription }

class _SourceImportDialogState extends State<SourceImportDialog> {
  final TextEditingController _script = TextEditingController();
  final TextEditingController _url = TextEditingController();

  /// 已选本地文件：文件名 + 识别结果（识别在选中的那一刻做，用户当场就能看到
  /// 「这个文件是脚本 / 是清单 / 认不出」，而不是提交后才失败）。
  final List<({String name, SourceImportInput input})> _files =
      <({String name, SourceImportInput input})>[];

  _ImportMode _mode = _ImportMode.local;
  late Section _section = widget.initialSection ??
      widget.section ??
      widget.sections?.first ??
      Section.novel;

  String? _error;

  /// 正面提示（例如「已从剪贴板填入」），与 [_error] 互斥。
  String? _hint;
  String? _progress;
  bool _busy = false;

  /// 文件选择器的可选项：iOS 只认 UTI、Windows 只认扩展名，两边都给。
  /// 末项 `public.data` 是对未登记脚本扩展名的兜底（宁可多显示，不可选不中）。
  static const XTypeGroup _scriptTypeGroup = XTypeGroup(
    label: '源脚本',
    extensions: <String>['js', 'md5', 'txt'],
    uniformTypeIdentifiers: <String>[
      'com.netscape.javascript-source',
      'public.plain-text',
      'public.data',
    ],
  );

  bool get _hasSectionPicker => widget.sections != null && widget.sections!.length > 1;

  @override
  void dispose() {
    _script.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        _hasSectionPicker ? '导入源' : '添加源 · ${_section.label}',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_hasSectionPicker) ..._buildSectionPicker(),
              Text(
                _hasSectionPicker
                    ? '源只写入所选板块，不会跨板块共用。'
                    : '源只写入当前板块，不会跨板块共用。',
                style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 12),
              SegmentedButton<_ImportMode>(
                segments: const <ButtonSegment<_ImportMode>>[
                  ButtonSegment<_ImportMode>(
                    value: _ImportMode.local,
                    icon: Icon(Icons.description_outlined),
                    label: Text('本地文件'),
                  ),
                  ButtonSegment<_ImportMode>(
                    value: _ImportMode.subscription,
                    icon: Icon(Icons.cloud_download_outlined),
                    label: Text('订阅链接'),
                  ),
                ],
                selected: <_ImportMode>{_mode},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => setState(() {
                          _mode = selection.first;
                          _error = null;
                        }),
              ),
              const SizedBox(height: 12),
              ...(_mode == _ImportMode.local ? _buildLocal() : _buildSubscription()),
              if (_progress != null) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _progress!,
                      style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                    ),
                  ],
                ),
              ],
              if (_hint != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _hint!,
                  style: const TextStyle(fontSize: 12, color: LumeTheme.success),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: LumeTheme.danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : _loadBuiltin,
          child: const Text('载入内置示例'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_submitLabel),
        ),
      ],
    );
  }

  String get _submitLabel {
    if (_busy) return '处理中…';
    return _mode == _ImportMode.local ? '导入' : '拉取并导入';
  }

  List<Widget> _buildSectionPicker() => <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final section in widget.sections!)
              ChoiceChip(
                label: Text(section.label),
                selected: _section == section,
                onSelected: _busy
                    ? null
                    : (_) => setState(() => _section = section),
              ),
          ],
        ),
        const SizedBox(height: 8),
      ];

  List<Widget> _buildLocal() => <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _pickLocal,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('选择本地文件'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _fromClipboard,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('从剪贴板'),
            ),
          ],
        ),
        if (_files.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Text(
                '已选 ${_files.length} 个文件',
                style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const Spacer(),
              TextButton(
                onPressed: _busy ? null : () => setState(_files.clear),
                child: const Text('清空'),
              ),
            ],
          ),
          for (final file in _files) _buildFileRow(file),
          const SizedBox(height: 4),
        ] else
          const SizedBox(height: 12),
        TextField(
          controller: _script,
          maxLines: 6,
          enabled: !_busy,
          decoration: const InputDecoration(
            hintText: '或直接粘贴源脚本内容',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '脚本头部写一行「// LumeSource: {"id":"…","name":"…"}」即可被识别；'
          '只写顶层函数（getList(page) 等）的脚本同样支持。'
          '也可以选择「一行一个地址」的清单文件（.txt / .js.md5），'
          '会按订阅逐个拉取并记下来源地址。',
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
      ];

  /// 单个已选文件：文件名 + 识别结论（认不出的当场标红，不用等提交）。
  Widget _buildFileRow(({String name, SourceImportInput input}) file) {
    final kind = file.input.kind;
    final importable = file.input.isImportable;
    final detail = kind == SourceImportInputKind.manifest
        ? '${kind.label}（${file.input.urls.length} 个地址）'
        : kind.label;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: LumeTheme.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            detail,
            style: TextStyle(
              fontSize: 12,
              color: importable ? LumeTheme.success : LumeTheme.danger,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSubscription() => <Widget>[
        TextField(
          controller: _url,
          enabled: !_busy,
          // 订阅可以是一行一个脚本地址的清单，所以允许多行粘贴。
          maxLines: 3,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '订阅地址（http / https）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _fromClipboard,
          icon: const Icon(Icons.content_paste, size: 18),
          label: const Text('从剪贴板'),
        ),
        const SizedBox(height: 4),
        const Text(
          '订阅返回单个脚本时直接导入；返回「一行一个脚本地址」的清单时逐个拉取；'
          '返回 MD5 校验值（.js.md5）时，去掉 .md5 后缀取脚本并校验后再导入。',
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
      ];

  /// 内置示例脚本：新用户先跑通「导入 → 浏览」这套动作的最低门槛。
  Future<void> _loadBuiltin() async {
    final text = await rootBundle.loadString('assets/js/example_source.js');
    if (!mounted) return;
    setState(() {
      _mode = _ImportMode.local;
      _script.text = text;
      _error = null;
      _hint = null;
    });
  }

  /// 选本地文件（可多选）：读进来就地识别，超出上限的部分不接收并说明。
  Future<void> _pickLocal() async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      final picked = await (widget.readLocalScripts ?? _readLocalScripts)();
      if (!mounted) return;
      // 用户取消选择：保持原状，不算错误。
      if (picked.isEmpty) return;
      setState(() {
        var added = 0;
        for (final file in picked) {
          if (_files.length >= widget.maxLocalFiles) break;
          if (_files.any((item) => item.name == file.name && item.input.text == file.text)) {
            continue;
          }
          _files.add((
            name: file.name,
            input: SourceImportInput.classify(
              file.text,
              name: file.name,
              urlLimit: widget.maxScripts,
            ),
          ));
          added++;
        }
        _hint = picked.length > added
            ? '单次最多 ${widget.maxLocalFiles} 个文件，本次收下前 $added 个'
            : null;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '读取文件失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 默认本地读取：系统文件选择器（多选）→ 字节 → UTF-8 解码 → 剥 BOM。
  static Future<List<({String name, String text})>> _readLocalScripts() async {
    final files = await openFiles(acceptedTypeGroups: <XTypeGroup>[_scriptTypeGroup]);
    final result = <({String name, String text})>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      // 文件常带 UTF-8 BOM（EF BB BF）：解码后先剥掉再交出文本。
      result.add((
        name: file.name,
        text: stripScriptBom(utf8.decode(bytes, allowMalformed: true)),
      ));
    }
    return result;
  }

  /// 读剪贴板并按内容自动选通道：脚本填进粘贴框、地址清单填进订阅框、
  /// 备份与裸校验值则直说该去哪儿（不静默失败）。
  Future<void> _fromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      setState(() {
        _error = '剪贴板里没有文本';
        _hint = null;
      });
      return;
    }
    final input = SourceImportInput.classify(
      text,
      name: '剪贴板',
      urlLimit: widget.maxScripts,
    );
    setState(() {
      _error = null;
      _hint = null;
      switch (input.kind) {
        case SourceImportInputKind.script:
          _mode = _ImportMode.local;
          _script.text = text;
          _hint = '已从剪贴板填入脚本，点「导入」写入${_section.label}板块';
        case SourceImportInputKind.manifest:
          _mode = _ImportMode.subscription;
          _url.text = text;
          _hint = '已从剪贴板填入 ${input.urls.length} 个地址，点「拉取并导入」';
        case SourceImportInputKind.checksum:
        case SourceImportInputKind.backup:
        case SourceImportInputKind.unknown:
          _error = input.describeFailure;
      }
    });
  }

  void _submit() {
    _gather();
  }

  /// 收集本次要导入的内容：三条通道的输入都过一遍识别，然后按形态分流。
  Future<void> _gather() async {
    final items = <SourceImportItem>[];
    final skipped = <SourceImportSkip>[];
    final notes = <String>[];
    final urls = <String>[];

    void take(SourceImportInput input, String label) {
      switch (input.kind) {
        case SourceImportInputKind.script:
          items.add(SourceImportItem(script: input.text, label: label));
        case SourceImportInputKind.manifest:
          urls.addAll(input.urls);
        case SourceImportInputKind.checksum:
        case SourceImportInputKind.backup:
        case SourceImportInputKind.unknown:
          skipped.add(SourceImportSkip(label: label, message: input.describeFailure));
      }
    }

    for (final file in _files) {
      take(file.input, file.name);
    }
    if (_script.text.trim().isNotEmpty) {
      take(
        SourceImportInput.classify(
          _script.text,
          name: '粘贴',
          urlLimit: widget.maxScripts,
        ),
        '粘贴',
      );
    }
    if (_url.text.trim().isNotEmpty) {
      final raw = _url.text;
      final input = SourceImportInput.classify(
        raw,
        name: '订阅链接',
        urlLimit: widget.maxScripts,
      );
      // 订阅框里认不出时给一句更贴题的话：这里最常见的错是地址没带 http(s)。
      if (input.kind == SourceImportInputKind.unknown) {
        skipped.add(
          const SourceImportSkip(
            label: '订阅',
            message: '订阅地址要以 http:// 或 https:// 开头（也可以直接粘贴脚本内容）。',
          ),
        );
      } else {
        take(input, '订阅');
      }
      // 清单比上限长时如实说明：截断是防地址风暴的设计，但不该让用户以为漏导入。
      final probe = SourceSubscription.urlsIn(raw, limit: widget.maxScripts + 1);
      if (probe.length > widget.maxScripts) {
        notes.add('清单较长，本次只处理前 ${widget.maxScripts} 条地址。');
      }
    }

    if (items.isEmpty && urls.isEmpty) {
      // 一条都进不了链路：把原因留在弹窗里（进结果弹窗只会让用户多点两次）。
      setState(() {
        _error = skipped.isEmpty
            ? '请选择本地文件、粘贴脚本内容，或填写订阅地址'
            : skipped.first.message;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
      _progress = null;
    });
    try {
      if (urls.isNotEmpty) {
        final scripts = await _resolve(urls);
        if (!mounted) return;
        if (scripts.isEmpty) {
          // 清单拉完一条脚本也没有（互相引用的清单、空清单）：说清楚，不静默收场。
          setState(() {
            _error = '订阅里没有可导入的源脚本';
            _progress = null;
          });
          return;
        }
        for (final script in scripts) {
          items.add(
            SourceImportItem(script: script, label: '订阅', originUrl: urls.first),
          );
        }
      }
      if (items.isEmpty) {
        // 只剩认不出的条目：原因留在弹窗里，进结果弹窗只会让用户多点两次。
        setState(() {
          _error = skipped.first.message;
          _progress = null;
        });
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        SourceImportRequest(
          section: _section,
          items: items,
          skipped: skipped,
          notes: notes,
        ),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _error = '订阅拉取失败：$error';
        _progress = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 逐个拉取订阅地址：正文是脚本就收下；正文是 `.js.md5` 校验值就按约定取脚本
  /// 实体并核对校验；正文是「一行一个地址」的清单时再逐个拉一层。
  ///
  /// 解析逻辑在 [SourceSubscription]（与「更新订阅源」共用同一份实现）；
  /// 这里额外包一层计数，只为在弹窗里显示「正在拉取第 N 个地址」。
  Future<List<String>> _resolve(List<String> urls) {
    var fetches = 0;
    final fetch = widget.fetchSubscription ?? _fetchSubscriptionText;
    return SourceSubscription(
      maxScripts: widget.maxScripts,
      fetch: (url) async {
        fetches++;
        if (mounted) setState(() => _progress = '正在拉取第 $fetches 个地址…');
        return fetch(url);
      },
    ).resolve(urls);
  }

  /// 默认订阅拉取：走宿主网络层（统一 UA），与图源请求同一出口。
  static Future<SourceFetchResult> _fetchSubscriptionText(String url) async {
    final http = LumeHttp();
    try {
      final response = await http.send(url: url);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }
      return SourceFetchResult(
        bytes: response.body,
        text: stripScriptBom(response.text),
      );
    } finally {
      http.dispose();
    }
  }
}
