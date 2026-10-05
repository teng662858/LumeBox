import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/video/danmaku/danmaku_models.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';

/// 弹幕：解析（宽容口径）、时间窗口定位、设置收敛。
///
/// 弹幕是可选能力，因此「坏数据不炸」「缺失不报错」和功能本身一样重要。
void main() {
  group('弹幕解析', () {
    test('基础形状：time + text', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 1000, 'text': '第一条'},
        <String, Object?>{'time': 2500, 'text': '第二条'},
      ]);
      expect(track.length, 2);
      expect(track.items.first.time, const Duration(seconds: 1));
      expect(track.items.first.text, '第一条');
    });

    test('时间三种写法：毫秒 / 秒（小数）/ 字符串', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 5000, 'text': '毫秒'},
        <String, Object?>{'timeSeconds': 2.5, 'text': '秒'},
        <String, Object?>{'time': '1500', 'text': '字符串毫秒'},
        <String, Object?>{'t': 300, 'text': 't 简写'},
      ]);
      expect(track.length, 4);
      expect(track.items[0].time, const Duration(milliseconds: 300));
      expect(track.items[1].time, const Duration(milliseconds: 1500));
      expect(track.items[2].time, const Duration(milliseconds: 2500));
      expect(track.items[3].time, const Duration(milliseconds: 5000));
      expect(track.items.map((item) => item.text), <String>['t 简写', '字符串毫秒', '秒', '毫秒']);
    });

    test('信封三种字段名：danmaku / items / comments', () {
      for (final key in <String>['danmaku', 'items', 'comments']) {
        final track = DanmakuTrack.parse(<String, Object?>{
          key: <Object?>[
            <String, Object?>{'time': 100, 'text': 'x'},
          ],
        });
        expect(track.length, 1, reason: '信封字段 $key 应被识别');
      }
    });

    test('位置模式：scroll / top / bottom 与数字写法', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 0, 'text': 'a', 'mode': 'top'},
        <String, Object?>{'time': 1, 'text': 'b', 'mode': 'bottom'},
        <String, Object?>{'time': 2, 'text': 'c', 'mode': '5'},
        <String, Object?>{'time': 3, 'text': 'd', 'mode': '4'},
        <String, Object?>{'time': 4, 'text': 'e'},
        <String, Object?>{'time': 5, 'text': 'f', 'mode': '乱七八糟'},
      ]);
      expect(track.items[0].mode, DanmakuMode.top);
      expect(track.items[1].mode, DanmakuMode.bottom);
      expect(track.items[2].mode, DanmakuMode.top, reason: '5 = 顶部');
      expect(track.items[3].mode, DanmakuMode.bottom, reason: '4 = 底部');
      expect(track.items[4].mode, DanmakuMode.scroll, reason: '默认滚动');
      expect(track.items[5].mode, DanmakuMode.scroll, reason: '认不出来按滚动');
    });

    test('颜色：十进制 / 十六进制字符串 / 非法值', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 0, 'text': 'a', 'color': 0xFF0000},
        <String, Object?>{'time': 1, 'text': 'b', 'color': '#00FF00'},
        <String, Object?>{'time': 2, 'text': 'c', 'color': 'zzz'},
        <String, Object?>{'time': 3, 'text': 'd'},
      ]);
      expect(track.items[0].color, 0xFF0000);
      expect(track.items[1].color, 0x00FF00);
      expect(track.items[2].color, 0xFFFFFF, reason: '非法颜色回退白色');
      expect(track.items[3].color, 0xFFFFFF);
    });

    test('字号：倍数与像素两种口径都收敛到 0.5~2.0', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 0, 'text': 'a', 'fontSize': 1.5},
        <String, Object?>{'time': 1, 'text': 'b', 'size': 25},
        <String, Object?>{'time': 2, 'text': 'c', 'size': 999},
        <String, Object?>{'time': 3, 'text': 'd', 'size': 0.01},
      ]);
      expect(track.items[0].fontSize, 1.5);
      expect(track.items[1].fontSize, 1.0, reason: '25px ≈ 1.0 倍');
      expect(track.items[2].fontSize, 2.0, reason: '超上限收敛');
      expect(track.items[3].fontSize, 0.5, reason: '超下限收敛');
    });

    test('坏数据不炸：缺时间 / 缺文本 / 非对象一律跳过', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'text': '没有时间'},
        <String, Object?>{'time': 100},
        '不是对象',
        42,
        null,
        <String, Object?>{'time': 200, 'text': '   '},
        <String, Object?>{'time': 300, 'text': '好的一条'},
      ]);
      expect(track.length, 1);
      expect(track.items.single.text, '好的一条');
    });

    test('无法识别的整体载荷 → 空轨（不抛错）', () {
      expect(DanmakuTrack.parse(null).isEmpty, isTrue);
      expect(DanmakuTrack.parse('字符串').isEmpty, isTrue);
      expect(DanmakuTrack.parse(<String, Object?>{'foo': 1}).isEmpty, isTrue);
    });

    test('按时间排序：输入的乱序会被理顺', () {
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 3000, 'text': 'c'},
        <String, Object?>{'time': 1000, 'text': 'a'},
        <String, Object?>{'time': 2000, 'text': 'b'},
      ]);
      expect(track.items.map((item) => item.text), <String>['a', 'b', 'c']);
    });
  });

  group('时间窗口（拖动进度条时每帧都要用）', () {
    final track = DanmakuTrack.parse(<Object?>[
      for (var i = 1; i <= 10; i++)
        <String, Object?>{'time': i * 1000, 'text': '$i'},
    ]);

    test('取 [from, to) 区间：左闭右开', () {
      final window = track.window(
        const Duration(milliseconds: 3000),
        const Duration(milliseconds: 6000),
      );
      expect(window.map((item) => item.text), <String>['3', '4', '5']);
    });

    test('窗口外返回空；空轨也安全', () {
      expect(
        track.window(const Duration(seconds: 20), const Duration(seconds: 30)),
        isEmpty,
      );
      expect(
        DanmakuTrack.empty.window(Duration.zero, const Duration(seconds: 1)),
        isEmpty,
      );
    });

    test('边界：from 正好等于某条的时间即包含它', () {
      final window = track.window(
        const Duration(seconds: 5),
        const Duration(seconds: 5, milliseconds: 1),
      );
      expect(window.single.text, '5');
    });
  });

  group('弹幕设置', () {
    test('默认值合法且收敛后不变', () {
      const defaults = DanmakuSettings.defaults;
      expect(defaults.clamped(), defaults);
      expect(defaults.enabled, isTrue);
    });

    test('越界值被收敛到合法区间', () {
      const wild = DanmakuSettings(
        opacity: 5,
        fontScale: 99,
        displayArea: -1,
        speedScale: 0,
        strokeWidth: 100,
        maxOnScreen: 99999,
      );
      final clamped = wild.clamped();
      expect(clamped.opacity, DanmakuSettings.maxOpacity);
      expect(clamped.fontScale, DanmakuSettings.maxFontScale);
      expect(clamped.displayArea, DanmakuSettings.minArea);
      expect(clamped.speedScale, DanmakuSettings.minSpeed);
      expect(clamped.strokeWidth, DanmakuSettings.maxStroke);
      expect(clamped.maxOnScreen, DanmakuSettings.maxOnScreenLimit);
    });

    test('JSON 往返与坏数据回退', () {
      const settings = DanmakuSettings(
        enabled: false,
        opacity: 0.5,
        fontScale: 1.5,
        maxOnScreen: 100,
      );
      expect(
        DanmakuSettings.fromJson(settings.toJson()),
        settings,
      );
      expect(DanmakuSettings.fromJson(null), DanmakuSettings.defaults);
      expect(
        DanmakuSettings.fromJson(<String, Object?>{'opacity': 'abc'}).opacity,
        DanmakuSettings.defaults.opacity,
      );
      // 字符串数字也认。
      expect(
        DanmakuSettings.fromJson(<String, Object?>{'opacity': '0.6'}).opacity,
        0.6,
      );
    });

    test('样式换算：字号倍数 × 设置字号，透明度进颜色', () {
      const item = DanmakuItem(
        time: Duration.zero,
        text: 'x',
        color: 0xFF0000,
        fontSize: 1.5,
      );
      const settings = DanmakuSettings(fontScale: 2.0, opacity: 0.5, strokeWidth: 2);
      final style = DanmakuStyle.of(item, settings);
      expect(style.fontSize, DanmakuStyle.baseFontSize * 3.0);
      expect(style.strokeWidth, 2);
      expect(style.color.r, closeTo(1.0, 0.01));
      expect(style.color.a, closeTo(0.5, 0.02));
    });
  });

  group('弹幕缓存', () {
    test('按「作品/剧集」隔离；超上限丢最早的', () {
      final cache = DanmakuCache(maxEntries: 2);
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 0, 'text': 'x'},
      ]);

      cache.put('a', 'e1', track);
      cache.put('a', 'e2', track);
      expect(cache.get('a', 'e1'), isNotNull);
      expect(cache.get('a', 'e2'), isNotNull);
      expect(cache.get('b', 'e1'), isNull, reason: '不同作品互不可见');

      // 超上限：最早插入的 e1 被挤掉。
      cache.put('a', 'e3', track);
      expect(cache.length, 2);
      expect(cache.get('a', 'e1'), isNull);
      expect(cache.get('a', 'e3'), isNotNull);
    });

    test('同一键重复写入是覆盖（不挤占容量）', () {
      final cache = DanmakuCache(maxEntries: 2);
      final track = DanmakuTrack.parse(<Object?>[
        <String, Object?>{'time': 0, 'text': 'x'},
      ]);
      cache.put('a', 'e1', track);
      cache.put('a', 'e1', track);
      cache.put('a', 'e2', track);
      expect(cache.length, 2, reason: '覆盖不该占两个位置');
    });
  });
}
