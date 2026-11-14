import 'danmaku/danmaku_panel.dart';

import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';
import '../../core/shell/dock_liquid_settings.dart';
import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/module_glass_scope.dart';
import '../../shared/widgets/native_glass_preview.dart';

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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      FrostedSettings.instance,
      PlayerPanelActivity.depth,
    ]),
    builder: (context, _) {
      final native = NativeGlassPreview.enabledOf(context);
      if ((!enabled && !native) || VideoGlassScope.active(context)) {
        return child;
      }
      final shade = FrostedSettings.instance.playerGlassShade;
      return ModuleGlassScope(
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
            // UIKit samples Flutter overlays as a single surface. Suspend
            // control-bar glass through panel dismissal to avoid refracting
            // episode/settings text into the bars beneath the drawer.
            nativeGlass: PlayerPanelActivity.depth.value == 0,
            translucentOverlay: true,
            nativeStyle: dark && native ? DockNativeGlassStyle.thin : null,
            nativeBrightness: dark && native ? Brightness.light : null,
            neutralTint: dark && native,
            nativeBaseOpacity: dark && native ? shade : .32,
            opacity: dark && native ? shade : .72,
            color: dark
                ? native
                      ? Colors.black
                      : const Color(0xFF171721)
                : null,
            child: child,
          ),
        ),
      );
    },
  );
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
