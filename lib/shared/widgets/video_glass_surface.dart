import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';

/// One neutral glass material for video capsules, menus and modal panels.
/// Only the background is filtered; foreground widgets keep full opacity.
class VideoGlassSurface extends StatelessWidget {
  const VideoGlassSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.dark = false,
    this.materialOpacity = opacity,
  });

  static const tint = Colors.white;
  static const opacity = .58;
  static const panelOpacity = .78;
  static const foreground = Color(0xFF17181B);
  final Widget child;
  final double radius;
  final bool dark;
  final double materialOpacity;

  @override
  Widget build(BuildContext context) {
    if (VideoGlassScope.active(context)) return child;
    final inherited = Theme.of(context);
    final ink = dark ? const Color(0xFFF3F5F4) : foreground;
    final reduced =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.of(context).accessibleNavigation ||
        FrostedSettings.instance.reduceTransparency;
    final scheme = ColorScheme.fromSeed(
      seedColor: inherited.colorScheme.primary,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF202428) : const Color(0xFFF2F2F5),
    );
    final theme = inherited.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      disabledColor: const Color(0xFF777880),
      chipTheme: inherited.chipTheme.copyWith(
        color: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: Colors.transparent,
        selectedColor: Colors.transparent,
        disabledColor: Colors.transparent,
      ),
      dividerColor: Colors.black.withValues(alpha: .12),
      textTheme: inherited.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: IconThemeData(color: ink),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: ink),
      ),
      listTileTheme: inherited.listTileTheme.copyWith(
        textColor: ink,
        iconColor: ink,
      ),
      appBarTheme: inherited.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: inherited.inputDecorationTheme.copyWith(
        fillColor: Colors.white.withValues(alpha: .3),
        labelStyle: const TextStyle(color: Color(0xFF45464C)),
        hintStyle: const TextStyle(color: Color(0xFF64656D)),
      ),
    );
    Widget background = ColoredBox(
      color: (dark ? const Color(0xFF202428) : tint).withValues(
        alpha: reduced ? .97 : materialOpacity,
      ),
    );
    if (!reduced) {
      background = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: background,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(child: background),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .45),
                    width: .7,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: .12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          VideoGlassScope(
            child: Theme(
              data: theme,
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!.copyWith(color: ink),
                child: IconTheme(
                  data: IconThemeData(color: ink),
                  child: Material(
                    type: MaterialType.transparency,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VideoGlassScope extends InheritedWidget {
  const VideoGlassScope({super.key, required super.child});
  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoGlassScope>() != null;
  @override
  bool updateShouldNotify(VideoGlassScope oldWidget) => false;
}

/// Keep Flutter's popup route positioning, dismissal and result handling, while
/// rendering all entries over a single backdrop instead of one filter per row.
List<PopupMenuEntry<T>> videoGlassMenuEntries<T>(
  List<PopupMenuEntry<T>> entries,
) => [_VideoGlassMenuEntry<T>(entries)];

class _VideoGlassMenuEntry<T> extends PopupMenuEntry<T> {
  const _VideoGlassMenuEntry(this.entries);
  final List<PopupMenuEntry<T>> entries;
  @override
  double get height => entries.fold(0, (sum, entry) => sum + entry.height);
  @override
  bool represents(T? value) => false;
  @override
  State<_VideoGlassMenuEntry<T>> createState() =>
      _VideoGlassMenuEntryState<T>();
}

class _VideoGlassMenuEntryState<T> extends State<_VideoGlassMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => VideoGlassSurface(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.entries,
      ),
    ),
  );
}

/// The AlertDialog still owns focus, semantics, keyboard insets and constraints.
/// Its visible title, content and actions share one glass background.
Widget videoGlassDialogSurface(BuildContext context, Widget dialog) {
  if (dialog is! AlertDialog) return dialog;
  final theme = Theme.of(context);
  return AlertDialog(
    key: dialog.key,
    semanticLabel: dialog.semanticLabel,
    insetPadding: dialog.insetPadding,
    constraints: dialog.constraints,
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    contentPadding: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    content: VideoGlassSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (dialog.icon != null)
            Padding(
              padding: dialog.iconPadding ?? const EdgeInsets.all(16),
              child: dialog.icon!,
            ),
          if (dialog.title != null)
            Padding(
              padding:
                  dialog.titlePadding ??
                  const EdgeInsets.fromLTRB(24, 22, 24, 8),
              child: DefaultTextStyle(
                style: (dialog.titleTextStyle ?? theme.textTheme.titleLarge!)
                    .copyWith(color: VideoGlassSurface.foreground),
                child: dialog.title!,
              ),
            ),
          if (dialog.content != null)
            Flexible(
              child: Padding(
                padding:
                    dialog.contentPadding ??
                    const EdgeInsets.fromLTRB(24, 12, 24, 20),
                child: dialog.scrollable
                    ? SingleChildScrollView(child: dialog.content!)
                    : dialog.content!,
              ),
            ),
          if (dialog.actions?.isNotEmpty == true)
            Padding(
              padding:
                  dialog.actionsPadding ??
                  const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: OverflowBar(
                alignment: dialog.actionsAlignment ?? MainAxisAlignment.end,
                spacing: 8,
                children: dialog.actions!,
              ),
            ),
        ],
      ),
    ),
  );
}
