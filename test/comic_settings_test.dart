import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/comic/comic_settings.dart';

/// 漫画进阶设置的验证：跨页配对（首页单独 / 直接配对）、翻页方向、页间距、
/// 预加载半径的持久化。
///
/// 跨页配对是这里最要紧的一块：纸质漫画的排法是「封面独立、跨页从第 2、3 页
/// 开始配」，配错了每一屏的两页都是错位的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_comic_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    library = await ReadingLibrary.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('跨页配对：首页单独（纸质漫画排法）', () {
    const settings = ComicReaderSettings();

    test('第 0 屏只有第 1 张（封面独占）', () {
      expect(settings.imagesOfSpread(0, 10), (0, 0));
    });

    test('之后每屏两张：1+2、3+4', () {
      expect(settings.imagesOfSpread(1, 10), (1, 2));
      expect(settings.imagesOfSpread(2, 10), (3, 4));
      expect(settings.imagesOfSpread(3, 10), (5, 6));
    });

    test('末页落单时区间收成一张（不留不存在的下标）', () {
      expect(settings.imagesOfSpread(5, 10), (9, 9));
    });

    test('屏数 = 1 + ceil((n-1)/2)', () {
      expect(settings.spreadCount(1), 1);
      expect(settings.spreadCount(2), 2); // 封面 + 第 2 张
      expect(settings.spreadCount(3), 2); // 封面 + (2,3)
      expect(settings.spreadCount(4), 3);
      expect(settings.spreadCount(10), 6);
    });

    test('图序号 → 屏序号（进度恢复用）', () {
      expect(settings.spreadIndexOf(0), 0);
      expect(settings.spreadIndexOf(1), 1);
      expect(settings.spreadIndexOf(2), 1);
      expect(settings.spreadIndexOf(3), 2);
      expect(settings.spreadIndexOf(4), 2);
    });
  });

  group('跨页配对：直接配对', () {
    const settings = ComicReaderSettings(
      spreadMode: ComicSpreadMode.pairFromStart,
    );

    test('第 0 屏是 1+2', () {
      expect(settings.imagesOfSpread(0, 10), (0, 1));
      expect(settings.imagesOfSpread(1, 10), (2, 3));
    });

    test('屏数 = ceil(n/2)', () {
      expect(settings.spreadCount(4), 2);
      expect(settings.spreadCount(5), 3);
    });

    test('图序号 → 屏序号', () {
      expect(settings.spreadIndexOf(0), 0);
      expect(settings.spreadIndexOf(1), 0);
      expect(settings.spreadIndexOf(2), 1);
    });
  });

  group('配对与屏序号互为逆运算（进度恢复不漂移）', () {
    for (final mode in ComicSpreadMode.values) {
      test('${mode.label}：每张图都能通过屏序号找回', () {
        final settings = ComicReaderSettings(spreadMode: mode);
        const imageCount = 11;
        for (var index = 0; index < imageCount; index++) {
          final spread = settings.spreadIndexOf(index);
          final (first, second) = settings.imagesOfSpread(spread, imageCount);
          expect(
            index == first || index == second,
            isTrue,
            reason: '第 $index 张应落在第 $spread 屏的 [$first, $second] 里',
          );
        }
      });
    }

    test('空章节与越界屏序号都有确定行为（不崩）', () {
      const settings = ComicReaderSettings();
      expect(settings.spreadCount(0), 0);
      expect(settings.imagesOfSpread(0, 0).$1, lessThan(0));
      expect(settings.imagesOfSpread(99, 5).$1, lessThan(0));
      expect(settings.imagesOfSpread(-1, 5).$1, lessThan(0));
    });
  });

  group('翻页方向', () {
    test('默认从左往右；从右往左由 id 正确解析', () {
      expect(
        const ComicReaderSettings().isRightToLeft,
        isFalse,
      );
      expect(
        ComicReadingDirection.fromId('rtl'),
        ComicReadingDirection.rightToLeft,
      );
      expect(
        ComicReaderSettings(
          direction: ComicReadingDirection.rightToLeft,
        ).isRightToLeft,
        isTrue,
      );
      expect(
        ComicReadingDirection.fromId('乱写'),
        ComicReadingDirection.leftToRight,
        reason: '坏值回退默认，不崩',
      );
    });
  });

  group('阅读背景与点击行为', () {
    test('默认：纯黑背景 + 点击呼出工具栏（与改动前行为一致）', () {
      const settings = ComicReaderSettings();
      expect(settings.background, ComicReaderBackground.black);
      expect(settings.tapAction, ComicTapAction.toolbar);
      expect(settings.background.color, const Color(0xFF000000));
    });

    test('四个背景预设都有各自底色，坏 id 回退纯黑', () {
      final colors = <Color>[
        for (final background in ComicReaderBackground.values) background.color,
      ];
      expect(colors.toSet().length, ComicReaderBackground.values.length,
          reason: '预设之间颜色不能重复');
      expect(
        ComicReaderBackground.fromId('彩虹色'),
        ComicReaderBackground.black,
      );
      expect(ComicTapAction.fromId('乱写'), ComicTapAction.toolbar);
    });
  });

  group('持久化', () {
    test('新增字段都能落库并读回', () {
      const original = ComicReaderSettings(
        mode: ComicReadingMode.doublePage,
        marginRatio: 0.2,
        doubleTapZoom: true,
        preloadRadius: 4,
        direction: ComicReadingDirection.rightToLeft,
        spreadMode: ComicSpreadMode.pairFromStart,
        pageGap: 12,
        background: ComicReaderBackground.eyeCare,
        tapAction: ComicTapAction.pageTurn,
      );
      original.save(library);

      final restored = ComicReaderSettings.load(library);
      expect(restored.mode, ComicReadingMode.doublePage);
      expect(restored.marginRatio, closeTo(0.2, 0.001));
      expect(restored.doubleTapZoom, isTrue);
      expect(restored.preloadRadius, 4, reason: '预加载半径以前没落库，现在要能读回');
      expect(restored.direction, ComicReadingDirection.rightToLeft);
      expect(restored.spreadMode, ComicSpreadMode.pairFromStart);
      expect(restored.pageGap, closeTo(12, 0.01));
      expect(restored.background, ComicReaderBackground.eyeCare);
      expect(restored.tapAction, ComicTapAction.pageTurn);
    });

    test('越界值收敛：预加载半径与页间距都在范围内', () {
      final clamped = const ComicReaderSettings().copyWith(
        preloadRadius: 99,
        pageGap: 999,
      );
      expect(clamped.preloadRadius, ComicReaderSettings.maxPreloadRadius);
      expect(clamped.pageGap, ComicReaderSettings.maxPageGap);

      final low = const ComicReaderSettings().copyWith(
        preloadRadius: 0,
        pageGap: -5,
      );
      expect(low.preloadRadius, 1);
      expect(low.pageGap, 0);
    });

    test('库被改坏（非法值）时回退默认，不崩', () {
      library.setSetting(ComicReaderSettings.keyPreloadRadius, '很多');
      library.setSetting(ComicReaderSettings.keyPageGap, '宽一点');
      library.setSetting(ComicReaderSettings.keyDirection, '左右横跳');
      library.setSetting(ComicReaderSettings.keySpreadMode, '随便');
      library.setSetting(ComicReaderSettings.keyBackground, '彩虹色');
      library.setSetting(ComicReaderSettings.keyTapAction, '双击');

      final restored = ComicReaderSettings.load(library);
      expect(restored.preloadRadius, ComicReaderSettings.defaultPreloadRadius);
      expect(restored.pageGap, 0);
      expect(restored.direction, ComicReadingDirection.leftToRight);
      expect(restored.spreadMode, ComicSpreadMode.coverFirst);
      expect(restored.background, ComicReaderBackground.black);
      expect(restored.tapAction, ComicTapAction.toolbar);
    });

    test('页间距落库时按比例存（上限变化也不会读出越界值）', () {
      const settings = ComicReaderSettings(pageGap: ComicReaderSettings.maxPageGap);
      settings.save(library);
      expect(
        ComicReaderSettings.load(library).pageGap,
        closeTo(ComicReaderSettings.maxPageGap, 0.01),
      );
    });
  });
}
