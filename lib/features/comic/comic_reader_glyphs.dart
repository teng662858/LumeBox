import 'package:flutter/material.dart';

/// Vertical page boundaries and a reading arrow, distinct from a download icon.
class ComicReaderVerticalFlowGlyph extends StatelessWidget {
  const ComicReaderVerticalFlowGlyph({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(24),
    painter: _VerticalFlowPainter(
      color ?? IconTheme.of(context).color ?? Colors.black,
    ),
  );
}

class _VerticalFlowPainter extends CustomPainter {
  const _VerticalFlowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final path = Path()
      ..moveTo(5, 4)
      ..lineTo(5, 20)
      ..moveTo(19, 4)
      ..lineTo(19, 20)
      ..moveTo(12, 4)
      ..lineTo(12, 18)
      ..moveTo(8, 14)
      ..lineTo(12, 18)
      ..lineTo(16, 14);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_VerticalFlowPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// A horizontal battery whose fill follows the real device level.
class ComicReaderBatteryGlyph extends StatelessWidget {
  const ComicReaderBatteryGlyph({
    super.key,
    required this.level,
    required this.color,
  });
  final int? level;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(22, 17),
    painter: _BatteryPainter(level, color),
  );
}

class _BatteryPainter extends CustomPainter {
  const _BatteryPainter(this.level, this.color);
  final int? level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 22, size.height / 17);
    final paint = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(.7, 3.7, 18, 9.6),
        const Radius.circular(2),
      ),
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    paint.style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(20, 6.5, 1.6, 4),
        const Radius.circular(.8),
      ),
      paint,
    );
    if (level != null && level! > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(2.3, 5.3, 14.8 * level!.clamp(0, 100) / 100, 6.4),
          const Radius.circular(.8),
        ),
        paint,
      );
    } else if (level == null) {
      canvas.drawRect(const Rect.fromLTWH(6, 8, 7, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_BatteryPainter oldDelegate) =>
      level != oldDelegate.level || color != oldDelegate.color;
}
