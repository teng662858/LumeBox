import 'package:flutter/material.dart';

import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/module_glass_scope.dart';
import '../../shared/widgets/native_glass_preview.dart';

/// Reader controls share the app material; comic artwork is never filtered.
class ComicGlassBackdrop extends StatelessWidget {
  const ComicGlassBackdrop({
    super.key,
    required this.radius,
    required this.child,
    this.color = Colors.white,
    this.opacity = .58,
  });
  final double radius;
  final Widget child;
  final Color color;
  final double opacity;
  @override
  Widget build(BuildContext context) => ModuleGlassScope(
    module: GlassModule.comic,
    part: GlassPart.panels,
    child: FrostedGlassWidget(
      key: const Key('comic.glass.backdrop'),
      radius: radius,
      part: GlassPart.panels,
      color: color,
      opacity: opacity,
      blur: 18,
      neutralTint: true,
      translucentOverlay: true,
      nativeGlass: NativeGlassPreview.enabledOf(context),
      child: child,
    ),
  );
}
