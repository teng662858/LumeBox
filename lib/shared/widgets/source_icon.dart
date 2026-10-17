import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_favicon.dart';
import '../../core/theme/lume_theme.dart';

/// 源图标：优先真图标（源声明的地址 → 站点约定名 → 首页 `<link rel=icon>`），
/// 全都拿不到时才回退到稳定的首字母字母块。
///
/// 取图标这件事本身在 [SourceFavicon] 里（候选地址、源会话、图片校验、缓存），
/// 本控件只负责「有就画、没有就占位」，因此测试里可以注入替身解析器。
class SourceIcon extends StatefulWidget {
  const SourceIcon({
    super.key,
    required this.name,
    this.siteUrl = '',
    this.iconUrl = '',
    this.siteIcon = '',
    this.size = 40,
    this.section,
    this.sourceId,
    this.favicon,
  });

  final String name, siteUrl, iconUrl, siteIcon;
  final double size;

  /// 这个图标属于哪个板块的哪个源；给了它就带上该源验证过的会话去取图标
  /// （Cloudflare 站不带会话只会拿到 403）。
  final Section? section;
  final String? sourceId;

  /// 替身解析器（测试用）；为空时用应用级单例。
  final SourceFavicon? favicon;

  @override
  State<SourceIcon> createState() => _SourceIconState();
}

class _SourceIconState extends State<SourceIcon> {
  Uint8List? _bytes;
  int _loadGeneration = 0;

  SourceFavicon get _resolver => widget.favicon ?? SourceFavicon.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SourceIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteUrl != widget.siteUrl ||
        oldWidget.iconUrl != widget.iconUrl ||
        oldWidget.siteIcon != widget.siteIcon ||
        oldWidget.section != widget.section ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.favicon != widget.favicon) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final generation = ++_loadGeneration;
    final explicit = <String>[
      if (widget.iconUrl.trim().isNotEmpty) widget.iconUrl.trim(),
      if (widget.siteIcon.trim().isNotEmpty) widget.siteIcon.trim(),
    ];
    final site = widget.siteUrl.trim();
    if (site.isEmpty && explicit.isEmpty) return;
    _resolver
        .load(
          origin: site,
          explicit: explicit,
          section: widget.section,
          sourceId: widget.sourceId,
        )
        .then((bytes) {
          if (!mounted || generation != _loadGeneration) return;
          setState(() => _bytes = bytes);
        })
        .catchError((Object _) {
          // 解析器自己已经吞掉了「取不到」；这里只防意外异常把列表带崩。
          if (mounted && generation == _loadGeneration) {
            setState(() => _bytes = null);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final radius = BorderRadius.circular(12);
    final fallback = _monogram(radius);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: radius,
        child: bytes == null
            // 加载中先显示首字母（不转圈）：图标到齐后自然替换，列表不跳。
            ? fallback
            : Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                cacheWidth: (widget.size * 3).round(),
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }

  Widget _monogram(BorderRadius radius) => DecoratedBox(
    decoration: BoxDecoration(
      color: LumeTheme.accent.withValues(alpha: .12),
      borderRadius: radius,
    ),
    child: Center(
      child: Text(
        widget.name.isEmpty ? '源' : widget.name.characters.first,
        style: TextStyle(
          color: LumeTheme.accent,
          fontSize: (widget.size * .42) + 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
