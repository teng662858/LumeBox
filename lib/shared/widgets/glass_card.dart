import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../features/shell/shell_dock.dart';

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

/// 顶栏「向上顶」的幅度：外框贴屏幕顶端，内容只做**状态栏避让**。
///
/// 用户口径（第六次反馈）：顶栏外框本来就铺到 y=0，但内容被**完整的**安全区
/// （刘海机 62）压在下面，视觉上「整条横条不能往上靠」。参考做法是
/// **容器贴顶、内容单独避让**：内容少让一档（默认 12），标题与图标跟着上移，
/// 中间内容区同时多出这一段。
///
/// 12 是保守值：刘海机状态栏 62，缩到 50 之后图标盒（34）落在 50..84，
/// 灵动岛（约 11..48）与两侧时间/电量（约 22..42）都在它上面，不会压到。
/// 小状态栏（无刘海机 / 安卓，inset ≤ 24）不缩——那里时间电量就贴着顶，
/// 缩了会撞上（见 [trimmedTopInset]）。
const double kLumeTopInsetTrim = 12;

/// 顶栏内容实际要让出的顶部高度：状态栏高度减去一档 [kLumeTopInsetTrim]。
///
/// 状态栏太薄时（无刘海机 / 安卓，≤ 24）原样返回：那里没有可让的余地。
double trimmedTopInset(double statusInset) {
  if (statusInset <= 24) return statusInset;
  final trim = statusInset - 24 < kLumeTopInsetTrim
      ? statusInset - 24
      : kLumeTopInsetTrim;
  return statusInset - trim;
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
/// 用户口径（第五次反馈）：再薄一档。这一档试过 34，几何回归当场逮到
/// **图标按钮被压到 32**（`NavigationToolbar` 在栏高等于控件盒高时会再挤一次）
/// ——那正是用户明确不许的「缩放控件」。因此工具栏停在 36：
/// 上下各留 1pt 的容器余量，控件保持 34 的布局盒；
/// 这一轮把「再薄一点」落在页签条上（38 → 36，见 [BoardTabHeader.height]）。
///
/// 34 是硬下限：右上角那排图标按钮经 compact 密度折算后的布局盒就是 34。
const double kLumeToolbarHeight = 36;

/// 两种行为：
/// - **[behindBar] = false（默认）**：内容和以前一样从顶栏下方开始，顶栏是一层
///   半透明磨砂条（能透出页面底色与渐变，但内容不会从栏下滚过）；
/// - **[behindBar] = true**：内容铺满整屏（顶栏浮在其上），滚动内容从磨砂栏下
///   穿过——玻璃感来自这里。此时页面自己的滚动视图要让出顶栏高度：
///   用 [GlassScaffold.barInset]（滚动视图的 padding）或
///   [GlassScaffold.barHeight]（不是滚动视图的整块头部）。
///
/// **底部安全区只在导航壳里让**（见 [_reservesBottom]）：壳里的页面底部被悬浮
/// Dock 占着，让出来的那一段正好是 Dock 的脚印；push 出来的二级页面底下什么都没有，
/// 再让就变成「内容铺不到底、底部空一截」。
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
    return trimmedTopInset(MediaQuery.paddingOf(context).top) +
        kLumeToolbarHeight +
        (extra > 0 ? extra : 0);
  }

  /// 内容要让出的顶部内边距（见 [barHeight]）。
  static EdgeInsets barInset(BuildContext context, {double extra = 0}) =>
      EdgeInsets.only(top: barHeight(context, extra: extra));

  @override
  Widget build(BuildContext context) {
    // 顶栏内容要让出的高度：**避让后的**状态栏 + 工具栏 + 页签条。
    // 用壳自己的 context 读（此时还没被 Scaffold 注入顶栏高度）。
    final statusInset = MediaQuery.paddingOf(context).top;
    final height =
        trimmedTopInset(statusInset) + kLumeToolbarHeight + bottomExtra;
    // 外框贴屏幕顶端、内容单独避让（用户口径 6）：把整条 AppBar 向上平移
    // 「让出来的那一档」，玻璃因此仍铺满状态栏区域（上沿被屏幕裁掉一点），
    // 而下沿与内部内容一起上移一档。Scaffold 给的约束不变，所以
    // body 的注入内边距仍是「未缩」的总高——下方 _GlassBarHeight 用 [height]
    // 覆盖它，列表与页面内容跟顶栏下沿严丝合缝。
    final unusedInset = statusInset - trimmedTopInset(statusInset);
    return Scaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset ?? true,
      appBar: unusedInset <= 0
          ? _buildBar()
          : _ShiftedAppBar(dy: unusedInset, child: _buildBar()),
      floatingActionButton: floatingActionButton,
      body: DecoratedBox(
        decoration: LumeTheme.background,
        // 穿栏时顶部不设安全区（顶栏由内容自己用 barInset 让出）；
        // 左右照常让开；**底部只在壳里让**（Dock 的脚印），二级页让内容铺到底
        // ——见 [_reservesBottom]。
        child: _GlassBarHeight(
          height: height,
          child: behindBar
              ? SafeArea(
                  top: false,
                  bottom: _reservesBottom(context),
                  child: child,
                )
              : SafeArea(
                  bottom: _reservesBottom(context),
                  child: child,
                ),
        ),
      ),
    );
  }

  /// 页签条高度。
  double get bottomExtra => bottom?.preferredSize.height ?? 0;

  /// 顶栏本体（外框是否整体上移由 [build] 决定）。
  GlassAppBar _buildBar() => GlassAppBar(
        title: Text(title ?? LumeTheme.appName),
        actions: actions,
        bottom: bottom,
        leading: leading,
      );
}

/// 底部安全区是否让出：**只在导航壳里让**。
///
/// 壳里的页面底部被悬浮 Dock 占着，而且 Flutter 在 `extendBody` 时已经把
/// `MediaQuery.padding.bottom` 换成了「Dock 的总高」——`SafeArea` 让出的那一段
/// 正好等于 Dock 的脚印：肉眼看不出（被胶囊盖住），也正是「最后一行不会被 Dock
/// 挡住」的实现，所以壳里必须继续让。
///
/// push 出来的二级页面（排行榜等「更多」页、各种设置页）**不在壳的子树里**，
/// 底部没有任何东西：同一段 `SafeArea` 就变成「内容铺不到底、底部空一截浅色条」
/// （用户口径：二级页底部的多余留白）。这些页面一律不让——内容一路铺到屏幕底边，
/// 最后一行由页面自己的尾部内边距兜住；需要固定底栏的页面（如筛选页）自己套
/// `SafeArea`。
///
/// 用 [BuildContext.getInheritedWidgetOfExactType] 而不是 `maybeOf`：这里只问
/// 「在不在壳里」，不需要跟着 Dock 的显隐重新构建整页。
bool _reservesBottom(BuildContext context) =>
    context.getInheritedWidgetOfExactType<ShellDockScope>() != null;

/// 把顶栏整体上移一档，同时保持 `PreferredSizeWidget` 契约。
///
/// 为什么是「整体平移」而不是「少加内边距」：`Scaffold` 按
/// `preferredSize + 状态栏高度` 给顶栏分配高度，改内边距只会让内容在那一格里
/// 悬空（玻璃下沿与页签条错位）。整体平移则让外框与内容一起上移，玻璃照样铺满
/// 状态栏区域，下沿与内容区严丝合缝（见 [kLumeTopInsetTrim]）。
class _ShiftedAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ShiftedAppBar({required this.dy, required this.child});

  final double dy;
  final PreferredSizeWidget child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) =>
      Transform.translate(offset: Offset(0, -dy), child: child);
}

/// 把「顶栏总高度」交给内容区（见 [GlassScaffold.barHeight]）。
class _GlassBarHeight extends InheritedWidget {
  const _GlassBarHeight({required this.height, required super.child});

  final double height;

  @override
  bool updateShouldNotify(_GlassBarHeight oldWidget) =>
      oldWidget.height != height;
}
