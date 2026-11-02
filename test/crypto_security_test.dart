import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:lume_box/core/js/source_crypto.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/security/local_cipher.dart';
import 'package:lume_box/core/security/windows_key_protection.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  final vectors = jsonDecode(
    File('test/fixtures/crypto/node_vectors.json').readAsStringSync(),
  ) as Map;
  for (final raw in vectors['aes'] as List) {
    final v = Map<String, dynamic>.from(raw as Map);
    test('Independent Node ${v['algorithm']} vector and authentication', () {
      final encrypted =
          SourceCrypto.run({...v, 'operation': 'aes', 'encrypt': true}) as Map;
      expect(encrypted['data'], v['ciphertext']);
      if (v['tag'] != '') expect(encrypted['tag'], v['tag']);
      final decrypted = SourceCrypto.run({
        ...v,
        'operation': 'aes',
        'encrypt': false,
        'data': v['ciphertext'],
      }) as Map;
      expect(decrypted['data'], v['data']);
      if (v['tag'] != '') {
        expect(
          () => SourceCrypto.run({
            ...v,
            'operation': 'aes',
            'encrypt': false,
            'data': v['ciphertext'],
            'aad': base64Encode([1]),
          }),
          throwsA(anything),
        );
      }
    });
  }
  test('Independent Node RSA OAEP-SHA256 and RSA-SHA256 signature', () {
    final v = Map<String, dynamic>.from(vectors['rsa'] as Map);
    expect(
      SourceCrypto.run({
        'operation': 'rsa',
        'pem': v['privateKey'],
        'private': true,
        'encrypt': false,
        'oaepHash': 'sha256',
        'data': v['encrypted'],
      }),
      v['data'],
    );
    final signature = SourceCrypto.run({
      'operation': 'sign',
      'pem': v['privateKey'],
      'algorithm': 'RSA-SHA256',
      'data': v['data'],
    });
    expect(signature, v['signature']);
    expect(
      SourceCrypto.run({
        'operation': 'verify',
        'pem': v['publicKey'],
        'algorithm': 'RSA-SHA256',
        'data': v['data'],
        'signature': signature,
      }),
      true,
    );
    expect(
      SourceCrypto.run({
        'operation': 'verify',
        'pem': v['publicKey'],
        'algorithm': 'RSA-SHA256',
        'data': base64Encode([1]),
        'signature': signature,
      }),
      false,
    );
  });
  test('Independent Node HKDF and scrypt vectors with bounded parameters', () {
    String hex(Object b64) =>
        base64Decode(b64 as String)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    expect(
      hex(
        SourceCrypto.run({
          'operation': 'hkdf',
          'algorithm': 'sha256',
          'key': base64Encode(utf8.encode('key')),
          'salt': base64Encode(utf8.encode('salt')),
          'info': base64Encode(utf8.encode('info')),
          'length': 32,
        }),
      ),
      '9ca0d662557439e3b83365f2da4626d35da195c6d9d1779f09838cf9e408966e',
    );
    expect(
      hex(
        SourceCrypto.run({
          'operation': 'scrypt',
          'key': base64Encode(utf8.encode('password')),
          'salt': base64Encode(utf8.encode('salt')),
          'N': 1024,
          'r': 8,
          'p': 1,
          'length': 32,
        }),
      ),
      '16dbc8906763c7f048977a68f9d305f7710e068ca2cd95dab372125bb3f19608',
    );
    expect(
      () => SourceCrypto.run({
        'operation': 'scrypt',
        'N': 65536,
        'r': 32,
        'length': 32,
      }),
      throwsFormatException,
    );
  });
  test('Local encryption rejects swapped contexts and tampered ciphertext', () {
    final c = LocalCipher(Uint8List(32));
    final text = c.seal('private-cookie', context: 'source:a');
    expect(text, isNot(contains('private-cookie')));
    expect(c.reveal(text, context: 'source:a'), 'private-cookie');
    expect(() => c.reveal(text, context: 'source:b'), throwsFormatException);
    final bytes = base64Decode(text.substring(LocalCipher.prefix.length));
    bytes[13] ^= 1;
    expect(
      () => c.reveal(
        '${LocalCipher.prefix}${base64Encode(bytes)}',
        context: 'source:a',
      ),
      throwsFormatException,
    );
  });
  test('Windows device key round-trips through OS DPAPI', () {
    if (!Platform.isWindows) return;
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final protected = WindowsKeyProtection.protect(key);
    expect(protected, isNot(orderedEquals(key)));
    expect(WindowsKeyProtection.unprotect(protected), orderedEquals(key));
    final damaged = Uint8List.fromList(protected);
    damaged[damaged.length - 1] ^= 1;
    expect(() => WindowsKeyProtection.unprotect(damaged), throwsStateError);
  });
  test(
    'Portable backups authenticate password, payload and KDF parameters',
    () async {
      final a = await BackupCipher.encode(
        '{"cookie":"secret-cookie"}',
        password: 'long-test-password',
      );
      final b = await BackupCipher.encode(
        '{"cookie":"secret-cookie"}',
        password: 'long-test-password',
      );
      expect(a, isNot(b));
      expect(a, isNot(contains('secret-cookie')));
      expect(
        await BackupCipher.decode(a, password: 'long-test-password'),
        '{"cookie":"secret-cookie"}',
      );
      await expectLater(
        BackupCipher.decode(a, password: 'wrong'),
        throwsFormatException,
      );
      final tampered = jsonDecode(a) as Map;
      tampered['iterations'] = 210001;
      await expectLater(
        BackupCipher.decode(
          jsonEncode(tampered),
          password: 'long-test-password',
        ),
        throwsFormatException,
      );
      tampered['iterations'] = 1000000000;
      await expectLater(
        BackupCipher.decode(
          jsonEncode(tampered),
          password: 'long-test-password',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'Real QuickJS synchronous AES, SHA512, secure random and PBKDF2',
    () async {
      expect(available, isTrue);
      enableEngineOnThisPlatform();
      final e = await LumeJsEngine.create(
        sourceId: 'crypto-test',
        section: Section.cat,
        http: LumeHttp(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
      try {
        expect(
          await e.loadScript(r'''
var LumeSource={list:function(){var c=require('crypto');Math.random=function(){throw new Error('PRNG forbidden');};
var key=Buffer.alloc(32),iv=Buffer.alloc(12),enc=c.createCipheriv('aes-256-gcm',key,iv);enc.setAAD(Buffer.from('aad'));
var encrypted=Buffer.concat([enc.update('hello','utf8'),enc.final()]);var dec=c.createDecipheriv('aes-256-gcm',key,iv);dec.setAAD(Buffer.from('aad'));dec.setAuthTag(enc.getAuthTag());
var plaintext=Buffer.concat([dec.update(encrypted),dec.final()]).toString();
var target=new Uint32Array(2);c.getRandomValues(target);var fill=Buffer.alloc(8);c.randomFillSync(fill,2,4);
return {plaintext:plaintext,sha512:c.createHash('sha512').update('abc').digest('hex'),random:c.randomBytes(32).length,uuid:c.randomUUID(),range:c.randomInt(10,20),fill:Array.from(fill._b),pbkdf:c.pbkdf2Sync('password','salt',1,32,'sha256').toString('hex')};}};
'''),
          isTrue,
          reason: e.lastLoadFailure?.message,
        );
        final result = await e.call('list') as Map;
        expect(result['plaintext'], 'hello');
        expect((result['sha512'] as String).length, 128);
        expect(result['random'], 32);
        expect(
          result['uuid'],
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(result['range'], inInclusiveRange(10, 19));
        expect((result['fill'] as List).sublist(0, 2), [0, 0]);
        expect((result['fill'] as List).sublist(6), [0, 0]);
        expect(
          result['pbkdf'],
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
        );
      } finally {
        e.dispose();
        restoreEnginePlatformGate();
      }
    },
  );
}
