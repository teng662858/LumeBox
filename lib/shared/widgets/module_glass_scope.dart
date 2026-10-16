export '../../core/theme/glass_modules.dart';

import 'package:flutter/material.dart';

import '../../core/theme/glass_modules.dart';

class ModuleGlassScope extends InheritedWidget {
  const ModuleGlassScope({
    super.key,
    required this.module,
    this.part,
    required super.child,
  });
  final GlassModule module;
  final GlassPart? part;
  static GlassModule moduleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModuleGlassScope>()?.module ??
      GlassModule.all;
  static GlassPart? partOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModuleGlassScope>()?.part;
  @override
  bool updateShouldNotify(ModuleGlassScope oldWidget) =>
      module != oldWidget.module || part != oldWidget.part;
}
