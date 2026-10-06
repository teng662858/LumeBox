import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// 磨砂玻璃层：半透明白底 + 背景模糊 + 极浅描边。
///
/// 用在「浮在内容之上」的表面上（顶部栏 / 底部栏 / 覆盖面板）——它下面有东西
/// 可透，才谈得上玻璃。直接铺在页面底色上的卡片不要用它（模糊一层纯色等于没
/// 模糊），那种场景要的是 [GlassCard] 的白底 + 阴影分层。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 0,
    this.blur = 24,
    this.color = LumeTheme.glass,
    this.border,
    this.padding,
  });

  final Widget child;

  /// 圆角；0 表示直角（整条顶栏 / 底栏）。
  final double radius;

  /// 模糊强度。
  final double blur;

  /// 玻璃底色（默认半透明白）。
  final Color color;

  /// 描边；为空时给一圈极浅边。
  final Border? border;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: border ?? Border.all(color: LumeTheme.hairline),
          ),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

/// 卡片：纯白底 + 极浅描边 + 极柔和阴影，靠微弱色差与阴影从底上浮起。
///
/// 与旧版「深色玻璃卡」的差别：**不再默认开背景模糊**。模糊只在「卡片压在封面 /
/// 图片之上」时有意义（那种场合传 [frosted]），铺在浅色底上的卡片开模糊等于白付
/// 代价——书架、章节列表这类页面动辄上百张卡，模糊的开销是实打实的。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.radius = 20,
    this.frosted = false,
    this.color,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final double radius;

  /// 是否磨砂（卡片压在图片 / 封面之上时打开）。
  final bool frosted;

  /// 自定义底色；为空时用纯白。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final border = BorderRadius.circular(radius);
    final decoration = color == null
        ? LumeTheme.cardDecoration(radius: radius)
        : BoxDecoration(
            color: color,
            borderRadius: border,
            border: Border.all(color: LumeTheme.hairline),
            boxShadow: LumeTheme.cardShadow,
          );
    final surface = DecoratedBox(
      decoration: decoration,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: border,
          child: Padding(
            padding: padding ?? const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
    if (!frosted) {
      return ClipRRect(borderRadius: border, child: surface);
    }
    return ClipRRect(
      borderRadius: border,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: surface,
      ),
    );
  }
}

/// 玻璃顶部栏：半透明磨砂条 + 标题 + 动作区（可选页签条）。
///
/// 磨砂层走 [AppBar] 的 `flexibleSpace`，因此标题居中、返回键、动作按钮、
/// 状态栏图标明暗这些既有行为全部保留。要让内容真的从栏下透出来，宿主页面需要
/// 开 `extendBodyBehindAppBar`，并让滚动内容滚到栏下（见 [GlassScaffold] 的
/// [GlassScaffold.behindBar]）。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    this.title,
    this.actions,
    this.bottom,
    this.leading,
    this.automaticallyImplyLeading,
    this.toolbarHeight,
    this.centerTitle,
  });

  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? leading;
  final bool? automaticallyImplyLeading;
  final double? toolbarHeight;
  final bool? centerTitle;

  @override
  Size get preferredSize => Size.fromHeight(
        (toolbarHeight ?? kToolbarHeight) + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      actions: actions,
      bottom: bottom,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading ?? true,
      toolbarHeight: toolbarHeight,
      centerTitle: centerTitle,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: const ClipRect(
        child: GlassPanel(
          border: Border(
            bottom: BorderSide(color: LumeTheme.hairline),
          ),
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 带玻璃顶部栏的页面骨架，供各板块页面复用。
///
/// 标题默认使用项目名称；板块页面传入对应板块名（小说 / 漫画等）。
///
/// 两种行为：
/// - **[behindBar] = false（默认）**：内容和以前一样从顶栏下方开始，顶栏是一层
///   半透明磨砂条（能透出页面底色与渐变，但内容不会从栏下滚过）；
/// - **[behindBar] = true**：内容铺满整屏（顶栏浮在其上），滚动内容从磨砂栏下
///   穿过——玻璃感来自这里。此时页面自己的滚动视图要让出顶栏高度：
///   用 [GlassScaffold.barInset]（滚动视图的 padding）或
///   [GlassScaffold.barHeight]（不是滚动视图的整块头部）。
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.bottom,
    this.leading,
    this.floatingActionButton,
    this.behindBar = false,
    this.resizeToAvoidBottomInset,
  });

  final Widget child;

  /// 页面标题。为空时回退到项目名称。
  final String? title;

  final List<Widget>? actions;

  /// 顶栏下方的页签条等（做成顶栏的一部分，与顶栏共用同一层磨砂）。
  final PreferredSizeWidget? bottom;

  final Widget? leading;
  final Widget? floatingActionButton;

  /// 内容是否铺到顶栏之下（见类文档）。
  final bool behindBar;

  final bool? resizeToAvoidBottomInset;

  /// 顶部栏占的高度：状态栏 + 工具栏 + 页签条（+ [extra]）。
  ///
  /// 用调用点自己的 context 读状态栏高度即可——这里刻意不去注入 / 改写
  /// MediaQuery，页面自身的 build 与它下面的子 widget 读到的值一致，
  /// 不必关心自己在哪一层。
  static double barHeight(BuildContext context, {double extra = 0}) =>
      MediaQuery.paddingOf(context).top +
      kToolbarHeight +
      (extra > 0 ? extra : 0);

  /// 内容要让出的顶部内边距（见 [barHeight]）。
  static EdgeInsets barInset(BuildContext context, {double extra = 0}) =>
      EdgeInsets.only(top: barHeight(context, extra: extra));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset ?? true,
      appBar: GlassAppBar(
        title: Text(title ?? LumeTheme.appName),
        actions: actions,
        bottom: bottom,
        leading: leading,
      ),
      floatingActionButton: floatingActionButton,
      body: DecoratedBox(
        decoration: LumeTheme.background,
        // 穿栏时顶部不设安全区（顶栏由内容自己用 barInset 让出）；
        // 左右与底部照常让开，底部安全区与悬浮 Dock 的高度都不会被内容压到。
        child: behindBar
            ? SafeArea(top: false, child: child)
            : SafeArea(child: child),
      ),
    );
  }
}
