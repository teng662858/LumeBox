import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/theme/appearance.dart';
import '../../core/theme/user_fonts.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({super.key, this.fonts, this.pickFont});
  final UserFonts? fonts;
  final Future<XFile?> Function()? pickFont;
  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  UserFonts get _fonts => widget.fonts ?? UserFonts.instance;
  final _appearance = AppearanceController.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _fonts.boot();
    if (mounted) setState(() {});
  }

  void _message(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file =
          await (widget.pickFont?.call() ??
              openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(
                    label: '字体文件',
                    extensions: ['ttf', 'otf', 'ttc'],
                    uniformTypeIdentifiers: ['public.font'],
                  ),
                ],
              ));
      if (file == null || !mounted) return;
      final font = await _fonts.importFile(file);
      if (mounted) {
        _appearance.apply(_appearance.settings.copyWith(fontId: font.id));
      }
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(UserFont font) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await _fonts.ensureLoaded(font.id)) {
        if (mounted) {
          _appearance.apply(_appearance.settings.copyWith(fontId: font.id));
        }
      } else {
        _message('字体不可用，请重新导入；当前使用系统字体。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(UserFont font) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本机字体？'),
        content: Text(font.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    try {
      await _fonts.remove(font.id);
      if (_appearance.settings.fontId == font.id) {
        _appearance.apply(_appearance.settings.copyWith(fontId: ''));
      }
    } catch (error) {
      _message(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_appearance, _fonts]),
    builder: (context, _) {
      final settings = _appearance.settings;
      final selected = _fonts.familyFor(settings.fontId) == null
          ? ''
          : settings.fontId;
      void apply(AppearanceSettings value) => _appearance.apply(value);
      return GlassScaffold(
        title: '字体与字号',
        actions: [
          IconButton(
            tooltip: '导入字体文件',
            onPressed: _busy ? null : _import,
            icon: const LumeIcon(Icons.add, slot: 'font_settings_page.1'),
          ),
        ],
        child: ListView(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.fromLTRB(16, 8, 16, 32)),
          children: [
            const SettingsGroupTitle('字号', topPadding: 0),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '山间来信 · A quiet afternoon.\n预览字体大小',
                    key: Key('fonts.preview'),
                    style: TextStyle(fontSize: 16, height: 1.6),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Text('A', style: TextStyle(fontSize: 12)),
                      Expanded(
                        child: Slider(
                          key: const Key('fonts.scale'),
                          value: settings.textScale.clamp(.7, 1.6),
                          min: .7,
                          max: 1.6,
                          divisions: 18,
                          semanticFormatterCallback: (v) =>
                              '${(v * 100).round()}%',
                          onChanged: (value) =>
                              apply(settings.copyWith(textScale: value)),
                        ),
                      ),
                      const Text('A', style: TextStyle(fontSize: 22)),
                    ],
                  ),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    children: [
                      Text(
                        '当前 ${(settings.textScale * 100).round()}%',
                        key: const Key('fonts.scaleLabel'),
                      ),
                      TextButton(
                        onPressed: () => apply(settings.copyWith(textScale: 1)),
                        child: const Text('恢复 100%'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 10, 6, 20),
              child: Text(
                '仅调整文字大小，播放器等页面的文字也会生效。图标、按钮尺寸和页面留白不随此滑杆缩放。',
                style: TextStyle(fontSize: 12, color: settingsNoteColor),
              ),
            ),
            const SettingsGroupTitle('字形'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('普通'),
                    trailing: !settings.fontBold
                        ? const LumeIcon(
                            Icons.check,
                            slot: 'font_settings_page.2',
                          )
                        : null,
                    onTap: () => apply(settings.copyWith(fontBold: false)),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    title: const Text('粗体'),
                    subtitle: const Text('默认'),
                    trailing: settings.fontBold
                        ? const LumeIcon(
                            Icons.check,
                            slot: 'font_settings_page.3',
                          )
                        : null,
                    onTap: () => apply(settings.copyWith(fontBold: true)),
                  ),
                  const Divider(height: 1, indent: 56),
                  SwitchListTile(
                    title: const Text('斜体'),
                    value: settings.fontItalic,
                    onChanged: (value) =>
                        apply(settings.copyWith(fontItalic: value)),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 10, 6, 20),
              child: Text(
                '普通会减轻界面主题中的标题与按钮字重，斜体可叠加。阅读正文仍保留阅读器自身的排版设置。',
                style: TextStyle(fontSize: 12, color: settingsNoteColor),
              ),
            ),
            const SettingsGroupTitle('字体'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('系统默认'),
                    trailing: selected.isEmpty
                        ? const LumeIcon(
                            Icons.check,
                            slot: 'font_settings_page.4',
                          )
                        : null,
                    onTap: () => apply(settings.copyWith(fontId: '')),
                  ),
                  for (final font in _fonts.fonts)
                    ListTile(
                      key: ValueKey('fonts.${font.id}'),
                      title: Text(font.name),
                      subtitle: const Text('长按删除'),
                      trailing: selected == font.id
                          ? const LumeIcon(
                              Icons.check,
                              slot: 'font_settings_page.5',
                            )
                          : null,
                      onTap: _busy ? null : () => _choose(font),
                      onLongPress: _busy ? null : () => _remove(font),
                    ),
                  ListTile(
                    leading: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const LumeIcon(
                            Icons.add_circle_outline,
                            slot: 'font_settings_page.6',
                          ),
                    title: const Text('导入字体文件'),
                    onTap: _busy ? null : _import,
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 10, 6, 0),
              child: Text(
                '支持 .ttf / .otf / .ttc，单个文件不超过 32 MB。缺少的字由系统字体补上；字体文件只保存在本机，不进入备份和同步。',
                style: TextStyle(fontSize: 12, color: settingsNoteColor),
              ),
            ),
          ],
        ),
      );
    },
  );
}
