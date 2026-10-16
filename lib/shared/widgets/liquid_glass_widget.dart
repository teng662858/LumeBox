import '../../core/theme/lume_theme.dart';
import '../../core/theme/liquid_performance_guard.dart';
import 'module_glass_scope.dart';
import 'frosted_glass_widget.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';

/// Explicit opt-in liquid surface, controlled by global and module settings.
/// Large surfaces share the performance guard and fall back during sustained jank.
/// [child] is the complete existing UI, returned unchanged when disabled.
class LiquidGlassWidget extends StatelessWidget {
  const LiquidGlassWidget({
    super.key,
    this.blur = 8,
    this.highlight = .5,
    this.distort = .3,
    this.opacity = .12,
    this.radius = 20,
    this.speed = 1,
    this.border = false,
    required this.child,
    this.legacy,
    this.area,
  }) : assert(blur >= 0 && blur < double.infinity),
       assert(highlight >= 0 && highlight <= 1),
       assert(distort >= 0 && distort <= 1),
       assert(opacity >= 0 && opacity <= 1),
       assert(radius >= 0 && radius < double.infinity);

  final double blur, highlight, distort, opacity, radius, speed;
  final bool border;
  final Widget child;
  final Widget? legacy;
  Widget get fallback => legacy ?? child;
  final GlassArea? area;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) {
      final settings = GlassEffectsSettings.instance;
      if (area != null) {
        final part = area == GlassArea.subscriptionBadges
            ? GlassPart.badges
            : GlassPart.buttons;
        final module = ModuleGlassScope.moduleOf(context);
        if (settings.hasModuleConfiguration(module, part)) {
          final tune = settings.moduleTuning(module, part);
          if (!tune.enabled) return fallback;
          if (!tune.liquid) {
            if (!settings.frostedEnabled) return fallback;
            return FrostedGlassWidget(
              blur: tune.blur,
              opacity: tune.opacity,
              radius: tune.radius,
              border: tune.border,
              child: child,
            );
          }
          if (!settings.liquidEnabled ||
              !ui.ImageFilter.isShaderFilterSupported) {
            return fallback;
          }
          return _LiquidSurface(
            options: LiquidGlassWidget(
              blur: tune.blur,
              opacity: tune.opacity,
              radius: tune.radius,
              highlight: tune.highlight,
              distort: tune.distort,
              speed: tune.speed,
              border: tune.border,
              legacy: legacy,
              child: child,
            ),
          );
        }
      }
      // Do not even allocate a shader/ticker/clip when off. Unsupported
      // renderers also use the exact legacy UI instead of a weaker imitation.
      if (!GlassEffectsSettings.instance.liquidEnabled ||
          area != null && !GlassEffectsSettings.instance.active(area!) ||
          !ui.ImageFilter.isShaderFilterSupported) {
        return fallback;
      }
      if (area == null) return _LiquidSurface(options: this);
      final tune = GlassEffectsSettings.instance.tuning(area!);
      return _LiquidSurface(
        options: LiquidGlassWidget(
          blur: tune.blur,
          opacity: tune.opacity,
          radius: tune.radius,
          highlight: tune.highlight,
          distort: tune.distort,
          speed: tune.speed,
          border: tune.border,
          legacy: legacy,
          child: child,
        ),
      );
    },
  );
}

class _LiquidSurface extends StatefulWidget {
  const _LiquidSurface({required this.options});
  final LiquidGlassWidget options;

  @override
  State<_LiquidSurface> createState() => _LiquidSurfaceState();
}

class _LiquidSurfaceState extends State<_LiquidSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _program;
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  ui.FragmentShader? _shader;
  final _guard = LiquidPerformanceGuard.instance;
  int _lastBucket = -1;
  LiquidQuality? _lastQuality;
  Widget? _cachedSurface;

  @override
  void initState() {
    super.initState();
    _guard.attach();
    _animation.duration = Duration(
      milliseconds: (12000 / widget.options.speed.clamp(.25, 2)).round(),
    );
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'assets/shaders/liquid_glass.frag',
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // A missing shader is a legacy fallback, never a broken control.
      _program = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _guard.detach();
    _animation.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LiquidSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cachedSurface = null;
    _lastBucket = -1;
    if (oldWidget.options.speed != widget.options.speed) {
      _animation.duration = Duration(
        milliseconds: (12000 / widget.options.speed.clamp(.25, 2)).round(),
      );
      if (!MediaQuery.disableAnimationsOf(context)) _animation.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final options = widget.options;
    if (shader == null) return options.fallback;
    return AnimatedBuilder(
      animation: Listenable.merge([_animation, _guard]),
      child: options.child,
      builder: (context, child) {
        if (_guard.quality == LiquidQuality.legacy) return options.fallback;
        final fps = _guard.animationFps;
        final seconds = 12 / options.speed.clamp(.25, 2);
        final bucket = (_animation.value * seconds * fps).floor();
        if (bucket == _lastBucket &&
            _lastQuality == _guard.quality &&
            _cachedSurface != null) {
          return _cachedSurface!;
        }
        _lastBucket = bucket;
        _lastQuality = _guard.quality;
        final reduced = _guard.quality == LiquidQuality.reduced;
        final phase = bucket / (seconds * fps);
        shader
          ..setFloat(2, phase * 6.283185307)
          ..setFloat(3, reduced ? options.distort * .35 : options.distort)
          ..setFloat(4, options.highlight);
        return _cachedSurface = ClipRRect(
          borderRadius: BorderRadius.circular(options.radius),
          child: BackdropFilter(
            filter: ui.ImageFilter.compose(
              outer: ui.ImageFilter.shader(shader),
              inner: ui.ImageFilter.blur(
                sigmaX: reduced ? options.blur.clamp(0, 6) : options.blur,
                sigmaY: reduced ? options.blur.clamp(0, 6) : options.blur,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(options.radius),
                color: LumeTheme.readableGlass(
                  Theme.of(context).colorScheme.surface
                      .withValues(alpha: options.opacity),
                ),
                boxShadow: LumeTheme.cardShadow,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
