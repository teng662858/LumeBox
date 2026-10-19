import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../../core/session/section.dart';
import 'media_resource_router.dart';

class MediaLibraryStrip extends StatelessWidget {
  const MediaLibraryStrip({super.key, required this.section});
  final Section section;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MediaLibrary.instance,
    builder: (context, _) => ListTile(
      dense: true,
      leading: LumeIcon(
        section == Section.novel
            ? Icons.headphones
            : Icons.library_add_outlined,
        slot: 'media_library_page.1',
        variant: true,
      ),
      title: Text(section == Section.novel ? '有声小说与导入资源' : '导入资源'),
      subtitle: MediaLibrary.instance.entries(section).isEmpty
          ? null
          : Text('${MediaLibrary.instance.entries(section).length} 个条目'),
      trailing: const LumeIcon(
        Icons.chevron_right,
        slot: 'media_library_page.2',
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => MediaLibraryPage(section: section),
        ),
      ),
    ),
  );
}

class MediaLibraryPage extends StatefulWidget {
  const MediaLibraryPage({super.key, required this.section});
  final Section section;
  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  final library = MediaLibrary.instance;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(library.boot());
  }

  Future<void> _files() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '音频、视频或文字小说',
          extensions: [
            'mp3',
            'm4a',
            'aac',
            'flac',
            'ogg',
            'opus',
            'wav',
            'mp4',
            'mkv',
            'mov',
            'm4v',
            'txt',
          ],
          uniformTypeIdentifiers: [
            'public.audio',
            'public.movie',
            'public.plain-text',
          ],
        ),
      ],
    );
    if (files.isEmpty || !mounted) return;
    setState(() => busy = true);
    try {
      final imported = <MediaResource>[];
      for (final file in files) {
        imported.add(
          await MediaResourceService().file(File(file.path), name: file.name),
        );
      }
      if (imported.length > 1 &&
          imported.every((r) => r.kind == ResourceKind.audioBook)) {
        final first = imported.first;
        final merged = MediaResource(
          id: first.id,
          title: files.first.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
          kind: ResourceKind.audioBook,
          destination: Section.novel,
          episodes: [for (final item in imported) ...item.episodes],
        );
        await library.add(merged);
        for (final item in imported.skip(1)) {
          await library.remove(item.id);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已按内容类型预分类，可在条目菜单中修改类型或移动所在库')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('导入失败，请检查文件权限和剩余空间')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _link() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _MediaLinkDialog(),
    );
    if (value == null || !mounted) return;
    setState(() => busy = true);
    try {
      final uri = Uri.parse(value);
      final tracks = await const MediaTrackProbe().inspect(uri);
      final kind = tracks.kind ?? ResourceKind.audioBook;
      final id = 'link-${DateTime.now().microsecondsSinceEpoch}';
      await library.add(
        MediaResource(
          id: id,
          title: uri.pathSegments.isEmpty
              ? uri.host
              : Uri.decodeComponent(uri.pathSegments.last),
          kind: kind,
          destination: kind.defaultSection,
          episodes: [ResourceEpisode(id: id, title: '第1集', url: uri)],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法导入该媒体链接')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.section == Section.novel ? '有声小说与导入资源' : '视频导入资源'),
      actions: [
        PopupMenuButton<String>(
          tooltip: '导入资源',
          enabled: !busy,
          onSelected: (value) => value == 'file' ? _files() : _link(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'file', child: Text('导入本地文件（可多选）')),
            PopupMenuItem(value: 'link', child: Text('导入媒体链接')),
          ],
          icon: const LumeIcon(Icons.add, slot: 'media_library_page.3'),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final entries = library.entries(widget.section);
        return Column(
          children: [
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        '点右上角 + 导入资源\n成品有声书会默认放入小说库',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final item = entries[index];
                        return ListTile(
                          leading: LumeIcon(
                            switch (item.kind) {
                              ResourceKind.audioBook => Icons.headphones,
                              ResourceKind.novel => Icons.menu_book,
                              ResourceKind.video => Icons.movie_outlined,
                            },
                            slot: 'media_library_page.4',
                            variant: true,
                          ),
                          title: Text(item.title),
                          subtitle: Text(
                            '${item.kind.label} · ${item.episodes.length} 集',
                          ),
                          onTap: () async {
                            try {
                              await openMediaResource(context, item);
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('资源打开失败，请检查类型、源和网络'),
                                  ),
                                );
                              }
                            }
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'type') {
                                await editMediaPlacement(context, item);
                              } else if (value == 'remove') {
                                await library.remove(item.id);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'type',
                                child: Text('修改类型 / 移动所在库'),
                              ),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('移出导入列表'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

Future<MediaResource?> editMediaPlacement(
  BuildContext context,
  MediaResource resource,
) async {
  final value = await showDialog<(ResourceKind, Section)>(
    context: context,
    builder: (_) => _PlacementDialog(resource: resource),
  );
  if (value == null) return null;
  return MediaLibrary.instance.move(resource.id, value.$1, value.$2);
}

class _PlacementDialog extends StatefulWidget {
  const _PlacementDialog({required this.resource});
  final MediaResource resource;
  @override
  State<_PlacementDialog> createState() => _PlacementDialogState();
}

class _PlacementDialogState extends State<_PlacementDialog> {
  late ResourceKind kind = widget.resource.kind;
  late Section section = widget.resource.destination;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('类型与所在库'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<ResourceKind>(
          initialValue: kind,
          decoration: const InputDecoration(labelText: '资源类型'),
          items: [
            for (final item in ResourceKind.values)
              DropdownMenuItem(value: item, child: Text(item.label)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => kind = value);
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<Section>(
          initialValue: section,
          decoration: const InputDecoration(labelText: '所在库'),
          items: const [
            DropdownMenuItem(value: Section.novel, child: Text('小说')),
            DropdownMenuItem(value: Section.video, child: Text('视频')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => section = value);
          },
        ),
        const SizedBox(height: 16),
        const Text('自动识别只是默认分类。手动修改后会保留，不需要重新导入。'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (kind, section)),
        child: const Text('保存'),
      ),
    ],
  );
}

class _MediaLinkDialog extends StatefulWidget {
  const _MediaLinkDialog();
  @override
  State<_MediaLinkDialog> createState() => _MediaLinkDialogState();
}

class _MediaLinkDialogState extends State<_MediaLinkDialog> {
  final controller = TextEditingController();
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('媒体链接'),
    content: TextField(
      controller: controller,
      autocorrect: false,
      decoration: InputDecoration(hintText: 'https://…', errorText: error),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final uri = Uri.tryParse(controller.text.trim());
          if (uri == null ||
              !['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty) {
            setState(() => error = '请填写有效的 HTTP / HTTPS 地址');
            return;
          }
          Navigator.pop(context, uri.toString());
        },
        child: const Text('导入'),
      ),
    ],
  );
}
