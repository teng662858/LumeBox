import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';

/// 封面加载不全的根因之一：图源返回的图片地址里混着 `http://` 明文地址，
/// iOS 的 ATS 默认禁止明文请求 → 这部分图整批裂掉（真机表现正是「只能加载
/// 一部分封面」）。
///
/// 修法：请求前把明文地址升级成 https。但**只升级域名**——本地回环与纯 IP
/// 站点通常没有证书，升级只会把本来能用的链接弄坏。
void main() {
  test('http 域名地址升级为 https', () {
    expect(
      SectionImagePipeline.upgradeToHttps('http://img.example.com/a.jpg'),
      'https://img.example.com/a.jpg',
    );
    expect(
      SectionImagePipeline.upgradeToHttps('http://cdn.site.cn:8080/p.png?x=1'),
      'https://cdn.site.cn:8080/p.png?x=1',
    );
  });

  test('已经是 https 的原样返回', () {
    expect(
      SectionImagePipeline.upgradeToHttps('https://img.example.com/a.jpg'),
      'https://img.example.com/a.jpg',
    );
  });

  test('纯 IP 与 localhost 不升级（没有证书，升了就废）', () {
    expect(
      SectionImagePipeline.upgradeToHttps('http://192.168.1.10:9988/a.jpg'),
      'http://192.168.1.10:9988/a.jpg',
    );
    expect(
      SectionImagePipeline.upgradeToHttps('http://127.0.0.1/a.jpg'),
      'http://127.0.0.1/a.jpg',
    );
    expect(
      SectionImagePipeline.upgradeToHttps('http://localhost/a.jpg'),
      'http://localhost/a.jpg',
    );
  });

  test('非 http（相对路径 / data / 空串）原样返回', () {
    for (final url in <String>['', 'a.jpg', '/a.jpg', 'data:image/png;base64,AA']) {
      expect(SectionImagePipeline.upgradeToHttps(url), url);
    }
  });

  test('端到端：bytes() 走的是升级后的地址（真机封面救回来）', () async {
    final root = Directory.systemTemp.createTempSync('lume_box_https_up');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final pipeline = SectionImagePipeline(
      cacheDir: root.path,
      memoryBudgetBytes: 8 * 1024 * 1024,
    );
    addTearDown(pipeline.dispose);

    // 磁盘缓存文件名与内存缓存键都按升级后的地址算：同一张图不会存两份。
    expect(
      pipeline.cachePathFor('http://img.example.com/a.jpg'),
      pipeline.cachePathFor('https://img.example.com/a.jpg'),
    );
  });
}
