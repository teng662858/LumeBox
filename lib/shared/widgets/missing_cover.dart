import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';

/// Decorative replacement artwork. The card's separate title remains its accessible name.
class MissingCover extends StatelessWidget {
  const MissingCover({super.key, required this.title, required this.section});
  final String title;
  final Section section;
  @override
  Widget build(BuildContext context) {
    final icon = switch (section) {
      Section.novel => Icons.menu_book_outlined,
      Section.comic => Icons.auto_stories_outlined,
      Section.video => Icons.play_circle_outline,
      Section.cat => Icons.pets_outlined,
    };
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              LumeTheme.accent.withValues(alpha: .20),
              LumeTheme.accent.withValues(alpha: .06),
            ],
          ),
        ),
        child: CustomPaint(
          painter: _CoverPainter(
            title,
            icon,
            LumeTheme.accent,
            LumeTheme.textPrimary,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _CoverPainter extends CustomPainter {
  const _CoverPainter(this.title, this.icon, this.accent, this.ink);
  final String title;
  final IconData icon;
  final Color accent, ink;
  void label(
    Canvas canvas,
    String text,
    TextStyle style,
    double width,
    Offset offset, {
    int lines = 1,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: lines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1, width));
    painter.paint(
      canvas,
      Offset(offset.dx + (width - painter.width) / 2, offset.dy),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final compact = size.width < 80 || size.height < 110;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final glyph = String.fromCharCode(icon.codePoint);
    label(
      canvas,
      glyph,
      TextStyle(
        fontWeight: FontWeight.w600,
        fontFamily: icon.fontFamily,
        fontSize: (compact ? 64 : 130) + 1,
        color: accent.withValues(alpha: .1),
      ),
      compact ? 64 : 130,
      Offset(size.width - 72, -20),
    );
    final top = compact
        ? math.max(0.0, (size.height - 22) / 2)
        : math.max(10.0, size.height * .24);
    label(
      canvas,
      glyph,
      TextStyle(
        fontWeight: FontWeight.w600,
        fontFamily: icon.fontFamily,
        fontSize: (compact ? 22 : 34) + 1,
        color: accent.withValues(alpha: .75),
      ),
      size.width,
      Offset(0, top),
    );
    if (!compact) {
      final width = math.max(1.0, size.width - 24),
          available = math.max(1, size.height - top - 70);
      final lines = math.min(4, math.max(1, (available / 22.5).floor()));
      label(
        canvas,
        title.isEmpty ? 'LumeBox' : title,
        TextStyle(
          fontSize: LumeTypography.titleSize,
          height: 1.5,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        width,
        Offset(12, top + 45),
        lines: lines,
      );
      label(
        canvas,
        'LUME BOX',
        TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: LumeTypography.captionSize,
          letterSpacing: 3,
          color: accent.withValues(alpha: .5),
        ),
        size.width,
        Offset(0, size.height - 22),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      title != old.title ||
      icon != old.icon ||
      accent != old.accent ||
      ink != old.ink;
}
