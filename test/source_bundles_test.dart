import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/python_local_proxy.dart';
import 'package:lume_box/core/source/source_package.dart';
import 'package:lume_box/core/source/source_bundle.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/shell/shell_settings.dart';

List<int> sourceZip(Map<String, Object> files) {
  final archive = Archive();
  for (final file in files.entries) {
    final bytes = file.value is String
        ? utf8.encode(file.value as String)
        : file.value as List<int>;
    archive.add(ArchiveFile(file.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  test('普通源内嵌 CryptoJS 的 UMD 导出不改变源类型', () {
    const script =
        "var CryptoJS=(function(){var module,exports; if(typeof exports==='object')module.exports={}; if(typeof require==='function')require('crypto'); return {};})(); var LumeSource={id:'normal',name:'normal'};";
    expect(SourcePackage.kindOf(script), SourcePackageKind.javascript);
    expect(SourcePackage.prepare(script), script);
    expect(
      SourcePackage.kindOf("module.exports = {categories(){return [];}}"),
      SourcePackageKind.module,
    );
    expect(
      SourcePackage.kindOf(
        "(function(){module.exports={categories(){return [];}};})();",
      ),
      SourcePackageKind.module,
      reason: '保留没有全局源对象的 CommonJS 打包脚本',
    );
  });
  test('订阅模块跳过内建依赖，仅下载真实相对模块', () async {
    final requests = <String>[];
    final subscription = SourceSubscription(
      fetch: (url) async {
        requests.add(url);
        final text = url.endsWith('main.mjs')
            ? "import {createHash} from 'crypto'; import './helper.js'; export default {categories(){return [];}};"
            : "if(typeof require==='function'){try{require('node:crypto');}catch(_){}}";
        return SourceFetchResult(
          bytes: base64Decode(base64Encode(utf8.encode(text))),
          text: text,
        );
      },
    );
    final result = await subscription.scriptRefsAt(
      'https://fixture.invalid/main.mjs',
      {},
    );
    expect(result, hasLength(1));
    expect(subscription.complete, isTrue);
    expect(requests, [
      'https://fixture.invalid/main.mjs',
      'https://fixture.invalid/helper.js',
    ]);
  });
  test('JS 订阅自动递归加载相对依赖与循环依赖，更新后仍可离线重读', () async {
    final responses = {
      'https://fixture.invalid/src/main.mjs': "import {home} from '../lib/helper.mjs'; export default {categories:home};",
      'https://fixture.invalid/lib/helper.mjs':
          "import '../src/main.mjs'; export function home(){return [];}",
    };
    final visited = <String>[];
    final subscription = SourceSubscription(
      fetch: (url) async {
        visited.add(url);
        final text = responses[url]!;
        return SourceFetchResult(
          bytes: base64Decode(base64Encode(utf8.encode(text))),
          text: text,
        );
      },
    );
    final refs = await subscription.scriptRefsAt(responses.keys.first, {});
    final bundle = SourceBundle.parse(refs.single.script)!;
    expect(visited, responses.keys.toList());
    expect(bundle.files.keys, containsAll(['src/main.mjs', 'lib/helper.mjs']));
    expect(bundle.resolve(bundle.entry, '../lib/helper.mjs'), 'lib/helper.mjs');
  });
  test('ZIP 源包原始字节订阅、备份重读、目录越界与原生代码校验', () async {
    final bytes = sourceZip({
      'lume.json': '{"entry":"pkg/main.py"}',
      'pkg/main.py': 'from .helper import title',
      'pkg/helper.py': 'title="分类"',
    });
    final script = SourcePackage.fromBytes(bytes, name: 'fixture.zip');
    expect(SourcePackage.kindOf(script), SourcePackageKind.python);
    expect(
      SourceBundle.parse(SourcePackage.prepare(script))!.files.keys,
      contains('pkg/helper.py'),
    );
    final sub = SourceSubscription(
      fetch: (_) async => SourceFetchResult(
        bytes: base64Decode(base64Encode(bytes)),
        text: utf8.decode(bytes, allowMalformed: true),
      ),
    );
    final refs = await sub.scriptRefsAt('https://fixture.invalid/file', {});
    expect(SourceBundle.parse(refs.single.script)!.entry, 'pkg/main.py');
    for (final path in ['../escape.py', '/escape.py', 'x.so', 'x.fwork']) {
      expect(
        () => SourcePackage.fromBytes(
          sourceZip({
            'lume.json': '{"entry":"main.py"}',
            'main.py': 'pass',
            path: 'bad',
          }),
        ),
        throwsFormatException,
        reason: path,
      );
    }
    expect(() => SourceBundle.checkedPath(r'a\bad.py'), throwsFormatException);
  });
  test('纯 Python wheel 与辅助文件一并导入，拒绝架构相关 wheel', () {
    final wheel = sourceZip({
      'helper/__init__.py': 'title="wheel"',
      'helper-1.dist-info/WHEEL': 'Root-Is-Purelib: true',
    });
    final bundle = SourceBundle.fromZip(
      sourceZip({
        'lume.json': '{"entry":"main.py"}',
        'main.py': 'import helper',
        'helper-1-py3-none-any.whl': wheel,
      }),
    );
    expect(bundle.files.keys, contains('helper/__init__.py'));
    expect(
      () => SourceBundle.fromZip(
        sourceZip({'main.py': 'pass', 'helper-1-cp313-ios.whl': wheel}),
      ),
      throwsFormatException,
    );
  });
  test('旧四 TAB 保留已有顺序与可见性，缺视频时承接猫源入口', () {
    final settings = ShellSettings.fromJson({
      'tabs': [
        {'id': 'settings'},
        {'id': 'cat'},
        {'id': 'video', 'visible': false},
        {'id': 'comic'},
      ],
    });
    expect(settings.tabs.map((e) => e.id), ['settings', 'video', 'comic']);
    expect(settings.isVisible('video'), false);
    expect(
      ShellSettings.fromJson({
        'tabs': [
          {'id': 'cat'},
          {'id': 'settings'},
        ],
      }).tabs.first.id,
      'video',
    );
  });
  test('真实回环代理：鉴权路径、Range、HEAD、错误及释放关闭端口', () async {
    final calls = <Map<String, Object?>>[];
    final proxy = PythonLocalProxy((request) async {
      calls.add(request);
      if (request['method'] == 'HEAD') {
        return {
          'status': 200,
          'mime': 'video/mp4',
          'headers': {'Content-Length': '7340032'},
          'body': '',
        };
      }
      return {
        'status': 206,
        'mime': 'video/mp2t',
        'headers': {'Content-Range': 'bytes 2-4/8'},
        'body': base64Encode([2, 3, 4]),
      };
    });
    final client = HttpClient();
    try {
      final url = Uri.parse('${await proxy.start()}&url=segment');
      final request = await client.getUrl(url);
      request.headers.set('Range', 'bytes=2-4');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((e) => e).toList(), [2, 3, 4]);
      expect((calls.single['headers'] as Map)['range'], 'bytes=2-4');
      expect((calls.single['params'] as Map)['url'], 'segment');
      final head = await (await client.headUrl(url)).close();
      expect(head.contentLength, 7340032);
      expect(await head.expand((e) => e).toList(), isEmpty);
      final unauthorized = await (await client.getUrl(
        url.replace(path: '/wrong'),
      )).close();
      expect(unauthorized.statusCode, 404);
      await unauthorized.drain<void>();
      proxy.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        () async => (await client.getUrl(url)).close(),
        throwsA(isA<SocketException>()),
      );
    } finally {
      proxy.dispose();
      client.close(force: true);
    }
  });
}
