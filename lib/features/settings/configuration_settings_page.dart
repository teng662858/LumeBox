import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/session/app_preferences.dart';
import '../../core/session/configuration_backup.dart';
import '../../shared/widgets/glass_card.dart';
import 'app_icon_settings_page.dart';
import 'settings_ui.dart';

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
    title: '配置备份与体验',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 开发预览 / 排版测试仍可在这里看到图标网格；正式入口已拆到
        // 「个性与界面 → App 图标」，本页只负责备份与体验。
        if (widget.previewIcons) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'App 图标',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const AppIconGrid(previewOnly: true),
          const SizedBox(height: 28),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('配置备份', style: Theme.of(context).textTheme.headlineSmall),
        ),
        ListTile(
          title: const Text('导出配置备份'),
          subtitle: const Text('全局设置、各版块偏好与源配置'),
          leading: const LumeIcon(
            Icons.upload_file,
            slot: 'configuration_settings_page.1',
          ),
          enabled: !busy,
          onTap: () => run(export),
        ),
        ListTile(
          title: const Text('恢复配置备份'),
          leading: const LumeIcon(
            Icons.settings_backup_restore,
            slot: 'configuration_settings_page.2',
          ),
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
          leading: const LumeIcon(
            Icons.history,
            slot: 'configuration_settings_page.3',
          ),
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
          SettingsFooterNote(
            status!,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          ),
        const SettingsFooterNote(
          '备份包含全局设置、各板块偏好与源配置；恢复会覆盖同名配置和源，恢复后需重启 App。',
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
        ),
      ],
    ),
  );
}
