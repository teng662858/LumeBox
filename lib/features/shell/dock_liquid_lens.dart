import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ImageFilterConfig, ImageFilterContext;

/// Optical overlay painted after the dock's icons and labels.
///
/// Impeller filters the live backdrop directly. Other renderers use a matrix
/// lens; neither path captures frames or duplicates the interactive tab row.
class DockLiquidLens extends StatefulWidget {
  const DockLiquidLens({
    super.key,
    required this.path,
    required this.press,
    required this.stretch,
    required this.highlight,
    this.lean = 0,
    this.grip = 0,
    this.refraction = 1,
    this.dispersion = 1,
  });

  static const shaderAsset = 'assets/shaders/dock_liquid_lens.frag';
  static const filterKey = Key('shell.dock.lens.filter');
  final Path path;
  final double press, stretch, highlight;
  final double lean, grip;
  final double refraction, dispersion;

  @override
  State<DockLiquidLens> createState() => _DockLiquidLensState();
}

class _DockLiquidLensState extends State<DockLiquidLens> {
  static ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = _program ??= await ui.FragmentProgram.fromAsset(
        DockLiquidLens.shaderAsset,
      );
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (error) {
      // Retain the dock's existing glass if an asset/driver is unavailable.
      debugPrint('Dock lens shader unavailable: $error');
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size.isEmpty) return const SizedBox.shrink();
          final reduced = MediaQuery.disableAnimationsOf(context);
          final press = reduced ? 0.0 : widget.press.clamp(0.0, 1.0);
          final stretch = reduced ? 0.0 : widget.stretch.clamp(0.0, 1.0);
          final strength =
              (.07 + .20 * press + .14 * stretch) * widget.refraction;
          final shader = _shader;
          final ImageFilterConfig filter;
          if (shader != null && ui.ImageFilter.isShaderFilterSupported) {
            // Floats 0/1 and sampler 0 are owned by ImageFilter.shader.
            shader
              ..setFloat(2, strength)
              ..setFloat(
                3,
                (.004 + .018 * press + .014 * stretch) * widget.dispersion,
              )
              ..setFloat(4, widget.highlight.clamp(0.0, 1.0) * .16)
              ..setFloat(9, reduced ? 0 : widget.lean.clamp(-1.0, 1.0))
              ..setFloat(10, reduced ? 0 : widget.grip.clamp(-1.0, 1.0))
              ..setFloat(11, press);
            filter = _LensShaderFilter(
              shader,
              MediaQuery.devicePixelRatioOf(context),
              () => (context.findRenderObject()! as RenderBox).localToGlobal(
                Offset.zero,
              ),
            );
          } else {
            // Keep the backdrop stable while Impeller loads the shader. The
            // matrix fallback is for Skia; its translated backdrop sampling
            // differs on Impeller when nested inside another backdrop filter.
            filter = _LensMatrixFilter(
              ui.ImageFilter.isShaderFilterSupported ? 1 : 1 + strength,
            );
          }
          return ClipPath(
            clipper: _LensClipper(widget.path),
            child: BackdropFilter(
              key: DockLiquidLens.filterKey,
              filterConfig: filter,
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    ),
  );
}

/// ImageFilter.shader samples the whole input texture, not just the clip.
/// Resolve the capsule's current canvas bounds at paint time and convert them
/// to physical pixels. This also handles preview repaint boundaries and DPR.
class _LensShaderFilter implements ImageFilterConfig {
  const _LensShaderFilter(this.shader, this.pixelRatio, this.origin);
  final ui.FragmentShader shader;
  final double pixelRatio;
  final Offset Function() origin;
  @override
  String get debugShortDescription => 'dockLensShader';
  @override
  ui.ImageFilter get filter => ui.ImageFilter.shader(shader);
  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final bounds = context.bounds;
    final position = origin();
    shader
      ..setFloat(5, position.dx * pixelRatio)
      ..setFloat(6, position.dy * pixelRatio)
      ..setFloat(7, bounds.width * pixelRatio)
      ..setFloat(8, bounds.height * pixelRatio);
    return filter;
  }
}

/// Backdrop matrices act in canvas coordinates. Resolve at paint time so the
/// lens stays centered while margin, bottom gap, preview scroll or size change.
class _LensMatrixFilter implements ImageFilterConfig {
  const _LensMatrixFilter(this.zoom);
  final double zoom;
  @override
  String get debugShortDescription => 'dockLens($zoom)';
  @override
  ui.ImageFilter? get filter => null;
  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final center = context.bounds.center;
    final matrix = Matrix4.identity()
      ..setEntry(0, 0, zoom)
      ..setEntry(1, 1, zoom)
      ..setEntry(0, 3, center.dx * (1 - zoom))
      ..setEntry(1, 3, center.dy * (1 - zoom));
    return ui.ImageFilter.matrix(
      matrix.storage,
      filterQuality: FilterQuality.high,
    );
  }
}

class _LensClipper extends CustomClipper<Path> {
  const _LensClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_LensClipper oldClipper) => oldClipper.path != path;
}
