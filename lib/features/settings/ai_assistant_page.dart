import 'package:flutter/material.dart';

import '../../core/translation/ai_assistant.dart';
import '../../shared/widgets/glass_card.dart';
import 'global_translation_settings_page.dart';

/// Requests are user initiated. Returned scripts remain drafts until imported.
class AiAssistantPage extends StatefulWidget {
  const AiAssistantPage({
    super.key,
    required this.title,
    required this.instruction,
    required this.input,
    this.applyScript = false,
  });
  final String title, instruction, input;
  final bool applyScript;
  @override
  State<AiAssistantPage> createState() => _AiAssistantPageState();
}

class _AiAssistantPageState extends State<AiAssistantPage> {
  final problem = TextEditingController();
  String? output, error;
  bool busy = false;
  @override
  void dispose() {
    problem.dispose();
    super.dispose();
  }

  Future<void> run() async {
    setState(() {
      busy = true;
      error = null;
      output = null;
    });
    try {
      final value = await AiAssistant.request(
        widget.instruction,
        '${problem.text}\n\n${widget.input}',
      );
      if (mounted) setState(() => output = value);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'AI 请求未完成，请检查网络和接口设置后重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: widget.title,
    child: ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        GlassScaffold.barHeight(context) + 16,
        16,
        24,
      ),
      children: [
        const Text('使用全局翻译中配置的 AI 接口、模型和密钥。点击发送会将下方内容及问题描述发送到该服务。'),
        TextButton(
          onPressed: busy
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const GlobalTranslationSettingsPage(),
                  ),
                ),
          child: const Text('AI 接口设置'),
        ),
        TextField(
          controller: problem,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '问题描述 / 修复要求'),
        ),
        ExpansionTile(
          title: const Text('查看将发送的内容'),
          children: [SelectableText(widget.input)],
        ),
        FilledButton(
          onPressed: busy ? null : run,
          child: Text(busy ? '正在分析…' : '发送并分析'),
        ),
        if (error != null) Text(error!),
        if (output != null) ...[
          SelectableText(output!),
          if (widget.applyScript)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, AiAssistant.script(output!)),
              child: const Text('采用为编辑草稿'),
            ),
        ],
      ],
    ),
  );
}
