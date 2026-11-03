import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/ats_fallback.dart';
import 'package:lume_box/core/net/ios_image_network.dart';
import 'package:lume_box/core/net/network_queue.dart';

/// 真机现象（直播盒子 / 火力视频）：整站只有明文 http 的源在 iPhone 上一律
/// 「首页加载失败」，错误是 `NSURLErrorDomain -1022 / transport_security`。
/// 原因不是站挂了，而是 URLSession 被 ATS 拦在出门之前。
///
/// 修法：认准这个失败码，换 `dart:io` 通道重发同一请求（它不经过 ATS）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有 HttpClient 换成「一律 400」的替身；这里要真连本机端口。
  setUpAll(() => HttpOverrides.global = null);

  late HttpServer server;
  late Uri base;
  var hits = 0;

  setUp(() async {
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      hits++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"pingtai":[{"title":"kawaii","address":"x.txt"}]}');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  NetworkRequest requestFor(String path) => NetworkRequest(
    url: '$base$path',
    headers: const {'User-Agent': 'lume-test'},
    source: 'test',
    retryOn: false,
    timeout: const Duration(seconds: 10),
  );

  test('ATS 拒绝之后用 dart:io 通道拿回同一个响应', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosImageNetwork.channel, (call) async {
      throw PlatformException(
        code: 'transport_security',
        message: 'iOS blocked this plain HTTP request',
        details: {'domain': 'kCFErrorDomainCFNetwork', 'code': -1022},
      );
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosImageNetwork.channel, null),
    );

    final response = await IosImageNetwork.send(requestFor('/mf/json.txt'));

    expect(hits, 1, reason: '兜底通道只发一次，不重复打站点');
    expect(response.statusCode, 200);
    expect(String.fromCharCodes(response.body), contains('kawaii'));
  });

  test('其余系统失败保持原样抛出（不掩盖真错误）', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosImageNetwork.channel, (call) async {
      throw PlatformException(code: 'network', message: 'system network failed');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosImageNetwork.channel, null),
    );

    await expectLater(
      IosImageNetwork.send(requestFor('/mf/json.txt')),
      throwsA(isA<PlatformException>()),
    );
    expect(hits, 0, reason: '普通网络失败不走明文兜底');
  });

  test('兜底通道自己也能发 POST 体（接口类源要用）', () async {
    final response = await sendWithoutAts(
      NetworkRequest(
        url: '$base/api/list',
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        body: '{"page":1}',
        source: 'test',
        retryOn: false,
      ),
    );
    expect(response.statusCode, 200);
  });
}
