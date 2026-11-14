import 'native_glass_surfaces.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Bottom sheets follow the search anchor; source/filter drawers use safe top.
class DrawerGeometry {
  static final Map<Size, double> _searchEdges = {};
  static double top(BuildContext context) {
    final media = MediaQuery.of(context);
    final browse = context
        .dependOnInheritedWidgetOfExactType<BrowseDrawerGeometry>();
    if (browse != null) {
      return browse.top.clamp(0.0, media.size.height);
    }
    return (_searchEdges[media.size] ?? (media.viewPadding.top + 84)).clamp(
      media.viewPadding.top,
      media.size.height,
    );
  }

  static double height(BuildContext context) =>
      math.max(0, MediaQuery.sizeOf(context).height - top(context));

  /// SafeArea may have consumed the page's padding. The Flutter view still
  /// reports the system cutout. Only the panel content is inset; its background
  /// extends behind the status bar to the top of the screen.
  static double browseTop(BuildContext context) {
    final media = MediaQuery.of(context), view = View.of(context);
    final safeTop = math.max(
      media.viewPadding.top,
      view.viewPadding.top / view.devicePixelRatio,
    );
    return (safeTop + 4).clamp(0.0, media.size.height);
  }
}

class BrowseDrawerGeometry extends InheritedWidget {
  const BrowseDrawerGeometry({
    super.key,
    required this.top,
    required super.child,
  });
  final double top;
  @override
  bool updateShouldNotify(BrowseDrawerGeometry oldWidget) =>
      top != oldWidget.top;
}

/// Measures the home search control in screen coordinates, without changing layout.
class DrawerSearchAnchor extends SingleChildRenderObjectWidget {
  const DrawerSearchAnchor({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SearchAnchorRender(MediaQuery.sizeOf(context));
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _SearchAnchorRender).screenSize = MediaQuery.sizeOf(
      context,
    );
  }
}

class _SearchAnchorRender extends RenderProxyBox {
  _SearchAnchorRender(this.screenSize);
  Size screenSize;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final bottom = localToGlobal(Offset(0, size.height)).dy;
    if (bottom > 0 && bottom < screenSize.height / 2) {
      DrawerGeometry._searchEdges[screenSize] = bottom;
    }
  }
}

Future<T?> showLumeBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool useRootNavigator = false,
  bool? showDragHandle,
  double? elevation,
}) {
  final top = DrawerGeometry.top(context);
  return showGlassModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    elevation: elevation,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    showDragHandle: false,
    builder: (context) => ConstrainedBox(
      key: const ValueKey('lume-bottom-drawer-frame'),
      constraints: BoxConstraints(
        maxHeight: math.max(0, MediaQuery.sizeOf(context).height - top),
      ),
      child: builder(context),
    ),
  );
}
