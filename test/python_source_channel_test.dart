import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/python_source_engine.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/js_data_source.dart';
import 'package:lume_box/core/source/source_models.dart';
import 'package:lume_box/core/source/source_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<Map> host(Map<String, Object?> args) async {
    final reply = Completer<ByteData?>();
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
      PythonSourceEngine.channel.name,
      codec.encodeMethodCall(MethodCall('host', args)),
      reply.complete,
    );
    return jsonDecode(codec.decodeEnvelope((await reply.future)!)) as Map;
  }

  tearDown(
    () => messenger.setMockMethodCallHandler(PythonSourceEngine.channel, null),
  );

  test('相同 Python 配置只跨桥一次，变化与重新加载仍会同步', () async {
    final actions = <String>[];
    messenger.setMockMethodCallHandler(PythonSourceEngine.channel, (
      call,
    ) async {
      final args = call.arguments as Map;
      actions.add('${args['action']}');
      return jsonEncode({
        'ok': true,
        'value': {
          'methods': ['home'],
        },
      });
    });
    final client = LumeHttp(
      client: MockClient((_) async => http.Response('', 200)),
    );
    final engine = PythonSourceEngine(
      sourceId: 'config-cache-test',
      http: client,
    );
    addTearDown(() {
      engine.dispose();
      client.dispose();
    });
    await engine.loadScript('class Spider: pass');
    await Future.wait(
      List.generate(
        6,
        (_) => engine.applyScriptConfig({'domain': 'https://fixture.test'}),
      ),
    );
    expect(actions.where((a) => a == 'config'), hasLength(1));
    await engine.applyScriptConfig({'domain': 'https://other.test'});
    expect(actions.where((a) => a == 'config'), hasLength(2));
    await engine.loadScript('class Spider: pass');
    await engine.applyScriptConfig({'domain': 'https://other.test'});
    expect(actions.where((a) => a == 'config'), hasLength(3));
  });

  test('漫画 PY 使用漫画引擎与图片载荷，同名视频源网络会话独立', () async {
    final loads = <Map>[];
    messenger.setMockMethodCallHandler(PythonSourceEngine.channel, (
      call,
    ) async {
      final args = call.arguments as Map;
      if (args['action'] == 'load') {
        loads.add(args);
        return jsonEncode({
          'ok': true,
          'value': {
            'methods': ['list', 'detail', 'chapters', 'content'],
          },
        });
      }
      return jsonEncode({
        'ok': true,
        'value': {
          'kind': 'images',
          'images': ['https://images.test/1.jpg'],
          'imageHeaders': {
            'https://images.test/1.jpg': {
              'Referer': 'https://comic.test/read/1',
            },
          },
        },
      });
    });
    final requests = <String>[];
    final comicHttp = LumeHttp(
      client: MockClient((r) async {
        requests.add('comic');
        return http.Response('', 200);
      }),
    );
    final videoHttp = LumeHttp(
      client: MockClient((r) async {
        requests.add('video');
        return http.Response('', 200);
      }),
    );
    final comic = await SourceEngineRegistry.createForScript(
      script: 'class Spider: pass',
      kind: CatEngineKind.quickjs,
      sourceId: 'same-python-id',
      http: comicHttp,
      section: Section.comic,
    ) as PythonSourceEngine;
    final video = PythonSourceEngine(
      sourceId: 'same-python-id',
      http: videoHttp,
    );
    addTearDown(() {
      comic.dispose();
      video.dispose();
      comicHttp.dispose();
      videoHttp.dispose();
    });
    final script = SourcePackage.prepare(
      'class Spider: pass',
      name: 'manga.py',
    );
    expect(await comic.loadScript(script), isTrue);
    expect(loads.single['section'], 'comic');
    expect(loads.single['sourceId'], 'comic:same-python-id');
    final metadata = SourceMetadata.merge(
      SourceMetadata.parseHeader(script),
      SourceMetadata.parse(await comic.metadata()),
    )!;
    expect(metadata.category, 'comic');
    expect(metadata.sectionMismatch(Section.comic), isNull);
    final source = JsDataSource(
      id: 'manga',
      name: '漫画',
      section: Section.comic,
      runtime: _PythonRuntime(comic),
    );
    final content = await source.content(
      itemId: 'book',
      chapterId: 'chapter',
    ) as ImageContent;
    expect(content.images, ['https://images.test/1.jpg']);
    expect(
      content.imageHeaders[content.images.single]!['Referer'],
      'https://comic.test/read/1',
    );
    for (final id in ['comic:same-python-id', 'same-python-id']) {
      expect(
        (await host({
          'sourceId': id,
          'request': jsonEncode({
            'method': 'http',
            'payload': {'url': 'https://fixture.test/', 'body': ''},
          }),
        }))['ok'],
        isTrue,
      );
    }
    expect(requests, ['comic', 'video']);
    expect(
      await SourceEngineRegistry.createForScript(
        script: script,
        kind: CatEngineKind.quickjs,
        sourceId: 'cat-python',
        http: comicHttp,
        section: Section.cat,
      ),
      isNull,
    );
  });

  test('Python HTTP 失败保留 TLS 分类和系统错误码，不泄露原始异常内容', () async {
    final errors = [
      PlatformException(
        code: 'network',
        message: 'https://private.invalid/?token=private-token',
        details: {
          'domain': 'NSURLErrorDomain',
          'code': -1200,
          'headers': {'Cookie': 'private-cookie'},
        },
      ),
      PlatformException(
        code: 'tls_handshake',
        message: 'private-token',
        details: {'domain': 'NSURLErrorDomain', 'code': -1200},
      ),
      PlatformException(
        code: 'certificate',
        message: 'private-token',
        details: {'domain': 'NSURLErrorDomain', 'code': -1202},
      ),
    ];
    for (var index = 0; index < errors.length; index++) {
      var requests = 0;
      final client = LumeHttp(
        client: MockClient((_) async {
          requests++;
          throw errors[index];
        }),
      );
      final engine = PythonSourceEngine(sourceId: 'tls-$index', http: client);
      final result = await host({
        'sourceId': 'tls-$index',
        'request': jsonEncode({
          'method': 'http',
          'payload': {'url': 'https://fixture.invalid/list', 'body': ''},
        }),
      });
      expect(result['ok'], isFalse);
      final message = result['error'] as String;
      expect(
        message,
        contains(
          index == 2 ? 'CERTIFICATE_VERIFY_FAILED' : 'TLS_HANDSHAKE_FAILED',
        ),
      );
      expect(message, contains(index == 2 ? '-1202' : '-1200'));
      expect(message, isNot(contains('private')));
      expect(message, isNot(contains('headers')));
      expect(requests, 1);
      engine.dispose();
      client.dispose();
    }
  });

  test('Python 网络桥保留二进制、请求头、重定向语义，并拒绝已释放来源', () async {
    late http.Request outgoing;
    final client = LumeHttp(
      client: MockClient((request) async {
        outgoing = request;
        return http.Response.bytes(
          [0, 255, 128],
          302,
          headers: {'Location': '/next'},
        );
      }),
    );
    final engine = PythonSourceEngine(sourceId: 'python-network', http: client);
    final args = <String, Object?>{
      'sourceId': 'python-network',
      'request': jsonEncode({
        'method': 'http',
        'timeout': 3,
        'payload': {
          'url': 'https://fixture.invalid/upload',
          'method': 'POST',
          'headers': {
            'Content-Type': 'application/octet-stream',
            'Referer': 'https://fixture.invalid/',
          },
          'body': base64Encode([0, 255, 1]),
        },
      }),
    };
    final reply = await host(args);
    expect(reply['ok'], isTrue, reason: '$reply');
    expect(outgoing.bodyBytes, [0, 255, 1]);
    expect(outgoing.followRedirects, isFalse);
    expect(outgoing.headers['Referer'], 'https://fixture.invalid/');
    expect(base64Decode(reply['value']['body']), [0, 255, 128]);
    expect(reply['value']['status'], 302);
    engine.dispose();
    expect((await host(args))['ok'], isFalse);
    client.dispose();
  });

  test('原生返回依赖说明能保留，超时后标记运行时需要重建', () async {
    final actions = <String>[];
    messenger.setMockMethodCallHandler(PythonSourceEngine.channel, (
      call,
    ) async {
      final args = call.arguments as Map;
      actions.add(args['action'] as String);
      if (args['action'] == 'load') {
        return jsonEncode({
          'ok': true,
          'value': {
            'methods': ['list', 'content'],
            'warnings': ['Android 专属路径需要外部后端'],
          },
        });
      }
      if (args['action'] == 'call') {
        return jsonEncode({
          'ok': false,
          'error': {'kind': 'timeout', 'message': '执行超时'},
        });
      }
      return '{"ok":true,"value":null}';
    });
    final client = LumeHttp();
    final engine = PythonSourceEngine(
      sourceId: 'python-lifecycle',
      http: client,
    );
    expect(
      await engine.loadScript(
        SourcePackage.prepare('class Spider:\n    pass\n', name: 'fixture.py'),
      ),
      isTrue,
    );
    expect(
      (await engine.metadata())!['compatibilityWarnings'],
      contains('Android 专属路径需要外部后端'),
    );
    expect((await engine.callResult('list')).isOk, isFalse);
    expect(engine.isPoisoned, isTrue);
    engine.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(actions.last, 'dispose');
    client.dispose();
  });
}

class _PythonRuntime implements JsSourceRuntime {
  _PythonRuntime(this.engine);
  final PythonSourceEngine engine;
  @override
  Future<Object?> call(String method, [Object? argument]) async =>
      (await engine.callResult(method, argument)).value;
  @override
  Future<Set<String>> contractMethods() async =>
      (await engine.contractMethods()) ?? {};
}
