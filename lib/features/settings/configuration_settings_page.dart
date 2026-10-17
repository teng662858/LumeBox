import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/session/app_preferences.dart';
import '../../core/session/configuration_backup.dart';
import '../../shared/widgets/glass_card.dart';

class ConfigurationSettingsPage extends StatefulWidget {
  const ConfigurationSettingsPage({super.key, this.previewIcons = false});

  /// Show the mobile icon section in the standalone desktop layout preview.
  final bool previewIcons;
  @override
  State<ConfigurationSettingsPage> createState() =>
      _ConfigurationSettingsPageState();
}

class _ConfigurationSettingsPageState extends State<ConfigurationSettingsPage> {
  final preferences = AppPreferences.instance;
  final backup = ConfigurationBackup();
  bool busy = false;
  String? status;
  String selectedIcon = 'default';
  @override
  void initState() {
    super.initState();
    if (Platform.isIOS || Platform.isAndroid) {
      const MethodChannel('lumebox/app_icon')
          .invokeMethod<String>('current')
          .then((value) {
            if (mounted) setState(() => selectedIcon = value ?? 'default');
          })
          .catchError((Object _) {});
    }
  }

  Future<void> run(Future<String?> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await action();
      if (mounted && result != null) setState(() => status = result);
    } catch (error) {
      if (mounted) setState(() => status = '操作未完成：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> export() async {
    final text = await backup.export();
    if (Platform.isIOS || Platform.isAndroid) {
      final saved = await const MethodChannel('lumebox/configuration')
          .invokeMethod<bool>('export', {
            'text': text,
            'name':
                'LumeBox-config-${DateTime.now().millisecondsSinceEpoch}.json',
          });
      return saved == true ? '配置备份已导出' : null;
    }
    final location = await getSaveLocation(
      suggestedName:
          'LumeBox-config-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    if (location == null) return null;
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'application/json',
    ).saveTo(location.path);
    return '配置备份已导出';
  }

  Future<String?> restore() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '配置备份',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json'],
        ),
      ],
    );
    if (file == null || !mounted) return null;
    return restoreText(await file.readAsString());
  }

  Future<String?> restoreAutomatic() async {
    final files = await backup.snapshots();
    if (!mounted) return null;
    if (files.isEmpty) return '暂无自动备份';
    final selected = await showDialog<File>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择自动备份'),
        children: [
          for (final file in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, file),
              child: Text(file.uri.pathSegments.last),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return null;
    return restoreText(await selected.readAsString());
  }

  Future<String?> restoreText(String text) async {
    if (!mounted) return null;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复配置备份'),
        content: const Text('备份中的同名配置和源将覆盖当前设置。恢复后请重新启动 App。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (yes != true) return null;
    await backup.restore(text);
    await preferences.boot();
    return '配置已恢复，请重新启动 App 以应用全部界面设置';
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '配置与体验',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.previewIcons || Platform.isIOS || Platform.isAndroid) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'App 图标',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (name, label) in [
                ('default', '经典'),
                ('Aurora', '极光青'),
                ('Obsidian', '曜石紫'),
                ('Solar', '日曜金'),
                ('Orbit', '星环蓝'),
                ('Prism', '流光棱镜'),
                ('Spark', '电光青'),
              ])
                InkWell(
                  onTap: busy || widget.previewIcons
                      ? null
                      : () => run(() async {
                          await const MethodChannel('lumebox/app_icon')
                              .invokeMethod<bool>('set', name);
                          if (mounted) setState(() => selectedIcon = name);
                          return '已切换为$label图标';
                        }),
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 70,
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            'assets/icon/${name == 'default' ? 'app_icon_1024' : name}.png',
                            width: 60,
                            height: 60,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${selectedIcon == name ? '✓ ' : ''}$label',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('配置备份', style: Theme.of(context).textTheme.headlineSmall),
        ),
        ListTile(
          title: const Text('导出配置备份'),
          subtitle: const Text('全局设置、各版块偏好与源配置'),
          leading: const Icon(Icons.upload_file),
          enabled: !busy,
          onTap: () => run(export),
        ),
        ListTile(
          title: const Text('恢复配置备份'),
          leading: const Icon(Icons.settings_backup_restore),
          enabled: !busy,
          onTap: () => run(restore),
        ),
        SwitchListTile(
          title: const Text('自动备份'),
          subtitle: const Text('每天使用 App 时备份到本机，保留最近 7 份'),
          value: preferences.autoBackup,
          onChanged: busy
              ? null
              : (value) {
                  setState(() => preferences.autoBackup = value);
                  preferences.save();
                  if (value) {
                    run(() async {
                      await backup.automatic();
                      return '自动备份已保存到本机';
                    });
                  }
                },
        ),
        ListTile(
          title: const Text('立即自动备份'),
          enabled: !busy,
          onTap: () => run(() async {
            await backup.automatic();
            return '备份已保存到本机';
          }),
        ),
        ListTile(
          title: const Text('恢复自动备份'),
          leading: const Icon(Icons.history),
          enabled: !busy,
          onTap: () => run(restoreAutomatic),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('使用体验', style: Theme.of(context).textTheme.headlineSmall),
        ),
        SwitchListTile(
          title: const Text('触感反馈'),
          value: preferences.haptics,
          onChanged: (value) {
            setState(() => preferences.haptics = value);
            preferences.save();
            preferences.selectionFeedback();
          },
        ),
        ListTile(
          title: const Text('触感强度'),
          subtitle: const Text('选择档位即可体验反馈'),
          trailing: DropdownButton<HapticStrength>(
            value: preferences.hapticStrength,
            items: [
              for (final strength in HapticStrength.values)
                DropdownMenuItem(value: strength, child: Text(strength.label)),
            ],
            onChanged: preferences.haptics
                ? (value) {
                    if (value == null) return;
                    setState(() => preferences.hapticStrength = value);
                    preferences.save();
                    preferences.selectionFeedback();
                  }
                : null,
          ),
        ),
        SwitchListTile(
          title: const Text('后台播放'),
          subtitle: const Text('视频退到后台时继续播放音频'),
          value: preferences.backgroundPlayback,
          onChanged: (value) {
            setState(() => preferences.backgroundPlayback = value);
            preferences.save();
          },
        ),
        if (busy) const LinearProgressIndicator(),
        if (status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text(status!, style: Theme.of(context).textTheme.labelSmall),
          ),
      ],
    ),
  );
}
