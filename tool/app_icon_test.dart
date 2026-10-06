/// App 图标生成器（开发期工具，不参与常规测试）。
///
/// 为什么要程序化生成：图标要与全局浅色主题同步提亮（去掉过重的深色底），
/// 而位图是二进制资源——手绘或换一张图都看不出「提亮了多少」。把构图写成代码，
/// 配色就成了可审阅、可再改的一行行常量。
///
/// 构图沿用原图标的三层玻璃卡 + 播放键 + 折角：
/// 1. 底：极浅的蓝紫白渐变（浅色主题的底色口径）；
/// 2. 三层圆角卡：蓝→品牌紫的亮色渐变，逐层错位，白色描边；
/// 3. 前景：白色播放三角 + 右下折角（原图标的记号）。
///
/// 运行：`flutter test tool/app_icon_test.dart`
/// 产物：`assets/icon/app_icon_1024.png`（无 Alpha，可交给 flutter_launcher_icons）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _size = 1024;

// ---------------------------------------------------------------------- 色板

/// 底：极浅（浅色主题的底色方向，不再压深色）。
const Color _bgTop = Color(0xFFF7F6FF);
const Color _bgBottom = Color(0xFFE8ECFF);

/// 卡片渐变：亮蓝 → 品牌紫。
const Color _cardBlue = Color(0xFF6E9BFF);
const Color _cardPurple = Color(0xFF8B5CF6);

/// 前景：白（与卡片的高对比）。
const Color _fore = Color(0xFFFFFFFF);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成 1024 图标', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _size, _size));

    _paintBackground(canvas);
    _paintCards(canvas);
    _paintGlyph(canvas);

    final picture = recorder.endRecording();
    final image = await picture.toImage(_size.toInt(), _size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();

    final file = File('assets/icon/app_icon_1024.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1000));
  });
}

/// 底：整幅浅色渐变。
void _paintBackground(Canvas canvas) {
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, _size, _size),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        const Offset(_size, _size),
        <Color>[_bgTop, _bgBottom],
      ),
  );
}

/// 三层错位玻璃卡：越靠上越亮，右下角最深，做出「叠了一层」的层次。
void _paintCards(Canvas canvas) {
  const double cardSide = 470;
  const double radius = 96;
  // 三层从左下到右上的错位量。
  const List<double> offsets = <double>[-78, 0, 78];

  for (var index = 0; index < offsets.length; index++) {
    final dx = _size / 2 + offsets[index] - cardSide / 2;
    final dy = _size / 2 - offsets[index] - cardSide / 2;
    final rect = Rect.fromLTWH(dx, dy, cardSide, cardSide);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(radius));

    // 影子：只做极淡的一层，避免浅底上发灰。
    canvas.drawRRect(
      rrect.shift(const Offset(0, 14)),
      Paint()
        ..color = const Color(0x1A2A2A66)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );

    // 填充：左下的卡偏蓝、右上的卡偏紫，三层共用一条渐变轴。
    final warm = Color.lerp(_cardBlue, _cardPurple, index / (offsets.length - 1))!;
    final cool = Color.lerp(_cardPurple, _cardBlue, 0.25 * index)!;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft + const Offset(0, cardSide * 0.15),
          rect.bottomRight - const Offset(0, cardSide * 0.1),
          <Color>[
            warm.withValues(alpha: 0.92 - index * 0.06),
            cool.withValues(alpha: 0.86 - index * 0.06),
          ],
        ),
    );

    // 白色描边：玻璃边缘。
    canvas.drawRRect(
      rrect.deflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = _fore.withValues(alpha: 0.75),
    );
  }
}

/// 前景记号：播放三角 + 右下折角，画在最上面那张卡的中心。
void _paintGlyph(Canvas canvas) {
  const double cardSide = 470;
  final center = Offset(_size / 2, _size / 2);

  // 播放三角：略向右偏，视觉重心才在卡片中心。
  const double triSize = 190;
  final path = Path()
    ..moveTo(center.dx - triSize * 0.32, center.dy - triSize * 0.5)
    ..lineTo(center.dx + triSize * 0.52, center.dy)
    ..lineTo(center.dx - triSize * 0.32, center.dy + triSize * 0.5)
    ..close();
  canvas.drawPath(
    path,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(center.dx - triSize * 0.32, center.dy - triSize * 0.5),
        Offset(center.dx + triSize * 0.52, center.dy + triSize * 0.5),
        <Color>[const Color(0xFFEFF3FF), _fore],
      ),
  );

  // 折角：包住三角右下角，像屏幕的一角。
  const double armLength = 210;
  const double stroke = 26;
  final corner = Offset(
    center.dx + cardSide / 2 - 118,
    center.dy + cardSide / 2 - 118,
  );
  final bracket = Path()
    ..moveTo(corner.dx - armLength, corner.dy)
    ..lineTo(corner.dx, corner.dy)
    ..lineTo(corner.dx, corner.dy - armLength);
  canvas.drawPath(
    bracket,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _fore.withValues(alpha: 0.92),
  );

  // 三角与折角之间的呼吸感：一圈极淡的光晕。
  canvas.drawCircle(
    center,
    cardSide * 0.42,
    Paint()
      ..shader = ui.Gradient.radial(
        center,
        cardSide * 0.42,
        <Color>[_fore.withValues(alpha: 0.16), _fore.withValues(alpha: 0)],
      ),
  );
}

/// 供后续微调颜色时用的一键列印（保留：改配色时先看值再改）。
// ignore: unused_element
String debugPalette() => <Color>[_bgTop, _bgBottom, _cardBlue, _cardPurple]
    .map((color) => color.toARGB32().toRadixString(16))
    .join(', ');

// 保持 math import 有用（圆形构图角度换算留给后续加弧形元素时用）。
// ignore: unused_element
double _deg(double value) => value * math.pi / 180;
