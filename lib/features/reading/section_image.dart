import 'dart:ui' as ui;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/theme/lume_theme.dart';

/// 板块远程图片：走本板块的图片管线取图，负责引用计数、占位与失败态。
///
/// 生命周期细节（内存优化的一半在这里）：
/// - 挂载时向管线登记一次引用，卸载时释放——被展示的位图不会被 LRU 淘汰，
///   画到的图永远不会是已释放的；
/// - 换 URL（列表复用）时先释放旧引用再取新的；
/// - 取图失败只显示占位，不抛异常：封面挂了不该把整页拖下水。
class SectionImage extends StatefulWidget {
  const SectionImage({
    super.key,
    required this.pipeline,
    required this.url,
    this.targetWidth,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final SectionImagePipeline pipeline;

  /// 图片地址。为空字符串时直接显示占位。
  final String url;

  /// 解码目标宽度（按显示宽度解码，避免大图占满内存）。
  final int? targetWidth;

  final BoxFit fit;

  /// 圆角；为空时不裁剪。
  final BorderRadius? borderRadius;

  @override
  State<SectionImage> createState() => _SectionImageState();
}

class _SectionImageState extends State<SectionImage> {
  ui.Image? _image;
  bool _failed = false;

  /// 自动重试计数（弱网下封面一两次失败就永久占位，用户看到的就是
  /// 「很多封面加载不出来」——失败后自己再试几次，别让人去滑来滑去）。
  int _retries = 0;
  Timer? _retryTimer;

  /// 最多自动重试 2 次。
  static const int _maxRetries = 2;

  /// 退避间隔：1.2s、3s（够短，看得见；够长，不给图床添乱）。
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 1200),
    Duration(seconds: 3),
  ];

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SectionImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.targetWidth != widget.targetWidth ||
        !identical(oldWidget.pipeline, widget.pipeline)) {
      _release();
      _resolve();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _release();
    super.dispose();
  }

  /// 当前持有引用的那张图（URL 与解码宽度）。
  ///
  /// 必须记住它而不是用 `widget` 的当前值：`didUpdateWidget` 之后 `widget`
  /// 已经是新图，照它释放会把旧图的引用漏掉（被钉住到管线销毁为止）。
  String? _heldUrl;
  int? _heldWidth;

  void _release() {
    if (_image == null) return;
    widget.pipeline.release(_heldUrl ?? widget.url, targetWidth: _heldWidth);
    _image = null;
    _heldUrl = null;
    _heldWidth = null;
  }

  Future<void> _resolve() async {
    final url = widget.url.trim();
    if (url.isEmpty) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final width = widget.targetWidth;
    // image() 返回的图自带一次引用（见管线的引用契约），由 _release 归还。
    final image = await widget.pipeline.image(url, targetWidth: width);
    if (!mounted) {
      // 页面已退出：立刻把这次引用还回去，别把它钉在管线上。
      if (image != null) widget.pipeline.release(url, targetWidth: width);
      return;
    }
    if (image == null) {
      setState(() => _failed = true);
      // 自动重试：只在页面还在、且没超过次数时排队。
      if (_retries < _maxRetries) {
        final delay = _retryDelays[_retries];
        _retries++;
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          if (!mounted) return;
          unawaited(_resolve());
        });
      }
      return;
    }
    _heldUrl = url;
    _heldWidth = width;
    _retryTimer?.cancel();
    _retryTimer = null;
    setState(() {
      _image = image;
      _failed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    Widget child;
    if (image != null) {
      child = RawImage(
        image: image,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
      );
    } else {
      child = _Placeholder(failed: _failed);
    }
    final radius = widget.borderRadius;
    return radius == null ? child : ClipRRect(borderRadius: radius, child: child);
  }
}

/// 占位与失败态：统一走主题色，不引入额外资源。
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: LumeTheme.fill,
      child: Center(
        child: Icon(
          failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
          size: 22,
          color: LumeTheme.muted,
        ),
      ),
    );
  }
}
