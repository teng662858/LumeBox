import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/shell/native_navigation_settings.dart';
import '../../core/theme/lume_theme.dart';
import 'shell_dock_bar.dart';

class SystemTabBarCapabilities {
  const SystemTabBarCapabilities({this.supported = false, this.height = 64});

  final bool supported;
  final double height;
  static const channel = MethodChannel('lumebox/system_tab_bar');

  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<SystemTabBarCapabilities> load() async {
    if (!isIOS) return const SystemTabBarCapabilities();
    try {
      final value = await channel.invokeMapMethod<String, Object?>(
        'capabilities',
      );
      return SystemTabBarCapabilities(
        supported: value?['supported'] == true,
        height: validHeight(value?['height']) ?? 64,
      );
    } on PlatformException {
      return const SystemTabBarCapabilities();
    } on MissingPluginException {
      return const SystemTabBarCapabilities();
    }
  }

  static double? validHeight(Object? value) =>
      value is num && value.isFinite && value >= 49 && value <= 100
      ? value.toDouble()
      : null;
}

/// Native UIKit glass controls. The platform view occupies only this bar's bounds;
/// it never owns or replaces the Flutter page controller.
class SystemDockBar extends StatelessWidget {
  const SystemDockBar({
    super.key,
    required this.entries,
    required this.activeId,
    required this.onSelect,
    required this.settings,
    required this.height,
    required this.bottomMargin,
    required this.onHeightChanged,
    required this.onUnavailable,
    this.trailingWidth = 0,
    this.visible = true,
  });

  static const viewType = 'lumebox/system_tab_bar';
  final List<ShellDockEntry> entries;
  final String activeId;
  final ValueChanged<String> onSelect;
  final NativeNavigationSettings settings;
  final double height;
  final double bottomMargin;
  final double trailingWidth;
  final bool visible;
  final ValueChanged<double> onHeightChanged;
  final VoidCallback onUnavailable;

  static double marginFor({
    required double width,
    required int entryCount,
    required double requested,
    required double trailingWidth,
  }) => requested.clamp(
    0.0,
    math.max(0.0, (width - trailingWidth - entryCount * 52) / 2),
  );

  @override
  Widget build(BuildContext context) {
    // Remove the native view and its event handler when hidden. A transparent
    // native bar must never remain on top of the keyboard, player or reader.
    if (!visible || entries.isEmpty) return const SizedBox.shrink();
    final safe = MediaQuery.viewPaddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final margin = marginFor(
          width: constraints.maxWidth - safe.horizontal,
          entryCount: entries.length,
          requested: settings.horizontalMargin,
          trailingWidth: trailingWidth,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            safe.left + margin,
            0,
            safe.right + margin + trailingWidth,
            math.max(0, bottomMargin),
          ),
          child: SizedBox(
            height: settings.heightFor(height),
            child: _SystemTabBarView(bar: this),
          ),
        );
      },
    );
  }
}

class _SystemTabBarView extends StatefulWidget {
  const _SystemTabBarView({required this.bar});
  final SystemDockBar bar;

  @override
  State<_SystemTabBarView> createState() => _SystemTabBarViewState();
}

class _SystemTabBarViewState extends State<_SystemTabBarView> {
  MethodChannel? _channel;
  String? _sent;
  bool _syncing = false;

  Map<String, Object> get _configuration {
    final bar = widget.bar;
    return {
      'entries': [
        for (final entry in bar.entries) {'id': entry.id, 'label': entry.label},
      ],
      'activeId': bar.activeId,
      'brightness': Theme.of(context).brightness.name,
      'showLabels': bar.settings.showLabels,
      'solidIcons': bar.settings.solidIcons,
      'iconSize': bar.settings.iconSize,
      'barHeight': bar.settings.barHeight,
      'materialOpacity': bar.settings.materialOpacity,
      'opaqueBackground': bar.settings.opaqueBackground,
      'tintColor': bar.settings.solidIcons
          ? (Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFFFFFFFF)
                    : const Color(0xFF161616))
                .toARGB32()
          : bar.settings.followThemeColor
          ? LumeTheme.accent.toARGB32()
          : bar.settings.tintColor,
    };
  }

  @override
  void didUpdateWidget(_SystemTabBarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_sync());
  }

  void _created(int id) {
    if (!mounted) return;
    final channel = MethodChannel('${SystemDockBar.viewType}_$id');
    _channel = channel;
    _sent = null;
    channel.setMethodCallHandler((call) async {
      if (!mounted || !identical(channel, _channel)) return;
      if (call.method == 'selected') {
        final id = call.arguments;
        if (id is String && widget.bar.entries.any((e) => e.id == id)) {
          widget.bar.onSelect(id);
        }
      } else if (call.method == 'metrics') {
        _metrics(call.arguments);
      }
    });
    unawaited(_sync());
  }

  void _metrics(Object? arguments) {
    if (arguments is! Map) return;
    final height = SystemTabBarCapabilities.validHeight(arguments['height']);
    if (height != null && height != widget.bar.height) {
      widget.bar.onHeightChanged(height);
    }
  }

  Future<void> _sync() async {
    final channel = _channel;
    if (channel == null || _syncing) return;
    _syncing = true;
    try {
      // Coalesce slider/selection changes while a previous update is in flight.
      // Native completion always receives the latest state, including reorder.
      while (mounted && identical(channel, _channel)) {
        final parameters = _configuration;
        final signature = jsonEncode(parameters);
        if (_sent == signature) break;
        _sent = signature;
        final metrics = await channel.invokeMethod<Object?>(
          'update',
          parameters,
        );
        if (mounted && identical(channel, _channel)) _metrics(metrics);
      }
    } on PlatformException {
      if (mounted) widget.bar.onUnavailable();
    } on MissingPluginException {
      if (mounted) widget.bar.onUnavailable();
    } finally {
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiKitView(
    viewType: SystemDockBar.viewType,
    creationParams: _configuration,
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: _created,
    gestureRecognizers: {
      Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
    },
  );
}
