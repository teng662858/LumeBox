import 'package:flutter/material.dart';

/// Geometry uses the safe, available area rather than the physical screen.
abstract final class PlayerLayout {
  static const tapSize = 44.0;
  static const controlsAutoHideDelay = Duration(seconds: 5);
  static double panelWidth(double available) =>
      (available * .34).clamp(260.0, 320.0).clamp(0.0, available);

  static int episodeColumns(
    double width, {
    required bool longLabels,
    double labelWidth = 0,
  }) =>
      ((width + 8) /
              ((longLabels ? 88.0 : 44.0).clamp(
                    labelWidth + 12,
                    double.infinity,
                  ) +
                  8))
          .floor()
          .clamp(2, 5);

  static Duration motion(BuildContext context, [int milliseconds = 220]) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: milliseconds);

  static String seekDelta(Duration from, Duration to) {
    final seconds = (to - from).inSeconds;
    if (seconds == 0) return '当前位置';
    return '${seconds > 0 ? '前进' : '后退'} ${seconds.abs()} 秒';
  }
}
