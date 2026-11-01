import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';

void main() {
  if (Platform.isWindows) {
    for (final mode in ['Debug', 'Release', 'Profile']) {
      final file = File(
        'build/windows/x64/runner/$mode/quickjs_c_bridge_plugin.dll',
      );
      if (!file.existsSync()) continue;
      Qjs.overrideLibrary(DynamicLibrary.open(file.absolute.path));
      Qjs.reclaimRuntime = false;
      break;
    }
  }
  test('巴卡换域名后直接阅读、搜索和重新登录使用新域名及图片 Referer', () async {
    LumeJsEngine.debugSupportedOverride = true;
    addTearDown(() => LumeJsEngine.debugSupportedOverride = null);
    final http = _FixtureHttp();
    final engine = await LumeJsEngine.create(
      sourceId: 'bakamh_comic',
      http: http,
      section: Section.comic,
    );
    addTearDown(engine.dispose);
    expect(
      await engine.loadScript(File('sources/comic/巴卡漫画.js').readAsStringSync()),
      isTrue,
    );
    for (final domain in ['https://bakamh.com', 'https://bakamh.ru']) {
      await engine.applySourceConfig({
        'domain': domain,
        'account': 'fixture',
        'password': 'fixture',
      });
      final start = http.calls.length;
      final content = await engine.call('content', {
        'id': '/manga/sample/',
        'chapterId': 'https://bakamh.com/manga/sample/c-1/',
      }) as Map;
      expect(content['images'], ['https://img.example/1.jpg']);
      expect(
        (content['imageHeaders']
            as Map)['https://img.example/1.jpg']['Referer'],
        '$domain/manga/sample/c-1/',
      );
      await engine.call('list', {'keyword': 'sample', 'page': 1});
      expect(
        http.calls.skip(start).every((url) => url.startsWith('$domain/')),
        isTrue,
      );
      expect(
        http.posts.where((url) => url == '$domain/wp-login.php').length,
        1,
      );
    }
  }, skip: Qjs.isAvailable ? false : 'QuickJS 原生桥不可用');
}

class _FixtureHttp extends LumeHttp {
  final calls = <String>[];
  final posts = <String>[];
  final loggedIn = <String>{};

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    int? maxBytes,
    Duration? timeout,
  }) async {
    calls.add(url);
    final uri = Uri.parse(url);
    String html;
    if (uri.path == '/wp-login.php') {
      if (method == 'POST') {
        posts.add(url);
        expect(Uri.splitQueryString(body!)['redirect_to'], '${uri.origin}/');
        loggedIn.add(uri.origin);
        html = '<body class="logged-in"></body>';
      } else {
        html = '<form><input name="log"><input name="pwd"></form>';
      }
    } else if (uri.path == '/wp-admin/admin-ajax.php') {
      html = '{"data":[]}';
    } else {
      html = loggedIn.contains(uri.origin)
          ? '<div class="reading-content"><img src="https://img.example/1.jpg"></div>'
          : '<div class="mkjp-ea-lock"></div>';
    }
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(html)),
      headers: const {},
    );
  }
}
