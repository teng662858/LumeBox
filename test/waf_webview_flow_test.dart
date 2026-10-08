import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/source_request_log.dart';
import 'package:lume_box/core/net/waf.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/source/waf_webview_page.dart';

/// 手动「网页视图」的统一流程（[runWafWebViewFlow]）。
///
/// 真机反馈过三轮「点了没反应」，因此这个文件钉的是**出口的完备性**：
/// 地址一定有着落（四层兜底 → 最后问用户要一次）、点了一定有反应（开窗失败也
/// 弹窗说明）、只有真拿到 Cookie 才算过。
void main() {
  setUp(SourceRequestLog.resetForTesting);
  tearDown(SourceRequestLog.resetForTesting);

  /// 把流程跑在一个最小的宿主界面里（流程依赖真实的 Navigator / Dialog）。
  ///
  /// 返回未完成的 Future：测试在把对话框交互完之后再 await 它，确认结局。
  Future<Future<T>> start<T>(
    WidgetTester tester,
    Future<T> Function(BuildContext context) body,
  ) async {
    late Future<T> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => pending = body(context),
                child: const Text('run'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('run'));
    await tester.pump();
    return pending;
  }

  testWidgets('地址兜底命中：窗口直接开在该源最近请求过的地址上', (tester) async {
    SourceRequestLog.record('92mh_comic', 'https://www.92mh.com/list/1/1.html');
    final opened = <String>[];

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.comic,
        sourceId: '92mh_comic',
        sourceName: '92漫画',
        // 老脚本的标记文案：没有 URL（粘贴导入的源也没有订阅地址）。
        failureMessage: 'NEED_WEBVIEW_VERIFY：92漫画 需要网页视图过一次 Cloudflare 校验（HTTP 403）',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async {
          opened.add(url);
          return <String, String>{'cf_clearance': 'x'};
        },
      ),
    );

    expect(await pending, WafWebViewOutcome.collected);
    expect(
      opened,
      <String>['https://www.92mh.com/list/1/1.html'],
      reason: '要打开**被拦的那条地址**（挑战按路径下发）',
    );
  });

  testWidgets('验证窗用与 API 同一个 UA（cf_clearance 绑 IP + UA）', (tester) async {
    SourceRequestLog.record('s', 'https://guarded.example.com/list');
    String? openedWith;

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.comic,
        sourceId: 's',
        sourceName: '带防护的源',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async {
          openedWith = userAgent;
          return <String, String>{'cf_clearance': 'x'};
        },
        // 解析器注入：真机走 LumeSources（图源覆盖 → 全局 → 内置默认）。
        userAgentFor: (_, _) async => 'Safari-UA/17.0',
      ),
    );

    expect(await pending, WafWebViewOutcome.collected);
    expect(
      openedWith,
      'Safari-UA/17.0',
      reason: '网页视图必须用 App 请求侧那一个 UA：'
          'WKWebView 默认 UA 不带 Safari 段，CF 会给一张没有勾选框的白页',
    );
  });

  testWidgets('地址全落空：弹地址输入框，填了就能开', (tester) async {
    final opened = <String>[];

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.comic,
        sourceId: 'mystery',
        sourceName: '谜之源',
        failureMessage: 'NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP 403）',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async {
          opened.add(url);
          return <String, String>{'cf_clearance': 'x'};
        },
      ),
    );

    expect(find.text('打开'), findsOneWidget, reason: '四层都落空时必须问用户要一次地址');
    await tester.enterText(find.byType(TextField), 'www.example.com/list/1.html');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(await pending, WafWebViewOutcome.collected);
    expect(
      opened,
      <String>['https://www.example.com'],
      reason: '带路径的地址要规整到 origin',
    );
  });

  testWidgets('输入看不懂：留在对话框里给提示，取消才算没开', (tester) async {
    final opened = <String>[];

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.comic,
        sourceId: 'mystery',
        sourceName: '谜之源',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async {
          opened.add(url);
          return <String, String>{'cf_clearance': 'x'};
        },
      ),
    );

    await tester.enterText(find.byType(TextField), '随便写点什么');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('像这样填：www.example.com'), findsOneWidget);
    expect(opened, isEmpty, reason: '看不懂的输入不该真的去开窗');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await pending, WafWebViewOutcome.notOpened);
  });

  testWidgets('开窗抛异常：弹窗说明，绝不让点击静默失败', (tester) async {
    SourceRequestLog.record('s', 'https://broken.example.com/api');

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.video,
        sourceId: 's',
        sourceName: '坏源',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async =>
            throw StateError('WebView 插件未就绪'),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('验证窗口打不开'), findsOneWidget);
    expect(find.textContaining('WebView 插件未就绪'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(await pending, WafWebViewOutcome.notOpened);
  });

  testWidgets('窗口开了但没取到会话：如实区分，不冒充成功', (tester) async {
    SourceRequestLog.record('s', 'https://slow.example.com/api');

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.video,
        sourceId: 's',
        sourceName: '慢源',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async =>
            const <String, String>{},
      ),
    );

    expect(await pending, WafWebViewOutcome.emptySession);
  });

  testWidgets('手动【网页视图】不要求武装：点了就开（自动路径的许可与它无关）', (tester) async {
    SourceRequestLog.record('manual-source', 'https://guarded.example.com/list');
    final opened = <String>[];

    final pending = await start<WafWebViewOutcome>(
      tester,
      (context) => runWafWebViewFlow(
        context: context,
        section: Section.comic,
        sourceId: 'manual-source',
        sourceName: '带防护的源',
        failureMessage: 'NEED_WEBVIEW_VERIFY（HTTP 403）',
        opener: ({
          required context,
          required url,
          required sourceName,
          section,
          sourceId,
          userAgent,
        }) async {
          opened.add(url);
          return <String, String>{'cf_clearance': 'x'};
        },
      ),
    );

    expect(await pending, WafWebViewOutcome.collected);
    expect(
      opened,
      <String>['https://guarded.example.com/list'],
      reason: '手动出口的语义一条都没变：点了就开、取到会话就报 collected',
    );
  });

  group('网页视图 UA：必须与设备自己的 Safari 一致', () {
    test('WKWebView 默认 UA → 补 Version/Safari 两段，其余原样', () {
      const webView = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
      expect(
        safariUserAgentFrom(webView),
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
        'Mobile/15E148 Safari/604.1',
        reason: 'iOS 版本必须来自这台设备的 UA——写死 17.0 会被 CF 识别成内置控件，'
            '挑战页勾选框一闪就被强制跳走（真机反馈）',
      );
    });

    test('已经是 Safari UA 的不动它', () {
      const safari = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 '
          'Mobile/15E148 Safari/604.1';
      expect(safariUserAgentFrom(safari), safari);
    });

    test('套了 Version 但缺 Safari 的补齐；解析不出系统版本也给通用值', () {
      const partial = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148';
      expect(safariUserAgentFrom(partial), endsWith('Safari/604.1'));
      expect(
        safariUserAgentFrom('SomeWeirdAgent/1.0'),
        'SomeWeirdAgent/1.0 Version/17.0 Mobile/15E148 Safari/604.1',
      );
      expect(safariUserAgentFrom(''), '');
    });
  });

  group('自动验证窗的几个判定（纯函数：WebView 跑不进 flutter test，见 waf_webview_test.dart）', () {
    group('UA：一定给出一个 Safari 形态的（B3：静默失败会白屏）', () {
      test('用户显式配过：照用（cf_clearance 绑 IP + UA，用户的选择优先）', () {
        expect(
          resolveWebViewUserAgent(
            configured: 'MyClient/1.0',
            webViewDefault: 'whatever',
          ),
          'MyClient/1.0',
        );
      });

      test('读得到设备默认 UA：补成与本机 Safari 一致', () {
        const device = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
        final ua = resolveWebViewUserAgent(webViewDefault: device);
        expect(ua, contains('Safari/'));
        expect(ua, contains('Version/18.5'));
      });

      test('读不到（通道抛错 / 返回空）：用内置兜底，绝不留空', () {
        expect(resolveWebViewUserAgent(webViewDefault: ''), wafFallbackUserAgent);
        expect(resolveWebViewUserAgent(webViewDefault: null), wafFallbackUserAgent);
        expect(
          resolveWebViewUserAgent(configured: '   ', webViewDefault: '  '),
          wafFallbackUserAgent,
          reason: '返回空串 = 不放 UA = WKWebView 默认那份（没有 Safari/ 段），CF 给一张没有勾选框的页',
        );
        expect(wafFallbackUserAgent, contains('Safari/'));
        expect(wafFallbackUserAgent, contains('Version/'));
      });

      test('页面实际 UA 不含 Safari/：要求换兜底 UA 重开一次', () {
        expect(
          webViewUserAgentNeedsRepair(liveUserAgent: 'MyApp/1.0 (iPhone)'),
          isTrue,
        );
        expect(
          webViewUserAgentNeedsRepair(
            liveUserAgent: resolveWebViewUserAgent(webViewDefault: 'x'),
          ),
          isFalse,
        );
        expect(
          webViewUserAgentNeedsRepair(liveUserAgent: ''),
          isFalse,
          reason: '读不到 UA 不算「没生效」，没证据就不折腾',
        );
        expect(
          webViewUserAgentNeedsRepair(
            liveUserAgent: 'MyApp/1.0',
            override: 'MyApp/1.0',
          ),
          isFalse,
          reason: '用户自己配的 UA 不插手（不少图源配的就是 App 自己的 UA）',
        );
      });
    });

    group('放行判定：只有 cf_clearance 算（B2：__cf_bm 在挑战之前就有）', () {
      test('cf_clearance 到了：放行（见过挑战页也算）', () {
        expect(
          cookieJarLooksPassed('cf_clearance=abc; other=1', challengeSeen: true),
          isTrue,
        );
        expect(
          cookieJarLooksPassed('cf_clearance=abc', challengeSeen: false),
          isTrue,
        );
      });

      test('只有 __cf_bm 且这一页见过挑战：**不算**放行', () {
        expect(
          cookieJarLooksPassed('__cf_bm=xyz', challengeSeen: true),
          isFalse,
          reason: '__cf_bm 在挑战前就写下了：拿它当放行，自动小窗会在开出来 '
              '1~2 秒后就自己关掉——用户看到的正是「窗口一闪，勾选框还没出现就没了」',
        );
      });

      test('只有 __cf_bm 且从没见过挑战页：算放行（无感校验那条路）', () {
        expect(
          cookieJarLooksPassed('__cf_bm=xyz', challengeSeen: false),
          isTrue,
        );
      });

      test('别的 Cookie / 空串 / 只有名字没有值：都不算', () {
        expect(cookieJarLooksPassed('foo=1', challengeSeen: false), isFalse);
        expect(cookieJarLooksPassed('', challengeSeen: false), isFalse);
        expect(cookieJarLooksPassed('cf_clearance=', challengeSeen: true), isFalse);
      });

      test('document.cookie 被包成 JSON 字符串的那份也认', () {
        expect(
          cookieJarLooksPassed('"cf_clearance=abc; __cf_bm=x"', challengeSeen: true),
          isTrue,
        );
      });
    });

    group('parseJsCookie：裸串 / JSON 串都认', () {
      test('裸串', () {
        expect(
          parseJsCookie('a=1; b=2'),
          <String, String>{'a': '1', 'b': '2'},
        );
      });

      test('JSON 包着的串（runJavaScriptReturningResult 的口径）', () {
        expect(
          parseJsCookie('"a=1; b=2"'),
          <String, String>{'a': '1', 'b': '2'},
        );
      });

      test('转义过的 JSON 串', () {
        expect(
          parseJsCookie(r'"cf_clearance=abc; __cf_bm=x"'),
          <String, String>{'cf_clearance': 'abc', '__cf_bm': 'x'},
        );
      });

      test('空串 / 没有等号的片段：跳过，不抛', () {
        expect(parseJsCookie(''), isEmpty);
        expect(parseJsCookie('  '), isEmpty);
        expect(parseJsCookie('nonsense'), isEmpty);
      });
    });

    group('挑战页探针：读得懂、且「要不要重开」有据可依（B1）', () {
      test('探针 JSON 解析成正文字段', () {
        final probe = WafPageProbe.parse(
          '"{\\"t\\":\\"Just a moment...\\",\\"n\\":\\"\\",\\"f\\":2,\\"c\\":true}"',
        );
        expect(probe.title, 'Just a moment...');
        expect(probe.blank, isTrue);
        expect(probe.iframeCount, 2);
        expect(probe.challenge, isTrue);
      });

      test('解析不出来（null / 垃圾）：空探针，什么都不做', () {
        for (final raw in <String?>[null, '', 'garbage', '[]']) {
          final probe = WafPageProbe.parse(raw);
          expect(probe.challenge, isFalse);
          expect(probe.iframeCount, 0);
          expect(probe.bodyText, '');
        }
      });

      test('稳定空白 + 刚才确实是挑战页 + 没有挑战痕迹 → 允许重开', () {
        expect(
          shouldRestoreChallengePage(
            probe: const WafPageProbe(title: '', bodyText: '', iframeCount: 0),
            challengeSeen: true,
            userTouched: false,
            restores: 0,
          ),
          isTrue,
        );
      });

      test('页面上**现在**还有挑战痕迹 → 绝不重开（重开会掐掉挑战脚本与 iframe）', () {
        expect(
          shouldRestoreChallengePage(
            probe: const WafPageProbe(bodyText: '', challenge: true),
            challengeSeen: true,
            userTouched: false,
            restores: 0,
          ),
          isFalse,
          reason: '正文空只是**一次采样**：挑战控件是 JS 后画的，这时重开会把还在路上'
              '的 challenge-platform 脚本和 Turnstile 的 iframe 一起取消掉——'
              '勾选框从此再也画不出来（真机反馈的根因）',
        );
      });

      test('页面里还有 iframe → 绝不重开', () {
        expect(
          shouldRestoreChallengePage(
            probe: const WafPageProbe(bodyText: '', iframeCount: 1),
            challengeSeen: true,
            userTouched: false,
            restores: 0,
          ),
          isFalse,
        );
      });

      test('从没见过挑战痕迹 / 用户已经碰过页面 / 重开次数用完 → 都不重开', () {
        const blankProbe = WafPageProbe(bodyText: '');
        expect(
          shouldRestoreChallengePage(
            probe: blankProbe,
            challengeSeen: false,
            userTouched: false,
            restores: 0,
          ),
          isFalse,
        );
        expect(
          shouldRestoreChallengePage(
            probe: blankProbe,
            challengeSeen: true,
            userTouched: true,
            restores: 0,
          ),
          isFalse,
          reason: '用户多半正在点勾选框：重开会把他做到一半的操作扔掉',
        );
        expect(
          shouldRestoreChallengePage(
            probe: blankProbe,
            challengeSeen: true,
            userTouched: false,
            restores: maxChallengeRestores,
          ),
          isFalse,
        );
      });

      test('正文有内容（页面看着正常）→ 不重开', () {
        expect(
          shouldRestoreChallengePage(
            probe: const WafPageProbe(bodyText: '内容'),
            challengeSeen: true,
            userTouched: false,
            restores: 0,
          ),
          isFalse,
        );
      });
    });

    group('失败卡不许盖在挑战页上（B4：白卡看起来就像「没有勾选框」）', () {
      test('有错误且没见过挑战页：压卡（给可读原因 + 出口）', () {
        expect(
          shouldCoverWebViewWithError(
            error: '连接被拒',
            challengeSeen: false,
          ),
          isTrue,
        );
      });

      test('见过挑战页 / 没有错误：都不压卡', () {
        expect(
          shouldCoverWebViewWithError(
            error: '连接被拒',
            challengeSeen: true,
          ),
          isFalse,
          reason: '那一下失败多半就是挑战页自己引起的（403/503 + 取消导航），'
              '盖上白卡等于把勾选框藏起来',
        );
        expect(
          shouldCoverWebViewWithError(error: null, challengeSeen: false),
          isFalse,
        );
        expect(
          shouldCoverWebViewWithError(error: '  ', challengeSeen: false),
          isFalse,
        );
      });
    });
  });

  group('地址工具', () {
    test('guessWebViewAddress：订阅地址优先，其次是源 id 里的域名', () {
      expect(
        guessWebViewAddress(sourceId: 'x', originUrl: 'https://a.example.com/x/y'),
        'https://a.example.com',
      );
      expect(
        guessWebViewAddress(sourceId: 'www.92mh.com_备份', originUrl: ''),
        'https://www.92mh.com',
      );
      expect(guessWebViewAddress(sourceId: 'no-host', originUrl: ''), '');
    });

    test('normalizeWebViewAddress：补协议、剥路径，看不懂返回 null', () {
      expect(normalizeWebViewAddress('www.example.com'), 'https://www.example.com');
      expect(
        normalizeWebViewAddress('http://example.com/a/b?c=1'),
        'http://example.com',
      );
      expect(
        normalizeWebViewAddress('https://www.92mh.com/list/1/1.html'),
        'https://www.92mh.com',
      );
      expect(normalizeWebViewAddress('  '), isNull);
      expect(normalizeWebViewAddress('随便写点什么'), isNull);
    });

    test('webViewTargetHint：卡片上要看得出来源站地址拿到了', () {
      SourceRequestLog.record('s', 'https://www.92mh.com/');
      expect(
        webViewTargetHint(
          failureMessage: 'NEED_WEBVIEW_VERIFY（HTTP 403）',
          sourceId: 's',
        ),
        '网页视图将打开：https://www.92mh.com/',
      );
      expect(webViewTargetHint(sourceId: 'mystery'), isNull);
    });
  });
}
