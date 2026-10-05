import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'source_form.dart';

/// 图源可视化编辑器：**表单模式**填写 → 生成规范脚本 → **高级模式**手改 → 导入。
///
/// 定位（见 [SourceFormDraft] 的说明）：它是「新建图源的脚手架」，不是任意脚本的
/// 解析器。表单能生成一份能跑的函数式图源脚本；生成后可以继续在高级模式里手改。
/// 手改过的脚本反解不回表单（会提示），此时只有高级模式——不假装能还原。
///
/// 与导入链路的关系：生成 / 手改后的脚本交给 [SourceManager.importScript]，
/// 走的是与「+ 添加图源」完全相同的校验路径（脚本载入 → 元信息 → 落库）。
class SourceEditorPage extends StatefulWidget {
  const SourceEditorPage({
    super.key,
    required this.section,
    this.manager,
    this.initialScript,
  });

  final Section section;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  /// 初始脚本（从某图源「编辑」进来时带入）。
  final String? initialScript;

  @override
  State<SourceEditorPage> createState() => _SourceEditorPageState();
}

class _SourceEditorPageState extends State<SourceEditorPage> {
  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  late SourceFormDraft _draft;
  late final TextEditingController _script;

  /// 表单 / 高级模式。
  bool _formMode = true;

  /// 高级模式下脚本被手改过：反解回表单会丢改动，因此禁用表单模式。
  bool _scriptDirty = false;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialScript;
    _draft = (initial == null ? null : SourceFormDraft.parse(initial)) ??
        const SourceFormDraft();
    _script = TextEditingController(text: initial ?? _draft.buildScript());
    if (initial != null) _formMode = false;
  }

  @override
  void dispose() {
    _script.dispose();
    _manager.close();
    super.dispose();
  }

  /// 表单改动：同步重生成脚本（表单是脚本的来源）。
  void _updateDraft(SourceFormDraft next) {
    setState(() {
      _draft = next;
      _script.text = next.buildScript();
      _scriptDirty = false;
    });
  }

  void _switchToForm() {
    if (_scriptDirty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('脚本已手动修改，切回表单会丢失这些改动'),
        ),
      );
      return;
    }
    final parsed = SourceFormDraft.parse(_script.text);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这份脚本不是编辑器生成的，只能继续用高级模式')),
      );
      return;
    }
    setState(() {
      _draft = parsed;
      _formMode = true;
    });
  }

  /// 导入：走与「+ 添加图源」相同的校验路径。
  Future<void> _import() async {
    final issue = _formMode ? _draft.validate() : null;
    if (issue != null) {
      setState(() => _error = issue);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _manager.importScript(_script.text);
      if (!mounted) return;
      if (!result.isSuccess) {
        setState(() => _error = result.message ?? '导入失败');
        return;
      }
      if (!mounted) return;
      final navigator = Navigator.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入：${result.descriptor!.name}')),
      );
      navigator.pop(true);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 复制脚本全文（剪贴板是异步的，单独抽出来避免跨 async 用 context）。
  Future<void> _copyScript(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _script.text));
    messenger.showSnackBar(
      const SnackBar(content: Text('已复制脚本全文')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: '${widget.section.label} · 图源编辑器',
      actions: <Widget>[
        IconButton(
          tooltip: '复制脚本',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: () => _copyScript(context),
        ),
        TextButton(
          onPressed: _busy ? null : _import,
          child: Text(_busy ? '导入中…' : '导入'),
        ),
      ],
      child: Column(
        children: <Widget>[
          _buildModeBar(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A80)),
              ),
            ),
          Expanded(
            child: _formMode ? _buildForm() : _buildScriptEditor(),
          ),
        ],
      ),
    );
  }

  Widget _buildModeBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: true, label: Text('表单')),
              ButtonSegment<bool>(value: false, label: Text('高级（脚本）')),
            ],
            selected: <bool>{_formMode},
            onSelectionChanged: (values) {
              final wantForm = values.first;
              if (wantForm) {
                _switchToForm();
              } else {
                setState(() => _formMode = false);
              }
            },
          ),
          const Spacer(),
          Text(
            _formMode ? '改表单即时生成脚本' : '直接编辑脚本',
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 表单

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Label('基本信息'),
              _text(
                label: '图源 id',
                value: _draft.id,
                hint: '字母数字与 - _，例如 my-site',
                onChanged: (value) => _updateDraft(_draft.copyWith(id: value)),
              ),
              _text(
                label: '图源名称',
                value: _draft.name,
                hint: '显示在列表里的名字',
                onChanged: (value) => _updateDraft(_draft.copyWith(name: value)),
              ),
              _text(
                label: '版本',
                value: _draft.version,
                hint: '1.0.0',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(version: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Label('接口'),
              _text(
                label: '站点地址',
                value: _draft.baseUrl,
                hint: 'https://example.com',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(baseUrl: value)),
              ),
              _text(
                label: '列表路径',
                value: _draft.listPath,
                hint: '/api/list',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(listPath: value)),
              ),
              _text(
                label: '详情路径',
                value: _draft.detailPath,
                hint: '/api/detail',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(detailPath: value)),
              ),
              _text(
                label: '搜索参数名',
                value: _draft.searchKeywordParam,
                hint: 'wd',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(searchKeywordParam: value)),
              ),
              _text(
                label: '页码参数名',
                value: _draft.pageParam,
                hint: 'page',
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(pageParam: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Label('解析'),
              const Text(
                '列表来源',
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final template in SourceListTemplate.values)
                    ChoiceChip(
                      label: Text(template.label),
                      selected: _draft.listTemplate == template,
                      onSelected: (_) =>
                          _updateDraft(_draft.copyWith(listTemplate: template)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_draft.listTemplate == SourceListTemplate.json) ...<Widget>[
                _text(
                  label: '列表字段路径',
                  value: _draft.jsonListField,
                  hint: 'data.list（留空 = 响应本身就是数组）',
                  onChanged: (value) =>
                      _updateDraft(_draft.copyWith(jsonListField: value)),
                ),
                _text(
                  label: '标题字段',
                  value: _draft.jsonTitleField,
                  hint: 'title',
                  onChanged: (value) =>
                      _updateDraft(_draft.copyWith(jsonTitleField: value)),
                ),
                _text(
                  label: 'id 字段',
                  value: _draft.jsonIdField,
                  hint: 'id',
                  onChanged: (value) =>
                      _updateDraft(_draft.copyWith(jsonIdField: value)),
                ),
                _text(
                  label: '封面字段',
                  value: _draft.jsonCoverField,
                  hint: 'cover',
                  onChanged: (value) =>
                      _updateDraft(_draft.copyWith(jsonCoverField: value)),
                ),
              ] else
                const Text(
                  'HTML 模式用内置正则抓取页面里的链接（<a href>），'
                  '生成后可在高级模式里按站点结构调整。',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              const SizedBox(height: 12),
              _text(
                label: '附加请求头',
                value: _draft.headers,
                hint: '每行一条，例如：Referer: https://example.com',
                maxLines: 3,
                onChanged: (value) =>
                    _updateDraft(_draft.copyWith(headers: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Label('生成的脚本预览'),
              SizedBox(
                height: 220,
                child: SingleChildScrollView(
                  child: SelectableText(
                    _script.text,
                    style: const TextStyle(fontSize: 11, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _text({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextFormField(
        initialValue: value,
        maxLines: maxLines,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  // ------------------------------------------------------------ 高级模式

  Widget _buildScriptEditor() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _script,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontSize: 12, height: 1.4, fontFamily: 'monospace'),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: '图源脚本（函数式契约：getList / getDetail / getChapters / getContent）',
        ),
        onChanged: (_) {
          if (!_scriptDirty) setState(() => _scriptDirty = true);
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      );
}
