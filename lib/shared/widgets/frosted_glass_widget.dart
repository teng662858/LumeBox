import '../../core/theme/lume_theme.dart';
import '../../core/theme/frosted_settings.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Explicit opt-in static glass; independent of floating module settings.
class FrostedGlassWidget extends StatelessWidget {
  const FrostedGlassWidget({
    super.key,
    this.blur = 18,
    this.opacity = .72,
    this.radius = 20,
    this.border = true,
    this.color,
    required this.child,
  }) : assert(blur >= 0 && blur < double.infinity),
       assert(opacity >= 0 && opacity <= 1),
       assert(radius >= 0 && radius < double.infinity);

  final double blur, opacity, radius;
  final bool border;
  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FrostedSettings.instance,
    builder: (context, _) {
      final enabled = FrostedSettings.instance.frostedEnabled;
      final corners = BorderRadius.circular(radius);
      Widget content = ColoredBox(
        color: enabled
            ? LumeTheme.readableGlass(
                (color ?? LumeTheme.surface).withValues(alpha: opacity),
              )
            : (color ?? LumeTheme.surface).withValues(alpha: 1),
        child: child,
      );
      if (enabled && blur > 0) {
        content = BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: content,
        );
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: corners,
          boxShadow: LumeTheme.cardShadow,
        ),
        child: ClipRRect(borderRadius: corners, child: content),
      );
    },
  );
}
