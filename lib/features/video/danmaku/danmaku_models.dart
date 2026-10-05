import 'package:flutter/foundation.dart';

/// 一条弹幕。
///
/// 位置用**视频时间轴上的毫秒**表示（而不是「第几条」）：这样拖动进度条、切集、
/// 恢复播放位置时都能直接按时间取，不需要额外的对齐逻辑。
@immutable
class DanmakuItem {
  const DanmakuItem({
    required this.time,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFF,
    this.fontSize = 1.0,
  });

  /// 出现的时刻（相对视频开头，毫秒）。
  final Duration time;

  final String text;

  final DanmakuMode mode;

  /// RGB 颜色（0xRRGGBB）。不带 alpha：透明度由弹幕设置统一控制。
  final int color;

  /// 字号倍数（0.5~2.0）：弹幕常见的「大字号」标记。
  final double fontSize;

  /// 解析一条弹幕 JSON（图源契约 / 本地导入共用的宽容口径）。
  ///
  /// 时间接受三种写法：`time`（毫秒）、`t`（毫秒）、`timeSeconds`（秒，带小数）。
  /// 无法识别时返回 null——坏条目跳过，不让它污染整份弹幕。
  static DanmakuItem? parse(Object? json) {
    if (json is! Map) return null;
    final text = '${json['text'] ?? json['content'] ?? json['m'] ?? ''}'.trim();
    if (text.isEmpty) return null;

    final millis = _millis(json);
    if (millis == null) return null;

    return DanmakuItem(
      time: Duration(milliseconds: millis),
      text: text,
      mode: DanmakuMode.fromId('${json['mode'] ?? json['position'] ?? ''}'),
      color: _color(json['color']),
      fontSize: _size(json['fontSize'] ?? json['size']),
    );
  }

  static int? _millis(Map json) {
    final raw = json['time'] ?? json['t'];
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return parsed;
      final seconds = double.tryParse(raw);
      if (seconds != null) return (seconds * 1000).round();
    }
    final seconds = json['timeSeconds'];
    if (seconds is num) return (seconds * 1000).round();
    if (seconds is String) {
      final parsed = double.tryParse(seconds);
      if (parsed != null) return (parsed * 1000).round();
    }
    return null;
  }

  static int _color(Object? value) {
    if (value is int) return value & 0xFFFFFF;
    if (value is num) return value.toInt() & 0xFFFFFF;
    if (value is String) {
      final text = value.replaceFirst('#', '').trim();
      final parsed = int.tryParse(text, radix: 16);
      if (parsed != null) return parsed & 0xFFFFFF;
    }
    return 0xFFFFFF;
  }

  static double _size(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse('${value ?? ''}');
    if (parsed == null) return 1.0;
    // 常见两种口径：倍数（0.5~2）与像素（12~48）。大于 3 视为像素。
    final scale = parsed > 3 ? parsed / 25 : parsed;
    return scale.clamp(0.5, 2.0);
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuItem &&
      other.time == time &&
      other.text == text &&
      other.mode == mode &&
      other.color == color;

  @override
  int get hashCode => Object.hash(time, text, mode, color);

  @override
  String toString() => 'DanmakuItem(${time.inMilliseconds}ms, $text)';
}

/// 弹幕位置。
enum DanmakuMode {
  /// 从右向左滚动（默认）。
  scroll('scroll', '滚动'),

  /// 固定在顶部。
  top('top', '顶部'),

  /// 固定在底部。
  bottom('bottom', '底部');

  const DanmakuMode(this.id, this.label);

  final String id;
  final String label;

  /// 从图源给的标识还原；认不出来按滚动处理（最普遍）。
  static DanmakuMode fromId(String id) {
    final value = id.trim().toLowerCase();
    if (value == 'top' || value == '5') return DanmakuMode.top;
    if (value == 'bottom' || value == '4') return DanmakuMode.bottom;
    return DanmakuMode.scroll;
  }
}

/// 一份弹幕（一部作品的某一集）。
///
/// 排序按时间升序：渲染层按时间窗口取用，有序才能二分定位。
@immutable
class DanmakuTrack {
  const DanmakuTrack(this.items);

  static const DanmakuTrack empty = DanmakuTrack(<DanmakuItem>[]);

  final List<DanmakuItem> items;

  bool get isEmpty => items.isEmpty;

  int get length => items.length;

  /// 解析图源 / 本地文件给的弹幕载荷。
  ///
  /// 接受三种形状（与图源契约的宽容口径一致）：
  /// - 数组：`[{time, text}, …]`；
  /// - 信封：`{danmaku: [...]}` 或 `{items: [...]}` 或 `{comments: [...]}`；
  /// - 无法识别 → 空轨（不抛错，弹幕缺失不该影响播放）。
  static DanmakuTrack parse(Object? json) {
    final list = switch (json) {
      List() => json,
      Map() => json['danmaku'] ?? json['items'] ?? json['comments'],
      _ => null,
    };
    if (list is! List) return empty;

    final items = <DanmakuItem>[];
    for (final raw in list) {
      final parsed = DanmakuItem.parse(raw);
      if (parsed != null) items.add(parsed);
    }
    items.sort((a, b) => a.time.compareTo(b.time));
    return DanmakuTrack(List<DanmakuItem>.unmodifiable(items));
  }

  /// 取时间窗口 `[from, to)` 内的弹幕。
  ///
  /// 用二分找起点再顺序收集：拖动进度条后每帧都要取一次，线性扫全表会白烧 CPU。
  List<DanmakuItem> window(Duration from, Duration to) {
    if (items.isEmpty) return const <DanmakuItem>[];
    var low = 0;
    var high = items.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (items[mid].time < from) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final result = <DanmakuItem>[];
    for (var i = low; i < items.length; i++) {
      if (items[i].time >= to) break;
      result.add(items[i]);
    }
    return result;
  }

  /// 附近有多少条（用于「本集弹幕 N 条」的展示）。
  int get total => items.length;
}
