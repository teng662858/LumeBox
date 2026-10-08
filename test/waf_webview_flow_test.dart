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
