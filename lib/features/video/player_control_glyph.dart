import 'package:flutter/material.dart';

import '../../shared/widgets/lume_icon.dart';

/// Fullscreen controls share a rounded, two logical pixel outline.
class PlayerControlGlyph extends StatelessWidget {
  const PlayerControlGlyph(
    this.icon, {
    super.key,
    this.size = 22,
    this.color = const Color(0xFFF8F8F8),
  });
  final IconData icon;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => LumeIcon(
    icon,
    slot: 'player.stroke',
    variant: true,
    group: '视频播放器',
    size: size,
    color: color,
    fallback: CustomPaint(
      size: Size.square(size),
      painter: _ControlPainter(icon, color),
    ),
  );
}

class _ControlPainter extends CustomPainter {
  const _ControlPainter(this.icon, this.color);
  final IconData icon;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    void line(double x, double y, double a, double b) => path
      ..moveTo(x, y)
      ..lineTo(a, b);
    void box(double l, double t, double r, double b) => path.addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(l, t, r, b),
        const Radius.circular(2),
      ),
    );
    if (icon == Icons.high_quality_outlined) {
      box(2, 5, 22, 19);
      line(6, 9, 6, 15);
      line(11, 9, 11, 15);
      line(6, 12, 11, 12);
      path
        ..moveTo(15, 9)
        ..lineTo(15, 15)
        ..lineTo(18, 15)
        ..quadraticBezierTo(21, 12, 18, 9)
        ..close();
    } else if (icon == Icons.arrow_back_ios_new) {
      path
        ..moveTo(15, 4)
        ..lineTo(7, 12)
        ..lineTo(15, 20);
    } else if (icon == Icons.play_arrow) {
      path
        ..moveTo(7, 4)
        ..lineTo(20, 12)
        ..lineTo(7, 20)
        ..close();
    } else if (icon == Icons.pause) {
      box(6, 4, 9, 20);
      box(15, 4, 18, 20);
    } else if (icon == Icons.skip_previous || icon == Icons.skip_next) {
      final previous = icon == Icons.skip_previous;
      if (previous) {
        line(5, 5, 5, 19);
        path
          ..moveTo(19, 5)
          ..lineTo(8, 12)
          ..lineTo(19, 19)
          ..close();
      } else {
        line(19, 5, 19, 19);
        path
          ..moveTo(5, 5)
          ..lineTo(16, 12)
          ..lineTo(5, 19)
          ..close();
      }
    } else if (icon == Icons.lock || icon == Icons.lock_open) {
      box(5, 10, 19, 21);
      path
        ..moveTo(8, 10)
        ..lineTo(8, 6)
        ..cubicTo(8, 1, 16, 1, 16, 6);
      if (icon == Icons.lock) path.lineTo(16, 10);
      line(12, 14, 12, 17);
    } else if (icon == Icons.screen_rotation_alt) {
      path
        ..moveTo(3, 9)
        ..cubicTo(3, 2, 17, 1, 20, 7)
        ..moveTo(20, 3)
        ..lineTo(20, 7)
        ..lineTo(16, 7);
      path
        ..moveTo(21, 15)
        ..cubicTo(21, 22, 7, 23, 4, 17)
        ..moveTo(4, 21)
        ..lineTo(4, 17)
        ..lineTo(8, 17);
      path.addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(8, 7, 8, 10),
          const Radius.circular(1.5),
        ),
      );
    } else if (icon == Icons.picture_in_picture ||
        icon == Icons.picture_in_picture_alt) {
      box(2, 4, 22, 20);
      box(12, 11, 20, 18);
    } else if (icon == Icons.change_circle_outlined) {
      box(6, 6, 18, 18);
      box(9, 9, 15, 15);
      for (final a in [8.0, 12.0, 16.0]) {
        line(a, 2, a, 6);
        line(a, 18, a, 22);
        line(2, a, 6, a);
        line(18, a, 22, a);
      }
    } else if (icon == Icons.more_horiz || icon == Icons.tune) {
      for (final x in [5.0, 12.0, 19.0]) {
        path.addOval(Rect.fromCircle(center: Offset(x, 12), radius: 1));
      }
    } else if (icon == Icons.chat_bubble_outline) {
      path
        ..moveTo(5, 4)
        ..lineTo(19, 4)
        ..quadraticBezierTo(22, 4, 22, 7)
        ..lineTo(22, 16)
        ..quadraticBezierTo(22, 19, 19, 19)
        ..lineTo(9, 19)
        ..lineTo(3, 22)
        ..lineTo(3, 7)
        ..quadraticBezierTo(3, 4, 5, 4);
      line(7, 9, 18, 9);
      line(7, 14, 15, 14);
    } else if (icon == Icons.speed) {
      path
        ..moveTo(3, 18)
        ..cubicTo(-1, 0, 25, 0, 21, 18)
        ..close();
      line(12, 14, 17, 8);
    } else if (icon == Icons.bookmark_add_outlined) {
      path
        ..moveTo(6, 3)
        ..lineTo(18, 3)
        ..lineTo(18, 21)
        ..lineTo(12, 17)
        ..lineTo(6, 21)
        ..close();
      line(9, 9, 15, 9);
      line(12, 6, 12, 12);
    } else {
      box(3, 4, 21, 20);
      line(7, 8, 7, 8.1);
      line(11, 8, 18, 8);
      line(7, 12, 7, 12.1);
      line(11, 12, 18, 12);
      line(7, 16, 7, 16.1);
      line(11, 16, 18, 16);
    }
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * 24 / size.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(0, 24 / size.height);
    final shadowPen =
        Shadow(
            color: const Color(0x59000000),
            blurRadius: 3 * 24 / size.width,
          ).toPaint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = pen.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, shadowPen);
    canvas.restore();
    canvas.drawPath(
      path,
      pen
        ..maskFilter = null
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ControlPainter oldDelegate) =>
      oldDelegate.icon != icon || oldDelegate.color != color;
}
