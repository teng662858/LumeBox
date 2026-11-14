import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/shell/dock_liquid_settings.dart';

/// iOS 原生系统材质底座，供底栏和全局玻璃表面共用。
///
/// iOS 26 原生层使用 `UIGlassEffect`，旧系统回退磨砂。
/// Flutter 侧负责布局，图标/文字/交互仍由 Flutter
/// 绘制，因此这是“原生材质底座 + Flutter 内容层”，不是完整的原生 TabBar。
///
/// 材质的模糊、折射与高光由系统管理；配置通过通道更新，避免重建原生视图。
class DockNativeGlass extends StatefulWidget {
  const DockNativeGlass({
    super.key,
    required this.borderRadius,
    required this.cornerRadius,
    this.style = DockNativeGlassStyle.regular,
    this.tintColor = Colors.white,
    this.tintOpacity = .06,
    this.reduceTransparency = false,
    this.materialOpacity = 1,
  });

  static const String viewType = 'lumebox/glass_backdrop';
  static const String updateChannelPrefix = 'lumebox/glass_backdrop';

  /// 只有 iPhone 真机/模拟器才有原生 `UIVisualEffectView`。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  final BorderRadius borderRadius;
  final double cornerRadius;
  final DockNativeGlassStyle style;
  final Color tintColor;
  final double tintOpacity;
  final bool reduceTransparency;
  final double materialOpacity;

  @override
  State<DockNativeGlass> createState() => _DockNativeGlassState();
}

class _DockNativeGlassState extends State<DockNativeGlass> {
  MethodChannel? _channel;
  Map<String, Object?>? _sent;

  Map<String, Object?> get _configuration => <String, Object?>{
    'style': widget.style.name,
    'cornerRadius': widget.cornerRadius,
    'brightness': Theme.of(context).brightness.name,
    'reduceTransparency': widget.reduceTransparency,
    'tintColor': widget.tintColor.toARGB32(),
    'tintOpacity': widget.tintOpacity,
    'materialOpacity': widget.materialOpacity,
  };

  @override
  void didUpdateWidget(DockNativeGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pushConfiguration();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pushConfiguration();
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('${DockNativeGlass.updateChannelPrefix}_$id');
    _sent = null;
    _pushConfiguration();
  }

  Future<void> _pushConfiguration() async {
    final channel = _channel;
    if (channel == null) return;
    final params = _configuration;
    if (mapEquals(_sent, params)) return;
    _sent = params;
    try {
      await channel.invokeMethod<void>('update', params);
    } on PlatformException catch (error) {
      _sent = null;
      debugPrint('Native dock configuration unavailable: $error');
    } on MissingPluginException {
      _sent = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DockNativeGlass.supported) return const SizedBox.expand();
    return NativeOverlayView(
      builder: (_) => IgnorePointer(
        child: UiKitView(
          viewType: DockNativeGlass.viewType,
          creationParams: _configuration,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
      ),
    );
  }
}

/// Dispose UIKit overlays during route transitions rather than offstaging them.
/// A non-opaque popup must keep the underlying material visible.
class NativeOverlayView extends StatelessWidget {
  const NativeOverlayView({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    final ticking = TickerMode.valuesOf(context).enabled;
    return AnimatedBuilder(
      animation: animation ?? const AlwaysStoppedAnimation<double>(1),
      builder: (context, _) {
        if (!ticking ||
            route?.offstage == true ||
            (animation != null &&
                animation.status != AnimationStatus.completed)) {
          return const SizedBox.expand();
        }
        return builder(context);
      },
    );
  }
}
