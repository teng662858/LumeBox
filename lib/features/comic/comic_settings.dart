import '../../core/reading/reading.dart';

/// 漫画阅读模式。
enum ComicReadingMode {
  /// 条漫瀑布流：纵向连续滚动，长条图不做分页。
  waterfall('waterfall', '条漫瀑布流'),

  /// 单页左右翻页：一屏一页，左右翻页。
  single('single', '单页左右翻页'),

  /// 双页跨页：一屏并排两页，适合横屏或平板。
  doublePage('doublePage', '双页跨页');

  const ComicReadingMode(this.id, this.label);

  final String id;
  final String label;

  static ComicReadingMode fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return ComicReadingMode.waterfall;
  }
}

/// 漫画阅读器设置：阅读模式、侧边距、双击放大开关、预加载半径。
///
/// 持久化在本板块的 `reading.db`（reading_setting 表）里，键名带板块前缀，
/// 因此漫画与小说的阅读偏好各存各的，互不影响。
class ComicReaderSettings {
  const ComicReaderSettings({
    this.mode = ComicReadingMode.waterfall,
    this.marginRatio = 0,
    this.doubleTapZoom = false,
    this.preloadRadius = defaultPreloadRadius,
  });

  /// 侧边距上限：占屏宽 50%。再宽就只剩一条缝，不再是阅读体验。
  static const double maxMarginRatio = 0.5;

  static const int defaultPreloadRadius = 2;

  /// 预加载半径上限：前后各 N 张。给得太大等于把整章都拉进内存。
  static const int maxPreloadRadius = 5;

  static const String keyMode = 'comic.reader.mode';
  static const String keyMargin = 'comic.reader.margin';
  static const String keyDoubleTapZoom = 'comic.reader.doubleTapZoom';

  /// 阅读模式。
  final ComicReadingMode mode;

  /// 左右侧边距，占屏宽比例 0..[maxMarginRatio]。
  final double marginRatio;

  /// 双击放大开关：开启后双击图片在 1x / 2x 之间切换（并支持双指缩放）。
  final bool doubleTapZoom;

  /// 滑动预加载半径（前后各 N 张）。
  final int preloadRadius;

  /// 由比例换算出的左右边距像素。
  double marginOf(double width) => width * marginRatio.clamp(0.0, maxMarginRatio);

  ComicReaderSettings copyWith({
    ComicReadingMode? mode,
    double? marginRatio,
    bool? doubleTapZoom,
    int? preloadRadius,
  }) {
    return ComicReaderSettings(
      mode: mode ?? this.mode,
      marginRatio: (marginRatio ?? this.marginRatio)
          .clamp(0.0, maxMarginRatio)
          .toDouble(),
      doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom,
      preloadRadius: (preloadRadius ?? this.preloadRadius)
          .clamp(1, maxPreloadRadius)
          .toInt(),
    );
  }

  /// 从板块阅读库读取设置；缺项或值非法时回退默认值。
  static ComicReaderSettings load(ReadingLibrary library) {
    return ComicReaderSettings(
      mode: ComicReadingMode.fromId(library.setting(keyMode)),
      marginRatio: _parseRatio(library.setting(keyMargin)),
      doubleTapZoom: library.setting(keyDoubleTapZoom) == 'true',
    );
  }

  /// 写回板块阅读库。
  void save(ReadingLibrary library) {
    library.setSetting(keyMode, mode.id);
    library.setSetting(keyMargin, marginRatio.toStringAsFixed(4));
    library.setSetting(keyDoubleTapZoom, doubleTapZoom ? 'true' : 'false');
  }

  static double _parseRatio(String? raw) {
    if (raw == null) return 0;
    final value = double.tryParse(raw);
    if (value == null) return 0;
    return value.clamp(0.0, maxMarginRatio).toDouble();
  }
}
