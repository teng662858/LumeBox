import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/source_request_log.dart';
import 'package:lume_box/core/net/waf.dart';
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
      expect(askedUrl, 'https://guarded.example.com',
          reason: '校验地址从失败文本里捞出来，统一收口到 origin'
              '（cf_clearance 是整域的，开首页就够；与手动出口同一套解析）');
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

    test('老脚本（标记文案里没有 URL）：自动校验也要拿得到站址', () async {
      // 真机那份 92 漫画脚本就是这么写的：抛标记但不带地址。
      final runtime = _StaleMarkedRuntime();
      final source = JsDataSource(
        id: 'mh92_comic',
        name: '92漫画',
        section: Section.comic,
        runtime: runtime,
      );
      // 报 WAF 错之前一定发过请求：网络层记下的地址就是自动校验窗的地址来源。
      SourceRequestLog.record('mh92_comic', 'https://www.92mh.com/list/1/1.html');

      String? askedUrl;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        askedUrl = url;
        return false;
      });

      await expectLater(source.categories(), throwsA(isA<SourceException>()));
      expect(
        askedUrl,
        'https://www.92mh.com',
        reason: '自动弹窗不能因为文案里没有 URL 就静默不动',
      );
    });
  });

/// 「网页视图」按钮的地址解析（真机反馈两轮「点了没反应」）。
///
/// 场景就是 92 漫画：脚本是**粘贴导入**的（没有订阅地址）、老脚本的报错文案里
/// 也**没有 URL**。以前这种组合解析不出地址 → 按钮点了静默退出。
/// 现在必须能从「该源最近请求过的地址」兜底拿到 origin。
void webViewOriginTests() {
  setUp(SourceRequestLog.resetForTesting);
  tearDown(SourceRequestLog.resetForTesting);

  test('老脚本 + 粘贴导入：用最近请求过的地址兜底（92漫画那种）', () {
    // 报错文案里没有任何 URL（老脚本就是这么写的）。
    const message = 'NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP 403）';
    // 但报 WAF 错之前一定发过请求，网络层记下了地址。
    SourceRequestLog.record('mh92_comic', 'https://www.92mh.com/list/1/1.html');
    final url = resolveWebViewOrigin(
      failureMessage: message,
      sourceId: 'mh92_comic',
      originUrl: '', // 粘贴导入：没有订阅地址
    );
    expect(url, 'https://www.92mh.com', reason: '必须拿得到源站 origin 才能弹窗');
  });

  test('文案里带 URL 时优先用它（新脚本）', () {
    final url = resolveWebViewOrigin(
      failureMessage: 'NEED_WEBVIEW_VERIFY（HTTP 403 https://a.example.com/api/x）',
      sourceId: 'x',
      originUrl: '',
    );
    expect(url, 'https://a.example.com');
  });

  test('订阅地址与源 id 里的域名也能兜底', () {
    expect(
      resolveWebViewOrigin(
        failureMessage: 'NEED_WEBVIEW_VERIFY',
        sourceId: 'x',
        originUrl: 'https://sub.example.com/feed.json',
      ),
      'https://sub.example.com',
    );
    expect(
      resolveWebViewOrigin(
        failureMessage: 'NEED_WEBVIEW_VERIFY',
        sourceId: 'www.92mh.com_备用',
      ),
      'https://www.92mh.com',
    );
  });

  test('真的都没有才返回 null（调用方给提示，不再静默退出）', () {
    expect(
      resolveWebViewOrigin(failureMessage: 'NEED_WEBVIEW_VERIFY', sourceId: ''),
      isNull,
    );
  });

  test('非 http 的地址不进记录（本地路径对验证窗没意义）', () {
    SourceRequestLog.record('s', 'file:///tmp/a.html');
    expect(SourceRequestLog.lastFor('s'), isNull);
  });
}

  group('网页视图地址解析（点了没反应那条）', webViewOriginTests);
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

/// 老脚本那种抛法：**标记里不带任何 URL**（真机那份 92 漫画脚本的原文）。
class _StaleMarkedRuntime implements JsSourceRuntime {
  int calls = 0;

  @override
  Future<Set<String>> contractMethods() async => const <String>{'categories'};

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    calls++;
    throw const SourceException(
      SourceErrorKind.callFailed,
      'NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP 403）',
    );
  }
}
