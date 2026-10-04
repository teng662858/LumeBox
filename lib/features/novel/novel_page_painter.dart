import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'novel_pagination.dart';
import 'novel_typesetting.dart';

/// 一页的绘制画布：段落切片 → 已排版的 [TextPainter]。
///
/// 只在「分页结果、排版参数、主题」变化时重建，重建时释放旧的 TextPainter。
/// 每页只排「这一页可见的那几段」，因此绘制成本与整章长度无关——这是小说引擎
/// 能流畅翻大章节的关键：分页算一次，绘制只碰当前页（以及翻页时相邻的一页）。
class NovelPageCanvas {
  NovelPageCanvas._(this.page, this._pieces);

  /// 由分页结果构造一页的可绘制内容。
  ///
  /// 切片裁剪点落在原排版的行首，重新排版后的断行与整段排版一致，
  /// 因此不必为绘制重排整章。
  static NovelPageCanvas build({
    required NovelPage page,
    required NovelChapterText text,
    required NovelTypesetting typesetting,
    required NovelReaderTheme theme,
    required double contentWidth,
  }) {
    final style = typesetting.baseStyle.copyWith(color: theme.textColor);
    final pieces = <_SegmentPiece>[];
    for (final segment in page.segments) {
      final paragraph = text.paragraphs[segment.paragraphIndex];
      final start = segment.start.clamp(0, paragraph.length);
      final end = segment.end.clamp(start, paragraph.length);
      if (end <= start) continue;
      final painter = TextPainter(
        text: TextSpan(text: paragraph.substring(start, end), style: style),
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: contentWidth);
      pieces.add(_SegmentPiece(painter, segment.dy));
    }
    return NovelPageCanvas._(page, pieces);
  }

  final NovelPage page;
  final List<_SegmentPiece> _pieces;

  /// 按内容区左上角为原点绘制本页正文。
  void paint(Canvas canvas, Offset origin) {
    for (final piece in _pieces) {
      piece.painter.paint(canvas, origin + Offset(0, piece.dy));
    }
  }

  void dispose() {
    for (final piece in _pieces) {
      piece.painter.dispose();
    }
    _pieces.clear();
  }
}

class _SegmentPiece {
  const _SegmentPiece(this.painter, this.dy);

  final TextPainter painter;
  final double dy;
}

/// 一页的画笔：背景 + 正文 + 页眉（章名）+ 页脚（页码与进度）。
///
/// 主题色、页边距、字号都在这里落地；工具栏不在这一层（它是 Widget 覆盖层）。
class NovelPagePainter extends CustomPainter {
  NovelPagePainter({
    required this.theme,
    required this.typesetting,
    required this.title,
    required this.pageIndex,
    required this.pageCount,
    required this.chapterRatio,
    required double contentWidth,
    this.content,
    this.hint,
  })  : contentWidth = contentWidth,
        _header = _layout(
          title,
          typesetting,
          theme.secondary,
          12,
          maxWidth: contentWidth,
        ),
        _footerLeft = _layout(
          '第 ${pageIndex + 1}/$pageCount 页',
          typesetting,
          theme.secondary,
          11,
        ),
        _footerRight = _layout(
          '${(chapterRatio * 100).round()}%',
          typesetting,
          theme.secondary,
          11,
        ),
        _hint = hint == null
            ? null
            : _layout(hint, typesetting, theme.secondary, 13);

  final NovelReaderTheme theme;
  final NovelTypesetting typesetting;
  final String title;
  final int pageIndex;
  final int pageCount;

  /// 正文内容宽度（视口宽 - 页边距），页眉按它截断。
  final double contentWidth;

  /// 本章进度 0..1（按字符）。
  final double chapterRatio;

  /// 正文内容；空页（章首 / 章末提示）为 null。
  final NovelPageCanvas? content;

  /// 空页提示文案。
  final String? hint;

  final TextPainter _header;
  final TextPainter _footerLeft;
  final TextPainter _footerRight;
  final TextPainter? _hint;

  static TextPainter _layout(
    String text,
    NovelTypesetting typesetting,
    Color color,
    double fontSize, {
    double maxWidth = double.infinity,
  }) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: typesetting.baseStyle.copyWith(
          color: color,
          fontSize: fontSize,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 阅读器自带背景色：不依赖 App 主题，深色/浅色主题各自成立。
    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    final margin = typesetting.margin;
    final footerY = size.height - margin - NovelTypesetting.footerHeight + 8;

    if (_header.width > 0 && size.width > margin * 2 + 8) {
      _header.paint(canvas, Offset(margin, margin));
    }
    content?.paint(
      canvas,
      Offset(
        margin,
        margin + NovelTypesetting.headerHeight,
      ),
    );
    _footerLeft.paint(canvas, Offset(margin, footerY));
    _footerRight.paint(
      canvas,
      Offset(size.width - margin - _footerRight.width, footerY),
    );

    final hint = _hint;
    if (hint != null) {
      hint.paint(
        canvas,
        Offset(
          (size.width - hint.width) / 2,
          (size.height - hint.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(NovelPagePainter oldDelegate) =>
      !identical(oldDelegate.content, content) ||
      oldDelegate.theme != theme ||
      oldDelegate.title != title ||
      oldDelegate.pageIndex != pageIndex ||
      oldDelegate.pageCount != pageCount ||
      oldDelegate.hint != hint ||
      oldDelegate.contentWidth != contentWidth ||
      oldDelegate.typesetting != typesetting;
}

/// 翻页模式。
enum NovelTurnMode {
  /// 仿真 Curl：把纸从一侧掀起、折叠、露出下一页。
  curl('curl', '仿真翻页'),

  /// 平移 Slide：两页同时平移，像推纸一样。
  slide('slide', '平移翻页'),

  /// 覆盖 Cover：只有新页移动，盖住旧页。
  cover('cover', '覆盖翻页'),

  /// 上下连续滚动：整章纵向连排。
  scroll('scroll', '上下滚动');

  const NovelTurnMode(this.id, this.label);

  final String id;
  final String label;

  static const String settingKey = 'novel.turnMode';

  static NovelTurnMode fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return NovelTurnMode.slide;
  }

  bool get isPaged => this != NovelTurnMode.scroll;
}

/// 仿真 Curl 翻页的画笔。
///
/// 几何模型（简化仿真，不做网格形变）：
/// - **底页**（较早那页）始终铺满，它要被「露出来」；
/// - **到达的那张纸**（较晚那页）从右侧铺进来，铺下的部分为平面，
///   前沿卷起的部分折叠回左侧并做水平镜像——镜像出来的正是纸的背面；
/// - 折痕位置 `foldX = (1 - t) * width`：前进时从右缘扫向左缘，后退时反向收回；
/// - 折痕左侧投影到底页上、卷边压暗并加一道折痕高光，形成纸的厚度与阴影。
class NovelCurlPainter extends CustomPainter {
  NovelCurlPainter({
    required this.base,
    required this.moving,
    required this.progress,
    this.curlWidth = 46,
  });

  /// 底页（被覆盖、将被露出的那页）。
  final NovelPagePainter base;

  /// 正在铺进来的那张纸。
  final NovelPagePainter moving;

  /// 翻页进度 0..1。0 = 完全是底页，1 = 完全是新页。
  final double progress;

  /// 卷边最大宽度。
  final double curlWidth;

  @override
  void paint(Canvas canvas, Size size) {
    base.paint(canvas, size);
    final foldX = size.width * (1 - progress);
    if (foldX >= size.width) return;

    // 平面部分：纸的左侧部分铺在右侧。
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(foldX, 0, size.width - foldX, size.height));
    canvas.translate(foldX, 0);
    moving.paint(canvas, size);
    canvas.restore();

    // 折痕在底页上的投影：让纸「离开桌面」。
    final shadowWidth = math.min(22.0, size.width - foldX);
    if (shadowWidth > 0.5) {
      canvas.drawRect(
        Rect.fromLTWH(foldX, 0, shadowWidth, size.height),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(foldX, 0),
            Offset(foldX + shadowWidth, 0),
            <Color>[const Color(0x66000000), const Color(0x00000000)],
          ),
      );
    }

    // 卷起的边缘：镜像回左侧，压暗成纸背。
    final flap = math.min(curlWidth, math.min(foldX, size.width - foldX));
    if (flap <= 0.5) return;
    final flapRect = Rect.fromLTWH(foldX - flap, 0, flap, size.height);
    canvas.save();
    canvas.clipRect(flapRect);
    canvas.translate(foldX, 0);
    canvas.scale(-1, 1);
    moving.paint(canvas, size);
    canvas.restore();

    canvas.drawRect(
      flapRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(foldX - flap, 0),
          Offset(foldX, 0),
          <Color>[const Color(0x1A000000), const Color(0x4D000000)],
        ),
    );
    canvas.drawLine(
      Offset(foldX, 0),
      Offset(foldX, size.height),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(NovelCurlPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      !identical(oldDelegate.base, base) ||
      !identical(oldDelegate.moving, moving);
}

/// 翻页时的页与页之间的投影：平移 / 覆盖模式用它给「纸上纸」一点厚度。
class NovelEdgeShadowPainter extends CustomPainter {
  const NovelEdgeShadowPainter({required this.width, required this.onLeft});

  final double width;

  /// true 时阴影在左侧边缘（覆盖模式新页从右进）。
  final bool onLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = onLeft
        ? Rect.fromLTWH(0, 0, width, size.height)
        : Rect.fromLTWH(size.width - width, 0, width, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.left == 0 ? rect.centerLeft : rect.centerRight,
          rect.left == 0 ? rect.topRight : rect.topLeft,
          <Color>[const Color(0x59000000), const Color(0x00000000)],
        ),
    );
  }

  @override
  bool shouldRepaint(NovelEdgeShadowPainter oldDelegate) =>
      oldDelegate.width != width || oldDelegate.onLeft != onLeft;
}
