import 'package:flutter/material.dart';

import '../../core/theme/icon_customization.dart';

typedef EditAppIcon = void Function(
  BuildContext context,
  String slot,
  IconData? original,
);

class AppIconEditingScope extends InheritedWidget {
  const AppIconEditingScope({
    super.key,
    required this.onEdit,
    required super.child,
  });
  final EditAppIcon onEdit;
  static AppIconEditingScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppIconEditingScope>();
  @override
  bool updateShouldNotify(AppIconEditingScope oldWidget) =>
      onEdit != oldWidget.onEdit;
}

/// Keeps Icon's public type and sizing/semantics contract. Unchanged icons paint
/// through Icon.build directly, without duplicating icons or their actions.
class LumeIcon extends Icon {
  const LumeIcon(
    super.icon, {
    required this.slot,
    this.variant = false,
    this.label,
    this.group,
    this.fallback,
    super.key,
    super.size,
    super.fill,
    super.weight,
    super.grade,
    super.opticalSize,
    super.color,
    super.shadows,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
    super.blendMode,
    super.fontWeight,
  });
  final String slot;
  final bool variant;
  final String? label, group;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final registry = IconCustomization.instance;
    final id = registry.slotKey(slot, icon, variant);
    registry.seen(
      id,
      icon,
      label: label ?? context.findAncestorWidgetOfExactType<Tooltip>()?.message,
      group: group,
    );
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final selection = registry.choice(id, icon);
        final replacement = registry.glyph(selection);
        final image = registry.image(selection);
        Widget child;
        if (image != null) {
          final theme = IconTheme.of(context);
          final rawSize = size ?? theme.size ?? 24;
          final actualSize =
              (applyTextScaling ?? theme.applyTextScaling ?? false)
              ? MediaQuery.textScalerOf(context).scale(rawSize)
              : rawSize;
          child = Semantics(
            label: semanticLabel,
            child: ExcludeSemantics(
              child: SizedBox.square(
                dimension: actualSize,
                child: Opacity(
                  opacity: theme.opacity ?? 1,
                  child: Image.memory(
                    image.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    color: selection!.tint ? color ?? theme.color : null,
                    colorBlendMode: BlendMode.srcIn,
                    errorBuilder: (_, _, _) => _original(context),
                  ),
                ),
              ),
            ),
          );
        } else if (replacement != null) {
          child = Icon(
            replacement,
            size: size,
            fill: fill,
            weight: weight,
            grade: grade,
            opticalSize: opticalSize,
            color: color,
            shadows: shadows,
            semanticLabel: semanticLabel,
            textDirection: textDirection,
            applyTextScaling: applyTextScaling,
            blendMode: blendMode,
            fontWeight: fontWeight,
          ).build(context);
        } else {
          child = _original(context);
        }
        final editor = AppIconEditingScope.of(context);
        if (registry.editMode && editor != null && icon != null) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => editor.onEdit(context, id, icon),
            child: child,
          );
        }
        return child;
      },
    );
  }

  Widget _original(BuildContext context) => fallback ?? super.build(context);
}
