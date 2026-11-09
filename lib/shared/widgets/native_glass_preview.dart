import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';
import '../../features/shell/dock_native_glass.dart';

class NativeGlassPreview extends InheritedNotifier<FrostedSettings> {
  NativeGlassPreview({super.key, required super.child})
    : super(notifier: FrostedSettings.instance);

  static bool enabledOf(BuildContext context) {
    if (!DockNativeGlass.supported) return false;
    final settings =
        context
            .dependOnInheritedWidgetOfExactType<NativeGlassPreview>()
            ?.notifier ??
        FrostedSettings.instance;
    return settings.nativePreview &&
        settings.frostedEnabled &&
        !settings.reduceTransparency &&
        !MediaQuery.highContrastOf(context);
  }
}
