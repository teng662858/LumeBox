import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

/// 「Node 味道的打包产物」端到端回归：一个脚本里连续用上真实猫源用到的
/// 那套能力——`require` 各内建、Buffer 二进制读写、TextEncoder、URL、
/// crypto 哈希、zlib 解压、内存 fs、EventEmitter、stream、结构化克隆，
/// 以及 `http.get` 经宿主桥拿到数据——最后按数据源契约返回条目。
///
/// 真实脚本（用户提供的 6.4MB Node 打包产物）实测到的是这些**用法**；
/// 本用例把用法固化下来，避免后续改动把某一块打回原形。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('Node 风味脚本', () {
    test('打包产物常见用法串联：一次跑通', () async {
      final host = _Host();
      final sandbox = LumeSandbox.create(
        id: 'node-flavored',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.catRegistry,
      );
      addTearDown(sandbox.dispose);

      // 真实脚本在加载期就会 require 一串内建，并把工具函数挂到 module.exports。
      final gzipBase64 = base64Encode(gzip.encode(utf8.encode('{"list":[{"vod_id":1,"vod_name":"测试条目"}]}')));
      final loaded = await sandbox.load('''
        var crypto = require('node:crypto');
        var path = require('node:path');
        var util = require('node:util');
        var fs = require('fs');
        var zlib = require('zlib');
        var stream = require('node:stream');
        var EventEmitter = require('node:events').EventEmitter;

        var module = { exports: {} };
        var LumeSource = {
          id: 'node-flavored',
          name: 'Node 风味源',
          version: '1.0.0',
          async list(argument) {
            // 1. 二进制/编码工具链
            var payload = Buffer.alloc(6);
            payload.writeUInt16LE(0x0102, 0);
            payload.writeUInt32BE(0xdeadbeef, 2);
            var signature = crypto.createHash('md5').update(String(argument.page || 1)).digest('hex');
            var encoded = new TextEncoder().encode('分页');
            var url = new URL('https://api.example.com/list');
            url.searchParams.set('page', String(argument.page || 1));
            url.searchParams.set('sign', signature);
            url.searchParams.set('wd', '中 文');

            // 2. 本地态：内存 fs + 路径工具
            fs.mkdirSync(path.join('/tmp', 'cat'), { recursive: true });
            fs.writeFileSync('/tmp/cat/cache.json', JSON.stringify({ hex: payload.toString('hex'), head: Array.from(encoded) }));

            // 3. 事件与流
            var emitter = new EventEmitter();
            var seen = [];
            emitter.on('hit', function (value) { seen.push(value); });
            emitter.emit('hit', 'first');

            var collected = '';
            var passthrough = new stream.PassThrough();
            passthrough.on('data', function (chunk) { collected += chunk; });
            passthrough.write('stream-ok');
            passthrough.end();

            // 4. 网络：经宿主桥（http 垫片 → fetch → Dart）
            var http = require('http');
            var response = await new Promise(function (resolve, reject) {
              http.get(url.toString(), function (res) {
                var text = '';
                res.on('data', function (chunk) { text += chunk; });
                res.on('end', function () { resolve({ status: res.statusCode, text: text }); });
              }).on('error', reject);
            });

            // 5. 解压 + 结构化克隆 + util 格式化
            var inflated = zlib.gunzipSync(Buffer.from('$gzipBase64', 'base64')).toString('utf8');
            var body = structuredClone(JSON.parse(inflated));
            var label = util.format('%s/%d', body.list[0].vod_name, payload.readUInt16LE(0));

            return {
              items: [{
                id: signature.slice(0, 8),
                title: label + '|' + seen.join(',') + '|' + collected,
                subtitle: JSON.parse(fs.readFileSync('/tmp/cat/cache.json', 'utf8')).hex + '|' + response.status + '|' + response.text
              }],
              hasMore: false
            };
          }
        };
        globalThis.LumeSource = LumeSource;
        'loaded'
      ''');
      expect(loaded.isOk, isTrue, reason: loaded.error?.message);

      final result = await sandbox.call('LumeSource.list', <String, Object?>{'page': 1});
      expect(result.isOk, isTrue, reason: result.error?.message);

      // 宿主收到的请求：URL 已按 URLSearchParams 序列化（空格 → +）。
      expect(host.calls.single, contains('https://api.example.com/list?page=1&sign='));
      expect(host.calls.single, contains('wd=%E4%B8%AD+%E6%96%87'));

      final payload = result.value! as Map<Object?, Object?>;
      final item = (payload['items']! as List<Object?>).single! as Map<Object?, Object?>;
      // 标题里带着：util.format + 小端读取 + 事件 + 流的结果。
      expect(item['title'], '测试条目/258|first|stream-ok');
      // 副标题里带着：二进制十六进制、宿主响应状态与正文。
      expect(item['subtitle'], '0201deadbeef|200|host-body');
      // id 是 md5('1') 的前 8 位。
      expect(item['id'], 'c4ca4238');
    });
  }, skip: skipReason);
}

/// 记录请求并回填响应（模拟宿主网络层）。
class _Host implements SandboxHost {
  final List<String> calls = <String>[];

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    final payload = request.payload;
    final map = payload is Map ? payload : const <Object?, Object?>{};
    calls.add('${map['url']}');
    return <String, Object?>{
      'status': 200,
      'headers': <String, String>{'content-type': 'application/json'},
      'body': 'host-body',
    };
  }
}

DynamicLibrary? _resolveBridge() {
  if (!Platform.isWindows) {
    try {
      return DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (!file.existsSync()) continue;
    try {
      return DynamicLibrary.open(file.absolute.path);
    } catch (_) {
      continue;
    }
  }
  return null;
}
