import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 图源生成器（可视化爬虫模块）——**预留占位页**。
///
/// ## 定位
///
/// 工具附属功能，入口在**全局设置页**（不新增底部 Tab：底部 5 个主 Tab 保持不变，
/// 生成器不是主阅读板块，放设置页更合理）。
///
/// ## 本轮范围（Phase2 收尾）
///
/// 只搭 UI 骨架：网址输入框、正则 / 选择器配置区、生成与预览按钮的布局。
/// **所有交互按钮点击一律弹「功能开发中」**，不实现任何爬虫相关业务逻辑——
/// 不发请求、不解析页面、不生成脚本、不写图源。数据表（`crawler_config`）已在
/// [GeneratorDatabase] 里预留，字段齐备，后续迭代直接填充能力即可。
///
/// ## 为什么先把骨架摆出来
///
/// 一是让「生成器」在设置页里有确定的落点（避免将来再改导航结构）；
/// 二是把界面分区（输入 / 规则 / 产物）先定下来，后续迭代只需往格子里填逻辑，
/// 不再动布局。骨架里的分区与字段名，与数据库预留字段一一对应。
class SourceGeneratorPage extends StatelessWidget {
  const SourceGeneratorPage({super.key});

  /// 「功能开发中」的统一文案：说清这是什么状态、以及现在能用什么替代。
  static const String pendingMessage =
      '功能开发中：图源生成器（可视化爬虫）尚未实现。\n\n'
      '当前请手写图源脚本后导入——开发文档见仓库的 docs/lumesource-guide.md，'
      '里面带小说 / 漫画 / 视频三份可真跑的模板，照抄改地址即可。';

  /// 弹「功能开发中」（所有交互按钮共用）。
  void _pending(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('功能开发中'),
        content: const Text(pendingMessage),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      // 内容从玻璃顶栏底下穿过，顶部空间由列表的 barInset 让——见 settings_page
      // 的同名注释：漏了这一句，SafeArea 与 barInset 会各让一次栏高。
      behindBar: true,
      title: '图源生成器',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          const _PendingBanner(),
          const SizedBox(height: 16),
          _SectionCard(
            title: '目标网址',
            subtitle: '要生成图源的站点列表页或接口地址',
            children: <Widget>[
              const _DisabledField(
                icon: Icons.link,
                hint: 'https://example.com/list',
              ),
              const SizedBox(height: 12),
              _FieldRow(
                children: <Widget>[
                  const Expanded(
                    child: _DisabledField(
                      icon: Icons.sell_outlined,
                      hint: '分页参数名（如 page）',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DisabledDropdown(
                      label: '编码',
                      value: 'UTF-8',
                      options: const <String>['UTF-8', 'GBK'],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '正则 / 选择器配置',
            subtitle: '列表、详情、正文三处规则（对应数据表里的三个规则字段）',
            children: <Widget>[
              const _DisabledField(
                icon: Icons.format_list_bulleted,
                hint: '列表规则：条目选择器或正则',
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              const _DisabledField(
                icon: Icons.article_outlined,
                hint: '详情规则：标题 / 封面 / 简介',
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              const _DisabledField(
                icon: Icons.subject_outlined,
                hint: '正文规则：文本 / 图片列表 / 播放地址',
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              const _DisabledField(
                icon: Icons.code,
                hint: '附加请求头（JSON：UA / Referer / Cookie）',
                maxLines: 2,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '生成与预览',
            subtitle: '生成图源脚本，或先预览抓取结果',
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pending(context),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('预览抓取结果'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _pending(context),
                      icon: const Icon(Icons.auto_fix_high, size: 18),
                      label: const Text('生成图源脚本'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '生成的脚本会走对应板块的正常导入链路（与手动导入同一套校验），'
                '不会绕过板块隔离。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _ReservedNote(),
        ],
      ),
    );
  }
}

/// 顶部横幅：说清本页当前的状态。
class _PendingBanner extends StatelessWidget {
  const _PendingBanner();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.construction_outlined,
            size: 22,
            color: LumeTheme.accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '图源生成器（开发中）',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '这是预留的界面骨架：布局与字段已按规划摆好，功能尚未实现。'
                  '本页所有按钮点击后都会提示「功能开发中」。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: LumeTheme.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部说明：预留项边界（不碰核心逻辑）。
class _ReservedNote extends StatelessWidget {
  const _ReservedNote();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '预留扩展项',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '本模块为后续迭代预留，不影响 Phase2 已交付的图源、沙箱与播放器能力。'
            '配置存储表（crawler_config）已预先建好，字段含目标网址、三处规则、'
            '分页参数、编码、请求头与生成结果。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }
}

/// 分区卡片：标题 + 说明 + 内容。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// 一行并排字段：**窄屏自动竖排**。
///
/// 为什么需要判断而不是直接 `Row`：并排的两个字段各自带标签 / 提示文案，在
/// iPhone SE（320pt）这类窄屏上，光提示文案就撑破了半屏宽度——`Expanded` 只能
/// 约束外框，拦不住文字按最小固有宽度撑开，结果就是右侧溢出（实测 320pt 下
/// 溢出 17px，画面上是黄黑条纹）。窄屏竖排比压字号 / 截断提示更好：这两项
/// 本来就是并列的独立配置，竖排不损失任何信息。
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.children});

  final List<Widget> children;

  /// 低于这个宽度就竖排。取 360：iPhone SE / 老机型（320）会竖排，
  /// 主流机型（390+）保持并排。
  static const double stackBelow = 360;

  @override
  Widget build(BuildContext context) {
    // 用 MediaQuery 的**屏幕**宽度判断，而不是 LayoutBuilder：
    // 本组件铺在 ListView 里，拿到的高度约束是无限的，LayoutBuilder 在
    // 「无限高度 + 需要测量子项」时会引发一连串布局断言（实测 547 条错误）。
    // 判断「窄屏」本来就该看设备屏幕宽度，MediaQuery 正是这个口径。
    final screenWidth = MediaQuery.sizeOf(context).width;
    if (screenWidth < stackBelow) {
      // 竖排：把横排时的「横向间隔」换成等高间隔，并**拆掉 Expanded**。
      //
      // 拆 Expanded 是必须的：横排时子项靠 `Expanded` 平分宽度，而竖排后
      // Column 处在 ListView 的无限高度约束里，`Expanded` 会去撑满**无限高度**，
      // 直接触发「RenderFlex children have non-zero flex but incoming height
      // constraints are unbounded」。竖排时子项本来就靠父级宽度约束撑满整行，
      // 不需要 Expanded。
      final stacked = <Widget>[];
      for (final child in children) {
        if (child is SizedBox && child.width != null) {
          stacked.add(SizedBox(height: child.height ?? 12));
          continue;
        }
        stacked.add(child is Expanded ? child.child : child);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: stacked,
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// 禁用态输入框骨架。
///
/// 用 [AbsorbPointer] + 只读 [TextField] 而不是 `enabled: false`：禁用态的
/// 输入框在浅色主题下会整体灰掉，看不出「这里将来是个输入框」。骨架要的是
/// 「形态对、暂不可用」，因此保持正常外观、只拦住交互。
class _DisabledField extends StatelessWidget {
  const _DisabledField({
    required this.icon,
    required this.hint,
    this.maxLines = 1,
  });

  final IconData icon;
  final String hint;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: TextField(
        readOnly: true,
        maxLines: maxLines,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: LumeTheme.muted, fontSize: 13),
          icon: Icon(icon, size: 18, color: LumeTheme.muted),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// 禁用态下拉骨架。
class _DisabledDropdown extends StatelessWidget {
  const _DisabledDropdown({
    required this.label,
    required this.value,
    required this.options,
  });

  final String label;
  final String value;
  final List<String> options;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: <DropdownMenuItem<String>>[
          for (final option in options)
            DropdownMenuItem<String>(value: option, child: Text(option)),
        ],
        onChanged: (_) {},
      ),
    );
  }
}
