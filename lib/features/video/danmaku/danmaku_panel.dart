import '../../../shared/widgets/player_appearance_scope.dart';
import '../../../shared/widgets/native_glass_surfaces.dart';
import '../../../shared/widgets/video_glass_surface.dart';
import '../../../shared/widgets/module_glass_scope.dart';

import 'dart:async';
import 'dart:math' as math;

import '../player_layout.dart';

import 'package:flutter/material.dart';

/// Landscape: a right-edge drawer occupying 40% of the screen. Portrait: a bottom panel.
///
/// Only the panel moves; the barrier stays fixed. The frame handles the actual
/// view's keyboard inset, including input opened from a nested panel.
Future<T?> showDanmakuPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool edgeDrawer = true,
  double? maxPortraitHeight,
  bool compact = false,
}) {
  final back = PlayerPanelBackController();
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final route = RawDialogRoute<T>(
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: .22),
    transitionDuration: PlayerLayout.motion(context),
    transitionBuilder: (_, _, _, child) => child,
    pageBuilder: (context, animation, _) => themes.wrap(
      PlayerAppearanceScope(
        child: DanmakuPanelFrame(
          animation: animation,
          compact: compact,
          edgeDrawer: edgeDrawer,
          maxPortraitHeight: maxPortraitHeight,
          child: PlayerPanelScope(
            back: back,
            child: Builder(
              builder: (context) =>
                  _PanelBackGesture(back: back, child: builder(context)),
            ),
          ),
        ),
      ),
    ),
  );
  final result = navigator.push(route);
  PlayerPanelActivity._open(route);
  // popped resolves at the start of dismissal. UIKit must remain suspended
  // until the outgoing Flutter content has actually left the overlay.
  unawaited(route.completed.then((_) => PlayerPanelActivity._close(route)));
  return result;
}

class PlayerPanelActivity {
  static final depth = ValueNotifier<int>(0);
  static final _routes = <Route<dynamic>>[];
  static bool isTop(Route<dynamic>? route) =>
      _routes.isEmpty || identical(_routes.last, route);
  static void _open(Route<dynamic> route) {
    _routes.add(route);
    depth.value = _routes.length;
  }

  static void _close(Route<dynamic> route) {
    _routes.remove(route);
    depth.value = _routes.length;
  }
}

class DanmakuPanelFrame extends StatefulWidget {
  const DanmakuPanelFrame({
    super.key,
    required this.child,
    this.screenPadding,
    this.edgeDrawer = true,
    this.maxPortraitHeight,
    this.compact = false,
    this.animation,
  });
  final Animation<double>? animation;
  final bool compact;
  final Widget child;
  final EdgeInsets? screenPadding;
  final bool edgeDrawer;
  final double? maxPortraitHeight;
  @override
  State<DanmakuPanelFrame> createState() => _DanmakuPanelFrameState();
}

class _DanmakuPanelFrameState extends State<DanmakuPanelFrame>
    with WidgetsBindingObserver {
  double _dismissDistance = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    // Nested panels inherit a MediaQuery with its keyboard inset removed.
    // Read the actual view as well so an input panel still clears the keyboard.
    final view = View.of(context);
    final keyboard = math.max(
      media.viewInsets.bottom,
      view.viewInsets.bottom / view.devicePixelRatio,
    );
    final safe =
        widget.screenPadding ??
        MediaQuery.viewPaddingOf(
          Navigator.of(context, rootNavigator: true).context,
        );
    final edge = widget.edgeDrawer && landscape;
    // Keep a hard guarantee: subtract the keyboard inset even on iOS versions
    // where the modal sheet route does not resize its child on its own.
    final available = math.max(
      0.0,
      media.size.height -
          media.viewPadding.top -
          media.viewPadding.bottom -
          keyboard -
          16,
    );
    return AnimatedPadding(
      duration: PlayerLayout.motion(context, 180),
      curve: Curves.easeOutCubic,
      // 竖屏抽屉一律铺满屏宽、底部贴安全区；横屏仍是右侧 40% 贴边抽屉。
      padding: edge
          ? EdgeInsets.only(bottom: keyboard)
          : EdgeInsets.fromLTRB(
              0,
              keyboard > 0 ? 8 : media.viewPadding.top + 8,
              0,
              keyboard > 0
                  ? keyboard + 8
                  : math.max(media.viewPadding.bottom, 8.0),
            ),
      child: Align(
        alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
        child: SizedBox(
          key: const ValueKey('danmaku-panel-frame'),
          width: widget.compact
              ? math.min(340, media.size.width - safe.horizontal)
              : edge
              ? media.size.width * .4
              : landscape
              ? PlayerLayout.panelWidth(media.size.width - safe.horizontal - 32)
              : 560,
          height: widget.compact
              ? math.min(340, available)
              : edge
              ? math.max(0, media.size.height - keyboard)
              : landscape
              ? math.min(available, media.size.height * .85)
              : math.min(
                  widget.maxPortraitHeight ?? double.infinity,
                  available * (keyboard > 0 ? .85 : .40),
                ),
          child: ModuleGlassScope(
            module: GlassModule.video,
            part: GlassPart.panels,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                        begin: landscape
                            ? const Offset(1, 0)
                            : const Offset(0, 1),
                        end: Offset.zero,
                      )
                      .chain(CurveTween(curve: Curves.easeOutCubic))
                      .animate(
                        widget.animation ??
                            const AlwaysStoppedAnimation<double>(1),
                      ),
              child: GestureDetector(
                onVerticalDragStart: landscape
                    ? null
                    : (_) => _dismissDistance = 0,
                onVerticalDragUpdate: landscape
                    ? null
                    : (event) => _dismissDistance += event.primaryDelta ?? 0,
                onVerticalDragEnd: landscape
                    ? null
                    : (event) {
                        if (_dismissDistance >= 64 ||
                            (_dismissDistance > 0 &&
                                (event.primaryVelocity ?? 0) > 700)) {
                          Navigator.of(context).maybePop();
                        }
                      },
                child: ValueListenableBuilder<int>(
                  valueListenable: PlayerPanelActivity.depth,
                  builder: (context, _, child) => VideoGlassSurface(
                    nativeGlass: PlayerPanelActivity.isTop(
                      ModalRoute.of(context),
                    ),
                    radius: edge ? 0 : 24,
                    dark: Theme.of(context).brightness == Brightness.dark,
                    materialOpacity: .94,
                    filledOptions: true,
                    child: child!,
                  ),
                  child: MediaQuery.removeViewInsets(
                    context: context,
                    removeBottom: true,
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      removeBottom: true,
                      removeLeft: edge,
                      removeRight: edge,
                      child: Padding(
                        // 横屏贴边抽屉的内容对齐物理右边缘：iOS 横屏会把左右两侧
                        // 安全区都报成同一数值（它不知道机器朝哪边转），照搬右侧
                        // 数值会让卡片平白离屏 40–62pt，和 Android 观感不一致。
                        padding: edge
                            // 横屏贴边抽屉的工具条行放到面板最顶：不再让出顶部安全区，
                            // 否则在状态行下面空出一条。
                            ? EdgeInsets.only(
                                top: 0,
                                bottom: keyboard > 0 ? 0 : safe.bottom,
                              )
                            : EdgeInsets.zero,
                        child: Column(
                          children: [Expanded(child: widget.child)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks content opened from the player without changing global settings dialogs.
class PlayerPanelBackController {
  bool Function()? onBack;
}

class PlayerPanelScope extends InheritedWidget {
  const PlayerPanelScope({super.key, required this.back, required super.child});
  final PlayerPanelBackController back;
  static PlayerPanelBackController? backOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerPanelScope>()?.back;
  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerPanelScope>() != null;
  @override
  bool updateShouldNotify(PlayerPanelScope oldWidget) => false;
}

class _PanelBackGesture extends StatefulWidget {
  const _PanelBackGesture({required this.back, required this.child});
  final PlayerPanelBackController back;
  final Widget child;
  @override
  State<_PanelBackGesture> createState() => _PanelBackGestureState();
}

class _PanelBackGestureState extends State<_PanelBackGesture> {
  double distance = 0;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 20,
        child: GestureDetector(
          key: const ValueKey('player-panel-back-edge'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => distance = 0,
          onHorizontalDragUpdate: (event) =>
              distance += event.primaryDelta ?? 0,
          onHorizontalDragEnd: (_) {
            if (distance >= 64 && !(widget.back.onBack?.call() ?? false)) {
              Navigator.of(context, rootNavigator: true).maybePop();
            }
            distance = 0;
          },
          onHorizontalDragCancel: () => distance = 0,
        ),
      ),
    ],
  );
}

/// Input and help dialogs use the same player frame as episode selection.
Future<T?> showPlayerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool onlyInPlayer = false,
  bool useRootNavigator = true,
}) {
  if (onlyInPlayer && !PlayerPanelScope.active(context)) {
    return showGlassDialog<T>(
      context: context,
      builder: builder,
      useRootNavigator: useRootNavigator,
    );
  }
  return showDanmakuPanel<T>(
    context: context,
    maxPortraitHeight: 280,
    builder: (context) => _PlayerDialogBody(dialog: builder(context)),
  );
}

/// Auxiliary popups in shared settings retain their global presentation elsewhere.
Future<T?> showPlayerContextSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useSafeArea = true,
  bool showDragHandle = true,
}) => PlayerPanelScope.active(context)
    ? showDanmakuPanel<T>(context: context, builder: builder)
    : showGlassModalBottomSheet<T>(
        context: context,
        builder: builder,
        useSafeArea: useSafeArea,
        showDragHandle: showDragHandle,
      );

class _PlayerDialogBody extends StatelessWidget {
  const _PlayerDialogBody({required this.dialog});
  final Widget dialog;
  @override
  Widget build(BuildContext context) {
    final Widget? title, content;
    final List<Widget> actions;
    if (dialog is AlertDialog) {
      final alert = dialog as AlertDialog;
      title = alert.title;
      content = alert.content;
      actions = alert.actions ?? const [];
    } else if (dialog is SimpleDialog) {
      final simple = dialog as SimpleDialog;
      title = simple.title;
      content = ListView(
        padding: EdgeInsets.zero,
        children: simple.children ?? const [],
      );
      actions = const [];
    } else {
      return dialog;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                  child: title ?? const SizedBox.shrink(),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 22),
              ),
            ],
          ),
          const Divider(height: 16),
          Expanded(
            child: content == null
                ? const SizedBox.shrink()
                : content is ScrollView || content is SingleChildScrollView
                ? content
                : SingleChildScrollView(child: content),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: actions,
              ),
            ),
        ],
      ),
    );
  }
}
