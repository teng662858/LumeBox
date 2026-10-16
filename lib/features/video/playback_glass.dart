import '../../shared/widgets/drawer_geometry.dart';
import 'package:flutter/material.dart';

// Compatibility wrapper for existing routes; playback effects have been removed.
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
  Widget build(BuildContext context) => child;
}

Future<T?> showPlaybackMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool glass,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
}) => showLumeBottomSheet<T>(
  context: context,
  backgroundColor: backgroundColor,
  isScrollControlled: isScrollControlled,
  useSafeArea: useSafeArea,
  builder: builder,
);
