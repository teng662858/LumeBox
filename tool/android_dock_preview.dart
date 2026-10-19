/// Mobile-only preview of the production dock, with live appearance settings.
/// flutter run -d emulator-5580 -t tool/android_dock_preview.dart
library;

import 'package:flutter/material.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/tab_bar_settings_page.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';
import 'package:lume_box/features/settings/icon_library_page.dart';
import 'package:lume_box/core/theme/icon_customization.dart';
import 'package:lume_box/shared/widgets/lume_icon.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPreferences.instance.boot();
  await ShellSettingsController.instance.boot();
  await FloatingModules.instance.boot();
  await IconCustomization.instance.boot();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(accent: ThemeAccent.ruby),
      builder: (context, child) =>
          AppIconEditingScope(onEdit: editAppIcon, child: child!),
      home: const _DockPreview(),
    ),
  );
}

class _DockPreview extends StatefulWidget {
  const _DockPreview();
  @override
  State<_DockPreview> createState() => _DockPreviewState();
}

class _DockPreviewState extends State<_DockPreview> {
  bool fiveTabs = true;
  String selected = 'novel';
  static const entries = [
    ShellDockEntry(
      id: 'novel',
      label: '小说',
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book_rounded,
    ),
    ShellDockEntry(
      id: 'comic',
      label: '漫画',
      icon: Icons.auto_stories_outlined,
      selectedIcon: Icons.auto_stories_rounded,
    ),
    ShellDockEntry(
      id: 'video',
      label: '视频',
      icon: Icons.play_circle_outline,
      selectedIcon: Icons.play_circle,
    ),
    ShellDockEntry(
      id: 'cat',
      label: '猫源',
      icon: Icons.pets_outlined,
      selectedIcon: Icons.pets,
    ),
    ShellDockEntry(
      id: 'settings',
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ShellSettingsController.instance,
    builder: (context, _) {
      final visible = fiveTabs ? entries : [entries[0], entries[2], entries[4]];
      final active = visible.any((e) => e.id == selected) ? selected : 'novel';
      final appearance = ShellSettingsController.instance.settings.appearance;
      return Scaffold(
        backgroundColor: const Color(0xFFEEEDF4),
        appBar: AppBar(
          title: const Text('液态玻璃 · 交互预览'),
          actions: [
            IconButton(
              tooltip: '应用图标库',
              icon: const Icon(Icons.interests_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const IconLibraryPage(),
                ),
              ),
            ),
            IconButton(
              tooltip: '底部导航栏管理',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TabBarSettingsPage(),
                ),
              ),
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        body: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                children: [
                  const Text(
                    '按住底栏，再左右拖动；松手查看回弹。',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('三项')),
                      ButtonSegment(value: true, label: Text('五项')),
                    ],
                    selected: {fiveTabs},
                    onSelectionChanged: (values) =>
                        setState(() => fiveTabs = values.single),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '松手后选中：${entries.firstWhere((e) => e.id == active).label}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  for (var row = 0; row < 9; row++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        height: 108,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: LinearGradient(
                            colors: row.isEven
                                ? const [Color(0xFFB8D9E3), Color(0xFFEEC4C3)]
                                : const [Color(0xFFDBD0EA), Color(0xFFC4DBB6)],
                          ),
                        ),
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              entries[row % entries.length].icon,
                              size: 42,
                              color: const Color(0xFF334859),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'LumeBox 玻璃背景 ${row + 1}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Text(
                                    '文字、色块用于观察磨砂与折射',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ShellDockBar(
                entries: visible,
                activeId: active,
                onSelect: (id) => setState(() => selected = id),
                appearance: appearance,
                bottomMargin:
                    (MediaQuery.viewPaddingOf(context).bottom +
                            appearance.safeGap)
                        .clamp(-80.0, 200.0),
              ),
            ),
          ],
        ),
      );
    },
  );
}
