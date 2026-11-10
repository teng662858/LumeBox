import 'package:flutter/material.dart';

/// Commit once after editing, rather than writing settings on every slider tick.
class NumberSettingTile extends StatelessWidget {
  const NumberSettingTile({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
  });
  final String title, unit;
  final int value, min, max;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text('$min～$max $unit'),
    trailing: Text('$value $unit'),
    enabled: onChanged != null,
    onTap: onChanged == null
        ? null
        : () async {
            var draft = '$value';
            String? error;
            final result = await showDialog<int>(
              context: context,
              builder: (context) => StatefulBuilder(
                builder: (context, update) => AlertDialog(
                  title: Text(title),
                  content: TextFormField(
                    initialValue: draft,
                    onChanged: (v) => draft = v,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '$min～$max $unit',
                      errorText: error,
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final n = int.tryParse(draft.trim());
                        if (n == null || n < min || n > max) {
                          update(() => error = '请输入 $min～$max 的整数');
                        } else {
                          Navigator.pop(context, n);
                        }
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
            );
            if (result != null) onChanged?.call(result);
          },
  );
}
