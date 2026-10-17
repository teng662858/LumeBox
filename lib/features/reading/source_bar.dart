import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../source/source_picker_sheet.dart';

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
        if (!floating) ...[
          Icon(Icons.source_outlined, size: 18, color: LumeTheme.muted),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: InkWell(
            key: const ValueKey('open-source-picker'),
            borderRadius: BorderRadius.circular(14),
            onTap: busy
                ? null
                : () async {
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
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      current?.name ?? '未选择源',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: LumeTypography.titleSize,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more, size: 18, color: LumeTheme.muted),
                ],
              ),
            ),
          ),
        ),
        if (showManage)
          IconButton(
            tooltip: '源管理',
            icon: const Icon(Icons.tune, size: 20),
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
