import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/icon_catalog.dart';
import '../../core/theme/icon_customization.dart';
import '../../shared/widgets/glass_card.dart';

Future<void> editAppIcon(
  BuildContext context,
  String slot,
  IconData? original,
) async {
  await IconCustomization.instance.boot();
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => IconPickerPage(slot: slot, original: original),
    ),
  );
}

class IconLibraryPage extends StatefulWidget {
  const IconLibraryPage({super.key});
  @override
  State<IconLibraryPage> createState() => _IconLibraryPageState();
}

class _IconLibraryPageState extends State<IconLibraryPage> {
  final store = IconCustomization.instance;
  String query = '', group = '全部';
  bool changedOnly = false, busy = false;
  @override
  void initState() {
    super.initState();
    store.boot();
  }

  Future<void> _operation(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() => _operation(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'LumeBox 图标包',
          extensions: ['lumeicons', 'json'],
          uniformTypeIdentifiers: ['public.json', 'public.data'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > IconCustomization.maxPackBytes) {
      throw const FormatException('图标包请小于 16 MB');
    }
    await store.importPack(await file.readAsString());
  });
  Future<void> _export() => _operation(() async {
    await store.boot();
    await store.flush();
    if (Platform.isIOS || Platform.isAndroid) {
      await const MethodChannel('lumebox/configuration').invokeMethod<bool>(
        'export',
        {'text': store.exportPack(), 'name': 'LumeBox-icons.lumeicons'},
      );
      return;
    }
    final location = await getSaveLocation(
      suggestedName: 'LumeBox-icons.lumeicons',
    );
    if (location == null) return;
    await XFile.fromData(
      utf8.encode(store.exportPack()),
      mimeType: 'application/json',
      name: 'LumeBox-icons.lumeicons',
    ).saveTo(location.path);
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final slots = store.slots
          .where(
            (s) =>
                (group == '全部' || s.group == group) &&
                (!changedOnly || store.choice(s.id, s.fallback) != null) &&
                '${s.name} ${s.group} ${s.id}'.toLowerCase().contains(
                  query.toLowerCase(),
                ),
          )
          .toList();
      final groups = [
        '全部',
        ...store.slots.map((s) => s.group).toSet().toList()..sort(),
      ];
      return GlassScaffold(
        behindBar: true,
        title: '应用图标库',
        actions: [
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (v) async {
              if (v == 'import') await _import();
              if (v == 'export') await _export();
              if (!context.mounted) return;
              if (v == 'reset') {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('恢复全部默认图标？'),
                    content: const Text('保留已导入的图片，所有图标选择恢复默认。'),
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
                if (yes == true) store.resetAll();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('导入图标包')),
              PopupMenuItem(value: 'export', child: Text('导出当前图标包')),
              PopupMenuItem(value: 'reset', child: Text('恢复全部默认图标')),
            ],
          ),
        ],
        child: ListView.builder(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.all(16)),
          itemCount: slots.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '选择下面的项目换图标，修改立即生效。也可开启长按编辑，到对应页面长按图标更换。只改外观，原按钮功能和尺寸保留。',
                  ),
                  SwitchListTile(
                    key: const Key('icons.edit-mode'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开启长按图标更换'),
                    subtitle: const Text('关闭后恢复原有长按操作；重开 App 自动关闭编辑模式'),
                    value: store.editMode,
                    onChanged: store.setEditMode,
                  ),
                  TextField(
                    key: const Key('icons.search'),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索：导航、播放、书签、设置…',
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final name in groups)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(name),
                              selected: group == name,
                              onSelected: (_) => setState(() => group = name),
                            ),
                          ),
                      ],
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('只看已更换的图标'),
                    value: changedOnly,
                    onChanged: (v) => setState(() => changedOnly = v ?? false),
                  ),
                  Text(
                    '内置 ${builtInIcons.length} 款图标 · 已更换 ${store.overrides.length} 项 · 自己的图片 ${store.images.length} 张',
                  ),
                  if (busy) const LinearProgressIndicator(),
                  if (slots.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有找到对应项目，试试开启长按编辑，到目标图标直接更换。'),
                    ),
                ],
              );
            }
            final slot = slots[index - 1];
            return ListTile(
              key: ValueKey('icon-slot:${slot.id}'),
              leading: _ChoicePreview(
                choice: store.choice(slot.id, slot.fallback),
                original: slot.fallback,
              ),
              title: Text(
                slot.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                slot.group + (slot.dynamic ? ' · 可在对应页面长按精确更换' : ''),
              ),
              trailing: store.choice(slot.id, slot.fallback) == null
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.check_circle),
              onTap: () => editAppIcon(context, slot.id, slot.fallback),
            );
          },
        ),
      );
    },
  );
}

class IconPickerPage extends StatefulWidget {
  const IconPickerPage({super.key, required this.slot, this.original});
  final String slot;
  final IconData? original;
  @override
  State<IconPickerPage> createState() => _IconPickerPageState();
}

class _IconPickerPageState extends State<IconPickerPage> {
  final store = IconCustomization.instance;
  String query = '', family = '全部';
  bool tint = false, busy = false;
  IconChoice? selected;
  @override
  void initState() {
    super.initState();
    store.boot();
    selected = store.choice(widget.slot, widget.original);
    tint = selected?.tint ?? false;
  }

  void _apply() {
    try {
      store.set(widget.slot, selected);
      Navigator.pop(context);
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _importImage() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '图标图片',
            extensions: ['png', 'webp', 'jpg', 'jpeg'],
            uniformTypeIdentifiers: ['public.image'],
          ),
        ],
      );
      if (file == null) return;
      final image = await store.importImage(file);
      if (mounted) {
        setState(() {
          family = '我的图片';
          selected = IconChoice(image.id);
          tint = false;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final entries = builtInIcons
          .where(
            (e) =>
                (family == '全部' || family == e.family) &&
                '${e.name} ${e.id}'.toLowerCase().contains(query.toLowerCase()),
          )
          .toList();
      final images = (family == '全部' || family == '我的图片')
          ? store.images
                .where(
                  (e) => e.name.toLowerCase().contains(query.toLowerCase()),
                )
                .toList()
          : <UserIconImage>[];
      final name =
          store.slots.where((s) => s.id == widget.slot).firstOrNull?.name ??
          '当前图标';
      return Scaffold(
        appBar: AppBar(
          title: const Text('选择图标'),
          actions: [
            IconButton(
              tooltip: '导入自己的图片',
              onPressed: busy ? null : _importImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _ChoicePreview(
                            choice: selected,
                            original: widget.original,
                            size: 40,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            key: const Key('icons.restore'),
                            onPressed: busy
                                ? null
                                : () {
                                    store.set(widget.slot, null);
                                    Navigator.pop(context);
                                  },
                            child: const Text('恢复默认'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        key: const Key('icons.picker-search'),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '搜索图标名称或英文关键词',
                        ),
                        onChanged: (v) => setState(() => query = v),
                      ),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final name in ['全部', 'Material', 'iOS', '我的图片'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(name),
                                selected: family == name,
                                onSelected: (_) =>
                                    setState(() => family = name),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (selected?.id.startsWith('image:') ?? false)
                      SwitchListTile(
                        title: const Text('图片跟随按钮颜色'),
                        subtitle: const Text('关闭则保留图片原本的颜色'),
                        value: tint,
                        onChanged: (v) => setState(() {
                          tint = v;
                          selected = IconChoice(selected!.id, tint: v);
                        }),
                      ),
                    if (busy) const LinearProgressIndicator(),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid.builder(
                  itemCount: entries.length + images.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 90,
                    mainAxisExtent: 116,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final entry = index < entries.length
                        ? entries[index]
                        : null;
                    final image = entry == null
                        ? images[index - entries.length]
                        : null;
                    final id = entry?.id ?? image!.id;
                    final active = selected?.id == id;
                    return Material(
                      color: active
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        key: ValueKey('icon-choice:$id'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => setState(() {
                          selected = IconChoice(
                            id,
                            tint: image != null && tint,
                          );
                        }),
                        onLongPress: image == null
                            ? null
                            : () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('删除这张图标图片？'),
                                    content: const Text('正在使用它的位置会恢复默认图标。'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                );
                                if (yes == true) {
                                  store.deleteImage(id);
                                  if (mounted && selected?.id == id) {
                                    setState(() {
                                      selected = null;
                                      tint = false;
                                    });
                                  }
                                }
                              },
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _ChoicePreview(
                              choice: IconChoice(id, tint: tint),
                              original: widget.original,
                              size: 28,
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Text(
                                entry?.name ?? image!.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (entries.isEmpty && images.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没有找到图标，试试其他关键词或导入自己的图片。'),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('icons.apply'),
                onPressed: busy || selected == null || !store.valid(selected!)
                    ? null
                    : _apply,
                child: const Text('使用这个图标'),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ChoicePreview extends StatelessWidget {
  const _ChoicePreview({required this.choice, this.original, this.size = 28});
  final IconChoice? choice;
  final IconData? original;
  final double size;
  @override
  Widget build(BuildContext context) {
    final store = IconCustomization.instance;
    final image = store.image(choice);
    if (image != null) {
      return SizedBox.square(
        dimension: size,
        child: Image.memory(
          image.bytes,
          fit: BoxFit.contain,
          color: choice!.tint ? IconTheme.of(context).color : null,
          colorBlendMode: BlendMode.srcIn,
          errorBuilder: (_, _, _) =>
              Icon(original ?? Icons.widgets_outlined, size: size),
        ),
      );
    }
    return Icon(
      store.glyph(choice) ?? original ?? Icons.widgets_outlined,
      size: size,
    );
  }
}
