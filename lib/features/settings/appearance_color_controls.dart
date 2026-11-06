import 'package:flutter/material.dart';

import '../../core/theme/appearance.dart';
import '../../shared/widgets/glass_card.dart';
import 'custom_accent_picker.dart';

class BackgroundColorControls extends StatelessWidget {
  const BackgroundColorControls({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = AppearanceController.instance;
    final settings = controller.settings;
    Widget picker(Brightness brightness, String title) {
      final color = settings.backgroundColorFor(brightness);
      final hex = (color.toARGB32() & 0xffffff)
          .toRadixString(16)
          .padLeft(6, '0')
          .toUpperCase();
      return ListTile(
        key: ValueKey('background-${brightness.name}'),
        title: Text(title),
        subtitle: Text('#$hex'),
        trailing: CircleAvatar(backgroundColor: color, radius: 15),
        onTap: () async {
          final selected = await showCustomAccentPicker(context, color);
          if (selected == null) return;
          controller.apply(
            brightness == Brightness.light
                ? controller.settings.copyWith(
                    lightBackgroundArgb: selected.toARGB32(),
                  )
                : controller.settings.copyWith(
                    darkBackgroundArgb: selected.toARGB32(),
                  ),
          );
        },
      );
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          picker(Brightness.light, '浅色页面底色'),
          picker(Brightness.dark, '深色页面底色'),
          const SizedBox(height: 8),
          const Text('深色快捷配色'),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in [
                (0xFF121214, '石墨黑'),
                (0xFF000000, '纯黑'),
                (0xFF101A26, '深海蓝'),
              ])
                ChoiceChip(
                  label: Text(entry.$2),
                  selected: settings.darkBackgroundArgb == entry.$1,
                  onSelected: (_) => controller.apply(
                    controller.settings.copyWith(darkBackgroundArgb: entry.$1),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '底色分别随浅色／深色模式生效。颜色会保持对应明暗范围，避免文字看不清；阅读器的纸张颜色保持独立。',
            style: TextStyle(fontSize: 12),
          ),
          TextButton(
            onPressed: () => controller.apply(
              controller.settings.copyWith(
                resetLightBackground: true,
                resetDarkBackground: true,
              ),
            ),
            child: const Text('恢复默认底色'),
          ),
        ],
      ),
    );
  }
}

class SavedAppearancePalettesCard extends StatelessWidget {
  const SavedAppearancePalettesCard({super.key});
  Future<void> _save(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PaletteNameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      AppearanceController.instance.savePalette(name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceController.instance;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('我的配色方案', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text(
            '保存主题色、浅深底色和封面配色偏好；不改变字体或外观模式。同名保存会更新该方案。',
            style: TextStyle(fontSize: 12),
          ),
          for (final palette in controller.settings.savedPalettes)
            ListTile(
              key: ValueKey('saved-palette-${palette.name}'),
              contentPadding: EdgeInsets.zero,
              title: Text(palette.name),
              subtitle: const Text('点按应用配色'),
              onTap: () => controller.applyPalette(palette),
              trailing: IconButton(
                tooltip: '删除配色 ${palette.name}',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => controller.removePalette(palette.name),
              ),
            ),
          OutlinedButton.icon(
            key: const Key('save-appearance-palette'),
            onPressed: () => _save(context),
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('保存当前配色'),
          ),
        ],
      ),
    );
  }
}

class _PaletteNameDialog extends StatefulWidget {
  const _PaletteNameDialog();
  @override
  State<_PaletteNameDialog> createState() => _PaletteNameDialogState();
}

class _PaletteNameDialogState extends State<_PaletteNameDialog> {
  final _name = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保存配色方案'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 32,
      decoration: const InputDecoration(labelText: '方案名称'),
      onChanged: (_) => setState(() {}),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _name.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}
