import 'video_glass_surface.dart';

import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as material;

import '../../features/shell/dock_native_glass.dart';
import 'frosted_glass_widget.dart';
import 'native_glass_preview.dart';

Widget nativeDialogSurface(BuildContext context, Widget child) {
  if (!DockNativeGlass.supported || child is! AlertDialog) return child;
  final dialog = child;
  return Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding:
        dialog.insetPadding ??
        const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
    child: FrostedGlassWidget(
      radius: 28,
      nativeGlass: true,
      child: AlertDialog(
        title: dialog.title,
        titlePadding: dialog.titlePadding,
        titleTextStyle: dialog.titleTextStyle,
        content: dialog.content,
        contentPadding: dialog.contentPadding,
        contentTextStyle: dialog.contentTextStyle,
        actions: dialog.actions,
        actionsPadding: dialog.actionsPadding,
        actionsAlignment: dialog.actionsAlignment,
        actionsOverflowAlignment: dialog.actionsOverflowAlignment,
        actionsOverflowDirection: dialog.actionsOverflowDirection,
        actionsOverflowButtonSpacing: dialog.actionsOverflowButtonSpacing,
        buttonPadding: dialog.buttonPadding,
        icon: dialog.icon,
        iconPadding: dialog.iconPadding,
        iconColor: dialog.iconColor,
        semanticLabel: dialog.semanticLabel,
        alignment: dialog.alignment,
        scrollable: dialog.scrollable,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: EdgeInsets.zero,
      ),
    ),
  );
}

Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool nativeGlass = false,
  bool? videoGlass,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) => material.showDialog<T>(
  context: context,
  builder: (dialogContext) => (videoGlass ?? VideoGlassScope.active(context))
      ? videoGlassDialogSurface(dialogContext, builder(dialogContext))
      : nativeGlass || NativeGlassPreview.enabledOf(dialogContext)
      ? nativeDialogSurface(dialogContext, builder(dialogContext))
      : builder(dialogContext),
  barrierDismissible: barrierDismissible,
  barrierColor: barrierColor,
  barrierLabel: barrierLabel,
  useSafeArea: useSafeArea,
  useRootNavigator: useRootNavigator,
  routeSettings: routeSettings,
  anchorPoint: anchorPoint,
  traversalEdgeBehavior: traversalEdgeBehavior,
  fullscreenDialog: fullscreenDialog,
  requestFocus: requestFocus,
  animationStyle: animationStyle,
);

Future<T?> showGlassModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool nativeGlass = false,
  bool? videoGlass,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9 / 16,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  final useVideoGlass = videoGlass ?? VideoGlassScope.active(context);
  final useNativeGlass =
      DockNativeGlass.supported &&
      (nativeGlass ||
          (!isScrollControlled && NativeGlassPreview.enabledOf(context)));
  return material.showModalBottomSheet<T>(
    context: context,
    builder: (sheetContext) => useVideoGlass
        ? VideoGlassSurface(child: builder(sheetContext))
        : useNativeGlass
        ? FrostedGlassWidget(
            nativeGlass: true,
            radius: 28,
            child: builder(sheetContext),
          )
        : builder(sheetContext),
    backgroundColor: useVideoGlass || useNativeGlass
        ? Colors.transparent
        : backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: sheetAnimationStyle,
    requestFocus: requestFocus,
  );
}
