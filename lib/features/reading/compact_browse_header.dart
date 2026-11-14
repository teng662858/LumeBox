import 'package:flutter/material.dart';

import '../shell/dock_liquid_lens.dart';
import '../shell/dock_liquid_surface.dart';
import '../../core/theme/lume_theme.dart';
import '../shell/dock_native_glass.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/native_glass_preview.dart';
import '../../shared/widgets/lume_icon.dart';
import '../shell/shell_dock.dart';
import 'browse_layout_button.dart';

/// One row for source selection and the two collection shortcuts.
class CompactBrowseHeader extends StatelessWidget {
  const CompactBrowseHeader({
    super.key,
    required this.source,
    required this.actions,
    required this.mode,
    required this.onLayoutChanged,
  });
  final Widget source;
  final List<Widget> actions;
  final BrowseLayoutMode mode;
  final ValueChanged<BrowseLayoutMode> onLayoutChanged;

  @override
  Widget build(BuildContext context) {
    final header = DrawerSearchAnchor(
      child: Row(
        children: [
          Expanded(child: source),
          const SizedBox(width: 4),
          TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(
                fixedSize: const Size(56, 44),
                minimumSize: const Size(56, 44),
                maximumSize: const Size(56, 44),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                textStyle: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
          BrowseLayoutButton(
            mode: mode,
            onChanged: onLayoutChanged,
            quickSwitch: true,
          ),
        ],
      ),
    );
    return NativeGlassPreview.enabledOf(context)
        ? FrostedGlassWidget(nativeGlass: true, radius: 16, child: header)
        : header;
  }
}

class BrowseSearchButton extends StatefulWidget {
  const BrowseSearchButton({
    super.key,
    required this.onPressed,
    this.visible = true,
  });
  final VoidCallback? onPressed;
  final bool visible;

  @override
  State<BrowseSearchButton> createState() => _BrowseSearchButtonState();
}

class _BrowseSearchButtonState extends State<BrowseSearchButton> {
  ShellDockController? _controller;

  void _attach() {
    _controller?.attachSearch(
      this,
      widget.onPressed == null
          ? null
          : () {
              if (mounted) widget.onPressed?.call();
            },
    );
  }

  @override
  void deactivate() {
    _controller?.detachSearch(this);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ShellDockScope.maybeScopeOf(context);
    final controller =
        scope?.integratedSearch == true && TickerMode.valuesOf(context).enabled
        ? scope?.notifier
        : null;
    if (!identical(controller, _controller)) _controller?.detachSearch(this);
    _controller = controller;
    _attach();
    if (scope?.integratedSearch == true || !widget.visible) {
      // Keep the containing Stack sized by its positioned browse content.
      return const Positioned(
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }
    final beside = scope?.searchBesideDock == true;
    if (beside &&
        (scope?.notifier?.visible != true ||
            scope?.keyboardVisible == true ||
            MediaQuery.viewInsetsOf(context).bottom > 0)) {
      return const SizedBox.shrink();
    }
    final appearance = ShellSettingsController.instance.appearance;
    final navigationHeight = scope?.navigationHeight ?? appearance.height;
    final collapsed = beside && scope?.collapsed == true;
    final size = beside
        ? (collapsed
              ? (navigationHeight * .82).clamp(40.0, 150.0)
              : navigationHeight)
        : 52.0;
    final safe = scope?.safePadding ?? MediaQuery.viewPaddingOf(context);
    final margin =
        scope?.navigationMargin ??
        appearance.marginFor(
          MediaQuery.sizeOf(context).width - safe.horizontal,
          trailingWidth: size + 10,
        );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      // Keep one horizontal anchor throughout the animation. When the Dock
      // collapses, search joins the left-hand handle instead of staying right.
      left: beside
          ? collapsed
                ? safe.left + 8 + size + ShellDockScope.searchGap
                : MediaQuery.sizeOf(context).width - safe.right - margin - size
          : null,
      right: beside ? null : 16,
      bottom: beside
          ? scope?.dockBottom ?? safe.bottom + appearance.safeGap
          : safe.bottom + 12,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: size),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => DockSearchGlassButton(
          size: value,
          appearance: appearance,
          onPressed: widget.onPressed,
          beside: beside,
        ),
      ),
    );
  }
}

class DockSearchGlassButton extends StatefulWidget {
  const DockSearchGlassButton({
    super.key,
    this.tooltip = '搜索',
    this.surfaceKey = const ValueKey('browse-search-surface'),
    required this.size,
    required this.appearance,
    required this.onPressed,
    required this.beside,
  });
  final double size;
  final DockAppearance appearance;
  final VoidCallback? onPressed;
  final bool beside;
  final String tooltip;
  final Key surfaceKey;
  @override
  State<DockSearchGlassButton> createState() => _SearchGlassButtonState();
}

class _SearchGlassButtonState extends State<DockSearchGlassButton> {
  bool _pressed = false;
  final _surfaceKey = GlobalKey();
  Offset _origin() {
    final box = _surfaceKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) : Offset.zero;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: FloatingModules.instance,
    builder: (context, _) {
      final style = FloatingModules.instance.style(FloatingModule.dock);
      return Transform.translate(
        offset:
            ShellDockScope.maybeScopeOf(context)?.usesSystemNavigation == true
            ? Offset.zero
            : Offset(style.x, style.y),
        child: _surface(context),
      );
    },
  );

  Widget _surface(BuildContext context) {
    final liquid = widget.appearance.liquid;
    final style = FloatingModules.instance.style(FloatingModule.dock);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final glassColor = dark ? LumeTheme.glass : Colors.white;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final animate = widget.appearance.animateSelection && !reduced;
    final native =
        widget.beside &&
        DockNativeGlass.supported &&
        liquid.glassRenderer == DockGlassRenderer.nativeIos;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _pressed && animate ? 1 : 0),
      duration: Duration(
        milliseconds: animate ? widget.appearance.animationMs : 0,
      ),
      curve: Curves.easeOutBack,
      builder: (context, value, _) {
        final press = value.clamp(0.0, 1.0);
        final size = widget.size;
        return Transform.scale(
          scale: 1 + press * liquid.value(DockLiquidParameter.pressScale),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              key: _surfaceKey,
              fit: StackFit.expand,
              children: [
                if (native)
                  DockNativeGlass(
                    borderRadius: BorderRadius.circular(size / 2),
                    cornerRadius: size / 2,
                    style: liquid.nativeGlassStyle,
                    reduceTransparency: MediaQuery.highContrastOf(context),
                    tintColor: glassColor,
                    tintOpacity: liquid.value(DockLiquidParameter.nativeTint),
                  ),
                if (!native)
                  DockLiquidSurface(
                    filterKey: widget.surfaceKey,
                    borderRadius: BorderRadius.circular(size / 2),
                    blurSigma: style.blur,
                    fallbackSigma:
                        style.blur *
                        (1 -
                            press *
                                liquid.value(
                                  DockLiquidParameter.blurReduction,
                                )),
                    fallbackChild: DecoratedBox(
                      decoration: BoxDecoration(
                        color: glassColor.withValues(alpha: style.opacity),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: (dark ? Colors.white : const Color(0xFF6E6E73))
                              .withValues(
                                alpha:
                                    widget.appearance.borderOpacity *
                                    (dark ? 1 : .28),
                              ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: style.opacity * .35),
                            glassColor.withValues(alpha: style.opacity * .1),
                          ],
                        ),
                      ),
                    ),
                    lensRect: Rect.fromLTWH(0, 0, size, size),
                    lensRadius: size / 2,
                    lensScale: 1,
                    feather:
                        size * liquid.value(DockLiquidParameter.clarityFeather),
                    clarity: liquid.enabled(DockLiquidEffect.clarity)
                        ? press *
                              liquid.value(DockLiquidParameter.blurReduction)
                        : 0,
                    coreAlpha: liquid.value(DockLiquidParameter.coreAlpha),
                    backgroundAdapt: liquid.value(
                      DockLiquidParameter.backgroundAdapt,
                    ),
                    tintColor: glassColor,
                    tintOpacity: style.opacity,
                    pixelRatio: MediaQuery.devicePixelRatioOf(context),
                    stageOrigin: _origin,
                  ),
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: Listener(
                    onPointerDown: widget.onPressed == null
                        ? null
                        : (_) => setState(() => _pressed = true),
                    onPointerUp: (_) => setState(() => _pressed = false),
                    onPointerCancel: (_) => setState(() => _pressed = false),
                    child: IconButton(
                      tooltip: widget.tooltip,
                      onPressed: widget.onPressed,
                      constraints: BoxConstraints.tightFor(
                        width: size,
                        height: size,
                      ),
                      icon: LumeIcon(
                        Icons.search,
                        slot: 'browse.floating.search',
                        size: (size * .45).clamp(20, 40),
                      ),
                    ),
                  ),
                ),
                if (!native && liquid.enabled(DockLiquidEffect.optics))
                  DockLiquidLens(
                    path: Path()..addOval(Rect.fromLTWH(0, 0, size, size)),
                    press: press,
                    stretch: 0,
                    highlight: press,
                    refraction: liquid.value(DockLiquidParameter.refraction),
                    dispersion: liquid.value(DockLiquidParameter.dispersion),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
