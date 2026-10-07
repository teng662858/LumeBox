import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/waf.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 内置网页视图的**识别与会话**两半（用户要求的那套 Cloudflare 流程）。
///
/// WebView 本身是平台视图，跑不进 `flutter test`；这里守它两边最要紧的性质：
///   1. 只对**明确的 WAF 指纹**启用（普通 403 不许把用户引去网页视图）；
///   2. 会话按**图源**分开存、同名覆盖、可合并进请求头（cf_clearance 那枚必须带上）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_waf');
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
    WafSessions.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('识别：只认明确的 WAF 指纹', () {
    test('Cloudflare 挑战页的响应头 / 页面特征都算', () {
      expect(
        WafDetector.isChallenge(
          statusCode: 403,
          headers: const <String, String>{'cf-mitigated': 'challenge'},
        ),
        isTrue,
      );
      expect(
        WafDetector.isChallenge(
          statusCode: 503,
          body: '<html><title>Just a moment...</title>',
        ),
        isTrue,
      );
      expect(
        WafDetector.isChallenge(
          statusCode: 403,
          body: '<script src="/cdn-cgi/challenge-platform/x"></script>',
        ),
        isTrue,
      );
    });

    test('普通 403 / 防盗链不算（不许把用户引去网页视图）', () {
      expect(
        WafDetector.isChallenge(
          statusCode: 403,
          headers: const <String, String>{'server': 'nginx'},
          body: '<html>Forbidden</html>',
        ),
        isFalse,
        reason: '403 也可能是防盗链或权限问题，判据必须是 WAF 指纹而不是状态码',
      );
      expect(WafDetector.isChallenge(statusCode: 404, body: 'not found'), isFalse);
      expect(WafDetector.isChallenge(statusCode: 200, body: 'ok'), isFalse);
    });

    test('脚本抛出的失败文案也能认出来（页面据此显示【网页视图】）', () {
      expect(looksLikeWafFailure('拉取失败：HTTP 403 just a moment'), isTrue);
      expect(looksLikeWafFailure('安全验证 security check'), isTrue);
      expect(looksLikeWafFailure('拉取失败：HTTP 404'), isFalse);
      expect(looksLikeWafFailure(null), isFalse);
    });
  });

  group('会话：按图源存、同名覆盖、可合并进请求头', () {
    test('保存后能读回；同名覆盖、新的追加', () {
      final store = WafSessions.storeOf(Section.comic)!;
      store.save('92mh', <String, String>{
        'cf_clearance': 'old',
        'other': '1',
      });
      expect(store.cookieHeader('92mh'), 'cf_clearance=old; other=1');

      store.save('92mh', <String, String>{'cf_clearance': 'new'});
      final header = store.cookieHeader('92mh')!;
      expect(header, contains('cf_clearance=new'));
      expect(header, isNot(contains('old')), reason: '刷新过的凭证要盖掉旧的');
      expect(header, contains('other=1'), reason: '没提到的保留');
      expect(store.countOf('92mh'), 2);
    });

    test('按图源隔离：另一个源看不到它的会话', () {
      final store = WafSessions.storeOf(Section.comic)!;
      store.save('a-source', <String, String>{'cf_clearance': 'a'});
      expect(store.cookieHeader('b-source'), isNull);
    });

    test('合并进请求头：脚本自带 > 会话 > 图源配置（去重）', () {
      final merged = mergeCookieHeader(
        existing: 'foo=1',
        wafCookies: 'cf_clearance=abc; foo=2',
      );
      expect(merged, contains('cf_clearance=abc'));
      expect(merged, contains('foo=2'), reason: '会话是最新过校验的那一份，优先');
      expect(merged, isNot(contains('foo=1')));

      expect(mergeCookieHeader(existing: null, wafCookies: 'a=1'), 'a=1');
      expect(mergeCookieHeader(existing: 'a=1', wafCookies: null), 'a=1');
      expect(mergeCookieHeader(existing: null, wafCookies: null), isNull);
    });

    test('库没打开时如实返回「没有会话」（不会顺手开库）', () {
      WafSessions.resetForTesting();
      ReadingLibrary.close(Section.comic);
      expect(
        WafSessions.storeOf(Section.comic),
        isNull,
        reason: '库没打开就没有会话可读——不顺手把库打开',
      );
      expect(WafSessions.cookiesFor(Section.comic, '92mh'), isNull);
    });
  });
}
