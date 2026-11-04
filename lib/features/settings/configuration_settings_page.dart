import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/session/app_preferences.dart';
import '../../core/session/configuration_backup.dart';
import '../../core/security/local_cipher.dart';
import '../../core/theme/lume_theme.dart';
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
    final password = await backupPassword(confirm: true);
    if (password == null) return null;
    final text = await backup.export(password: password);
    if (Platform.isIOS || Platform.isAndroid) {
      final saved = await const MethodChannel('lumebox/configuration')
          .invokeMethod<bool>('export', {
            'text': text,
            'name':
                'LumeBox-config-${DateTime.now().millisecondsSinceEpoch}.json',
          });
      return saved == true
          ? '配置备份已导出${backup.warnings.isEmpty ? '' : '，部分配置已跳过：${backup.warnings.join('；')}'}'
          : null;
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
    return '配置备份已导出${backup.warnings.isEmpty ? '' : '，部分配置已跳过：${backup.warnings.join('；')}'}';
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
    final selected = await showGlassDialog<File>(
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
    String? password;
    if (BackupCipher.needsPassword(text)) {
      password = await backupPassword();
      if (password == null || !mounted) return null;
    }
    final preview = await backup.preview(text, password: password);
    final sourceChanges = await backup.previewSourceChanges(preview);
    final settingsChanges = await backup.previewSettingsChanges(preview);
    final readingChanges = await backup.previewReadingChanges(preview);
    if (!mounted) return null;
    final parts = ConfigurationRestorePart.values.toSet();
    final yes = await showGlassDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('预览并选择恢复内容'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '备份时间：${preview['createdAt'] ?? '未知'}\n全局配置：${(preview['files'] as Map).length} 项\n板块配置：${(preview['sections'] as Map).length} 组\n包含：${preview.containsKey('readingData') ? '收藏、历史和阅读／播放进度' : '无阅读进度'}；${preview.containsKey('subscriptions') || preview.containsKey('catData') ? '订阅配置' : '无订阅配置'}；播放器设置属于板块配置。\n不包含已下载媒体及本地模型。订阅配置按板块整组替换，其他同名配置会覆盖；恢复后请重启 App。',
                ),
                ExpansionTile(
                  title: Text('配置恢复预览 · ${settingsChanges.length} 项'),
                  subtitle: const Text('仅恢复勾选的类别；逐项显示预计新增、覆盖或跳过'),
                  children: [
                    for (final line in settingsChanges)
                      ListTile(dense: true, title: Text(line)),
                  ],
                ),
                ExpansionTile(
                  title: Text('阅读和进度预览 · ${readingChanges.length} 项'),
                  subtitle: const Text('仅在勾选收藏、历史与进度时恢复'),
                  children: [
                    for (final line in readingChanges)
                      ListTile(dense: true, title: Text(line)),
                  ],
                ),
                ExpansionTile(
                  title: Text('源恢复预览 · ${sourceChanges.length} 项'),
                  subtitle: const Text('按源 ID 估计，实际导入可能失败或使用不同 ID'),
                  children: [
                    for (final line in sourceChanges)
                      ListTile(dense: true, title: Text(line)),
                  ],
                ),
                for (final part in ConfigurationRestorePart.values)
                  CheckboxListTile(
                    title: Text(part.label),
                    value: parts.contains(part),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        parts.add(part);
                      } else {
                        parts.remove(part);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: parts.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('恢复'),
            ),
          ],
        ),
      ),
    );
    if (yes != true) return null;
    await backup.restore(text, password: password, parts: parts);
    await preferences.boot();
    return '配置已恢复，请重新启动 App 以应用全部界面设置${backup.warnings.isEmpty ? '' : '；${backup.warnings.join('；')}'}';
  }

  Future<String?> backupPassword({bool confirm = false}) =>
      showGlassDialog<String>(
        context: context,
        builder: (_) => _BackupPasswordDialog(confirm: confirm),
      );

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '配置备份',
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
        SettingsGroupCard(
          children: [
            ListTile(
              title: const Text('导出配置备份'),
              subtitle: Text(
                '使用密码加密全局设置、各版块偏好与源配置',
                style: TextStyle(
                  fontSize: LumeTypography.descriptionSize,
                  color: LumeTheme.descriptionColorOf(
                    Theme.of(context).brightness,
                  ),
                  height: 1.5,
                ),
              ),
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
          ],
        ),
        const SizedBox(height: 12),
        SettingsGroupCard(
          children: [
            SwitchListTile(
              title: const Text('自动备份'),
              subtitle: const Text('使用本机密钥加密，每天保留一份，最近 7 份可在本机恢复'),
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
          ],
        ),
        const SizedBox(height: 24),
        if (busy) const LinearProgressIndicator(),
        if (status != null)
          SettingsFooterNote(
            status!,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          ),
        const SettingsFooterNote(
          '备份包含全局设置、各板块偏好、收藏、历史、分集进度、手工媒体条目与源配置；不含已下载媒体及本地模型。恢复会覆盖同名配置和源，恢复后需重启 App。',
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
        ),
      ],
    ),
  );
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.confirm});
  final bool confirm;
  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final password = TextEditingController();
  final repeated = TextEditingController();
  String? error;
  @override
  void dispose() {
    password.dispose();
    repeated.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.confirm ? '设置备份密码' : '输入备份密码'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.confirm ? '备份将加密保存。请妥善保管密码，换设备恢复时也需要它。' : '请输入导出这份备份时设置的密码。',
        ),
        TextField(
          controller: password,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: '备份密码', errorText: error),
        ),
        if (widget.confirm)
          TextField(
            controller: repeated,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '再次输入密码'),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (password.text.isEmpty ||
              widget.confirm &&
                  (password.text.length < 8 ||
                      password.text != repeated.text)) {
            setState(
              () => error = widget.confirm ? '密码至少 8 位，两次输入须一致' : '请输入密码',
            );
            return;
          }
          Navigator.pop(context, password.text);
        },
        child: const Text('继续'),
      ),
    ],
  );
}
