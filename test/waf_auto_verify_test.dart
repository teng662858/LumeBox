import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/source_request_log.dart';
import 'package:lume_box/core/net/waf.dart';
import 'package:lume_box/core/net/waf_auto_verify.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';

import 'support/fake_source_manager.dart';

/// 自动过 WAF 校验（用户口径 2 / 3）：
/// - 脚本抛 `NEED_WEBVIEW_VERIFY` → 引擎层回调界面层弹小窗 → 拿到会话后**自动重试**
///   同一次调用（后续的详情 / 章节 / 播放地址就都能正常读）；
/// - **弹窗必须先有用户许可**（[WafAutoVerify.arm]，页面上「点了【重试】」的那一次）：
///   被动加载（切图源 / 切页签 / 预热 / 首页分类筛选页自己拉的第一次）一律不弹
///   ——这正是本次要修的那条真机反馈（刚切完图源，CF 验证小窗自己蹦出来）；
/// - 同一个源的并发失败**共用同一次校验**（不然会同时弹好几个窗口）；
/// - 没装钩子（纯单元测试 / 非界面环境）时行为与以前完全一致：原样失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('验证窗只在用户显式发起的那一次尝试后打开', () {
    test('被动加载（没 arm）：一次都不弹，调用方照旧拿到失败', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      // 切图源 / 切页签 / 预热：都是被动加载，没有 arm。
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: '92mh',
          sourceName: '92漫画',
          url: 'https://www.92mh.com/list/1/1.html',
        ),
        isFalse,
        reason: '用户没按过任何按钮：验证窗自己蹦出来就是他抱怨的那个 bug',
      );
      expect(calls, 0);
    });

    test('arm 之后：弹**一次**就把许可消费掉（要再弹必须重新 arm）', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.arm(section: Section.comic, sourceId: '92mh');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: '92mh',
          sourceName: '92漫画',
          url: 'https://www.92mh.com/list/1/1.html',
        ),
        isTrue,
      );
      expect(calls, 1, reason: '用户点了一次【重试】：弹一次');

      // 同一次尝试里后面的调用也带着标记：许可已经用掉了，不再弹第二个窗。
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: '92mh',
          sourceName: '92漫画',
          url: 'https://www.92mh.com/list/1/2.html',
        ),
        isFalse,
      );
      expect(calls, 1, reason: '许可是一次性的：一次尝试最多弹一个窗');

      // 用户再点一次【重试】→ 页面重新 arm → 允许再弹。
      WafAutoVerify.arm(section: Section.comic, sourceId: '92mh');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: '92mh',
          sourceName: '92漫画',
          url: 'https://www.92mh.com/list/1/3.html',
        ),
        isTrue,
      );
      expect(calls, 2);
    });

    test('许可只认「板块 + 源」这一个键，别的源不沾光', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.arm(section: Section.comic, sourceId: 'a');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 'b',
          sourceName: '乙源',
          url: 'https://b.example.com/',
        ),
        isFalse,
      );
      expect(calls, 0, reason: '用户点的是甲源的重试，不该把乙源的窗也弹出来');
    });

    test('许可过期后不再弹（用户那次尝试早已结束，别把它留给下一次被动加载）', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(WafAutoVerify.armIsFresh(now, now), isTrue);
      expect(
        WafAutoVerify.armIsFresh(
          now.subtract(WafAutoVerify.armTtl - const Duration(seconds: 1)),
          now,
        ),
        isTrue,
      );
      expect(
        WafAutoVerify.armIsFresh(
          now.subtract(WafAutoVerify.armTtl + const Duration(seconds: 1)),
          now,
        ),
        isFalse,
      );
    });

    test('disarm 撤回许可：用户那次尝试成功收尾后，后面的被动加载不弹', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.arm(section: Section.video, sourceId: 's');
      WafAutoVerify.disarm(section: Section.video, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.video,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/x',
        ),
        isFalse,
      );
      expect(calls, 0, reason: '收尾后撤回过许可，下一次被动加载不该把它捡起来用');
    });

    test('用户显式发起的那一次没拿到会话：压一段冷却，反复点【重试】不再弹', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        // 窗口开了，但用户直接点空白关掉 / 过完还是没 Cookie。
        return false;
      });

      WafAutoVerify.arm(section: Section.video, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.video,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/x',
        ),
        isFalse,
      );
      expect(calls, 1);

      // 用户又点了一次【重试】（页面会重新 arm）：冷却期内不再弹第二个窗。
      WafAutoVerify.arm(section: Section.video, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.video,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/x',
        ),
        isFalse,
      );
      expect(calls, 1, reason: '刚关掉的窗马上又弹一个一模一样的，用户只会觉得「关不掉」');

      // 冷却的纯函数口径：90 秒之内算冷却中，过后放行。
      final now = DateTime(2026, 1, 1, 12);
      expect(WafAutoVerify.cooldownActive(now, now), isTrue);
      expect(
        WafAutoVerify.cooldownActive(
          now.subtract(WafAutoVerify.cooldown + const Duration(seconds: 1)),
          now,
        ),
        isFalse,
      );
    });
  });

  group('已有会话：重试会带上它，不再弹窗', () {
    late Directory root;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('lume_box_waf_auto');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? root.path
            : null,
      );
      WafSessions.resetForTesting();
      await SectionScope.open(Section.comic);
      await ReadingLibrary.open(Section.comic);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      WafSessions.resetForTesting();
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('该源已经存过会话：arm 了也不弹（重试自己就会带上那份 Cookie）', () async {
      WafSessions.storeOf(Section.comic)!
          .save('92mh', <String, String>{'cf_clearance': 'x'});

      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.arm(section: Section.comic, sourceId: '92mh');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: '92mh',
          sourceName: '92漫画',
          url: 'https://www.92mh.com/list/1/1.html',
        ),
        isFalse,
        reason: '宿主网络层每次请求现取会话（source_registry 的 sessionCookies）：'
            '重试已经带上了 cf_clearance，再弹一个窗只是打扰',
      );
      expect(calls, 0);
    });

    test('对照组：没存过会话的源，同样的 arm 会弹', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.arm(section: Section.comic, sourceId: 'fresh');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 'fresh',
          sourceName: '新源',
          url: 'https://fresh.example.com/list',
        ),
        isTrue,
      );
      expect(calls, 1);
    });
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

    // 用户点了一次【重试】，这一次尝试里有两个并发调用同时被拦下。
    WafAutoVerify.arm(section: Section.video, sourceId: 'a');
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

    WafAutoVerify.arm(section: Section.video, sourceId: 'a');
    expect(
      await WafAutoVerify.run(
        section: Section.video,
        sourceId: 'a',
        sourceName: '甲源',
        url: 'https://example.com/a',
      ),
      isTrue,
    );
    WafAutoVerify.arm(section: Section.video, sourceId: 'b');
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

  group('同一时刻只允许一个验证窗（真机反馈的两个窗口叠在一起）', () {
    test('手动窗开着时：自动路径不弹第二个窗', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.beginManual();
      WafAutoVerify.arm(section: Section.comic, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/list/1/',
        ),
        isFalse,
        reason: '用户正在看手动窗，背后不许再弹一个自动小窗',
      );
      expect(calls, 0);

      // 手动流程收尾（拿到了会话）：自动路径恢复正常（要重新 arm 才有许可）。
      WafAutoVerify.endManual(
        section: Section.comic,
        sourceId: 's',
        collected: true,
      );
      WafAutoVerify.arm(section: Section.comic, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/list/1/',
        ),
        isTrue,
      );
      expect(calls, 1);
    });

    test('手动关掉但没拿到会话：冷却期内自动路径不弹（页面按钮照常可用）', () async {
      var calls = 0;
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        calls++;
        return true;
      });

      WafAutoVerify.beginManual();
      // 用户直接点 ✕ 关掉、一个 Cookie 都没取到。
      WafAutoVerify.endManual(section: Section.comic, sourceId: 's');
      WafAutoVerify.arm(section: Section.comic, sourceId: 's');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 's',
          sourceName: '源',
          url: 'https://example.com/list/1/',
        ),
        isFalse,
        reason: '刚关掉就马上弹一个一模一样的小窗，用户只会觉得「关不掉」',
      );
      expect(calls, 0);

      // 别的源不受影响。
      WafAutoVerify.arm(section: Section.comic, sourceId: 'other');
      expect(
        await WafAutoVerify.run(
          section: Section.comic,
          sourceId: 'other',
          sourceName: '另一个源',
          url: 'https://example.com/list/1/',
        ),
        isTrue,
      );
      expect(calls, 1);
    });
  });

  group('引擎层接线：标记 → 自动校验 → 重试', () {
    /// 第一次调用抛 NEED_WEBVIEW_VERIFY，校验通过后再调就成功。
    test('用户点了【重试】：分类调用被拦下时自动校验并重试，成功后继续解析', () async {
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

      // 页面上点了【重试】→ _retryWithWaf 先 arm 再重放。
      WafAutoVerify.arm(section: Section.video, sourceId: 'waf-source');
      final categories = await source.categories();
      expect(verifications, 1, reason: '被拦下要自动过一次校验');
      expect(askedUrl, 'https://guarded.example.com/api/x',
          reason: '校验地址用**被拦的那一条**（不是域名）：CF 的挑战按路径下发，'
              '很多站点首页早就被放行——开首页根本不会出勾选框（真机反馈）');
      expect(categories.length, 1);
      expect(runtime.calls, 2, reason: '校验通过后要重试同一次调用');
    });

    test('被动加载（切图源 / 预热）被拦下：不弹窗，错误原样抛给页面', () async {
      final runtime = _MarkedRuntime();
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

      await expectLater(
        source.categories(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('NEED_WEBVIEW_VERIFY'),
          ),
        ),
        reason: '页面照常拿到失败 → 给错误卡（【重试】+【网页视图】），这才是被动路径该有的行为',
      );
      expect(verifications, 0, reason: '没人按过按钮：绝不许自己弹窗');
      expect(runtime.calls, 1, reason: '没拿到会话，不该重试');
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

      WafAutoVerify.arm(section: Section.video, sourceId: 'waf-source');
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

      WafAutoVerify.arm(section: Section.video, sourceId: 'waf-source');
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

      WafAutoVerify.arm(section: Section.comic, sourceId: 'mh92_comic');
      await expectLater(source.categories(), throwsA(isA<SourceException>()));
      expect(
        askedUrl,
        'https://www.92mh.com/list/1/1.html',
        reason: '自动弹窗不能因为文案里没有 URL 就静默不动；'
            '并且要用网络层记下的**具体地址**（挑战按路径下发）',
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
    expect(
      url,
      'https://www.92mh.com/list/1/1.html',
      reason: '必须拿到**被拦的那条地址**才能触发挑战页（92 漫画首页是放行的，'
          '开首页看不到勾选框——真机反馈）',
    );
  });

  test('文案里带 URL 时优先用它，且**保留整条路径**（新脚本）', () {
    final url = resolveWebViewOrigin(
      failureMessage: 'NEED_WEBVIEW_VERIFY（HTTP 403 https://a.example.com/api/x）',
      sourceId: 'x',
      originUrl: '',
    );
    expect(
      url,
      'https://a.example.com/api/x',
      reason: '挑战按路径下发：裁成域名会打开一个「不需要验证」的首页',
    );
  });

  test('只有域名可用时（订阅地址 / 源 id）退回域名：聊胜于无', () {
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

  group('真机反馈那条链路：加载与【重试】都只出错误卡，验证窗只能由【网页视图】开', () {
    /// 一个「每次调用都被 WAF 拦下」的源：走**真实的** JsDataSource 接线
    /// （`_invokeOnce` 认标记 → 问自动校验 → 重试一次），只是脚本永远过不去。
    DataSource blockedSource() => JsDataSource(
          id: 'waf',
          name: '带防护的源',
          section: Section.comic,
          runtime: _AlwaysMarkedRuntime(),
        );

    Future<void> pumpExplore(WidgetTester tester, DataSource source) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: ExploreView(
              section: Section.comic,
              manager: FakeSourceManager(
                sources: const <SourceDescriptor>[
                  SourceDescriptor(
                    id: 'waf',
                    name: '带防护的源',
                    version: '1',
                    enabled: true,
                  ),
                ],
                opened: <String, DataSource>{'waf': source},
              ),
              layout: ExploreLayout.list,
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 装一个假的自动验证窗：`box[0]` 记「弹了几次」，每次都是「开完没拿到会话」。
    List<int> installWindowCounter() {
      final box = <int>[0];
      WafAutoVerify.install(({
        required section,
        required sourceId,
        required sourceName,
        required url,
      }) async {
        box[0]++;
        // 窗开了，但用户没点完就关掉（一个 Cookie 都没取到）。
        return false;
      });
      return box;
    }

    testWidgets('切图源后被动失败：只出错误卡（重试 + 网页视图），一个窗都不弹', (tester) async {
      final windows = installWindowCounter();

      await pumpExplore(tester, blockedSource());

      expect(windows[0], 0, reason: '用户没有任何动作：验证窗不许自己弹出来');
      expect(
        find.textContaining('NEED_WEBVIEW_VERIFY'),
        findsOneWidget,
        reason: '被动失败照旧给错误卡——用户看得见原因、也有下一步',
      );
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('网页视图'), findsOneWidget, reason: '手动出口照旧在');
    });

    testWidgets('点【重试】：也不弹窗（连续两轮口径），出口仍是【网页视图】', (tester) async {
      final windows = installWindowCounter();
      await pumpExplore(tester, blockedSource());

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(windows[0], 0, reason: '点【重试】不自动弹窗');
      expect(find.text('重试'), findsOneWidget, reason: '仍被拦下 → 回到错误卡');
      expect(
        find.text('网页视图'),
        findsOneWidget,
        reason: '验证窗的唯一入口是用户按【网页视图】',
      );

      // 再点几次也一个都不弹（不是「弹一次就冷却」，而是根本不弹）。
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(windows[0], 0, reason: '反复点重试也不该蹦出验证窗');
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
