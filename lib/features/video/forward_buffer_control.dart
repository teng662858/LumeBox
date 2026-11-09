import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/session/section_module_settings.dart';
import 'danmaku/danmaku_panel.dart';

class ForwardBufferControl extends StatelessWidget {
  const ForwardBufferControl({
    super.key,
    required this.seconds,
    required this.onChanged,
  });

  final int seconds;
  final ValueChanged<int> onChanged;

  Future<void> _edit(BuildContext context) async {
    final form = GlobalKey<FormState>();
    var input = '$seconds';
    final result = await showPlayerDialog<int>(
      context: context,
      onlyInPlayer: true,
      builder: (context) {
        void submit() {
          if (form.currentState?.validate() ?? false) {
            Navigator.pop(context, int.parse(input));
          }
        }

        return AlertDialog(
          title: const Text('前向缓冲'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: input,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '秒数',
                helperText: '0 使用默认预读 120 秒',
              ),
              onChanged: (value) => input = value,
              onFieldSubmitted: (_) => submit(),
              validator: (value) {
                final parsed = int.tryParse(value ?? '');
                if (parsed == null || parsed < 0) return '请输入非负整数';
                if (parsed > SectionModuleSettings.maxBufferSeconds) {
                  return '秒数超出可表示范围';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(onPressed: submit, child: const Text('保存')),
          ],
        );
      },
    );
    if (context.mounted && result != null && result != seconds) {
      onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => _edit(context),
    child: Text(seconds == 0 ? '默认（120 秒）' : '$seconds 秒'),
  );
}
