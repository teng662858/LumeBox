import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../reading/compact_browse_header.dart';
import 'dock_native_glass.dart';

class SystemSearchButton extends StatefulWidget {
  const SystemSearchButton({
    super.key,
    required this.size,
    required this.useNative,
    required this.onPressed,
  });
  static const viewType = 'lumebox/system_search_button';
  final double size;
  final bool useNative;
  final VoidCallback onPressed;
  @override
  State<SystemSearchButton> createState() => _SystemSearchButtonState();
}

class _SystemSearchButtonState extends State<SystemSearchButton> {
  MethodChannel? _channel;
  bool _failed = false;
  Map<String, Object> get _configuration {
    final settings = ShellSettingsController.instance.settings.nativeNavigation;
    return {
      'brightness': Theme.of(context).brightness.name,
      'tintColor': settings.solidIcons || settings.followThemeColor
          ? LumeTheme.accent.toARGB32()
          : settings.tintColor,
      'materialOpacity': settings.materialOpacity,
      'opaqueBackground': settings.opaqueBackground,
      'enabled': true,
    };
  }

  void _created(int id) {
    final channel = MethodChannel('${SystemSearchButton.viewType}_$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (mounted && identical(_channel, channel) && call.method == 'pressed') {
        widget.onPressed();
      }
    });
    unawaited(_update());
  }

  Future<void> _update() async {
    try {
      await _channel?.invokeMethod<void>('update', _configuration);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(SystemSearchButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_update());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_update());
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: widget.useNative && !_failed
        ? NativeOverlayView(
            builder: (_) => UiKitView(
              viewType: SystemSearchButton.viewType,
              creationParams: _configuration,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _created,
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  EagerGestureRecognizer.new,
                ),
              },
            ),
          )
        : DockSearchGlassButton(
            size: widget.size,
            appearance: ShellSettingsController.instance.appearance,
            onPressed: widget.onPressed,
            beside: true,
            tooltip: '全局搜索',
            surfaceKey: const ValueKey('global-search-surface'),
          ),
  );
}
