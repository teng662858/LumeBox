import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// All bottom drawers share the home search button's lower edge.
class DrawerGeometry {
  static final Map<Size, double> _searchEdges = {};
  static double top(BuildContext context) {
    final media = MediaQuery.of(context);
    return (_searchEdges[media.size] ?? (media.viewPadding.top + 84)).clamp(
      media.viewPadding.top,
      media.size.height,
    );
  }

  static double height(BuildContext context) =>
      math.max(0, MediaQuery.sizeOf(context).height - top(context));
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
  bool useSafeArea = false,
  bool useRootNavigator = false,
  bool? showDragHandle,
  double? elevation,
}) {
  final top = DrawerGeometry.top(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    elevation: elevation,
    isScrollControlled: true,
    useSafeArea: false,
    useRootNavigator: useRootNavigator,
    showDragHandle: false,
    builder: (context) => SizedBox(
      key: const ValueKey('lume-bottom-drawer-frame'),
      height: math.max(0, MediaQuery.sizeOf(context).height - top),
      child: builder(context),
    ),
  );
}
