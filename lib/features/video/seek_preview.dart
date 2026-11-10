import '../../core/reading/image_pipeline.dart';
import '../reading/section_image.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/player/mpv_engine.dart';
import '../../core/player/video_preview.dart';

/// A bounded gallery of frames already decoded during normal playback.
class SeekPreviewFrames {
  final _frames = <int, ui.Image>{};
  Object? _identity;
  bool _busy = false, _disposed = false;
  int _attempt = -30;
  void reset(Object? identity) {
    if (_identity == identity) return;
    _identity = identity;
    _attempt = -30;
    for (final frame in _frames.values) {
      frame.dispose();
    }
    _frames.clear();
  }

  Future<void> sample(VideoFrameCapture engine, int second) async {
    if (_disposed || _busy || second < _attempt + 30) return;
    _attempt = second;
    _busy = true;
    final identity = _identity;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final frame = await engine.captureFrame();
      if (frame == null || _disposed || _identity != identity) return;
      buffer = await ui.ImmutableBuffer.fromUint8List(frame.pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: frame.width,
        height: frame.height,
        rowBytes: frame.stride,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: frame.width >= frame.height
            ? 192
            : (frame.width * 192 / frame.height).round().clamp(1, 192),
      );
      final image = (await codec.getNextFrame()).image;
      if (_disposed || _identity != identity) {
        image.dispose();
        return;
      }
      _frames.remove(second)?.dispose();
      _frames[second] = image;
      while (_frames.length > 60) {
        _frames.remove(_frames.keys.first)?.dispose();
      }
    } catch (_) {
      /* Preview failure must never affect playback. */
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _busy = false;
    }
  }

  (int, ui.Image)? nearest(int second) {
    if (_frames.isEmpty) return null;
    final key = _frames.keys.reduce(
      (a, b) => (a - second).abs() <= (b - second).abs() ? a : b,
    );
    return (key - second).abs() <= 30 ? (key, _frames[key]!) : null;
  }

  void dispose() {
    reset(null);
    _disposed = true;
  }
}

class SeekPreview extends StatefulWidget {
  const SeekPreview({
    super.key,
    required this.target,
    required this.frames,
    required this.previews,
    this.pipeline,
  });
  final SectionImagePipeline? pipeline;
  final Duration target;
  final SeekPreviewFrames frames;
  final List<VideoPreview> previews;
  @override
  State<SeekPreview> createState() => _SeekPreviewState();
}

class _SeekPreviewState extends State<SeekPreview> {
  Timer? _settled;
  VideoPreview? source;
  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant SeekPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previews != widget.previews) source = null;
    if (oldWidget.target != widget.target ||
        oldWidget.previews != widget.previews) {
      _update();
    }
  }

  void _update() {
    _settled?.cancel();
    if (widget.previews.isEmpty) {
      source = null;
      return;
    }
    // A fast drag does not fire a thumbnail request for every intermediate point.
    _settled = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final second = widget.target.inSeconds;
      setState(
        () => source = widget.previews.reduce(
          (a, b) =>
              (a.seconds - second).abs() <= (b.seconds - second).abs() ? a : b,
        ),
      );
    });
  }

  @override
  void dispose() {
    _settled?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.frames.nearest(widget.target.inSeconds);
    final source = this.source;
    if (source == null && local == null) {
      return const Text('此位置暂无预览', style: TextStyle(fontSize: 11));
    }
    final time = Duration(seconds: source?.seconds ?? local!.$1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 160,
            height: 90,
            child: source == null
                ? RawImage(image: local!.$2, fit: BoxFit.contain)
                : widget.pipeline == null
                ? const Center(child: Text('预览不可用'))
                : SectionImage(
                    pipeline: widget.pipeline!,
                    url: source.url.toString(),
                    headers: source.headers,
                    targetWidth: 192,
                    fit: BoxFit.contain,
                    placeholder: const Center(child: Text('正在读取源预览')),
                  ),
          ),
        ),
        Text(
          '${source == null ? '已播放画面' : '源预览'} ${time.inMinutes}:${(time.inSeconds % 60).toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}
