import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/appearance.dart';
import '../../core/theme/cover_palette.dart';
import '../../core/theme/lume_theme.dart';

/// Home-only adaptation: does not write a sampled color back to user settings
/// or rebuild/reload the navigation shell when a recommendation changes.
class AdaptiveCoverSurface extends StatefulWidget {
  const AdaptiveCoverSurface({
    super.key,
    required this.child,
    this.item,
    this.pipeline,
    this.sampleColor,
  });
  final Widget child;
  final SourceItem? item;
  final SectionImagePipeline? pipeline;
  final Future<Color?> Function()? sampleColor;
  @override
  State<AdaptiveCoverSurface> createState() => _AdaptiveCoverSurfaceState();
}

class _AdaptiveCoverSurfaceState extends State<AdaptiveCoverSurface> {
  static final _cache = <String, Color>{};
  final _appearance = AppearanceController.instance;
  Color? _color;
  int _generation = 0;
  late bool _enabled = _appearance.settings.adaptiveColor;

  @override
  void initState() {
    super.initState();
    _appearance.addListener(_changed);
    _sample();
  }

  void _changed() {
    final enabled = _appearance.settings.adaptiveColor;
    if (_enabled != enabled) {
      _enabled = enabled;
      _generation++;
      if (enabled) _sample();
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(AdaptiveCoverSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item?.id != oldWidget.item?.id ||
        widget.item?.cover != oldWidget.item?.cover ||
        !mapEquals(widget.item?.coverHeaders, oldWidget.item?.coverHeaders) ||
        widget.pipeline != oldWidget.pipeline ||
        widget.sampleColor != oldWidget.sampleColor) {
      _color = null;
      _sample();
    }
  }

  Future<void> _sample() async {
    final generation = ++_generation;
    if (!_enabled) return;
    Color? color;
    final pipe = widget.pipeline, item = widget.item;
    try {
      if (widget.sampleColor != null) {
        color = await widget.sampleColor!();
      } else if (pipe != null &&
          item != null &&
          (item.cover?.isNotEmpty ?? false)) {
        final url = item.cover!;
        final headers = item.coverHeaders.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final key =
            '${pipe.section.id}|${identityHashCode(pipe)}|$url|$headers';
        color = _cache.remove(key);
        if (color != null) {
          _cache[key] = color;
        } else {
          pipe.configureImageHeaders({url: item.coverHeaders});
          final image = await pipe.colorSample(url);
          if (image != null) {
            try {
              if (!mounted || generation != _generation) return;
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              if (bytes != null) {
                color = dominantCoverColor(
                  bytes.buffer.asUint8List(
                    bytes.offsetInBytes,
                    bytes.lengthInBytes,
                  ),
                );
              }
            } finally {
              image.dispose();
            }
          }
          if (color != null) {
            _cache[key] = color;
            while (_cache.length > 32) {
              _cache.remove(_cache.keys.first);
            }
          }
        }
      }
    } catch (_) {
      /* Unavailable covers keep the selected manual theme. */
    }
    if (mounted && generation == _generation) setState(() => _color = color);
  }

  @override
  void dispose() {
    _generation++;
    _appearance.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    if (!_enabled || color == null) return widget.child;
    final theme = Theme.of(context);
    final primary = LumeTheme.readableForeground(
      color,
      theme.colorScheme.surface,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: primary,
          onPrimary: Colors.white,
          secondary: primary,
        ),
        progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
          color: primary,
        ),
      ),
      child: AnimatedContainer(
        key: const Key('appearance.adaptiveSurface'),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, .7, 1],
            colors: [
              Color.alphaBlend(
                color.withValues(
                  alpha: theme.brightness == Brightness.dark ? .2 : .14,
                ),
                theme.scaffoldBackgroundColor,
              ),
              theme.scaffoldBackgroundColor,
              theme.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
