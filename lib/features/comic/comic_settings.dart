import 'dart:ui' show Color;

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

/// 翻页方向。
///
/// 日漫与港漫从右往左读，国漫 / 欧美漫从左往右。方向错了每一页的阅读顺序都是
/// 反的（双页跨页尤其明显：两页左右颠倒）。
enum ComicReadingDirection {
  /// 从左往右（国漫 / 欧美漫，默认）。
  leftToRight('ltr', '从左往右'),

  /// 从右往左（日漫 / 港漫）。
  rightToLeft('rtl', '从右往左');

  const ComicReadingDirection(this.id, this.label);

  final String id;
  final String label;

  static ComicReadingDirection fromId(String? id) {
    for (final direction in values) {
      if (direction.id == id) return direction;
    }
    return ComicReadingDirection.leftToRight;
  }
}

/// 双页跨页的配对方式。
enum ComicSpreadMode {
  /// 首页单独一屏，之后每屏两页。
  ///
  /// 这是纸质漫画的排法：封面（第 1 页）独立，跨页从第 2、3 页开始配。
  /// 不这么排的话，单页封面会跟正文第一页挤在一屏，跨页全部错位一格。
  coverFirst('coverFirst', '首页单独'),

  /// 直接从第一页开始两页一屏。
  pairFromStart('pairFromStart', '直接配对');

  const ComicSpreadMode(this.id, this.label);

  final String id;
  final String label;

  static ComicSpreadMode fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return ComicSpreadMode.coverFirst;
  }
}

/// 阅读背景：图片之外的留白底色（只改底色，不动图片本身）。
///
/// 与小说侧阅读主题同一套色板（深灰 / 护眼绿 / 纯白取同值），漫画另加纯黑默认。
enum ComicReaderBackground {
  black('black', '纯黑', Color(0xFF000000)),
  gray('gray', '深灰', Color(0xFF1B1B20)),
  eyeCare('eyeCare', '护眼绿', Color(0xFFCFE8D2)),
  white('white', '纯白', Color(0xFFFFFFFF));

  const ComicReaderBackground(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;

  static ComicReaderBackground fromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return ComicReaderBackground.black;
  }
}

/// 点一下屏幕做什么。
enum ComicTapAction {
  /// 呼出 / 收起工具栏（现状默认）。
  toolbar('toolbar', '呼出工具栏'),

  /// 点击分区翻页：左 1/3 上一页、右 1/3 下一页、中间呼出工具栏。
  ///
  /// 只在单页 / 双页模式生效——瀑布流没有「页」可翻，仍是呼出工具栏。
  /// 分区方向随阅读方向：从右往左（日漫）时左 1/3 是下一页。
  pageTurn('pageTurn', '点击翻页');

  const ComicTapAction(this.id, this.label);

  final String id;
  final String label;

  static ComicTapAction fromId(String? id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return ComicTapAction.toolbar;
  }
}

/// 漫画阅读器设置：阅读模式、侧边距、双击放大开关、预加载半径、翻页方向、跨页配对、
/// 阅读背景、点击行为。
///
/// 持久化在本板块的 `reading.db`（reading_setting 表）里，键名带板块前缀，
/// 因此漫画与小说的阅读偏好各存各的，互不影响。
class ComicReaderSettings {
  const ComicReaderSettings({
    this.mode = ComicReadingMode.waterfall,
    this.marginRatio = 0,
    this.doubleTapZoom = false,
    this.preloadRadius = defaultPreloadRadius,
    this.direction = ComicReadingDirection.leftToRight,
    this.spreadMode = ComicSpreadMode.coverFirst,
    this.pageGap = 0,
    this.background = ComicReaderBackground.black,
    this.tapAction = ComicTapAction.toolbar,
  });

  /// 侧边距上限：占屏宽 50%。再宽就只剩一条缝，不再是阅读体验。
  static const double maxMarginRatio = 0.5;

  static const int defaultPreloadRadius = 2;

  /// 预加载半径上限：前后各 N 张。给得太大等于把整章都拉进内存。
  static const int maxPreloadRadius = 5;

  /// 页间距上限（逻辑像素）：再大就断了条漫的连续感。
  static const double maxPageGap = 24;

  static const String keyMode = 'comic.reader.mode';
  static const String keyMargin = 'comic.reader.margin';
  static const String keyDoubleTapZoom = 'comic.reader.doubleTapZoom';
  static const String keyPreloadRadius = 'comic.reader.preloadRadius';
  static const String keyDirection = 'comic.reader.direction';
  static const String keySpreadMode = 'comic.reader.spreadMode';
  static const String keyPageGap = 'comic.reader.pageGap';
  static const String keyBackground = 'comic.reader.background';
  static const String keyTapAction = 'comic.reader.tapAction';

  /// 阅读模式。
  final ComicReadingMode mode;

  /// 左右侧边距，占屏宽比例 0..[maxMarginRatio]。
  final double marginRatio;

  /// 双击放大开关：开启后双击图片在 1x / 2x 之间切换（并支持双指缩放）。
  final bool doubleTapZoom;

  /// 滑动预加载半径（前后各 N 张）。
  final int preloadRadius;

  /// 翻页方向（日漫从右往左）。
  final ComicReadingDirection direction;

  /// 双页跨页的配对方式。
  final ComicSpreadMode spreadMode;

  /// 页间距（逻辑像素）：条漫里就是图与图之间的空隙，翻页模式里是两页之间。
  final double pageGap;

  /// 阅读背景（图片之外的留白底色）。
  final ComicReaderBackground background;

  /// 点一下屏幕做什么（呼出工具栏 / 分区点击翻页）。
  final ComicTapAction tapAction;

  /// 由比例换算出的左右边距像素。
  double marginOf(double width) => width * marginRatio.clamp(0.0, maxMarginRatio);

  /// 是否从右往左（翻页控件的 `reverse` 取值）。
  bool get isRightToLeft => direction == ComicReadingDirection.rightToLeft;

  /// 第 [index] 张图在双页模式下所属的「屏」序号。
  ///
  /// 配对规则由 [spreadMode] 决定：
  /// - `coverFirst`：第 0 张独占一屏，之后每屏两张（1+2、3+4…）；
  /// - `pairFromStart`：0+1、2+3…
  ///
  /// 用图下标算屏序号（而不是反过来）是为了让「当前读到第几张」这个唯一状态
  /// 同时适用于三种模式：瀑布流按图算位置，单页一图一屏，双页再按屏换算。
  int spreadIndexOf(int index) {
    if (index <= 0) return 0;
    if (spreadMode == ComicSpreadMode.pairFromStart) return index ~/ 2;
    return (index + 1) ~/ 2;
  }

  /// 第 [spread] 屏包含的图下标区间（闭区间）；越界时返回空区间。
  ///
  /// 返回的区间可能只有一张（首页独占、或末页落单），调用方据此决定要不要
  /// 给另一半留空位。
  (int, int) imagesOfSpread(int spread, int imageCount) {
    if (imageCount <= 0 || spread < 0) return (-1, -2);
    if (spreadMode == ComicSpreadMode.pairFromStart) {
      final first = spread * 2;
      if (first >= imageCount) return (-1, -2);
      final second = first + 1;
      return (first, second >= imageCount ? first : second);
    }
    if (spread == 0) return (0, 0);
    final first = spread * 2 - 1;
    if (first >= imageCount) return (-1, -2);
    final second = first + 1;
    return (first, second >= imageCount ? first : second);
  }

  /// 双页模式下的总屏数。
  int spreadCount(int imageCount) {
    if (imageCount <= 0) return 0;
    if (spreadMode == ComicSpreadMode.pairFromStart) return (imageCount + 1) ~/ 2;
    // 首页独占 + 其余两两配对。
    return 1 + (imageCount - 1 + 1) ~/ 2;
  }

  ComicReaderSettings copyWith({
    ComicReadingMode? mode,
    double? marginRatio,
    bool? doubleTapZoom,
    int? preloadRadius,
    ComicReadingDirection? direction,
    ComicSpreadMode? spreadMode,
    double? pageGap,
    ComicReaderBackground? background,
    ComicTapAction? tapAction,
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
      direction: direction ?? this.direction,
      spreadMode: spreadMode ?? this.spreadMode,
      pageGap:
          (pageGap ?? this.pageGap).clamp(0.0, maxPageGap).toDouble(),
      background: background ?? this.background,
      tapAction: tapAction ?? this.tapAction,
    );
  }

  /// 从板块阅读库读取设置；缺项或值非法时回退默认值。
  static ComicReaderSettings load(ReadingLibrary library) {
    return ComicReaderSettings(
      mode: ComicReadingMode.fromId(library.setting(keyMode)),
      marginRatio: _parseRatio(library.setting(keyMargin)),
      doubleTapZoom: library.setting(keyDoubleTapZoom) == 'true',
      preloadRadius: _parseInt(
        library.setting(keyPreloadRadius),
        defaultPreloadRadius,
        1,
        maxPreloadRadius,
      ),
      direction: ComicReadingDirection.fromId(library.setting(keyDirection)),
      spreadMode: ComicSpreadMode.fromId(library.setting(keySpreadMode)),
      pageGap: _parseRatio(library.setting(keyPageGap)) * maxPageGap,
      background: ComicReaderBackground.fromId(library.setting(keyBackground)),
      tapAction: ComicTapAction.fromId(library.setting(keyTapAction)),
    );
  }

  /// 写回板块阅读库。
  void save(ReadingLibrary library) {
    library.setSetting(keyMode, mode.id);
    library.setSetting(keyMargin, marginRatio.toStringAsFixed(4));
    library.setSetting(keyDoubleTapZoom, doubleTapZoom ? 'true' : 'false');
    library.setSetting(keyPreloadRadius, preloadRadius.toString());
    library.setSetting(keyDirection, direction.id);
    library.setSetting(keySpreadMode, spreadMode.id);
    library.setSetting(keyPageGap, (pageGap / maxPageGap).toStringAsFixed(4));
    library.setSetting(keyBackground, background.id);
    library.setSetting(keyTapAction, tapAction.id);
  }

  static double _parseRatio(String? raw) {
    if (raw == null) return 0;
    final value = double.tryParse(raw);
    if (value == null) return 0;
    return value.clamp(0.0, 1.0).toDouble();
  }

  static int _parseInt(String? raw, int fallback, int min, int max) {
    final value = int.tryParse(raw ?? '');
    if (value == null) return fallback;
    return value.clamp(min, max);
  }
}
