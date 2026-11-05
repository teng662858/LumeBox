import 'package:flutter/gestures.dart';

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/shell/shell_dock.dart';
import 'drawer_geometry.dart';

enum BrowseDrawerSide { left, right }

/// The initiating edge gesture remains the pointer owner while the route opens.
class BrowseDrawerMotion extends ChangeNotifier {
  BrowseDrawerMotion({this.side = BrowseDrawerSide.right});
  final BrowseDrawerSide side;
  double progress = 0;
  bool? open;
  void update(double value) {
    if (open != null) return;
    progress = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  void settle(bool value) {
    if (open != null) return;
    open = value;
    notifyListeners();
  }
}

double browseDrawerWidth(double width) => width;

Future<T?> showBrowseSideDrawer<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required BrowseDrawerSide side,
  BrowseDrawerMotion? motion,
  bool edgeToggle = false,
  bool useRootNavigator = true,
}) async {
  final dock = ShellDockScope.maybeOf(context);
  final token = Object();
  dock?.hide(token);
  try {
    return await _showBrowseSideDrawer<T>(
      context: context,
      builder: builder,
      side: side,
      motion: motion,
      edgeToggle: edgeToggle,
      useRootNavigator: useRootNavigator,
    );
  } finally {
    dock?.show(token);
  }
}

Future<T?> _showBrowseSideDrawer<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required BrowseDrawerSide side,
  BrowseDrawerMotion? motion,
  required bool edgeToggle,
  required bool useRootNavigator,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final top = DrawerGeometry.top(context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final label = MaterialLocalizations.of(context).modalBarrierDismissLabel;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  FocusManager.instance.primaryFocus?.unfocus();
  if (motion != null && motion.open == null) {
    // Navigator.push cancels active pointers. Preview in the overlay until the
    // initiating finger lifts; only then commit a modal route for Back/results.
    final overlay = navigator.overlay!;
    final controller = AnimationController(
      vsync: overlay,
      value: motion.progress,
      duration: const Duration(milliseconds: 220),
    );
    final released = Completer<void>();
    void sync() {
      if (motion.open == null) {
        controller.value = motion.progress;
      } else if (!released.isCompleted) {
        released.complete();
      }
    }

    final entry = OverlayEntry(
      builder: (overlayContext) => themes.wrap(
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final width = browseDrawerWidth(constraints.maxWidth);
              return AbsorbPointer(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: .42 * controller.value,
                        ),
                      ),
                    ),
                    Positioned(
                      top: top,
                      bottom: 0,
                      width: width,
                      left: side == BrowseDrawerSide.left ? 0 : null,
                      right: side == BrowseDrawerSide.right ? 0 : null,
                      child: Transform.translate(
                        offset: Offset(
                          (side == BrowseDrawerSide.left ? -1 : 1) *
                              width *
                              (1 - controller.value),
                          0,
                        ),
                        child: Material(
                          key: ValueKey('browse-${side.name}-drawer'),
                          color: Theme.of(context).colorScheme.surface,
                          elevation: 16,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SafeArea(
                            top: false,
                            bottom: false,
                            child: Builder(builder: builder),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    final history = LocalHistoryEntry(onRemove: () => motion.settle(false));
    ModalRoute.of(context)?.addLocalHistoryEntry(history);
    motion.addListener(sync);
    overlay.insert(entry);
    try {
      await released.future;
      if (!reduceMotion) {
        await controller.animateTo(motion.open! ? 1 : 0).orCancel;
      }
      motion.progress = motion.open! ? 1 : 0;
    } finally {
      motion.removeListener(sync);
      history.remove();
      entry.remove();
      entry.dispose();
      // The removed entry may still use the animation until the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }
  if (!context.mounted) return null;
  if (motion?.open == false) return null;
  return navigator.push<T>(
    _BrowseDrawerRoute<T>(
      builder: builder,
      side: side,
      motion: motion,
      edgeToggle: edgeToggle,
      top: top,
      reduceMotion: reduceMotion,
      label: label,
      themes: themes,
    ),
  );
}

class _BrowseDrawerRoute<T> extends PopupRoute<T> {
  _BrowseDrawerRoute({
    required this.builder,
    required this.side,
    required this.top,
    required this.reduceMotion,
    required this.label,
    required this.themes,
    this.motion,
    this.edgeToggle = false,
  });
  final WidgetBuilder builder;
  final BrowseDrawerSide side;
  final double top;
  final bool reduceMotion;
  final String label;
  final CapturedThemes themes;
  final BrowseDrawerMotion? motion;
  final bool edgeToggle;
  int? edgePointer;
  Offset edgeStart = Offset.zero, edgeTravel = Offset.zero;
  bool fromLeftEdge = false;
  late AnimationController movement;
  bool settled = false;
  bool closing = false;

  @override
  Duration get transitionDuration =>
      Duration(milliseconds: reduceMotion ? 0 : 220);
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String get barrierLabel => label;
  @override
  AnimationController createAnimationController() =>
      movement = super.createAnimationController();

  @override
  TickerFuture didPush() {
    final result = super.didPush();
    motion?.addListener(sync);
    sync();
    return result;
  }

  void sync() {
    final input = motion;
    if (input == null || settled || closing) return;
    movement.stop();
    movement.value = input.progress;
    if (input.open case final target?) {
      settled = true;
      if (target) {
        movement.forward();
      } else {
        dismiss();
      }
    }
  }

  void dismiss() {
    if (closing || !isCurrent) return;
    closing = true;
    navigator?.pop();
  }

  @override
  bool didPop(T? result) {
    closing = true;
    return super.didPop(result);
  }

  @override
  void dispose() {
    motion?.removeListener(sync);
    super.dispose();
  }

  double get sign => side == BrowseDrawerSide.left ? 1 : -1;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = browseDrawerWidth(constraints.maxWidth);
        final inset = math.min(top, constraints.maxHeight * .4);
        return themes.wrap(
          AnimatedBuilder(
            animation: animation,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 16,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                bottom: false,
                child: Builder(builder: builder),
              ),
            ),
            builder: (context, child) => Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (!edgeToggle || closing || edgePointer != null) return;
                final edges = MediaQuery.systemGestureInsetsOf(context);
                final x = event.localPosition.dx;
                final left = x >= edges.left && x <= edges.left + 28;
                final right =
                    x >= constraints.maxWidth - edges.right - 28 &&
                    x <= constraints.maxWidth - edges.right;
                if (!left && !right) return;
                edgePointer = event.pointer;
                fromLeftEdge = left && !right;
                edgeStart = event.localPosition;
                edgeTravel = Offset.zero;
              },
              onPointerMove: (event) {
                if (event.pointer == edgePointer) {
                  edgeTravel = event.localPosition - edgeStart;
                }
              },
              onPointerUp: (event) {
                if (event.pointer != edgePointer) return;
                edgePointer = null;
                final inward = fromLeftEdge ? edgeTravel.dx : -edgeTravel.dx;
                if (inward >= 64 && inward > edgeTravel.dy.abs() * 1.2) {
                  dismiss();
                }
              },
              onPointerCancel: (event) {
                if (event.pointer == edgePointer) edgePointer = null;
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Semantics(
                      label: label,
                      button: true,
                      child: GestureDetector(
                        key: const Key('browse-drawer-scrim'),
                        behavior: HitTestBehavior.opaque,
                        onTap: dismiss,
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: .42 * animation.value,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: inset,
                    bottom: 0,
                    left: side == BrowseDrawerSide.left ? 0 : null,
                    right: side == BrowseDrawerSide.right ? 0 : null,
                    width: width,
                    child: Transform.translate(
                      offset: Offset(-sign * width * (1 - animation.value), 0),
                      child: GestureDetector(
                        key: ValueKey('browse-${side.name}-drawer'),
                        dragStartBehavior: DragStartBehavior.down,
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) {
                          settled = true;
                          movement.stop();
                        },
                        onHorizontalDragUpdate: (details) {
                          if (!closing) {
                            movement.value += sign * details.delta.dx / width;
                          }
                        },
                        onHorizontalDragCancel: () {
                          if (!closing) movement.forward();
                        },
                        onHorizontalDragEnd: (details) {
                          if (closing) return;
                          final speed = sign * (details.primaryVelocity ?? 0);
                          if (speed < -650 ||
                              (speed <= 650 && movement.value < .5)) {
                            dismiss();
                          } else {
                            movement.forward();
                          }
                        },
                        child: child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
