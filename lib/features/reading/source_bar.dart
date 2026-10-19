import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/source_switch_button.dart';
import '../source/source_picker_sheet.dart';
import '../source/video_source_scope.dart';

/// A source button opens the searchable, section-scoped source drawer.
class ReadingSourceBar extends StatelessWidget {
  const ReadingSourceBar({
    super.key,
    required this.sources,
    required this.currentId,
    required this.onSelect,
    required this.onManage,
    this.showManage = true,
    this.busy = false,
    this.floating = false,
    this.section,
    this.manager,
    this.onSourcesChanged,
  });
  final List<SourceDescriptor> sources;
  final String? currentId;
  final ValueChanged<String> onSelect;
  final VoidCallback onManage;
  final bool showManage, busy, floating;
  final Section? section;
  final SourceManager? manager;
  final Future<void> Function()? onSourcesChanged;

  @override
  Widget build(BuildContext context) {
    final current = sources
        .where((source) => source.id == currentId)
        .firstOrNull;
    final content = Row(
      children: [
        Expanded(
          child: SourceSwitchButton(
            key: const ValueKey('open-source-picker'),
            name: current?.name ?? '未选择源',
            iconSlot: 'source_bar.2',
            onPressed: busy
                ? null
                : () async {
                    final videoScope = VideoSourceScope.maybeOf(context);
                    if (section == Section.video && videoScope != null) {
                      await videoScope.openPicker(context);
                      return;
                    }
                    final board =
                        section ??
                        current?.section ??
                        sources.firstOrNull?.section ??
                        Section.novel;
                    var changed = false;
                    final selected = await showSourcePicker(
                      context: context,
                      section: board,
                      sources: sources,
                      currentId: currentId,
                      manager: manager,
                      onChanged: () => changed = true,
                    );
                    if (!context.mounted) return;
                    if (selected != null && selected != currentId) {
                      onSelect(selected);
                    } else if (changed) {
                      await onSourcesChanged?.call();
                    }
                  },
          ),
        ),
        if (showManage)
          IconButton(
            tooltip: '源管理',
            icon: const LumeIcon(Icons.tune, slot: 'source_bar.3', size: 20),
            onPressed: onManage,
          ),
      ],
    );
    const padding = EdgeInsets.fromLTRB(12, 2, 4, 2);
    return floating
        ? Padding(padding: padding, child: content)
        : GlassCard(radius: 14, padding: padding, child: content);
  }
}
