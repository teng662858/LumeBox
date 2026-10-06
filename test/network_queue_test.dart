import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;

import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';

/// 网络队列的验证（文档第六条：防封禁与并发控制）。
///
/// 这是「多图源批量搜索不炸 IP」的核心保障，因此断言集中在行为上：
/// 同一域名的并发**绝不超过上限**、不同域名可以并行、429/503 会退避重试、
/// 其余 4xx 不重试、Retry-After 被尊重。
void main() {
  /// 可编程的假发送端：记录并发峰值，按脚本给应答。
  late _FakeSender sender;

  NetworkQueue queueWith({
    int global = 8,
    int perHost = 2,
    int maxRetries = 2,
    Duration retryBase = const Duration(milliseconds: 10),
  }) {
    sender = _FakeSender();
    return NetworkQueue(
      settings: NetworkSettings(
        globalConcurrency: global,
        perHostConcurrency: perHost,
        maxRetries: maxRetries,
        retryBaseDelay: retryBase,
      ).clamped(),
      sender: sender.send,
    );
  }

  group('并发控制', () {
    test('单域名并发不超过上限（防封核心）', () async {
      final queue = queueWith(global: 12, perHost: 2);
      sender.hold = Completer<void>();

      final futures = <Future<NetworkResponse>>[
        for (var i = 0; i < 8; i++)
          queue.send(NetworkRequest(url: 'https://same.com/$i', source: 'src')),
      ];
      // 让 8 个请求都进入排队。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        sender.peakForHost('same.com'),
        lessThanOrEqualTo(2),
        reason: '同一个域名同时最多 2 个请求',
      );

      sender.hold!.complete();
      await Future.wait(futures);
      expect(sender.count, 8);
    });

    test('不同域名可并行（受全局上限约束）', () async {
      final queue = queueWith(global: 8, perHost: 2);
      sender.hold = Completer<void>();

      final futures = <Future<NetworkResponse>>[
        for (var i = 0; i < 4; i++)
          queue.send(NetworkRequest(url: 'https://host$i.com/a')),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        sender.peakTotal,
        4,
        reason: '四个不同域名各占一个额度，应当同时开跑',
      );
      expect(sender.peakTotal, lessThanOrEqualTo(8));

      sender.hold!.complete();
      await Future.wait(futures);
    });

    test('全局并发不超过上限（跨域名也一样）', () async {
      final queue = queueWith(global: 6, perHost: 3);
      sender.hold = Completer<void>();

      final futures = <Future<NetworkResponse>>[
        for (var i = 0; i < 12; i++)
          queue.send(NetworkRequest(url: 'https://host$i.com/a')),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sender.peakTotal, lessThanOrEqualTo(6));

      sender.hold!.complete();
      await Future.wait(futures);
      expect(sender.count, 12);
    });

    test('额度随请求结束释放：串行批次不互相阻塞', () async {
      final queue = queueWith(global: 6, perHost: 2);
      // 不 hold：每个请求立即完成。
      for (var i = 0; i < 6; i++) {
        await queue.send(NetworkRequest(url: 'https://a.com/$i'));
      }
      expect(sender.count, 6);
      expect(queue.activeGlobal, 0, reason: '全部结束后额度必须归还');
      expect(queue.activeForHost('a.com'), 0);
      expect(queue.waitingCount, 0);
    });
  });

  group('退避重试', () {
    test('429 会重试，并在成功后返回 200', () async {
      final queue = queueWith(maxRetries: 2, retryBase: const Duration(milliseconds: 5));
      sender.script['https://a.com/x'] = <int>[429, 200];

      final response = await queue.send(
        NetworkRequest(url: 'https://a.com/x', source: 'src'),
      );
      expect(response.statusCode, 200);
      expect(sender.attempts['https://a.com/x'], 2);
    });

    test('503 会重试；重试用尽后如实返回最后一次状态码', () async {
      final queue = queueWith(maxRetries: 2, retryBase: const Duration(milliseconds: 5));
      sender.script['https://a.com/x'] = <int>[503, 503, 503, 200];

      final response = await queue.send(NetworkRequest(url: 'https://a.com/x'));
      expect(response.statusCode, 503, reason: '超过 maxRetries 就不再试了');
      expect(sender.attempts['https://a.com/x'], 3, reason: '首次 + 2 次重试');
    });

    test('其余 4xx 不重试（地址错了就别再打目标站）', () async {
      final queue = queueWith(maxRetries: 3);
      sender.script['https://a.com/x'] = <int>[404, 200];

      final response = await queue.send(NetworkRequest(url: 'https://a.com/x'));
      expect(response.statusCode, 404);
      expect(sender.attempts['https://a.com/x'], 1, reason: '404 不重试');
    });

    test('POST 不参与重试（避免重复提交）', () async {
      final queue = queueWith(maxRetries: 3);
      sender.script['https://a.com/x'] = <int>[503, 200];

      final response = await queue.send(
        NetworkRequest(url: 'https://a.com/x', method: 'POST', retryOn: false),
      );
      expect(response.statusCode, 503);
      expect(sender.attempts['https://a.com/x'], 1);
    });

    test('网络异常会重试，最终抛出原始异常', () async {
      final queue = queueWith(maxRetries: 2, retryBase: const Duration(milliseconds: 5));
      sender.failTimes['https://a.com/x'] = 3;

      await expectLater(
        queue.send(NetworkRequest(url: 'https://a.com/x')),
        throwsA(isA<StateError>()),
      );
      expect(sender.attempts['https://a.com/x'], 3);
    });

    test('网络异常在第 N 次成功即返回', () async {
      final queue = queueWith(maxRetries: 2, retryBase: const Duration(milliseconds: 5));
      sender.failTimes['https://a.com/x'] = 1;

      final response = await queue.send(NetworkRequest(url: 'https://a.com/x'));
      expect(response.statusCode, 200);
      expect(sender.attempts['https://a.com/x'], 2);
    });
  });

  group('Retry-After', () {
    test('服务器给的秒数被尊重（且受上限约束）', () {
      expect(
        NetworkQueue.retryAfterOf(const NetworkResponse(
          statusCode: 429,
          body: <int>[],
          headers: <String, String>{'retry-after': '2'},
        )),
        const Duration(seconds: 2),
      );
      // 超过上限即收敛到上限，不无限等。
      expect(
        NetworkQueue.retryAfterOf(const NetworkResponse(
          statusCode: 429,
          body: <int>[],
          headers: <String, String>{'retry-after': '9999'},
        )),
        NetworkQueue.maxRetryAfter,
      );
      // 没有该头就是 null（走指数退避）。
      expect(
        NetworkQueue.retryAfterOf(const NetworkResponse(
          statusCode: 429,
          body: <int>[],
          headers: <String, String>{},
        )),
        isNull,
      );
    });

    test('HTTP 日期写法也能解析', () {
      final future = DateTime.now().toUtc().add(const Duration(seconds: 3));
      final value = HttpDate.format(future);
      final parsed = NetworkQueue.retryAfterOf(NetworkResponse(
        statusCode: 503,
        body: <int>[],
        headers: <String, String>{'Retry-After': value},
      ));
      expect(parsed, isNotNull);
      expect(parsed!.inSeconds, inInclusiveRange(1, 4));
    });
  });

  group('域名解析与设置收敛', () {
    test('hostOf 取域名；解析不出时用整串当键', () {
      expect(NetworkQueue.hostOf('https://a.com/x/y'), 'a.com');
      expect(NetworkQueue.hostOf('http://a.com:8080/x'), 'a.com');
      expect(NetworkQueue.hostOf('not a url'), 'not a url');
    });

    test('并发区间被强制收敛到文档范围（6~12 / 2~3）', () {
      const tooLow = NetworkSettings(globalConcurrency: 1, perHostConcurrency: 1);
      final clampedLow = tooLow.clamped();
      expect(clampedLow.globalConcurrency, NetworkSettings.minGlobalConcurrency);
      expect(clampedLow.perHostConcurrency, NetworkSettings.minPerHostConcurrency);

      const tooHigh = NetworkSettings(globalConcurrency: 999, perHostConcurrency: 99);
      final clampedHigh = tooHigh.clamped();
      expect(clampedHigh.globalConcurrency, NetworkSettings.maxGlobalConcurrency);
      expect(clampedHigh.perHostConcurrency, NetworkSettings.maxPerHostConcurrency);
    });
  });

  group('单图源覆盖优先级', () {
    test('图源覆盖优先于全局；空项继承全局', () {
      const global = NetworkSettings(
        userAgent: 'global-UA',
        proxy: 'http://global:1080',
      );
      const override = NetworkProfile(
        userAgent: 'source-UA',
        cookie: 'session=abc',
      );
      final merged = override.mergedWith(global);

      expect(merged.userAgent, 'source-UA', reason: '源 UA 优先');
      expect(merged.proxy, 'http://global:1080', reason: '源没配代理就继承全局');
      expect(merged.cookie, 'session=abc', reason: 'Cookie 只来自源自身');
    });

    test('全空覆盖 = 完全继承全局', () {
      const global = NetworkSettings(userAgent: 'global-UA', proxy: 'http://p:1');
      final merged = NetworkProfile.none.mergedWith(global);
      expect(merged.userAgent, 'global-UA');
      expect(merged.proxy, 'http://p:1');
      expect(merged.cookie, '');
      expect(NetworkProfile.none.isEmpty, isTrue);
    });

    test('Cookie 不参与「继承」：全局没有 Cookie 概念，图源之间互不共享', () {
      const global = NetworkSettings(userAgent: 'ua');
      final first = const NetworkProfile(cookie: 'a=1').mergedWith(global);
      final second = const NetworkProfile().mergedWith(global);
      expect(first.cookie, 'a=1');
      expect(second.cookie, '', reason: '另一个源不会拿到别人的 Cookie');
    });
  });
  group('LumeHttp 与队列接线', () {
    test('注入客户端时用注入的客户端发送（既有语义不变）', () async {
      final client = _RecordingClient();
      final http = LumeHttp(
        client: client,
        settings: const NetworkSettings(),
        source: '测试源',
      );
      addTearDown(http.dispose);

      final response = await http.send(url: 'https://injected.com/x');
      expect(response.statusCode, 200);
      expect(client.urls, <String>['https://injected.com/x']);
    });

    test('UA 按「图源覆盖 → 全局 → 内置默认」决定', () {
      final global = LumeHttp(
        client: _RecordingClient(),
        settings: const NetworkSettings(userAgent: 'global-UA'),
      );
      expect(global.effectiveUserAgent, 'global-UA');

      final overridden = LumeHttp(
        client: _RecordingClient(),
        settings: const NetworkSettings(userAgent: 'global-UA'),
        profile: const NetworkProfile(userAgent: 'source-UA'),
      );
      expect(overridden.effectiveUserAgent, 'source-UA');

      final fallback = LumeHttp(client: _RecordingClient());
      expect(fallback.effectiveUserAgent, LumeHttp.defaultUserAgent);
    });

    test('代理同样按「图源覆盖 → 全局」决定', () {
      final global = LumeHttp(
        client: _RecordingClient(),
        settings: const NetworkSettings(proxy: 'http://global:1'),
      );
      expect(global.effectiveProxy, 'http://global:1');

      final overridden = LumeHttp(
        client: _RecordingClient(),
        settings: const NetworkSettings(proxy: 'http://global:1'),
        profile: const NetworkProfile(proxy: 'http://source:2'),
      );
      expect(overridden.effectiveProxy, 'http://source:2');
    });

    test('共享队列注入后按队列排队（并发额度是全局的）', () async {
      final sender = _FakeSender();
      final queue = NetworkQueue(
        settings: const NetworkSettings(globalConcurrency: 6, perHostConcurrency: 2),
        sender: sender.send,
      );
      final http = LumeHttp(client: _RecordingClient(), queue: queue);
      addTearDown(http.dispose);

      final futures = <Future<LumeHttpResponse>>[
        for (var i = 0; i < 5; i++) http.send(url: 'https://shared.com/$i'),
      ];
      await Future.wait(futures);
      expect(sender.count, 5, reason: '请求确实经共享队列发出');
    });
  });
}

/// 可编程假发送端：记录并发峰值与调用次数，按脚本给状态码。
class _FakeSender {
  /// 每个 URL 的状态码序列（用尽后按最后一个重复）。
  final Map<String, List<int>> script = <String, List<int>>{};

  /// 每个 URL 前 N 次抛异常。
  final Map<String, int> failTimes = <String, int>{};

  final Map<String, int> attempts = <String, int>{};

  /// 非空时请求会挂起，直到它被 complete（用来观察并发）。
  Completer<void>? hold;

  int _active = 0;
  int _peakTotal = 0;
  final Map<String, int> _activeHosts = <String, int>{};
  final Map<String, int> _peakHosts = <String, int>{};
  int count = 0;

  int get peakTotal => _peakTotal;

  int peakForHost(String host) => _peakHosts[host] ?? 0;

  Future<NetworkResponse> send(NetworkRequest request) async {
    count++;
    final host = NetworkQueue.hostOf(request.url);
    _active++;
    _activeHosts[host] = (_activeHosts[host] ?? 0) + 1;
    if (_active > _peakTotal) _peakTotal = _active;
    if ((_activeHosts[host] ?? 0) > (_peakHosts[host] ?? 0)) {
      _peakHosts[host] = _activeHosts[host]!;
    }
    try {
      if (hold != null) await hold!.future;

      final attempt = (attempts[request.url] ?? 0) + 1;
      attempts[request.url] = attempt;

      final remainingFailures = failTimes[request.url] ?? 0;
      if (remainingFailures > 0) {
        failTimes[request.url] = remainingFailures - 1;
        throw StateError('模拟网络异常');
      }

      final statuses = script[request.url];
      final status = statuses == null || statuses.isEmpty
          ? 200
          : statuses[attempt - 1 < statuses.length ? attempt - 1 : statuses.length - 1];
      return NetworkResponse(
        statusCode: status,
        body: utf8.encode('{"ok":true}'),
        headers: const <String, String>{},
      );
    } finally {
      _active--;
      _activeHosts[host] = (_activeHosts[host] ?? 1) - 1;
      if ((_activeHosts[host] ?? 0) <= 0) _activeHosts.remove(host);
    }
  }
}

/// 记录请求的假客户端。
class _RecordingClient extends http.BaseClient {
  final List<String> urls = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    urls.add(request.url.toString());
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"ok":true}')),
      200,
      headers: const <String, String>{},
    );
  }
}
