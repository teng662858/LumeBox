import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 底部导航栏管理：**每个页签独立开关 + 拖拽排序**。
///
/// ## 两条硬约束（界面上都要说清）
///
/// 1. **至少保留 1 个页签**：全部关掉导航栏就空了，用户再也点不到任何入口。
///    因此最后一个可见页签的开关是**置灰**的，并说明原因（不是「点了没反应」）。
/// 2. **隐藏「设置」会留一个恢复入口**：设置页是进入本页的唯一入口。把它藏起来
///    之后没法再回来开别的页签——所以壳层会在左下角留一个小的设置按钮。
///    这一点必须写在界面上，否则用户会以为「隐藏设置 = 以后再也改不了导航栏」。
///
/// ## 实时生效
///
/// 每次改动直接写进 [ShellSettingsController]（它通知壳层重建），**不需要点保存、
/// 不需要重启**。这也是不做「保存/取消」按钮的原因：拖一下就立刻能看到底部变化，
/// 比「改完再确认」更符合拖拽这种直接操作的手感。
class TabBarSettingsPage extends StatelessWidget {
  const TabBarSettingsPage({super.key, this.controller});

  /// 设置控制器（测试可注入）；为空时用应用级单例。
  final ShellSettingsController? controller;

  ShellSettingsController get _controller =>
      controller ?? ShellSettingsController.instance;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '底部导航栏管理',
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final tabs = _controller.tabs;
    final visibleCount = tabs.where((tab) => tab.visible).length;
    final settingsHidden = !_controller.settingsVisible;

    return ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: <Widget>[
        _buildIntro(visibleCount),
        const SizedBox(height: 12),
        // 拖拽排序：ReorderableListView 需要有限高度，这里用 shrinkWrap
        // 嵌在 ListView 里（本页条目固定 5 条，不存在长列表性能问题）。
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: tabs.length,
          // onReorderItem（不是已废弃的 onReorder）：它给的 newIndex 已经是
          // 「移动后的最终下标」，与 ShellSettings.withMove 的语义一致，
          // 调用方不必自己处理 off-by-one。
          onReorderItem: (from, to) => _controller.move(from, to),
          itemBuilder: (context, index) {
            final tab = tabs[index];
            return _TabTile(
              key: ValueKey<String>('tab.${tab.id}'),
              index: index,
              config: tab,
              // 「至少保留 1 个」：最后一个可见项不许关。
              canHide: _controller.canHide(tab.id),
              onToggle: (value) => _toggle(context, tab.id, value),
            );
          },
        ),
        if (settingsHidden) ...<Widget>[
          const SizedBox(height: 12),
          const _SettingsHiddenNotice(),
        ],
        const SizedBox(height: 12),
        _buildFooter(context),
      ],
    );
  }

  Future<void> _toggle(BuildContext context, String id, bool value) async {
    final accepted = await _controller.setVisible(id, value);
    if (accepted || !context.mounted) return;
    // 被「至少保留 1 个」拒绝：明确告诉用户为什么，而不是让开关弹回去。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(ShellSettings.lastTabMessage)),
    );
  }

  Widget _buildIntro(int visibleCount) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '当前显示 $visibleCount 个页签',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '拖动手柄调整顺序，开关控制显示与隐藏。改动立即生效，不用重启 App。'
            '至少要保留 1 个页签，否则底部导航就空了。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '说明',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '· 隐藏某个板块只是把它从底部导航里收起来，数据、缓存与图源都不受影响，'
            '随时可以再打开；\n'
            '· 桌面端（Windows / macOS）用的是左侧栏，顺序跟随这里的设置；\n'
            '· 隐藏「设置」后，左下角会出现一个小的设置按钮，点它回来改回这里。',
            style: TextStyle(fontSize: 12, height: 1.6, color: LumeTheme.muted),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _controller.restoreDefaults(),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认（全部显示）'),
          ),
        ],
      ),
    );
  }
}

/// 一行页签：拖拽手柄 + 名称 + 开关。
class _TabTile extends StatelessWidget {
  const _TabTile({
    super.key,
    required this.index,
    required this.config,
    required this.canHide,
    required this.onToggle,
  });

  final int index;
  final ShellTabConfig config;

  /// 是否允许被关掉（最后一个可见项不允许）。
  final bool canHide;

  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final tab = ShellTab.byId(config.id);
    final label = tab?.label ?? config.id;
    final isLastVisible = config.visible && !canHide;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            // 拖拽手柄：显式的拖动区，避免与开关的点击手势打架。
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Icon(
                  Icons.drag_handle,
                  size: 20,
                  color: LumeTheme.textHint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  if (isLastVisible) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      '最后一个显示的页签，不能关掉',
                      style: TextStyle(
                        fontSize: 12,
                        color: LumeTheme.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: config.visible,
              // 最后一颗开关置灰：点不动比「点了弹提示再弹回来」更清楚，
              // 且旁边的文字已经说明了原因。
              onChanged: canHide ? onToggle : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「设置页已隐藏」的提示卡：告诉用户怎么回来。
class _SettingsHiddenNotice extends StatelessWidget {
  const _SettingsHiddenNotice();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 20, color: LumeTheme.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '「设置」页签已隐藏：底部导航里看不到它了。'
              '为了避免再也进不来本页，屏幕左下角会出现一个小的设置按钮，'
              '点它就能回到设置（以及本页）。',
              style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
            ),
          ),
        ],
      ),
    );
  }
}
