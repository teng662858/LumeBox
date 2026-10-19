import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/lume_theme.dart';
import 'diagnostic_exporter.dart';
import 'settings_ui.dart';

class DiagnosticExportTile extends StatefulWidget {
  const DiagnosticExportTile({super.key, this.collect, this.save});
  final Future<DiagnosticBundle> Function()? collect;
  final Future<bool> Function(DiagnosticBundle bundle)? save;
  @override
  State<DiagnosticExportTile> createState() => _DiagnosticExportTileState();
}

class _DiagnosticExportTileState extends State<DiagnosticExportTile> {
  bool busy = false;
  String? status;
  Future<void> export() async {
    var action = 'export';
    if (widget.save == null && Platform.isIOS) {
      final chosen = await showLumeBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const LumeIcon(
                  Icons.ios_share,
                  slot: 'diagnostic_export_tile.1',
                ),
                title: const Text('发送 / 分享诊断包'),
                onTap: () => Navigator.pop(context, 'share'),
              ),
              ListTile(
                leading: const LumeIcon(
                  Icons.save_alt,
                  slot: 'diagnostic_export_tile.2',
                ),
                title: const Text('保存到本地文件'),
                onTap: () => Navigator.pop(context, 'export'),
              ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      action = chosen;
    }
    if (busy) return;
    setState(() => busy = true);
    try {
      final bundle =
          await (widget.collect?.call() ?? DiagnosticExporter().collect());
      bool saved;
      if (widget.save != null) {
        saved = await widget.save!(bundle);
      } else if (Platform.isIOS || Platform.isAndroid) {
        saved =
            await const MethodChannel('lumebox/configuration')
                .invokeMethod<bool>(action, {
                  'bytes': bundle.bytes,
                  'name': bundle.name,
                  'mime': 'application/zip',
                }) ??
            false;
      } else {
        final location = await getSaveLocation(
          suggestedName: bundle.name,
          acceptedTypeGroups: const [
            XTypeGroup(label: '诊断包', extensions: ['zip']),
          ],
        );
        saved = location != null;
        if (location != null) {
          await XFile.fromData(
            bundle.bytes,
            mimeType: 'application/zip',
            name: bundle.name,
          ).saveTo(location.path);
        }
      }
      if (mounted) {
        setState(() => status = saved ? '诊断包已导出，可将 ZIP 文件发来排查' : '已取消导出');
      }
    } catch (_) {
      if (mounted) setState(() => status = '诊断包导出失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsEntryCard(
    icon: Icons.inventory_2_outlined,
    title: '一键导出诊断包',
    subtitle: status ?? '发送分享或保存到本地；过滤敏感信息',
    showChevron: false,
    trailing: busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : LumeIcon(
            Icons.file_upload_outlined,
            slot: 'diagnostic_export_tile.3',
            size: 20,
            color: LumeTheme.muted,
          ),
    onTap: busy ? null : export,
  );
}
