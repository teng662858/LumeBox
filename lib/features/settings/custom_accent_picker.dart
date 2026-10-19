import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<Color?> showCustomAccentPicker(BuildContext context, Color initial) =>
    showModalBottomSheet<Color>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CustomAccentPicker(initial: initial),
    );

class CustomAccentPicker extends StatefulWidget {
  const CustomAccentPicker({super.key, required this.initial});
  final Color initial;
  @override
  State<CustomAccentPicker> createState() => _CustomAccentPickerState();
}

class _CustomAccentPickerState extends State<CustomAccentPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: _hexOf(widget.initial));
  String? _error;
  String _hexOf(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  void _set(HSVColor value) {
    setState(() {
      _hsv = value;
      _error = null;
      _hex.text = _hexOf(value.toColor());
    });
  }

  void _select(Offset point, Size size) => _set(
    _hsv
        .withSaturation((point.dx / size.width).clamp(0.0, 1.0))
        .withValue((1 - point.dy / size.height).clamp(0.0, 1.0)),
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final foreground = color.computeLuminance() > .45
        ? Colors.black
        : Colors.white;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '自定义颜色',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '取消自定义颜色',
                      onPressed: () => Navigator.pop(context),
                      icon: const LumeIcon(
                        Icons.close,
                        slot: 'custom_accent_picker.1',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      math.min(
                        280,
                        math.max(120, MediaQuery.sizeOf(context).height * .3),
                      ),
                    );
                    return Semantics(
                      label: '饱和度和明度色板',
                      child: GestureDetector(
                        key: const Key('accent.saturationValue'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _select(d.localPosition, size),
                        onPanUpdate: (d) => _select(d.localPosition, size),
                        child: CustomPaint(
                          size: size,
                          painter: _ColorFieldPainter(_hsv),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: const LinearGradient(
                      colors: [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Color(0xFFFF00FF),
                        Colors.red,
                      ],
                    ),
                  ),
                  child: SizedBox(
                    height: 24,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 0,
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        thumbColor: HSVColor.fromAHSV(
                          1,
                          _hsv.hue,
                          1,
                          1,
                        ).toColor(),
                        overlayColor: Colors.transparent,
                      ),
                      child: Slider(
                        key: const Key('accent.hue'),
                        value: _hsv.hue,
                        max: 360,
                        semanticFormatterCallback: (value) =>
                            '色相 ${value.round()} 度',
                        onChanged: (value) => _set(_hsv.withHue(value)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      key: const Key('accent.preview'),
                      width: 44,
                      height: 44,
                      margin: const EdgeInsets.only(top: 4, right: 14),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        key: const Key('accent.hex'),
                        controller: _hex,
                        autocorrect: false,
                        enableSuggestions: false,
                        inputFormatters: [LengthLimitingTextInputFormatter(7)],
                        decoration: InputDecoration(
                          prefixText: '# ',
                          labelText: '十六进制颜色',
                          hintText: 'FF2D55',
                          errorText: _error,
                          suffixIcon: IconButton(
                            tooltip: '清空颜色值',
                            icon: const LumeIcon(
                              Icons.cancel_outlined,
                              slot: 'custom_accent_picker.2',
                            ),
                            onPressed: () {
                              _hex.clear();
                              setState(() => _error = '请输入 6 位颜色值');
                            },
                          ),
                        ),
                        onChanged: (text) {
                          final value = text.trim().replaceFirst(
                            RegExp(r'^#'),
                            '',
                          );
                          setState(() {
                            if (!RegExp(r'^[a-fA-F0-9]{6}$').hasMatch(value)) {
                              _error = '请输入 6 位颜色值，例如 FF2D55';
                            } else {
                              _error = null;
                              _hsv = HSVColor.fromColor(
                                Color(0xFF000000 | int.parse(value, radix: 16)),
                              );
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('accent.confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: foreground,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    onPressed: _error != null
                        ? null
                        : () => Navigator.pop(context, color),
                    child: const Text('使用这个颜色'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorFieldPainter extends CustomPainter {
  const _ColorFieldPainter(this.hsv);
  final HSVColor hsv;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(18)));
    canvas.drawColor(
      HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
      BlendMode.src,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Colors.transparent],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    canvas.restore();
    final point = Offset(
      (hsv.saturation * size.width).clamp(10, size.width - 10),
      ((1 - hsv.value) * size.height).clamp(10, size.height - 10),
    );
    canvas.drawCircle(point, 10, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      point,
      11,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      point,
      13,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ColorFieldPainter oldDelegate) => oldDelegate.hsv != hsv;
}
