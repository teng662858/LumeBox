import 'package:flutter/material.dart';

/// Video and Cat keep their own stores; this scope only shares navigation.
class VideoSourceScope extends InheritedWidget {
  const VideoSourceScope({
    super.key,
    required this.openPicker,
    required super.child,
  });

  final Future<void> Function(BuildContext context) openPicker;

  static VideoSourceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoSourceScope>();

  @override
  bool updateShouldNotify(VideoSourceScope oldWidget) => false;
}
