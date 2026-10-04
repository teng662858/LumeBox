import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/js/source_script.dart';
import '../../core/net/lume_http.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';

/// 板块页右上角的「+」添加图源按钮（小说 / 漫画 / 视频 / 猫源统一入口）。
///
/// 弹窗提供两种导入方式，导入的图源一律归属当前板块：
/// - 本地导入：挑本地 `.js` 脚本文件（也接受直接把脚本粘贴进来）；
/// - 订阅链接：填入远程订阅地址，经宿主网络层拉取在线图源脚本。
///
/// 文本口径与注册表一致：读进来的脚本先剥掉 UTF-8 BOM（[stripScriptBom]）
/// 再交给 [SourceManager.importScript]，带 BOM 的合法脚本不会误报缺少元信息。
///
/// 隔离：按钮绑定一个板块，只写本板块的库，不提供任何跨板块入口。
class AddSourceButton extends StatelessWidget {
  const AddSourceButton({
    super.key,
    required this.section,
    this.manager,
    this.onImported,
    this.readLocalScript,
    this.fetchSubscription,
  });

  /// 目标板块。图源只写入本板块。
  final Section section;

  /// 图源管理端口；为空时用本板块的正式实现。
  final SourceManager? manager;

  /// 导入全部结束且至少成功一条时回调（板块页据此刷新自己的列表 / 状态）。
  final VoidCallback? onImported;

  /// 本地脚本读取端口（测试注入）；为空时弹系统文件选择器。
  final Future<({String name, String text})?> Function()? readLocalScript;

  /// 订阅拉取端口（测试注入）；为空时经 [LumeHttp]（宿主网络层）拉取。
  final Future<String> Function(String url)? fetchSubscription;

  /// 单次订阅最多导入的脚本条数（订阅文本按「一行一个地址」解释时）。
  /// 上限是为了让误填的地址不会把批量导入变成不可控的请求风暴。
  static const int maxSubscriptionScripts = 20;

  /// 文件选择器的可选项：iOS 只认 UTI、Windows 只认扩展名，两边都给。
  /// 末项 `public.data` 是对未登记脚本扩展名的兜底（宁可多显示，不可选不中）。
  static const XTypeGroup _scriptTypeGroup = XTypeGroup(
    label: '图源脚本',
    extensions: <String>['js', 'md5', 'txt'],
    uniformTypeIdentifiers: <String>[
      'com.netscape.javascript-source',
      'public.plain-text',
      'public.data',
    ],
  );

  @override
  Widget build(BuildContext context) {
    final target = manager ?? LumeSources.manager(section);
    // 平台边界：没有图源运行时的平台（Android / Windows）没有可导入的目标，
    // 与板块页的骨架占位同一口径——按钮不出现。
    if (!target.runtimeAvailable) return const SizedBox.shrink();
    return IconButton(
      tooltip: '添加图源',
      icon: const Icon(Icons.add),
      onPressed: () => _open(context, target),
    );
  }

  Future<void> _open(BuildContext context, SourceManager target) async {
    final scripts = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AddSourceDialog(
        section: section,
        readLocalScript: readLocalScript ?? _readLocalScript,
        fetchSubscription: fetchSubscription ?? _fetchSubscriptionText,
        maxScripts: maxSubscriptionScripts,
      ),
    );
    if (scripts == null || scripts.isEmpty || !context.mounted) return;

    // 已有图源：用于把提示分成「已导入」与「已更新」两种口径。
    final existing = <String>{};
    try {
      for (final source in await target.list()) {
        existing.add(source.id);
      }
    } catch (error, stackTrace) {
      // 列表读不到不影响导入本身，最坏情况是把「已更新」说成「已导入」。
      LumeLog.error(error, stackTrace);
    }

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final messages = <String>[];
    var succeeded = false;
    for (final script in scripts) {
      final result = await target.importScript(stripScriptBom(script));
      final descriptor = result.descriptor;
      if (descriptor == null) {
        messages.add('导入失败：${result.message}');
        continue;
      }
      succeeded = true;
      messages.add(
        existing.contains(descriptor.id)
            ? '已更新：${descriptor.name}'
            : '已导入：${descriptor.name}',
      );
    }
    messenger.showSnackBar(SnackBar(content: Text(messages.join('\n'))));
    if (succeeded) onImported?.call();
  }

  /// 默认本地读取：系统文件选择器 → 字节 → UTF-8 解码 → 剥 BOM。
  static Future<({String name, String text})?> _readLocalScript() async {
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[_scriptTypeGroup],
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    // 文件常带 UTF-8 BOM（EF BB BF）：解码后先剥掉再交出文本。
    final text = stripScriptBom(utf8.decode(bytes, allowMalformed: true));
    return (name: file.name, text: text);
  }

  /// 默认订阅拉取：走宿主网络层（统一 UA），与图源请求同一出口。
  static Future<String> _fetchSubscriptionText(String url) async {
    final http = LumeHttp();
    try {
      final response = await http.send(url: url);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }
      return stripScriptBom(response.text);
    } finally {
      http.dispose();
    }
  }
}

enum _ImportMode { local, subscription }

/// 添加图源弹窗：本地脚本 / 订阅链接两种方式，成功后带着脚本清单关闭。
class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({
    required this.section,
    required this.readLocalScript,
    required this.fetchSubscription,
    required this.maxScripts,
  });

  final Section section;
  final Future<({String name, String text})?> Function() readLocalScript;
  final Future<String> Function(String url) fetchSubscription;
  final int maxScripts;

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final TextEditingController _script = TextEditingController();
  final TextEditingController _url = TextEditingController();

  _ImportMode _mode = _ImportMode.local;

  /// 已选中的本地文件名（只用于展示，脚本文本在输入框里）。
  String? _fileName;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _script.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('添加图源 · ${widget.section.label}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '图源只写入当前板块，不会跨板块共用。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 12),
              SegmentedButton<_ImportMode>(
                segments: const <ButtonSegment<_ImportMode>>[
                  ButtonSegment<_ImportMode>(
                    value: _ImportMode.local,
                    icon: Icon(Icons.description_outlined),
                    label: Text('本地脚本'),
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
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFFF8A80),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
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

  List<Widget> _buildLocal() => <Widget>[
        Row(
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _pickLocal,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('选择本地 .js 文件'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : _loadBuiltin,
              child: const Text('载入内置示例'),
            ),
          ],
        ),
        if (_fileName != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '已选择：$_fileName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _script,
          maxLines: 6,
          enabled: !_busy,
          decoration: const InputDecoration(
            hintText: '或直接粘贴图源脚本内容',
            border: OutlineInputBorder(),
          ),
        ),
      ];

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
        const Text(
          '订阅返回单个脚本时直接导入；返回「一行一个脚本地址」的清单时逐个拉取。',
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
      ];

  void _submit() {
    if (_mode == _ImportMode.subscription) {
      _pullSubscription();
      return;
    }
    final text = stripScriptBom(_script.text);
    if (text.trim().isEmpty) {
      setState(() => _error = '请粘贴脚本内容或选择本地文件');
      return;
    }
    Navigator.of(context).pop(<String>[text]);
  }

  /// 内置示例脚本：新用户先跑通「导入 → 浏览」这套动作的最低门槛。
  Future<void> _loadBuiltin() async {
    final text = await rootBundle.loadString('assets/js/example_source.js');
    if (!mounted) return;
    setState(() {
      _fileName = null;
      _script.text = text;
      _error = null;
    });
  }

  Future<void> _pickLocal() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await widget.readLocalScript();
      if (!mounted) return;
      // 用户取消选择：保持原状，不算错误。
      if (picked == null) return;
      setState(() {
        _fileName = picked.name;
        _script.text = picked.text;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '读取文件失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pullSubscription() async {
    final urls = _urlsIn(_url.text, limit: widget.maxScripts);
    if (urls.isEmpty) {
      setState(() => _error = '请填写 http / https 订阅地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scripts = await _collect(urls);
      if (!mounted) return;
      if (scripts.isEmpty) {
        setState(() => _error = '订阅里没有可导入的图源脚本');
        return;
      }
      Navigator.of(context).pop(scripts);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '订阅拉取失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 逐个拉取订阅地址：正文是脚本就收下；正文是「一行一个地址」的清单时，
  /// 再把清单里的地址拉一层（总条数不超过 [AddSourceButton.maxSubscriptionScripts]）。
  Future<List<String>> _collect(List<String> urls) async {
    final scripts = <String>[];
    for (final url in urls) {
      final body = stripScriptBom(await widget.fetchSubscription(url));
      if (_looksLikeScript(body)) {
        scripts.add(body);
        continue;
      }
      final nested = _urlsIn(
        body,
        limit: widget.maxScripts - scripts.length,
      );
      for (final url in nested) {
        final text = stripScriptBom(await widget.fetchSubscription(url));
        if (_looksLikeScript(text)) scripts.add(text);
      }
    }
    return scripts;
  }

  /// 从文本里挑出 http(s) 地址：一行一个，忽略空行与 `#` 开头的注释行。
  ///
  /// 订阅文本本身就是脚本（含 `LumeSource`）时不算地址清单。
  static List<String> _urlsIn(String text, {required int limit}) {
    if (limit <= 0 || _looksLikeScript(text)) return const <String>[];
    final urls = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (!_isHttpUrl(trimmed)) continue;
      urls.add(trimmed);
      if (urls.length >= limit) break;
    }
    return urls;
  }

  /// 是不是图源脚本：认头部元信息声明，也认脚本里的 `LumeSource` 全局对象。
  static bool _looksLikeScript(String text) =>
      SourceMetadata.parseHeader(text) != null || text.contains('LumeSource');

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}
