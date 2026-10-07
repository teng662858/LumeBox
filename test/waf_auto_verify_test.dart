import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/waf_auto_verify.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

/// 自动过 WAF 校验（用户口径 2 / 3）：
/// - 脚本抛 `NEED_WEBVIEW_VERIFY` → 引擎层回调界面层弹小窗 → 拿到会话后**自动重试**
///   同一次调用（后续的详情 / 章节 / 播放地址就都能正常读）；
/// - 同一个源的并发失败**共用同一次校验**（不然会同时弹好几个窗口）；
/// - 没装钩子（纯单元测试 / 非界面环境）时行为与以前完全一致：原样失败。
void main() {
  tearDown(WafAutoVerify.resetForTesting);

  test('没装钩子：不冒险，直接按失败返回', () async {
    expect(WafAutoVerify.isInstalled, isFalse);
    final handled = await WafAutoVerify.run(
      section: Section.video,
      sourceId: 'a',
      sourceName: '甲源',
      url: 'https://example.com/api',
    );
    expect(handled, isFalse);
  });

  test('同一个源的并发失败共用同一次校验（只弹一个窗）', () async {
    var calls = 0;
    WafAutoVerify.install(({
      required section,
      required sourceId,
      required sourceName,
      required url,
    }) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return true;
    });

    final results = await Future.wait(<Future<bool>>[
      WafAutoVerify.run(
        section: Section.video,
        sourceId: 'a',
        sourceName: '甲源',
        url: 'https://example.com/1',
      ),
      WafAutoVerify.run(
        section: Section.video,
        sourceId: 'a',
        sourceName: '甲源',
        url: 'https://example.com/2',
      ),
    ]);
    expect(calls, 1, reason: '同一个源同时只该跑一次校验');
    expect(results, <bool>[true, true]);
  });

  test('不同源各弹各的；校验抛异常按未通过处理', () async {
    var calls = 0;
    WafAutoVerify.install(({
      required section,
      required sourceId,
      required sourceName,
      required url,
    }) async {
      calls++;
      if (sourceId == 'b') throw StateError('窗口挂了');
      return true;
    });

    expect(
      await WafAutoVerify.run(
        section: Section.video,
        sourceId: 'a',
        sourceName: '甲源',
        url: 'https://example.com/a',
      ),
      isTrue,
    );
    expect(
      await WafAutoVerify.run(
        section: Section.video,
        sourceId: 'b',
        sourceName: '乙源',
        url: 'https://example.com/b',
      ),
      isFalse,
      reason: '校验本身出错就当没过：按普通失败往上抛，不静默吞掉',
    );
    expect(calls, 2);
  });

  group('引擎层接线：标记 → 自动校验 → 重试', () {
    /// 第一次调用抛 NEED_WEBVIEW_VERIFY，校验通过后再调就成功。
    test('分类调用被拦下时自动校验并重试，成功后继续解析', () async {
      final runtime = _MarkedRuntime();
      final source = JsDataSource(
        id: 'waf-source',
        name: '带防护的源',
        section: Section.video,
        runtime: runtime,
      );

      var verifications = 0;
      String? askedUrl;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        verifications++;
        askedUrl = url;
        return true;
      });

      final categories = await source.categories();
      expect(verifications, 1, reason: '被拦下要自动过一次校验');
      expect(askedUrl, 'https://guarded.example.com/api/x',
          reason: '校验地址要从失败文本里捞出来');
      expect(categories.length, 1);
      expect(runtime.calls, 2, reason: '校验通过后要重试同一次调用');
    });

    test('校验没通过：如实抛错（界面照旧给重试 / 网页视图）', () async {
      final runtime = _MarkedRuntime();
      final source = JsDataSource(
        id: 'waf-source',
        name: '带防护的源',
        section: Section.video,
        runtime: runtime,
      );
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async =>
          false);

      await expectLater(
        source.categories(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('NEED_WEBVIEW_VERIFY'),
          ),
        ),
      );
      expect(runtime.calls, 1, reason: '没拿到会话就不该重试');
    });

    test('只重试一次：重试仍被拦下不再循环弹窗', () async {
      final runtime = _AlwaysMarkedRuntime();
      final source = JsDataSource(
        id: 'waf-source',
        name: '带防护的源',
        section: Section.video,
        runtime: runtime,
      );
      var verifications = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        verifications++;
        return true;
      });

      await expectLater(source.categories(), throwsA(isA<SourceException>()));
      expect(verifications, 1, reason: '一次调用只自动校验一次');
      expect(runtime.calls, 2, reason: '首次 + 重试各一次');
    });
  });
}

/// 第一次抛 NEED_WEBVIEW_VERIFY，之后正常返回。
class _MarkedRuntime implements JsSourceRuntime {
  int calls = 0;

  @override
  Future<Set<String>> contractMethods() async => const <String>{'categories'};

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    calls++;
    if (calls == 1) {
      throw const SourceException(
        SourceErrorKind.callFailed,
        '拉取失败：HTTP 403 https://guarded.example.com/api/x NEED_WEBVIEW_VERIFY',
      );
    }
    return <Object?>[
      <String, Object?>{'id': 'c1', 'title': '分类一'},
    ];
  }
}

/// 一直抛标记（用来验证「只重试一次」）。
class _AlwaysMarkedRuntime implements JsSourceRuntime {
  int calls = 0;

  @override
  Future<Set<String>> contractMethods() async => const <String>{'categories'};

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    calls++;
    throw const SourceException(
      SourceErrorKind.callFailed,
      'NEED_WEBVIEW_VERIFY https://guarded.example.com/api/y',
    );
  }
}
