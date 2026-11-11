import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/net/network_queue.dart';

/// Preserve source schemes: forcing an HTTP-only image host to HTTPS can
/// produce TLS errors. ATS already has a separate HTTP transport fallback.
void main() {
  test('HTTP 图片域名与自定义端口保持源提供的协议', () {
    expect(
      SectionImagePipeline.canonicalUrl('http://img.example.com/a.jpg'),
      'http://img.example.com/a.jpg',
    );
    expect(
      SectionImagePipeline.canonicalUrl('http://cdn.site.cn:8080/p.png?x=1'),
      'http://cdn.site.cn:8080/p.png?x=1',
    );
  });

  test('已经是 https 的原样返回', () {
    expect(
      SectionImagePipeline.canonicalUrl('https://img.example.com/a.jpg'),
      'https://img.example.com/a.jpg',
    );
  });

  test('纯 IP 与 localhost 不升级（没有证书，升了就废）', () {
    expect(
      SectionImagePipeline.canonicalUrl('http://192.168.1.10:9988/a.jpg'),
      'http://192.168.1.10:9988/a.jpg',
    );
    expect(
      SectionImagePipeline.canonicalUrl('http://127.0.0.1/a.jpg'),
      'http://127.0.0.1/a.jpg',
    );
    expect(
      SectionImagePipeline.canonicalUrl('http://localhost/a.jpg'),
      'http://localhost/a.jpg',
    );
  });

  test('非 http（相对路径 / data / 空串）原样返回', () {
    for (final url in <String>[
      '',
      'a.jpg',
      '/a.jpg',
      'data:image/png;base64,AA',
    ]) {
      expect(SectionImagePipeline.canonicalUrl(url), url);
    }
  });

  test('HTTP 与 HTTPS 缓存隔离，不混用失效或认证响应', () async {
    final root = Directory.systemTemp.createTempSync('lume_box_https_up');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final pipeline = SectionImagePipeline(
      cacheDir: root.path,
      memoryBudgetBytes: 8 * 1024 * 1024,
    );
    addTearDown(pipeline.dispose);

    // A declared HTTPS resource must never reuse an HTTP response.
    expect(
      pipeline.cachePathFor('http://img.example.com/a.jpg'),
      isNot(pipeline.cachePathFor('https://img.example.com/a.jpg')),
    );
  });
  for (final scheme in ['http', 'https']) {
    test('封面下载保留 $scheme 地址与源请求头', () async {
      const path = 'www.lyyytv.cn/upload/cover.jpg';
      final urls = <String>[];
      final pipeline = SectionImagePipeline(
        cacheDir: '',
        diskCache: false,
        maxRetries: 0,
        requestSender: (request) async {
          urls.add(request.url);
          expect(request.headers['Referer'], 'http://cms.lyyytv.cn/');
          if (scheme == 'https') {
            throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
          }
          return const NetworkResponse(
            statusCode: 200,
            body: [1, 2, 3],
            headers: {},
          );
        },
      );
      addTearDown(pipeline.dispose);
      final url = '$scheme://$path';
      pipeline.configureImageHeaders({
        url: {'Referer': 'http://cms.lyyytv.cn/'},
      });
      expect(await pipeline.bytes(url), scheme == 'http' ? [1, 2, 3] : isNull);
      expect(urls, [
        url,
      ], reason: 'Do not invent HTTPS or downgrade declared HTTPS');
    });
  }

  test('变换型地址退回真实路径（CF Image Resizing 那类）', () {
    expect(
      SectionImagePipeline.normalizeTransform(
        'https://img2.ms39pn.com/cdn-cgi/image/quality=80,height=260/upload/vod/a.webp',
      ),
      'https://img2.ms39pn.com/upload/vod/a.webp',
    );
    expect(
      SectionImagePipeline.normalizeTransform('https://a.com/upload/b.webp'),
      'https://a.com/upload/b.webp',
      reason: '不带变换段的原样返回（不猜、不改写）',
    );
    expect(SectionImagePipeline.normalizeTransform(''), '');
  });

  test('同协议的变换地址与原图缓存键一致', () {
    final pipeline = SectionImagePipeline(
      cacheDir: Directory.systemTemp.createTempSync('lume_box_tf').path,
      memoryBudgetBytes: 1024 * 1024,
    );
    addTearDown(pipeline.dispose);
    expect(
      pipeline.cachePathFor(
        'http://img.a.com/cdn-cgi/image/height=260/upload/x.webp',
      ),
      pipeline.cachePathFor('http://img.a.com/upload/x.webp'),
      reason: '两种写法要落到同一个缓存文件',
    );
  });
}
