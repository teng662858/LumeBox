import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:ui' as ui;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import '../../core/reading/reading.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/net/waf.dart';
import '../source/waf_webview_page.dart';
import 'cover_viewport.dart';

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
    this.headers = const {},
    this.placeholder,
    this.onLoaded,
    this.onFailed,
  });

  final Widget? placeholder;
  final VoidCallback? onLoaded, onFailed;
  final SectionImagePipeline pipeline;
  final Map<String, String> headers;

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
  bool _resolving = false;
  CoverViewportState? _viewport;
  CoverViewportEntry? _viewportEntry;

  /// 换图期间继续显示的**上一帧**。
  ///
  /// 直播源的封面地址每轮都会换（地址里带快照时间戳），旧实现一换地址就先把
  /// 位图还回管线，占位图立刻顶上来——列表每 20 秒集体闪一下，看着像卡了。
  /// 这里把上一帧多钉一会儿：新图解码完成再归还引用（管线的引用计数会保护
  /// 它不被 LRU 淘汰），于是换图是「就地替换」而不是「先白一下再出来」。
  ui.Image? _stale;
  String? _staleUrl;
  int? _staleWidth;
  SectionImagePipeline? _stalePipeline;

  /// 自动重试计数（弱网下封面一两次失败就永久占位，用户看到的就是
  /// 「很多封面加载不出来」——失败后自己再试几次，别让人去滑来滑去）。
  int _retries = 0;
  Timer? _retryTimer;

  /// 最多自动重试 3 次：两次快退避 + 一次「慢补」。
  static const int _maxRetries = 3;

  /// 退避间隔：1.2s、3s、**12s**。
  ///
  /// 第三次刻意拉长：首页一屏二三十张封面同时开抢，图床按 IP 限流（429）时一批图
  /// 会在头两秒里集体失败——前两次重试还在同一波限流里，照样失败，封面就永久停在
  /// 占位图上（真机口径：「首页很多封面显示不出来，点进详情页同一条资源又能出来」：
  /// 详情页是**过一会儿**的单张请求，早就出了限流窗口）。等这一波过去再补一次，
  /// 大半能自己好。间隔不是「越久越好」：再长用户已经离开列表了。
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 1200),
    Duration(seconds: 3),
    Duration(seconds: 12),
  ];

  @override
  void initState() {
    super.initState();
    widget.pipeline.verificationRevision.addListener(_onVerificationChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewport = CoverViewport.of(context);
    if (_viewportEntry == null || !identical(viewport, _viewport)) {
      _registerViewport(viewport);
    }
  }

  void _registerViewport(CoverViewportState? viewport) {
    final old = _viewportEntry;
    if (old != null) _viewport?.unregister(old);
    _viewport = viewport;
    if (viewport == null) {
      _viewportEntry = null;
      if (_image == null && !_resolving) unawaited(_resolve());
      return;
    }
    widget.pipeline.configureImageHeaders({widget.url: widget.headers});
    final entry = CoverViewportEntry(
      context: context,
      pipeline: widget.pipeline,
      url: widget.url,
      width: widget.targetWidth,
      onVisible: () {
        if (_image == null &&
            !_resolving &&
            (!_failed ||
                (widget.pipeline.canRetry(widget.url) &&
                    _retries < _maxRetries))) {
          _retryTimer?.cancel();
          unawaited(_resolve());
        }
      },
    );
    _viewportEntry = entry;
    viewport.register(entry);
  }

  @override
  void didUpdateWidget(SectionImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pipeline, widget.pipeline)) {
      oldWidget.pipeline.verificationRevision.removeListener(
        _onVerificationChanged,
      );
      widget.pipeline.verificationRevision.addListener(_onVerificationChanged);
    }
    if (oldWidget.url != widget.url ||
        oldWidget.targetWidth != widget.targetWidth ||
        !mapEquals(oldWidget.headers, widget.headers) ||
        !identical(oldWidget.pipeline, widget.pipeline)) {
      _retryTimer?.cancel();
      _retries = 0;
      _failed = false;
      // 不立刻释放当前帧：先挂成「上一帧」，新图到了再还（见 [_releaseStale]）。
      _releaseStale();
      if (_image != null) {
        _stale = _image;
        _staleUrl = _heldUrl;
        _staleWidth = _heldWidth;
        _stalePipeline = _heldPipeline;
        _image = null;
        _heldUrl = null;
        _heldWidth = null;
        _heldPipeline = null;
      }
      _resolveSeq++;
      _resolving = false;
      _registerViewport(_viewport);
    }
  }

  /// 归还「上一帧」那次引用（位图由管线决定什么时候真正释放）。
  void _releaseStale() {
    final pipeline = _stalePipeline;
    final url = _staleUrl;
    if (pipeline != null && url != null) {
      pipeline.release(url, targetWidth: _staleWidth);
    }
    _stale = null;
    _staleUrl = null;
    _staleWidth = null;
    _stalePipeline = null;
  }

  @override
  void dispose() {
    final entry = _viewportEntry;
    if (entry != null) _viewport?.unregister(entry);
    widget.pipeline.verificationRevision.removeListener(_onVerificationChanged);
    _retryTimer?.cancel();
    _retryTimer = null;
    _releaseStale();
    _release();
    super.dispose();
  }

  /// 当前持有引用的那张图（URL 与解码宽度）。
  ///
  /// 必须记住它而不是用 `widget` 的当前值：`didUpdateWidget` 之后 `widget`
  /// 已经是新图，照它释放会把旧图的引用漏掉（被钉住到管线销毁为止）。
  String? _heldUrl;
  int? _heldWidth;
  SectionImagePipeline? _heldPipeline;
  int _resolveSeq = 0;
  bool _verifying = false;
  void _onVerificationChanged() {
    if (!mounted || !_failed) return;
    _retries = 0;
    _retryTimer?.cancel();
    unawaited(_resolve());
  }

  Future<void> _retryOrVerify() async {
    if (_verifying) return;
    final pipeline = widget.pipeline;
    final target = pipeline.verificationTargetFor(widget.url);
    final source = pipeline.boundSource;
    if (target != null && source != null) {
      _verifying = true;
      try {
        // Image hosts keep their own cookies in WebKit. Never merge these
        // credentials into the source site's Cookie header.
        final cookies = await showWafWebView(
          context: context,
          url: target,
          sourceName: '${source.name} · 图片验证',
          section: source.section,
          sourceId: source.id,
          userAgent: WafSessions.userAgentFor(source.section, source.id),
        );
        if (cookies?.isNotEmpty == true) {
          pipeline.verificationChanged();
          return;
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('图片验证窗口暂时无法打开，请重试')));
        }
        return;
      } finally {
        _verifying = false;
      }
    }
    if (!mounted) return;
    _retries = 0;
    _retryTimer?.cancel();
    await _resolve();
  }

  void _release() {
    if (_image == null) return;
    _heldPipeline?.release(_heldUrl ?? widget.url, targetWidth: _heldWidth);
    _image = null;
    _heldUrl = null;
    _heldWidth = null;
    _heldPipeline = null;
  }

  Future<void> _resolve() async {
    if (_viewportEntry != null && !_viewportEntry!.visible) return;
    final seq = ++_resolveSeq;
    _resolving = true;
    final pipeline = widget.pipeline;
    if (widget.headers.isNotEmpty) {
      pipeline.configureImageHeaders({widget.url: widget.headers});
    }
    final url = widget.url.trim();
    if (url.isEmpty) {
      _resolving = false;
      if (mounted) setState(() => _failed = true);
      return;
    }
    final width = widget.targetWidth;
    // image() 返回的图自带一次引用（见管线的引用契约），由 _release 归还。
    final entry = _viewportEntry;
    final image = await pipeline.image(
      url,
      targetWidth: width,
      isForeground: entry == null ? null : () => entry.visible,
    );
    if (seq == _resolveSeq) _resolving = false;
    if (!mounted || seq != _resolveSeq) {
      // 页面已退出：立刻把这次引用还回去，别把它钉在管线上。
      if (image != null) pipeline.release(url, targetWidth: width);
      return;
    }
    if (image == null) {
      setState(() => _failed = true);
      widget.onFailed?.call();
      // 自动重试：只在页面还在、且没超过次数时排队。
      if (_retries < _maxRetries && pipeline.canRetry(url)) {
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
    _heldPipeline = pipeline;
    _retryTimer?.cancel();
    _retryTimer = null;
    setState(() {
      _image = image;
      _failed = false;
    });
    // 新帧已经在屏上，上一帧的引用这时才还。
    _releaseStale();
    widget.onLoaded?.call();
  }

  @override
  Widget build(BuildContext context) {
    // 换图期间继续显示上一帧：宁可多看半秒旧画面，也别闪成占位图。
    final image = _image ?? _stale;
    Widget child;
    if (image != null) {
      child = RawImage(
        image: image,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
      );
    } else {
      child = _failed
          ? _FailedCover(
              // **只有需要网页验证的图床**才把点击让给「验证 / 重试」：源根本没给
              // 封面、404 这类失败整块卡片仍要把点击交给宿主去打开条目
              //（真机反馈：封面点不动，「要点下面的标题才可以」）。
              verifyLabel:
                  widget.pipeline.verificationTargetFor(widget.url) != null
                  ? '点击验证图片'
                  : null,
              tooltip: widget.pipeline.failureFor(widget.url) ?? '封面暂未加载',
              onTap: widget.pipeline.verificationTargetFor(widget.url) != null
                  ? () => unawaited(_retryOrVerify())
                  : null,
              placeholder:
                  widget.placeholder ?? const _Placeholder(failed: true),
            )
          : widget.placeholder ?? const _Placeholder(failed: false);
    }
    final radius = widget.borderRadius;
    return radius == null
        ? child
        : ClipRRect(borderRadius: radius, child: child);
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
        child: LumeIcon(
          failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
          slot: 'section_image.1',
          variant: true,
          size: 22,
          color: LumeTheme.muted,
        ),
      ),
    );
  }
}

/// 加载失败的封面：**默认不吃点击**（点击要落到条目卡片上去打开作品）。
///
/// 只有图床明确需要网页验证时才挂上自己的点击（并显示「点击验证图片」），
/// 否则整块封面就是一个纯展示的占位——真机反馈「点封面没反应、要点标题」。
class _FailedCover extends StatelessWidget {
  const _FailedCover({
    required this.tooltip,
    required this.placeholder,
    this.onTap,
    this.verifyLabel,
  });

  final String tooltip;
  final Widget placeholder;
  final VoidCallback? onTap;
  final String? verifyLabel;

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        placeholder,
        if (verifyLabel != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                verifyLabel!,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.captionSize,
                ),
              ),
            ),
          ),
      ],
    );
    return Tooltip(
      message: tooltip,
      child: onTap == null
          ? content
          : GestureDetector(onTap: onTap, child: content),
    );
  }
}
