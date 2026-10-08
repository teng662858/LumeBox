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
    this.color,
    this.border,
    this.padding,
  });

  final Widget child;

  /// 圆角；0 表示直角（整条顶栏 / 底栏）。
  final double radius;

  /// 模糊强度。
  final double blur;

  /// 玻璃底色（默认半透明白）。
  /// 玻璃底色；为空时用当前主题的 [LumeTheme.glass]。
  ///
  /// 不能写成构造参数默认值：主题色随亮度变化，是取值而非常量。
  final Color? color;

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
            color: color ?? LumeTheme.glass,
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
        (toolbarHeight ?? kLumeToolbarHeight) +
        (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      // 右上角那排图标：默认 IconButton 是 48×48 + 内边距，四个连排会占掉大半
      // 个标题栏。这里压到 42 的触达尺寸、去掉内边距——比默认紧凑，但不至于
      // 挤在一起（用户反馈「收得太紧了，放开一点点」，因此从 38 放到 42）。
      actionsPadding: const EdgeInsets.only(right: 10),
      actions: actions == null
          ? null
          : <Widget>[
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(42, 42),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: actions!,
                ),
              ),
            ],
      bottom: bottom,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading ?? true,
      toolbarHeight: toolbarHeight ?? kLumeToolbarHeight,
      centerTitle: centerTitle,
      // 标题与图标**贴状态栏下沿**：Material 默认还会在工具栏里再垂直居中一次，
      // 视觉上就是「顶栏往下陷」（用户反馈）。这里把标题内边距收到最小，
      // 控件尺寸不变、只是整条内容上移。
      titleSpacing: 0,
      leadingWidth: 48,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: ClipRRect(
        // 顶栏容器圆角（用户口径：容器加圆角、控件尺寸不变）——只圆下沿两角，
        // 上沿贴着屏幕顶端保持直角。16 → 20：第三次口径要的是「大圆角」，这个
        // 半径在 36 高的工具栏 + 38 高的页签条上已经明显看得出两个圆角。
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
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
/// 顶栏工具栏高度。
///
/// 用户要求「顶部导航整条往上移、贴近状态栏，只留一小段标准安全边距，不要往下
/// 陷」：栏矮一档，标题与图标就跟着上移，内容区同时多出这段高度。
///
/// 用户口径（第三次反馈）：不再往外推坐标，而是**收窄容器自身的垂直高度**——
/// 上下内边距各收 2pt，文字与图标尺寸**完全不变**，中间内容区因此多出一截。
///
/// 36 是硬下限：右上角那排图标按钮经 compact 密度折算后的布局盒是 34
/// （见 [GlassAppBar] 的 actions 样式），再矮 AppBar 就会把它压到 32——
/// 那是「缩放控件」，用户明确不许。
const double kLumeToolbarHeight = 36;

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

  /// 顶部栏占的高度：状态栏 + 工具栏 + 页签条。
  ///
  /// 取值分两种情况，调用方不必关心自己在哪一层：
  /// - 调用点在**本壳的内容区之内**（板块内容、列表……）：直接取壳算好的完整高度，
  ///   此时 [extra] 会被忽略（高度里已经含页签条）；
  /// - 调用点在**壳之上**（页面自身 build 里就地构造 child 时）：按真实状态栏高度
  ///   现算，并用 [extra] 补上该页自己放进顶栏的页签条高度。
  ///
  /// 之所以在壳内不能一律用 `MediaQuery.paddingOf(context).top + kToolbarHeight`：
  /// Flutter 在 `extendBodyBehindAppBar` 时会把**顶栏总高度**注入 body 的
  /// MediaQuery 内边距（这是它保证「内容不被顶栏遮住」的机制），
  /// 在内容区里这么算就会把顶栏高度加两遍——这正是下面这个获取点的用途。
  static double barHeight(BuildContext context, {double extra = 0}) {
    final provided =
        context.dependOnInheritedWidgetOfExactType<_GlassBarHeight>();
    if (provided != null) return provided.height;
    return MediaQuery.paddingOf(context).top +
        kLumeToolbarHeight +
        (extra > 0 ? extra : 0);
  }

  /// 内容要让出的顶部内边距（见 [barHeight]）。
  static EdgeInsets barInset(BuildContext context, {double extra = 0}) =>
      EdgeInsets.only(top: barHeight(context, extra: extra));

  @override
  Widget build(BuildContext context) {
    // 顶栏总高度：用壳自己的 context 读（此时还没被 Scaffold 注入顶栏高度）。
    final height =
        MediaQuery.paddingOf(context).top + kLumeToolbarHeight + bottomExtra;
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
        child: _GlassBarHeight(
          height: height,
          child: behindBar
              ? SafeArea(top: false, child: child)
              : SafeArea(child: child),
        ),
      ),
    );
  }

  /// 页签条高度。
  double get bottomExtra => bottom?.preferredSize.height ?? 0;
}

/// 把「顶栏总高度」交给内容区（见 [GlassScaffold.barHeight]）。
class _GlassBarHeight extends InheritedWidget {
  const _GlassBarHeight({required this.height, required super.child});

  final double height;

  @override
  bool updateShouldNotify(_GlassBarHeight oldWidget) =>
      oldWidget.height != height;
}
