import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_polyfills.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/source_bridge.dart';
import 'package:lume_box/core/js/venera_bridge.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/js_data_source.dart';

/// 桥接垫片的纯 Dart 验证（不需要原生引擎）：登记与注入顺序、四个板块的
/// 覆盖、别名表与契约方法名一致，以及「桥接只是宿主代理的语法糖」这条纪律。
///
/// 桥接在真实引擎上的行为由 `source_bridge_native_test.dart` 验证。
void main() {
  const bridgeId = LumeSourceBridge.polyfillId;

  test('注入顺序：环境垫片在前，桥接对象先于兼容层', () {
    final general = LumeSourcePolyfills.registry
        .ordered()
        .map((item) => item.id)
        .toList(growable: false);
    expect(general.first, 'lume.source.fetch', reason: '网络垫片最先（桥接依赖它）');
    expect(
      general.indexOf(VeneraComicSourcePolyfill.polyfillId),
      greaterThan(general.indexOf(bridgeId)),
      reason: 'Venera 兼容层把契约方法挂到桥接对象上，必须排在桥接之后',
    );

    final cat = LumeSourcePolyfills.catRegistry
        .ordered()
        .map((item) => item.id)
        .toList(growable: false);
    expect(cat.last, bridgeId);
    expect(
      cat.contains(VeneraComicSourcePolyfill.polyfillId),
      isFalse,
      reason: '猫源有自己的登记表，不叠 Venera 兼容层',
    );
    for (final id in <String>[
      'lume.source.fetch',
      ...CatPolyfills.all.map((item) => item.id),
    ]) {
      expect(
        cat.indexOf(id),
        lessThan(cat.indexOf(bridgeId)),
        reason: '$id 必须在桥接之前注入',
      );
    }
  });

  test('四个板块都注入桥接：猫源在 Node 垫片之上再叠一层', () {
    for (final section in Section.values) {
      final registry = LumeSourcePolyfills.forSection(section);
      expect(
        registry.contains(bridgeId),
        isTrue,
        reason: '${section.label} 也需要桥接对象（顶层函数写法靠它派发）',
      );
      expect(registry.contains('lume.source.fetch'), isTrue);
    }
    // 猫源专属垫片（process / Buffer / require…）仍然只进猫源。
    expect(LumeSourcePolyfills.forSection(Section.cat).contains('lume.cat.process'), isTrue);
    expect(LumeSourcePolyfills.forSection(Section.video).contains('lume.cat.process'), isFalse);
  });

  test('别名表与数据源契约同名同序', () {
    expect(LumeSourceBridge.methods, JsSourceContract.methods);
    for (final entry in LumeSourceBridge.aliases.entries) {
      final names = entry.value;
      expect(
        names.last,
        entry.key,
        reason: '对象式契约名必须在末位（命中它即收对象入参）',
      );
      expect(
        names.first,
        startsWith('get'),
        reason: '首位是函数式契约的推荐写法，报错里点名它',
      );
    }
    expect(LumeSourceBridge.aliases['list'], contains('getList'));
  });

  test('垫片源码：别名表注入、宿主能力齐备、赋值合并、不留占位符', () {
    final polyfill = const LumeSourceBridgePolyfill();
    final source = polyfill.source;

    expect(source.contains('__LUME_ALIAS_TABLE__'), isFalse, reason: '占位符必须被替换');
    expect(source.contains('"getList"'), isTrue, reason: '别名表由 Dart 侧注入');

    // 宿主能力：HTTP 走 fetch（最终还是宿主代理），文件 IO 走 store.* 代理。
    expect(source.contains('globalThis.fetch'), isTrue);
    expect(source.contains('store.read'), isTrue);
    expect(source.contains('store.write'), isTrue);
    expect(source.contains('store.keys'), isTrue);
    expect(source.contains('globalThis.LumeBridge'), isTrue,
        reason: '桥接只经宿主代理说话');

    // 脚本对全局 LumeSource 的赋值合并进桥接对象（宿主能力不被盖掉）。
    expect(source.contains("Object.defineProperty(globalThis, 'LumeSource'"), isTrue);
    expect(source.contains('reserved'), isTrue);

    // 纪律：不引入任何新的系统能力。
    for (final forbidden in <String>['child_process', 'require(', 'process.env']) {
      expect(
        source.contains(forbidden),
        isFalse,
        reason: '桥接不该出现 $forbidden',
      );
    }
    expect(polyfill.requires, <String>['lume.source.fetch']);
    expect(polyfill.id, bridgeId);
  });

  test('别名表可注入：测试与将来兼容别的命名生态', () {
    const custom = LumeSourceBridgePolyfill(<String, List<String>>{
      'list': <String>['getFeed', 'list'],
    });
    expect(custom.source.contains('"getFeed"'), isTrue);
    expect(custom.source.contains("'getSearch'"), isTrue,
        reason: '搜索别名是固定的一路分支');
  });
}
