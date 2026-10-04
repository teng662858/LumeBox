import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_polyfills.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/session/section.dart';

/// 猫源垫片登记表的验证（不需要原生引擎）：
/// 只对猫源注入、依赖顺序正确、垫片表本身不携带任何 IO 能力。
void main() {
  const catIds = <String>[
    'lume.cat.unsupported',
    'lume.cat.console',
    'lume.cat.timers',
    'lume.cat.process',
    'lume.cat.buffer',
    'lume.cat.require',
  ];

  test('按板块选表：只有猫源拿到垫片补全', () {
    final cat = LumeSourcePolyfills.forSection(Section.cat);
    for (final id in catIds) {
      expect(cat.contains(id), isTrue, reason: '猫源表缺少 $id');
    }
    // 网络垫片仍在（在通用垫片之上叠加，不是替换）。
    expect(cat.contains('lume.source.fetch'), isTrue);

    for (final section in <Section>[
      Section.novel,
      Section.comic,
      Section.video,
    ]) {
      final registry = LumeSourcePolyfills.forSection(section);
      expect(
        identical(registry, LumeSourcePolyfills.registry),
        isTrue,
        reason: '${section.label} 应当拿通用表',
      );
      for (final id in catIds) {
        expect(
          registry.contains(id),
          isFalse,
          reason: '${section.label} 不该有猫源垫片 $id（宪法第 3 条）',
        );
      }
    }
    // 反复取用是同一个登记表（不改动内部状态）。
    expect(
      identical(LumeSourcePolyfills.forSection(Section.cat), cat),
      isTrue,
    );
  });

  test('依赖顺序：require 在它引用的内建之后注入', () {
    final ordered = LumeSourcePolyfills.catRegistry.ordered();
    final ids = ordered.map((item) => item.id).toList(growable: false);

    // 依赖先于自身：require 需要 process / Buffer / console / timers。
    for (final dependency in <String>[
      'lume.cat.unsupported',
      'lume.cat.console',
      'lume.cat.timers',
      'lume.cat.process',
      'lume.cat.buffer',
    ]) {
      expect(
        ids.indexOf(dependency),
        lessThan(ids.indexOf('lume.cat.require')),
        reason: '$dependency 必须在 require 之前注入',
      );
    }
    expect(ids.length, ordered.toSet().length, reason: '没有重复注入');
  });

  test('猫源垫片是纯 JS：不直接碰宿主桥，边界提示齐备', () {
    // 猫源环境垫片（process / Buffer / require / console / 定时器）自己不认识宿主：
    // 网络与文件 IO 的唯一通路是通用 fetch 垫片 → LumeBridge → Dart。
    final catOnly = CatPolyfills.all.map((item) => item.source).join('\n');
    expect(
      catOnly.contains('globalThis.LumeBridge'),
      isFalse,
      reason: '猫源环境垫片不接触宿主桥对象（错误文案里提到它不算）',
    );

    final bootstrap = LumeSourcePolyfills.catRegistry.bootstrap();
    expect(bootstrap.contains('LumeBridge'), isTrue,
        reason: '登记表包含通用 fetch 垫片，网络仍走宿主桥接层');
    expect(bootstrap.contains('child_process'), isTrue,
        reason: '拒绝清单里点名了危险模块');
    expect(bootstrap.contains('LUME_UNSUPPORTED'), isTrue,
        reason: '边界错误带稳定 code，页面与脚本都能识别');
    expect(bootstrap.contains('WebAssembly'), isTrue,
        reason: 'WASM 存根必须注入');
  });

  test('垫片集合本身合法：id 唯一、源码非空、可登记', () {
    final ids = CatPolyfills.all.map((item) => item.id).toList(growable: false);
    expect(ids.toSet().length, ids.length);
    for (final polyfill in CatPolyfills.all) {
      expect(polyfill.source.trim(), isNotEmpty);
    }
    // 直接登记到自建表也要能通过校验（复用沙箱的登记约束）。
    expect(() => PolyfillRegistry(CatPolyfills.all), returnsNormally);
  });
}
