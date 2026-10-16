import '../../shared/widgets/module_glass_surface.dart';
import '../../shared/widgets/drawer_geometry.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';

/// Long horizontal choices keep a fixed, searchable access point.
class BrowseChoiceAccess extends StatelessWidget {
  const BrowseChoiceAccess({
    super.key,
    required this.child,
    required this.choices,
    required this.onSelected,
    this.selectedId,
    this.title = '分类',
    this.includeAll = true,
    this.showAccess = true,
    this.onOpen,
  });
  final Widget child;
  final List<SourceCategory> choices;
  final String? selectedId;
  final String title;
  final bool includeAll;
  final bool showAccess;
  final VoidCallback? onOpen;
  final ValueChanged<String?> onSelected;

  Future<void> _open(BuildContext context) async {
    final value = await showLumeBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ChoiceSheet(
        choices: choices,
        selectedId: selectedId,
        title: title,
        includeAll: includeAll,
      ),
    );
    if (value != null) onSelected(value.id);
  }

  @override
  Widget build(BuildContext context) {
    if (!showAccess || (choices.length <= 8 && onOpen == null)) return child;
    return Row(
      children: [
        Expanded(child: child),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: Tooltip(
            message: '展开全部$title',
            child: IconButton(
              color: LumeTheme.accent,
              visualDensity: VisualDensity.compact,
              onPressed: onOpen ?? () => _open(context),
              icon: const Icon(Icons.tune, size: 20),
            ),
          ),
        ),
      ],
    );
  }
}

class _Choice {
  const _Choice(this.id);
  final String? id;
}

class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({
    required this.choices,
    required this.selectedId,
    required this.title,
    required this.includeAll,
  });
  final List<SourceCategory> choices;
  final String? selectedId;
  final String title;
  final bool includeAll;
  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final options = [
      if (widget.includeAll) const SourceCategory(id: '', title: '全部'),
      ...widget.choices.where(
        (item) => !widget.includeAll || item.title != '全部',
      ),
    ];
    final shown = options
        .where(
          (item) =>
              item.title.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: DrawerGeometry.height(context),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '全部${widget.title}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) => setState(() => query = value),
                decoration: InputDecoration(
                  hintText: '搜索${widget.title}',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('没有匹配的选项'))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: shown.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 170,
                            mainAxisExtent: 48,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                      itemBuilder: (_, index) {
                        final option = shown[index];
                        final all =
                            widget.includeAll &&
                            index == 0 &&
                            option.id.isEmpty &&
                            option.title == '全部';
                        final selected = all
                            ? widget.selectedId == null
                            : option.id == widget.selectedId;
                        return TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: selected
                                ? LumeTheme.accent
                                : LumeTheme.textPrimary,
                            backgroundColor: selected
                                ? LumeTheme.accent.withValues(alpha: .15)
                                : LumeTheme.accent.withValues(alpha: .04),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.pop(
                            context,
                            _Choice(all ? null : option.id),
                          ),
                          child: Text(
                            option.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One panel for the primary category and every filter group.
Future<({String? category, Map<String, String> filters})?> showBrowseFilters({
  required BuildContext context,
  required List<SourceCategory> categories,
  required List<SourceFilterGroup> groups,
  required String? category,
  required Map<String, String> filters,
}) {
  final effectModule = ModuleGlassScope.moduleOf(context);
  var chosenCategory = category;
  var chosenFilters = Map<String, String>.of(filters);
  var query = '';
  return showLumeBottomSheet<
    ({String? category, Map<String, String> filters})
  >(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (context) => StatefulBuilder(
      builder: (context, setPanelState) {
        Widget choices(
          String title,
          List<SourceCategory> options,
          String? selected,
          ValueChanged<String?> choose,
        ) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (!options.any((o) => o.title == '全部'))
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: selected == null,
                    onSelected: (_) => setPanelState(() => choose(null)),
                  ),
                for (final option in options.where(
                  (o) => o.title.toLowerCase().contains(query.toLowerCase()),
                ))
                  ChoiceChip(
                    label: Text(option.title),
                    selected: selected == option.id,
                    onSelected: (_) => setPanelState(() => choose(option.id)),
                  ),
              ],
            ),
          ],
        );
        final media = MediaQuery.of(context);
        final keyboard = media.viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(
            key: const Key('classification-drawer-frame'),
            height: DrawerGeometry.height(context),
            child: Stack(
              children: [
                Positioned.fill(
                  bottom: 0,
                  child: ModuleGlassSurface(
                    module: effectModule,
                    part: GlassPart.home,
                    legacy: Material(
                      key: const Key('filter-content-background'),
                      color:
                          Theme.of(context)
                              .bottomSheetTheme
                              .modalBackgroundColor ??
                          Theme.of(context).bottomSheetTheme.backgroundColor ??
                          Theme.of(context).colorScheme.surface,
                      shape:
                          Theme.of(context).bottomSheetTheme.shape ??
                          const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(28),
                            ),
                          ),
                      clipBehavior: Clip.antiAlias,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    (keyboard > 0
                        ? 0
                        : math.max(
                            media.viewPadding.bottom,
                            media.padding.bottom,
                          )),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '分类与筛选',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      TextField(
                        onChanged: (s) => setPanelState(() => query = s.trim()),
                        decoration: const InputDecoration(
                          hintText: '搜索分类或筛选项',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          key: const Key('filter-options'),
                          padding: EdgeInsets.zero,
                          children: [
                            if (categories.isNotEmpty)
                              choices('分类', categories, chosenCategory, (id) {
                                chosenCategory = id;
                                chosenFilters.remove('tid');
                                chosenFilters.remove('class');
                              }),
                            for (final group in groups)
                              choices(
                                group.title,
                                group.options
                                    .map(
                                      (o) => SourceCategory(
                                        id: o.id,
                                        title: o.title,
                                      ),
                                    )
                                    .toList(),
                                chosenFilters[group.id] ??
                                    group.options
                                        .where((o) => o.title == '全部')
                                        .firstOrNull
                                        ?.id,
                                (id) {
                                  if (id == null) {
                                    chosenFilters.remove(group.id);
                                  } else {
                                    chosenFilters[group.id] = id;
                                  }
                                  if (group.id == 'tid') {
                                    chosenFilters.remove('class');
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                      SizedBox(
                        key: const Key('filter-footer'),
                        height: 60,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Row(
                              key: const Key('filter-actions'),
                              children: [
                                TextButton(
                                  onPressed: () => setPanelState(() {
                                    chosenCategory = null;
                                    chosenFilters.clear();
                                  }),
                                  child: const Text('重置'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, (
                                    category: chosenCategory,
                                    filters: chosenFilters,
                                  )),
                                  child: const Text('应用筛选'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
