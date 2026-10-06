import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/js/source_store.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';

/// 沙盒文件 IO 的后端（[SandboxStore]）与宿主接线（[LumeSourceHost]）的纯 Dart 验证：
/// 路径归一、上限、按图源隔离，以及 `LumeSource.fs.*` 落到的那几个代理方法。
///
/// 这一组不需要原生引擎：桥接对象在 JS 侧怎么调用不在本文件，JS 侧行为由
/// `source_bridge_native_test.dart` 在真实引擎上验证。
void main() {
  group('SandboxStore：路径与读写', () {
    test('路径归一：前导斜杠与重复斜杠落到同一条目', () {
      expect(SandboxStore.normalizeKey('/cache/a.json'), 'cache/a.json');
      expect(SandboxStore.normalizeKey('cache//a.json'), 'cache/a.json');
      expect(SandboxStore.normalizeKey(' /cache/a.json '), 'cache/a.json');

      final store = SandboxStore();
      store.write('/cache/a.json', 'v1');
      expect(store.read('cache/a.json'), 'v1');
      expect(store.containsKey('//cache/a.json'), isTrue);
    });

    test('空路径拒绝', () {
      expect(
        () => SandboxStore.normalizeKey('  //  '),
        throwsA(isA<SandboxHostException>()),
      );
      expect(
        () => SandboxStore().write('/', 'x'),
        throwsA(isA<SandboxHostException>()),
      );
    });

    test('覆盖写、删除与键列表（字典序）', () {
      final store = SandboxStore();
      store.write('b', '2');
      store.write('a', '1');
      store.write('a', '11');
      expect(store.read('a'), '11');
      expect(store.totalChars, '11'.length + '2'.length);
      expect(store.keys(), <String>['a', 'b']);

      expect(store.remove('a'), isTrue);
      expect(store.remove('a'), isFalse);
      expect(store.read('a'), isNull);
      expect(store.totalChars, 1);
    });

    test('实例之间互不可见（按图源隔离）', () {
      final first = SandboxStore();
      final second = SandboxStore();
      first.write('shared', 'one');
      expect(second.read('shared'), isNull);

      first.clear();
      second.write('shared', 'two');
      expect(second.read('shared'), 'two');
    });
  });

  group('SandboxStore：上限', () {
    test('单条超限即拒绝，且不写入', () {
      final store = SandboxStore(maxValueChars: 4);
      expect(
        () => store.write('big', '12345'),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('单条上限'),
          ),
        ),
      );
      expect(store.entryCount, 0);
      store.write('ok', '1234');
      expect(store.read('ok'), '1234');
    });

    test('总量超限即拒绝', () {
      final store = SandboxStore(maxValueChars: 16, maxTotalChars: 10);
      store.write('a', '12345');
      expect(
        () => store.write('b', '123456'),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('已满'),
          ),
        ),
      );
      // 覆盖写不吃总量额度：换掉旧值仍然可以。
      store.write('a', '1234567890');
      expect(store.read('a'), '1234567890');
      expect(store.totalChars, 10);
    });

    test('条目数超限即拒绝', () {
      final store = SandboxStore(maxEntries: 2);
      store.write('a', '1');
      store.write('b', '2');
      expect(
        () => store.write('c', '3'),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('条目已达上限'),
          ),
        ),
      );
      expect(store.entryCount, 2);
    });
  });

  group('LumeSourceHost：代理方法', () {
    late LumeSourceHost host;

    setUp(() => host = LumeSourceHost(
          LumeHttp(),
          timeout: const Duration(seconds: 1),
          section: Section.novel,
          sourceId: 'src',
        ));

    Future<Object?> call(String method, [Object? payload]) => host.invoke(
          SandboxHostRequest(
            sandboxId: host.expectedSandboxId,
            method: method,
            payload: payload,
          ),
        );

    test('写入 / 读取 / 存在 / 列键 / 删除', () async {
      expect(
        await call(SandboxHostMethods.storeWrite, <String, Object?>{
          'key': '/cache/list.json',
          'value': '{"page":1}',
        }),
        <String, Object?>{'ok': true},
      );

      expect(
        await call(SandboxHostMethods.storeRead, <String, Object?>{'key': 'cache/list.json'}),
        <String, Object?>{'value': '{"page":1}'},
      );
      expect(
        await call(SandboxHostMethods.storeHas, <String, Object?>{'key': 'cache/list.json'}),
        <String, Object?>{'exists': true},
      );
      expect(
        await call(SandboxHostMethods.storeKeys, null),
        <String, Object?>{
          'keys': <String>['cache/list.json'],
        },
      );
      expect(
        await call(SandboxHostMethods.storeRemove, <String, Object?>{'key': 'cache/list.json'}),
        <String, Object?>{'removed': true},
      );
      expect(
        await call(SandboxHostMethods.storeRead, <String, Object?>{'key': 'cache/list.json'}),
        <String, Object?>{'value': null},
      );
    });

    test('读不到就是 null，不抛异常', () async {
      expect(
        await call(SandboxHostMethods.storeRead, <String, Object?>{'key': 'nope'}),
        <String, Object?>{'value': null},
      );
    });

    test('非法入参给出可读拒绝', () async {
      await expectLater(
        call(SandboxHostMethods.storeRead, 'not-a-map'),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('入参必须是对象'),
          ),
        ),
      );
      await expectLater(
        call(SandboxHostMethods.storeRead, <String, Object?>{'key': '  '}),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('缺少 key'),
          ),
        ),
      );
      await expectLater(
        call(SandboxHostMethods.storeWrite, <String, Object?>{
          'key': 'a',
          'value': 42,
        }),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('必须是字符串'),
          ),
        ),
      );
    });

    test('未授权的方法一律拒绝', () async {
      await expectLater(
        call('fs.unlink', <String, Object?>{'key': 'a'}),
        throwsA(
          isA<SandboxHostException>().having(
            (error) => error.message,
            'message',
            contains('未授权的宿主方法'),
          ),
        ),
      );
    });

    test('dispose 清空存储（随引擎释放）', () async {
      await call(SandboxHostMethods.storeWrite, <String, Object?>{
        'key': 'a',
        'value': '1',
      });
      expect(host.store.entryCount, 1);
      host.dispose();
      expect(host.store.entryCount, 0);
    });
  });
}
