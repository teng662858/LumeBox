import 'package:flutter/material.dart';

import '../../core/source/source_extension_settings.dart';

class SourceRouteEditor extends StatelessWidget {
  const SourceRouteEditor({
    super.key,
    required this.title,
    required this.route,
    required this.onChanged,
    this.error,
    this.compact = false,
  });
  final String title;
  final SourceRoute route;
  final ValueChanged<SourceRoute> onChanged;
  final String? error;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    if (compact) {
      final summary = route.custom.isNotEmpty
          ? '自定义地址'
          : route.resolved.isEmpty
          ? '默认线路'
          : route.labels[route.selectedUrl] ?? route.selectedUrl;
      return ExpansionTile(
        key: ValueKey(error != null),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          '$title · $summary',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        initiallyExpanded: route.custom.isNotEmpty || error != null,
        children: [
          SourceRouteEditor(
            title: title,
            route: route,
            onChanged: onChanged,
            error: error,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
        ],
        if (route.urls.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey('$title:${route.selectedUrl}'),
            initialValue: route.selectedUrl,
            isExpanded: true,
            decoration: InputDecoration(labelText: '$title线路'),
            items: [
              for (var i = 0; i < route.urls.length; i++)
                DropdownMenuItem(
                  value: route.urls[i],
                  child: Text(
                    '${i == 0 ? '默认 · ' : ''}${route.labels[route.urls[i]] ?? route.urls[i]}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(route.copyWith(selected: v));
            },
          )
        else
          const Text('源未提供备选线路；可填写自定义地址供支持此设置的源使用。'),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: route.custom,
          decoration: InputDecoration(
            labelText: '自定义$title地址（填了优先）',
            hintText: 'https://cdn.example.com/资源路径',
            errorText: error,
          ),
          onChanged: (v) => onChanged(route.copyWith(custom: v)),
        ),
        const SizedBox(height: 6),
        Text('当前生效：${route.resolved.isEmpty ? '沿用源默认地址' : route.resolved}'),
      ],
    );
  }
}

class SourceExtensionEditor extends StatefulWidget {
  const SourceExtensionEditor({
    super.key,
    required this.definitions,
    required this.initialValues,
    required this.onChanged,
    this.onAction,
    this.actionHeading,
  });
  final List<SourceSetting> definitions;
  final Map<String, Object?> initialValues;
  final ValueChanged<Map<String, Object?>> onChanged;

  /// A single host action can share a compact row with its section heading.
  final String? actionHeading;
  final Future<String> Function(
    SourceSetting,
    Map<String, Object?>,
    Map<String, Object?>,
  )?
  onAction;
  @override
  State<SourceExtensionEditor> createState() => _SourceExtensionEditorState();
}

class _SourceExtensionEditorState extends State<SourceExtensionEditor> {
  late final values = Map<String, Object?>.of(widget.initialValues);
  String? busy, status;
  void changed(SourceSetting field, Object? value) {
    setState(() => values[field.key] = value);
    widget.onChanged(Map.of(values));
  }

  Future<void> act(SourceSetting field) async {
    if (busy != null) return;
    for (final d in widget.definitions) {
      final error = d.valueIssue(values[d.key] ?? d.fallback);
      if (error != null) {
        setState(() => status = '${d.title}：$error');
        return;
      }
    }
    setState(() {
      busy = field.key;
      status = null;
    });
    try {
      final inputs = field.inputs.isEmpty
          ? <String, Object?>{}
          : await _requestInputs(field);
      if (inputs == null || !mounted) return;
      final message = await widget.onAction!(field, Map.of(values), inputs);
      if (mounted) setState(() => status = message);
    } catch (_) {
      if (mounted) setState(() => status = '操作失败，请检查源设置和网络后重试');
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<Map<String, Object?>?> _requestInputs(SourceSetting action) async {
    var input = <String, Object?>{
      for (final f in action.inputs) f.key: f.fallback,
    };
    String? error;
    return showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(action.title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SourceExtensionEditor(
                  definitions: action.inputs,
                  initialValues: input,
                  onChanged: (v) => input = v,
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                for (final f in action.inputs) {
                  final issue = f.valueIssue(input[f.key]);
                  if (issue != null) {
                    update(() => error = '${f.title}：$issue');
                    return;
                  }
                }
                Navigator.pop(context, input);
              },
              child: const Text('执行'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < widget.definitions.length; i++) ...[
        if (widget.definitions[i].group.isNotEmpty &&
            (i == 0 ||
                widget.definitions[i - 1].group != widget.definitions[i].group))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.definitions[i].group,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        Padding(
          key: ValueKey(widget.definitions[i].key),
          padding: EdgeInsets.only(
            bottom: widget.actionHeading == null ? 12 : 0,
          ),
          child: field(widget.definitions[i]),
        ),
      ],
      if (status != null) Text(status!),
    ],
  );
  Widget field(SourceSetting d) {
    final value = values[d.key] ?? d.fallback;
    switch (d.type) {
      case 'toggle':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(d.title),
          subtitle: d.description.isEmpty ? null : Text(d.description),
          value: value == true,
          onChanged: (v) => changed(d, v),
        );
      case 'select':
        return DropdownButtonFormField<String>(
          initialValue: '$value',
          isExpanded: true,
          decoration: InputDecoration(
            labelText: d.title,
            hintText: d.placeholder.isEmpty ? null : d.placeholder,
            helperText: d.description.isEmpty ? null : d.description,
          ),
          items: [
            for (final o in d.options.entries)
              DropdownMenuItem(value: o.key, child: Text(o.value)),
          ],
          onChanged: (v) => changed(d, v),
        );
      case 'number':
      case 'text':
        return TextFormField(
          initialValue: '$value',
          obscureText:
              d.type == 'text' &&
              RegExp(
                r'password|passwd|secret|token|cookie|pwd',
                caseSensitive: false,
              ).hasMatch(d.key),
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: d.title,
            hintText: d.placeholder.isEmpty ? null : d.placeholder,
            helperText: d.description.isEmpty ? null : d.description,
          ),
          keyboardType: d.type == 'number'
              ? const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                )
              : TextInputType.text,
          maxLength: d.type == 'text' ? d.maxLength : null,
          onChanged: (v) =>
              changed(d, d.type == 'number' ? num.tryParse(v) ?? v : v),
        );
      case 'info':
        // SelectableText：说明里常写发布页/备用地址，用户要能长按复制。
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(d.title),
          subtitle: SelectableText(d.description),
        );
      case 'action':
        final button = OutlinedButton(
          onPressed: busy != null || widget.onAction == null
              ? null
              : () => act(d),
          child: Text(busy == d.key ? '处理中…' : d.title),
        );
        if (widget.actionHeading != null) {
          return Row(
            children: [
              Expanded(
                child: Text(
                  widget.actionHeading!,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Tooltip(message: d.description, child: button),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [button, if (d.description.isNotEmpty) Text(d.description)],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
