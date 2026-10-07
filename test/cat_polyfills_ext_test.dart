import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

/// 猫源垫片**扩展面**的真实引擎验证：平台全局（TextEncoder / URL /
/// structuredClone / storage）、Buffer 的二进制读写面、crypto（哈希向量逐个
/// 对照）、zlib 解压（数据由 Dart 侧生成）、可 require 的 Node 模块
/// （events / path / util / assert / stream / fs / os / tty / …），
/// 以及 http/https **确实经宿主桥接层发出**。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  LumeSandbox catSandbox({SandboxHost host = const _NullHost()}) =>
      LumeSandbox.create(
        id: 'cat-shim-ext',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.catRegistry,
      );

  Future<Object?> evalValue(LumeSandbox sandbox, String script) async {
    final result = await sandbox.eval(script);
    expect(result.isOk, isTrue, reason: result.error?.message);
    return result.value;
  }

  /// 出错分支的取值：返回 `code|message`，避免用例里到处写 try/catch。
  String errorProbe(String body) => '''
    (function () {
      try { $body; return 'no-error'; }
      catch (error) { return (error.code || error.name) + '|' + error.message; }
    })()
  ''';

  group('平台全局垫片', () {
    test('TextEncoder / TextDecoder：UTF-8 往返、BOM 处理、非法编码报错', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, 'new TextEncoder().encode("猫源😺").length'),
        10, // 猫源 = 6 字节，😺 = 4 字节
      );
      expect(
        await evalValue(
          sandbox,
          'new TextDecoder().decode(new TextEncoder().encode("猫源😺"))',
        ),
        '猫源😺',
      );
      expect(
        await evalValue(
          sandbox,
          'new TextDecoder("utf-16le").decode(Uint8Array.from([0x2b, 0x73, 0x90, 0x6e]))',
        ),
        '猫源',
      );
      // 默认吃掉开头的 BOM；ignoreBOM 时保留。
      expect(
        await evalValue(
          sandbox,
          'new TextDecoder().decode(Uint8Array.from([0xef, 0xbb, 0xbf, 0x41]))',
        ),
        'A',
      );
      expect(
        await evalValue(
          sandbox,
          'new TextDecoder("utf-8", {ignoreBOM: true}).decode(Uint8Array.from([0xef, 0xbb, 0xbf, 0x41])).charCodeAt(0)',
        ),
        0xfeff,
      );
      expect(
        await evalValue(sandbox, errorProbe('new TextDecoder("gbk")')),
        contains('RangeError'),
      );
    });

    test('URL / URLSearchParams：解析、参数读写、相对解析、序列化', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var url = new URL('https://api.example.com:8443/v1/search?wd=abc&page=2#top');
            return [
              url.protocol, url.host, url.hostname, url.port,
              url.pathname, url.search, url.hash, url.origin
            ].join('|');
          })()
        '''),
        'https:|api.example.com:8443|api.example.com|8443|/v1/search|?wd=abc&page=2|#top|https://api.example.com:8443',
      );

      expect(
        await evalValue(sandbox, '''
          (function () {
            var url = new URL('https://example.com/a/b?x=1');
            url.searchParams.set('wd', '中 文');
            url.searchParams.append('wd', 'second');
            url.searchParams.delete('x');
            return url.toString() + ' || ' + url.searchParams.get('wd') + ' || ' + url.searchParams.size;
          })()
        '''),
        'https://example.com/a/b?wd=%E4%B8%AD+%E6%96%87&wd=second || 中 文 || 2',
      );

      expect(
        await evalValue(sandbox, "new URL('../c?q=1', 'https://example.com/a/b/d').toString()"),
        'https://example.com/a/c?q=1',
      );
      expect(
        await evalValue(sandbox, "new URL('/x', 'https://example.com/a/b').toString()"),
        'https://example.com/x',
      );
      expect(
        await evalValue(sandbox, "new URLSearchParams({a: 1, b: 'x y'}).toString()"),
        'a=1&b=x+y',
      );
      expect(await evalValue(sandbox, "new URL('https://a.com').pathname"), '/');
      expect(
        await evalValue(sandbox, errorProbe("new URL('/relative')")),
        contains('TypeError'),
      );
    });

    test('structuredClone：深拷贝与环引用、不可克隆值报错', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var original = { a: 1, nested: { list: [1, 2] }, when: new Date(0) };
            original.self = original;
            var copy = structuredClone(original);
            copy.nested.list.push(3);
            return JSON.stringify([
              copy.a, copy.self === copy, original.nested.list.length, copy.when.getTime()
            ]);
          })()
        '''),
        <Object?>[1, true, 2, 0],
      );
      expect(
        await evalValue(sandbox, errorProbe('structuredClone(function () {})')),
        contains('DataCloneError'),
      );
    });

    test('localStorage / sessionStorage：进程内可用、不落盘', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            localStorage.setItem('k', 'v');
            sessionStorage.setItem('s', 2);
            return [localStorage.getItem('k'), localStorage.length, sessionStorage.getItem('s'), localStorage.getItem('missing')].join('|');
          })()
        '''),
        'v|1|2|',
      );
    });
  }, skip: skipReason);

  group('Buffer 扩展', () {
    test('utf16le 编解码与 isEncoding', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, "Buffer.from('猫源', 'utf16le').toString('hex')"),
        '2b73906e',
      );
      expect(
        await evalValue(sandbox, "Buffer.from('2b73906e', 'hex').toString('utf16le')"),
        '猫源',
      );
      expect(await evalValue(sandbox, "Buffer.isEncoding('utf16le')"), true);
      expect(await evalValue(sandbox, "Buffer.isEncoding('gbk')"), false);
    });

    test('二进制读写：UInt / Int / 64 位，越界报错', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var buffer = Buffer.alloc(8);
            buffer.writeUInt16LE(0x1234, 0);
            buffer.writeUInt32BE(0xdeadbeef, 2);
            buffer.writeInt8(-1, 6);
            return [
              buffer.readUInt16LE(0).toString(16),
              buffer.readUInt16BE(0).toString(16),
              buffer.readUInt32BE(2).toString(16),
              buffer.readUInt32LE(2).toString(16),
              buffer.readInt8(6)
            ].join('|');
          })()
        '''),
        '1234|3412|deadbeef|efbeadde|-1',
      );
      expect(
        await evalValue(sandbox, '''
          (function () {
            if (typeof BigInt !== 'function') return '0';
            var buffer = Buffer.alloc(8);
            buffer.writeBigUInt64LE(BigInt('123456789012345678'));
            return buffer.readBigUInt64LE(0).toString();
          })()
        '''),
        123456789012345678,
      );
      expect(
        await evalValue(sandbox, errorProbe('Buffer.alloc(2).readUInt32LE(0)')),
        contains('RangeError'),
      );
    });

    test('常用实例方法：indexOf / includes / copy / fill / reverse / compare / subarray', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var buffer = Buffer.from('hello world');
            var target = Buffer.alloc(5);
            var copied = Buffer.from('abcabc').copy(target, 0, 1, 5);
            var filled = Buffer.alloc(3).fill(0x41).toString('utf8');
            var reversed = Buffer.from('ab').reverse().toString('utf8');
            return [
              buffer.indexOf('world'),
              buffer.indexOf('zzz'),
              buffer.includes('hello'),
              buffer.lastIndexOf('l'),
              copied,
              // 注意：结果通道是 C 字符串，返回文本里不能带 NUL，
              // 所以零填充的字节用 hex 比对。
              target.toString('hex'),
              filled,
              reversed,
              Buffer.compare(Buffer.from('a'), Buffer.from('b')),
              buffer.subarray(0, 5).toString('utf8'),
              Array.from(buffer.values()).length
            ].join('|');
          })()
        '''),
        '6|-1|true|9|4|6263616200|AAA|ba|-1|hello|11',
      );
      expect(
        await evalValue(sandbox, 'Buffer.from(new Uint8Array([1, 2, 3]).buffer).toString("hex")'),
        '010203',
      );
    });
  }, skip: skipReason);

  group('crypto 垫片', () {
    test('哈希：md5 / sha1 / sha256 与标准向量一致（含中文 UTF-8）', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      Future<String> digest(String algorithm, String value) async =>
          (await evalValue(
            sandbox,
            "require('crypto').createHash('$algorithm').update('$value', 'utf8').digest('hex')",
          ))! as String;

      expect(await digest('md5', 'abc'), '900150983cd24fb0d6963f7d28e17f72');
      expect(await digest('md5', ''), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(await digest('md5', '猫源'), '33c539d76eca2e5ca7d7dd7cfe5366f3');
      expect(await digest('sha1', 'abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(await digest('sha1', '猫源'), '7ebfe9cdfad7be0bd76071268a76307e6d0c9bd2');
      expect(
        await digest('sha256', 'abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        await digest('sha256', '猫源'),
        'f113cf1848b7ef49ccf18d78ea436462583aab0f311626037e81346b4409eade',
      );
      // 分段 update 与一次 update 等价。
      expect(
        await evalValue(sandbox, '''
          (function () {
            var hash = require('crypto').createHash('sha256');
            hash.update('ab');
            hash.update(Buffer.from('c'));
            return hash.digest('hex');
          })()
        '''),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      // 不带编码时返回 Buffer（Node 口径）。
      expect(
        await evalValue(sandbox, "Buffer.isBuffer(require('crypto').createHash('md5').digest())"),
        true,
      );
    });

    test('HMAC / randomBytes / randomUUID / subtle.digest', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          require('crypto').createHmac('sha256', 'key')
            .update('The quick brown fox jumps over the lazy dog')
            .digest('hex')
        '''),
        'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      );
      expect(
        await evalValue(sandbox, "require('crypto').randomBytes(16).length"),
        16,
      );
      expect(
        await evalValue(
          sandbox,
          r'/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(require("crypto").randomUUID())',
        ),
        true,
      );
      expect(
        await evalValue(sandbox, '''
          (function () {
            var array = new Uint8Array(8);
            globalThis.crypto.getRandomValues(array);
            return array.length;
          })()
        '''),
        8,
      );
      // subtle.digest 与 createHash 同源：结果一致。
      expect(
        await evalValue(sandbox, '''
          (function () {
            globalThis.__subtleHex = null;
            globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc')).then(function (buffer) {
              globalThis.__subtleHex = Buffer.from(new Uint8Array(buffer)).toString('hex');
            });
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await evalValue(sandbox, 'globalThis.__subtleHex'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('不支持的算法给出可读错误', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, errorProbe("require('crypto').createHash('sha512')")),
        contains('md5 / sha1 / sha256'),
      );
    });
  }, skip: skipReason);

  group('zlib 垫片（解压）', () {
    test('gunzip / inflate / inflateRaw / unzip 解出 Dart 侧压缩的数据', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      // 三种块类型都覆盖：短文本（可能用定长码）、高重复文本（动态码）、
      // 伪随机文本（可能落回 stored 块）。
      final samples = <String>[
        'abc',
        '猫源解压测试 ' * 64,
        List<String>.generate(2048, (i) => String.fromCharCode(32 + (i * 37) % 90)).join(),
      ];
      for (final sample in samples) {
        final bytes = utf8.encode(sample);
        final gzipBase64 = base64Encode(gzip.encode(bytes));
        final zlibBase64 = base64Encode(zlib.encode(bytes));
        final rawBase64 = base64Encode(ZLibCodec(raw: true).encode(bytes));

        expect(
          await evalValue(
            sandbox,
            "require('zlib').gunzipSync(Buffer.from('$gzipBase64', 'base64')).toString('utf8').length",
          ),
          sample.length,
          reason: 'gunzip 长度不符（样例长度 ${sample.length}）',
        );
        expect(
          await evalValue(
            sandbox,
            "require('zlib').unzipSync(Buffer.from('$gzipBase64', 'base64')).toString('utf8')",
          ),
          sample,
        );
        expect(
          await evalValue(
            sandbox,
            "require('zlib').inflateSync(Buffer.from('$zlibBase64', 'base64')).toString('utf8')",
          ),
          sample,
        );
        expect(
          await evalValue(
            sandbox,
            "require('zlib').inflateRawSync(Buffer.from('$rawBase64', 'base64')).toString('utf8')",
          ),
          sample,
        );
      }
    });

    test('解压流：createGunzip 可 pipe，压缩侧给出可读错误', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      final gzipBase64 = base64Encode(gzip.encode(utf8.encode('流式解压内容')));
      expect(
        await evalValue(sandbox, '''
          (function () {
            globalThis.__out = '';
            var gunzip = require('zlib').createGunzip();
            gunzip.on('data', function (chunk) { globalThis.__out += chunk.toString('utf8'); });
            gunzip.write(Buffer.from('$gzipBase64', 'base64'));
            gunzip.end();
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await evalValue(sandbox, 'globalThis.__out'), '流式解压内容');

      expect(
        await evalValue(sandbox, errorProbe("require('zlib').gzipSync('x')")),
        contains('LUME_UNSUPPORTED'),
      );
    });
  }, skip: skipReason);

  group('Node 模块垫片', () {
    test('events：on / once / emit / removeListener / error 语义', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var EventEmitter = require('events').EventEmitter;
            var emitter = new EventEmitter();
            var seen = [];
            function onEvent(value) { seen.push('on:' + value); }
            emitter.on('data', onEvent);
            emitter.once('data', function (value) { seen.push('once:' + value); });
            emitter.emit('data', 1);
            emitter.emit('data', 2);
            emitter.removeListener('data', onEvent);
            emitter.emit('data', 3);
            return seen.join(',') + '|' + emitter.listenerCount('data');
          })()
        '''),
        'on:1,once:1,on:2|0',
      );
      expect(
        await evalValue(sandbox, errorProbe("new (require('events').EventEmitter)().emit('error', new Error('boom'))")),
        contains('boom'),
      );
    });

    test('path：posix 语义的 join / resolve / dirname / extname / relative', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var path = require('node:path');
            return [
              path.join('/a', 'b', '..', 'c'),
              path.resolve('a', 'b'),
              path.dirname('/a/b/c.txt'),
              path.basename('/a/b/c.txt', '.txt'),
              path.extname('/a/b/c.txt'),
              path.relative('/a/b', '/a/b/c/d'),
              path.normalize('/a//b/./c/'),
              path.isAbsolute('a')
            ].join('|');
          })()
        '''),
        '/a/c|/a/b|/a/b|c|.txt|c/d|/a/b/c/|false',
      );
    });

    test('util / assert / os / tty / 探测模块', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var util = require('util');
            function Base() {}
            function Child() { Base.call(this); }
            util.inherits(Child, Base);
            return [
              util.format('%s-%d-%j', 'a', 2, { k: 1 }),
              util.inspect({ a: [1, 2] }),
              util.types.isDate(new Date()),
              util.isDeepStrictEqual({ a: 1 }, { a: 1 }),
              Child.super_ === Base
            ].join('|');
          })()
        '''),
        "a-2-{\"k\":1}|{ a: [1, 2] }|true|true|true",
      );
      expect(
        await evalValue(sandbox, '''
          (function () {
            util = require('util');
            var parse = util.promisify(function (value, callback) { callback(null, value * 2); });
            globalThis.__promisified = null;
            parse(21).then(function (result) { globalThis.__promisified = result; });
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await evalValue(sandbox, 'globalThis.__promisified'), 42);

      expect(
        await evalValue(sandbox, errorProbe("require('assert').strictEqual(1, 2)")),
        contains('ERR_ASSERTION'),
      );
      expect(await evalValue(sandbox, "require('assert').deepStrictEqual({a:1},{a:1}) === undefined"), true);
      expect(await evalValue(sandbox, "require('os').platform()"), 'darwin');
      expect(await evalValue(sandbox, "require('tty').isatty(1)"), false);
      expect(await evalValue(sandbox, "require('perf_hooks').performance.now() >= 0"), true);
      expect(await evalValue(sandbox, "require('diagnostics_channel').channel('x').hasSubscribers"), false);
      expect(
        await evalValue(sandbox, "require('async_hooks').AsyncLocalStorage && new (require('async_hooks').AsyncLocalStorage)().getStore() === undefined"),
        true,
      );
      expect(await evalValue(sandbox, "typeof require('module').createRequire"), 'function');
      expect(await evalValue(sandbox, "require('module').isBuiltin('fs')"), true);
    });

    test('stream：Readable.from / PassThrough / pipeline', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var stream = require('stream');
            globalThis.__piped = '';
            var pass = new stream.PassThrough();
            pass.on('data', function (chunk) { globalThis.__piped += chunk; });
            stream.Readable.from(['a', 'b', 'c']).pipe(pass);
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await evalValue(sandbox, 'globalThis.__piped'), 'abc');
      expect(
        await evalValue(sandbox, '''
          (function () {
            var stream = require('stream');
            globalThis.__piped = '';
            var transform = new stream.Transform();
            transform._transform = function (chunk, encoding, callback) {
              callback(null, String(chunk).toUpperCase());
            };
            transform.on('data', function (chunk) { globalThis.__piped += chunk; });
            transform.write('ab');
            transform.end();
            return globalThis.__piped;
          })()
        '''),
        'AB',
      );
    });

    test('fs：内存盘读写、目录、promises 与流', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            var fs = require('fs');
            fs.mkdirSync('/cache/sub', { recursive: true });
            fs.writeFileSync('/cache/sub/a.txt', '内容');
            fs.appendFileSync('/cache/sub/a.txt', '追加');
            return [
              fs.readFileSync('/cache/sub/a.txt', 'utf8'),
              fs.existsSync('/cache/missing'),
              fs.readdirSync('/cache').join(','),
              fs.statSync('/cache/sub/a.txt').size,
              fs.statSync('/cache/sub').isDirectory()
            ].join('|');
          })()
        '''),
        '内容追加|false|sub|12|true',
      );
      expect(
        await evalValue(sandbox, '''
          (function () {
            require('fs/promises').writeFile('/x.txt', 'promise').then(function () {
              return require('fs/promises').readFile('/x.txt', 'utf8');
            }).then(function (text) { globalThis.__fsPromise = text; });
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await evalValue(sandbox, 'globalThis.__fsPromise'), 'promise');
      expect(
        await evalValue(sandbox, errorProbe("require('fs').readFileSync('/nope.txt')")),
        contains('ENOENT'),
      );
      // 内存盘不落盘：这里断言的是「沙箱内可见、且没有真实文件系统 API」。
      expect(
        await evalValue(sandbox, "require('fs').readFileSync('/cache/sub/a.txt').toString('utf8')"),
        '内容追加',
      );
    });

    test('网络与进程模块依旧被拒绝（可读错误）', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      // 契约分两半，两半都要守：
      //  ① **只 require、不使用**不抛——真机实测有订阅源只是顺手 require 了
      //     http2 / net（真正发请求用 fetch），载入期抛会把整份源挡在门外；
      //  ② **用到**（取属性 / 调用 / new）时抛点名到模块的可读错误。
      // 因此下面一律连一个属性访问一起取，测的是「用到才拒」。
      expect(await evalValue(sandbox, "typeof require('net')"), 'function');
      expect(
        await evalValue(sandbox, "typeof require('net').createServer"),
        'function',
        reason: '取属性拿到的是「调用即抛」的函数（不是静默 undefined）',
      );
      for (final name in <String>['net', 'node:tls', 'dns', 'child_process', 'worker_threads', 'http2']) {
        final message = await evalValue(sandbox, errorProbe("require('$name').createServer()"));
        expect(message, contains('LUME_UNSUPPORTED'), reason: '$name 用到了就该被拒');
      }
      // net / tls / http2 这类归到「自建服务端」那一类：文案要说清「为什么
      // 补上模块也跑不起来」（需要端口与进程），而不是只报「没内置」。
      expect(
        await evalValue(sandbox, errorProbe("require('node:net').connect()")),
        allOf(contains('自建服务端'), contains('补上这个模块也跑不起来')),
      );
      expect(
        await evalValue(sandbox, errorProbe("require('node:dns').lookup()")),
        contains('沙箱不提供进程、线程与底层网络'),
      );
      expect(
        await evalValue(sandbox, errorProbe("require('lodash').map()")),
        contains('可用内建模块'),
      );
    });
  }, skip: skipReason);

  group('http / https 走宿主桥接', () {
    test('http.get：经 fetch 桥接到宿主，响应按 Node 形状投递', () async {
      final host = _RecordingHost();
      final sandbox = catSandbox(host: host);
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            globalThis.__httpResult = null;
            var http = require('node:http');
            http.get('https://api.example.com/list?page=2', function (response) {
              var chunks = '';
              response.on('data', function (chunk) { chunks += chunk.toString('utf8'); });
              response.on('end', function () {
                globalThis.__httpResult =
                  response.statusCode + '|' + response.headers['content-type'] + '|' + chunks;
              });
            });
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(host.calls.single, 'https://api.example.com/list?page=2');
      // 脚本自带的请求头原样透传（UA 由宿主网络层统一补，不在这一层）。
      expect(host.headers.length, 1);
      expect(await evalValue(sandbox, 'globalThis.__httpResult'), '200|application/json|{"ok":true}');
    });

    test('http.request：POST + 请求头 + 事件回调 + pipe 到 PassThrough', () async {
      final host = _RecordingHost();
      final sandbox = catSandbox(host: host);
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            globalThis.__postResult = null;
            var http = require('http');
            var stream = require('stream');
            var payload = 'name=值';
            var options = new URL('https://api.example.com/save');
            var request = http.request({
              protocol: options.protocol,
              host: options.hostname,
              port: options.port,
              path: options.pathname + options.search,
              method: 'POST',
              headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': String(payload.length) }
            }, function (response) {
              var sink = new stream.PassThrough();
              var collected = '';
              sink.on('data', function (chunk) { collected += chunk; });
              response.pipe(sink);
              response.on('end', function () { globalThis.__postResult = response.statusCode + '|' + collected; });
            });
            request.on('error', function (error) { globalThis.__postResult = 'error|' + error.message; });
            request.write(payload);
            request.end();
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(host.calls.single, 'https://api.example.com/save');
      expect(host.methods.single, 'POST');
      expect(host.bodies.single, 'name=值');
      expect(host.headers.single['Content-Type'], 'application/x-www-form-urlencoded');
      expect(await evalValue(sandbox, 'globalThis.__postResult'), '200|{"ok":true}');
    });

    test('网络失败：错误经 request 的 error 事件抛出（不崩上下文）', () async {
      final host = _FailingHost();
      final sandbox = catSandbox(host: host);
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, '''
          (function () {
            globalThis.__errorText = null;
            var https = require('node:https');
            var request = https.request({ host: 'api.example.com', path: '/x', method: 'GET' }, function () {});
            request.on('error', function (error) { globalThis.__errorText = String(error); });
            request.end();
            return 'started';
          })()
        '''),
        'started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        await evalValue(sandbox, 'typeof globalThis.__errorText'),
        'string',
        reason: '失败要经 error 事件交回脚本，而不是让上下文崩掉',
      );
      expect(
        await evalValue(sandbox, 'globalThis.__errorText'),
        contains('连接失败'),
      );
    });

    test('http.createServer 明确拒绝（沙箱不监听端口）', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, errorProbe("require('http').createServer()")),
        contains('LUME_UNSUPPORTED'),
      );
    });
  }, skip: skipReason);
}

class _NullHost implements SandboxHost {
  const _NullHost();

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    throw const SandboxHostException('未支持的宿主方法');
  }
}

/// 记录请求并把响应回填给 fetch 垫片（模拟宿主网络层）。
class _RecordingHost implements SandboxHost {
  final List<String> calls = <String>[];
  final List<String> methods = <String>[];
  final List<String> bodies = <String>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    final payload = request.payload;
    final map = payload is Map ? payload : const <Object?, Object?>{};
    calls.add('${map['url']}');
    methods.add('${map['method']}');
    bodies.add(map['body'] == null ? '' : '${map['body']}');
    headers.add(<String, String>{
      for (final entry in (map['headers'] is Map ? map['headers'] as Map : const <Object?, Object?>{}).entries)
        '${entry.key}': '${entry.value}',
    });
    return <String, Object?>{
      'status': 200,
      'headers': <String, String>{'content-type': 'application/json'},
      'body': '{"ok":true}',
    };
  }
}

class _FailingHost implements SandboxHost {
  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    throw const SandboxHostException('连接失败');
  }
}

/// Windows 下取构建产物，其他平台走进程镜像。
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
