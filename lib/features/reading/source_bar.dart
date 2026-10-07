import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 顶部图源选择条：下拉切换本板块已启用的图源，右侧进入图源管理。
///
/// 候选只来自本板块——列表由调用方从板块级管理器取得，跨板块候选不可能出现。
/// 下拉列出的是「已启用」的图源；停用的图源若要浏览，需要先在管理页启用。
class ReadingSourceBar extends StatelessWidget {
  const ReadingSourceBar({
    super.key,
    required this.sources,
    required this.currentId,
    required this.onSelect,
    required this.onManage,
    this.showManage = true,
    this.busy = false,
  });

  /// 本板块已启用的图源。
  final List<SourceDescriptor> sources;

  /// 当前图源 id；为空时显示「未选择图源」。
  final String? currentId;

  final ValueChanged<String> onSelect;
  final VoidCallback onManage;

  /// 是否显示右侧的「源管理」入口（宿主顶栏已有同一入口时关掉，避免一屏两个）。
  final bool showManage;

  /// 切换中：期间禁止再次下拉，避免连点触发多次切换。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        children: <Widget>[
          Icon(Icons.source_outlined, size: 18, color: LumeTheme.muted),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: currentId,
                isExpanded: true,
                dropdownColor: LumeTheme.surface,
                borderRadius: BorderRadius.circular(14),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
                icon: Icon(
                  Icons.expand_more,
                  size: 18,
                  color: LumeTheme.muted,
                ),
                hint: Text(
                  '未选择源',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.muted,
                  ),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final source in sources)
                    DropdownMenuItem<String>(
                      value: source.id,
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onSelect(value);
                      },
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
      ),
    );
  }
}
