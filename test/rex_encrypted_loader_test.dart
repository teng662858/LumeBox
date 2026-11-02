import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/rex_encrypted_loader.dart';
import 'package:lume_box/core/js/rex_widget_host.dart';
import 'package:lume_box/core/js/source_tools.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/source/source_package.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/reading/reading_library.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

const _plaintext = '''WidgetMetadata={id:'encrypted-test',title:'Encrypted fixture',version:'3',modules:[{id:'films',title:'Films',functionName:'films'}]};
async function films(){return [{id:'play',type:'url',title:'Movie',videoUrl:'https://media.invalid/a.mp4'}];}''';
final _key = base64Encode(List.filled(32, 7));
String envelope([String text = _plaintext]) {
  final iv = base64Encode(List.filled(12, 1));
  final payload = SourceTools.run({
    'operation': 'aes',
    'mode': 'GCM',
    'key': _key,
    'iv': iv,
    'data': base64Encode(utf8.encode(text)),
    'encrypt': true,
  });
  return 'REXENC\n${jsonEncode({'v': 2, 'mkv': 'rex-1', 'alg': 'A256GCM', 'iv': iv, 'kb': base64Encode(List.filled(60, 2))})}\n$payload';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  test(
    'REX HTTP challenges use the existing manual browser verification flow',
    () async {
      final host = RexWidgetHost(
        LumeHttp(
          client: MockClient(
            (_) async => http.Response(
              '<html>Just a moment</html>',
              403,
              headers: {'cf-mitigated': 'challenge'},
            ),
          ),
        ),
        Section.video,
        'waf',
        const Duration(seconds: 3),
      );
      await expectLater(
        host.invoke('rex.request', {'url': 'https://fixture.invalid/list'}),
        throwsA(predicate((e) => e.toString().contains('NEED_WEBVIEW_VERIFY'))),
      );
    },
  );
  test('Official key contract, concurrent coalescing and no inherited source credentials', () async {
    var calls = 0;
    final original = LumeHttp(
      profile: const NetworkProfile(
        cookie: 'source-secret',
        userAgent: 'source-user-agent',
      ),
      rewriteUrl: (_) => 'https://untrusted.invalid/',
      client: MockClient((r) async {
        calls++;
        expect(r.url.toString(), RexEncryptedLoader.endpoint);
        expect(r.method, 'POST');
        expect(r.headers['Cookie'], isNull);
        expect(r.headers['Authorization'], isNull);
        expect(
          (jsonDecode(r.body) as Map).keys,
          unorderedEquals(['mkv', 'kb']),
        );
        return http.Response(jsonEncode({'key': _key}), 200);
      }),
    );
    final loader = RexEncryptedLoader(original.hostServiceClient());
    final script = envelope();
    expect(await Future.wait([loader.load(script), loader.load(script)]), [
      _plaintext,
      _plaintext,
    ]);
    expect(calls, 1);
    expect(await loader.load(script), _plaintext);
    expect(calls, 1);
  });
  test(
    'Damaged tag and unsupported format fail without plaintext fallback',
    () async {
      var calls = 0;
      final loader = RexEncryptedLoader(
        LumeHttp(
          client: MockClient((_) async {
            calls++;
            return http.Response(jsonEncode({'key': _key}), 200);
          }),
        ),
      );
      final lines = envelope().split('\n');
      final bytes = base64Decode(lines.last);
      bytes[0] ^= 1;
      lines[2] = base64Encode(bytes);
      await expectLater(loader.load(lines.join('\n')), throwsFormatException);
      await expectLater(loader.load('FWENC\n{}\nAAAA'), throwsFormatException);
      await expectLater(loader.load('REXENC\n{}\nAAAA'), throwsFormatException);
      expect(calls, 1);
    },
  );
  test('Key-service failure retries; malformed key and non-script plaintext rejected', () async {
    var calls = 0;
    final loader = RexEncryptedLoader(
      LumeHttp(
        settings: const NetworkSettings(maxRetries: 0),
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('{}', 403)
              : http.Response('{"key":"AA=="}', 200);
        }),
      ),
    );
    await expectLater(loader.load(envelope()), throwsFormatException);
    await expectLater(loader.load(envelope()), throwsFormatException);
    expect(calls, 2);
    final validKey = RexEncryptedLoader(
      LumeHttp(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'key': _key}), 200),
        ),
      ),
    );
    await expectLater(
      validKey.load(envelope('not executable')),
      throwsFormatException,
    );
  });
  test(
    'Real QuickJS executes decrypted source under persisted encrypted identity',
    () async {
      expect(available, isTrue);
      enableEngineOnThisPlatform();
      final root = Directory.systemTemp.createTempSync('rex_encrypted_native');
      await installTempSectionRoot(root);
      final script = SourcePackage.prepare(envelope(), name: 'encrypted.js');
      final identity = SourceMetadata.parseHeader(script)!.id;
      final e = QuickJsSourceEngine(
        await LumeJsEngine.create(
          sourceId: identity,
          section: Section.video,
          widgetCompatibility: true,
          http: LumeHttp(
            client: MockClient(
              (_) async => http.Response(jsonEncode({'key': _key}), 200),
            ),
          ),
        ),
      );
      try {
        expect(await e.loadScript(script), isTrue, reason: e.loadFailure);
        expect((await e.metadata())!['id'], identity);
        final list = await e.callResult('list', {'page': 1});
        expect(list.isOk, isTrue, reason: list.error?.message);
        expect((list.value as Map)['items'], hasLength(1));
        expect(script, isNot(contains('async function films')));
      } finally {
        e.dispose();
        ReadingLibrary.disposeAll();
        await SectionScope.closeAll();
        restoreEnginePlatformGate();
        root.deleteSync(recursive: true);
      }
    },
  );
}
