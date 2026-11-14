import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/shell/dock_native_glass.dart';
import '../../core/theme/lume_theme.dart';
import 'native_glass_preview.dart';

class NativeGlassControl extends StatefulWidget {
  const NativeGlassControl({
    super.key,
    required this.kind,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.activeColor,
    this.inactiveColor,
    this.secondaryTrackValue,
    this.secondaryTrackColor,
    this.compact = false,
  });
  final bool compact;
  final String kind;
  final Object value;
  final ValueChanged<Object>? onChanged;
  final double min, max;
  final int? divisions;
  final ValueChanged<Object>? onChangeStart, onChangeEnd;
  final Color? activeColor, inactiveColor, secondaryTrackColor;
  final double? secondaryTrackValue;
  @override
  State<NativeGlassControl> createState() => _NativeGlassControlState();
}

class _NativeGlassControlState extends State<NativeGlassControl> {
  MethodChannel? channel;
  Map<String, Object> get params => {
    'control': widget.kind,
    'compact': widget.compact,
    'value': widget.value,
    'enabled': widget.onChanged != null,
    'min': widget.min,
    'max': widget.max,
    'dark': Theme.of(context).brightness == Brightness.dark,
    'tintColor': (widget.activeColor ?? LumeTheme.accentFillOf(context))
        .toARGB32(),
    if (widget.inactiveColor case final color?) 'trackColor': color.toARGB32(),
    'bufferedValue': ?widget.secondaryTrackValue,
    if (widget.secondaryTrackColor case final color?)
      'bufferedColor': color.toARGB32(),
  };
  Future<void> update() async {
    try {
      await channel?.invokeMethod<void>('update', params);
    } on PlatformException {
      /* View may be exiting. */
    } on MissingPluginException {
      /* Not registered in widget tests. */
    }
  }

  @override
  void didUpdateWidget(covariant NativeGlassControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    update();
  }

  Object normalize(Object? value) {
    if (widget.kind == 'switch') return value == true;
    var number = (value as num).toDouble().clamp(widget.min, widget.max);
    if (widget.divisions != null &&
        widget.divisions! > 0 &&
        widget.max > widget.min) {
      number =
          widget.min +
          ((number - widget.min) /
                      (widget.max - widget.min) *
                      widget.divisions!)
                  .round() /
              widget.divisions! *
              (widget.max - widget.min);
    }
    return number;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.compact ? 32 : 48,
    width: widget.kind == 'switch' ? 60 : null,
    child: NativeOverlayView(
      builder: (_) => UiKitView(
        viewType: DockNativeGlass.viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: {
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        onPlatformViewCreated: (id) {
          channel = MethodChannel('lumebox/glass_control_$id')
            ..setMethodCallHandler((call) async {
              if (!mounted || widget.onChanged == null) return;
              final value = normalize(call.arguments);
              switch (call.method) {
                case 'changed':
                  widget.onChanged?.call(value);
                case 'began':
                  widget.onChangeStart?.call(value);
                case 'ended':
                  widget.onChangeEnd?.call(value);
              }
            });
          update();
        },
      ),
    ),
  );
  @override
  void dispose() {
    channel?.setMethodCallHandler(null);
    super.dispose();
  }
}

class NativeSwitchListTile extends StatelessWidget {
  const NativeSwitchListTile.adaptive({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.dense,
    this.isThreeLine = false,
    this.selected = false,
    this.activeColor,
    this.activeTrackColor,
    this.controlAffinity = ListTileControlAffinity.platform,
    this.useNative = false,
  });
  final bool value, isThreeLine, selected, useNative;
  final ValueChanged<bool>? onChanged;
  final Widget? title, subtitle, secondary;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  final Color? activeColor, activeTrackColor;
  final ListTileControlAffinity controlAffinity;
  @override
  Widget build(BuildContext context) {
    final native =
        DockNativeGlass.supported &&
        (useNative || NativeGlassPreview.enabledOf(context));
    if (!native) {
      return SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
        contentPadding: contentPadding,
        dense: dense,
        isThreeLine: isThreeLine,
        selected: selected,
        activeTrackColor:
            activeTrackColor ?? activeColor ?? LumeTheme.accentFillOf(context),
        controlAffinity: controlAffinity,
      );
    }
    final control = NativeGlassControl(
      kind: 'switch',
      value: value,
      activeColor: activeTrackColor ?? activeColor,
      onChanged: onChanged == null ? null : (v) => onChanged!(v as bool),
    );
    return ListTile(
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      dense: dense,
      isThreeLine: isThreeLine,
      selected: selected,
      leading: controlAffinity == ListTileControlAffinity.leading
          ? control
          : secondary,
      trailing: controlAffinity == ListTileControlAffinity.leading
          ? secondary
          : control,
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

class NativeGlassSlider extends StatelessWidget {
  const NativeGlassSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
    this.activeColor,
    this.inactiveColor,
    this.semanticFormatterCallback,
    this.secondaryTrackValue,
    this.useNative = false,
    this.compact = false,
  });
  final bool useNative, compact;
  final double value, min, max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final Color? activeColor, inactiveColor;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final double? secondaryTrackValue;
  @override
  Widget build(BuildContext context) =>
      DockNativeGlass.supported &&
          (useNative || NativeGlassPreview.enabledOf(context))
      ? NativeGlassControl(
          kind: 'slider',
          compact: compact,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: activeColor ?? SliderTheme.of(context).activeTrackColor,
          inactiveColor:
              inactiveColor ?? SliderTheme.of(context).inactiveTrackColor,
          secondaryTrackValue: secondaryTrackValue,
          secondaryTrackColor: SliderTheme.of(context)
              .secondaryActiveTrackColor,
          onChanged: onChanged == null ? null : (v) => onChanged!(v as double),
          onChangeStart: onChangeStart == null
              ? null
              : (v) => onChangeStart!(v as double),
          onChangeEnd: onChangeEnd == null
              ? null
              : (v) => onChangeEnd!(v as double),
        )
      : Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          semanticFormatterCallback: semanticFormatterCallback,
          secondaryTrackValue: secondaryTrackValue,
        );
}
