import 'danmaku/danmaku_panel.dart';

import 'package:flutter/material.dart';

import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/module_glass_scope.dart';

/// Legacy controls keep their saved switch; popup panels always share the
/// surrounding video glass and never stack a second filter over it.
class PlaybackGlass extends StatelessWidget {
  const PlaybackGlass({
    super.key,
    required this.enabled,
    required this.child,
    this.dark = false,
  });
  final bool enabled, dark;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      enabled && !VideoGlassScope.active(context)
      ? ModuleGlassScope(
          module: GlassModule.video,
          part: GlassPart.panels,
          child: Theme(
            data: dark
                ? Theme.of(context).copyWith(
                    brightness: Brightness.dark,
                    colorScheme: Theme.of(context).colorScheme
                        .copyWith(brightness: Brightness.dark),
                  )
                : Theme.of(context),
            child: FrostedGlassWidget(
              part: GlassPart.panels,
              nativeGlass: true,
              translucentOverlay: true,
              neutralTint: true,
              color: dark ? const Color(0xFF171721) : null,
              child: child,
            ),
          ),
        )
      : child;
}

Future<T?> showPlaybackMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool glass,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool edgeDrawer = true,
  bool compact = false,
}) => showDanmakuPanel<T>(
  context: context,
  builder: builder,
  edgeDrawer: edgeDrawer,
  compact: compact,
);
