import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../util/lume_log.dart';

/// A verified bundle is activated only on the next local-service start.
class BuiltinDanmakuBundle {
  static Future<void>? _updating;
  static const repository = 'teng662858/LumeBox-Danmaku';
  static const modulus =
      '7EkknSCFQNUXiAmNbfZxUPOXQ6SHdU1DZZlnmiHci-rzDpxdWmuQoRf366TOPKIeZ9Ma33gO49qbGPMLbdIQhGuOqyyttWxPgBFEG-vzZ9X5TzH64Kksol6dq--C3oYHrO84_Qf4vuZItgmU6OSD3zzYD3Mducs-VDdsX_ejT7VlvqiYhSRhrwZ3Zk0vsf4JQhT07bk-uhUZO6tTseIdh3nhWRS1VH4LbMP7mD6LsmK6CW-XS59CSLAqcPEq_lHNGHIiYzWbwqHn5PX91Z5TbvVHt8oZKGeDuNODc-BxarGE4WQaONGX0O_Ktjh2MJ3XFoYcAlFyhNiHXGQXSCDng0t9-gGFcPBTRAWZO3VP6bb_x8qR6p_VQZguHwbmySZqj046pTQzHpIZrTpME5vx8Aqxmi9SBC6Efz_y26GEkcJ2GJaj-u4Y5UPvCYXNJ4wpFXs94i7E4-rq1xQOmzPwaVveap6xIzpMOfUNpo35zjOSPEpH2snjlAaJmSLUjpyB';
  static const exponent = 'AQAB';

  static BigInt _integer(String encoded) => base64Url
      .decode(base64Url.normalize(encoded))
      .fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));
  static bool signed(List<int> data, List<int> signature) {
    try {
      final verifier = Signer('SHA-256/RSA')
        ..init(
          false,
          PublicKeyParameter<RSAPublicKey>(
            RSAPublicKey(_integer(modulus), _integer(exponent)),
          ),
        );
      return verifier.verifySignature(
        Uint8List.fromList(data),
        RSASignature(Uint8List.fromList(signature)),
      );
    } catch (_) {
      return false;
    }
  }

  static const files = {
    'index.js': 'adapterSha256',
    'upstream.cjs': 'patchedSha256',
  };

  static Future<Directory> install(Directory root) async {
    await root.create(recursive: true);
    final bundled = jsonDecode(
      await rootBundle.loadString('assets/local_danmaku/manifest.json'),
    ) as Map;
    final fallback = Directory('${root.path}/bundled');
    await fallback.create(recursive: true);
    for (final entry in files.entries) {
      final blob = await rootBundle.load('assets/local_danmaku/${entry.key}');
      final bytes = blob.buffer.asUint8List(
        blob.offsetInBytes,
        blob.lengthInBytes,
      );
      if (sha256.convert(bytes).toString() != bundled[entry.value]) {
        throw StateError('内置弹幕组件完整性校验失败');
      }
      final file = File('${fallback.path}/${entry.key}');
      if (!await file.exists() ||
          sha256.convert(await file.readAsBytes()).toString() !=
              bundled[entry.value]) {
        await file.writeAsBytes(bytes, flush: true);
      }
    }
    var selected = fallback;
    try {
      final activeBytes = await File('${root.path}/active.json').readAsBytes();
      final signature = base64Decode(
        await File('${root.path}/active.sig').readAsString(),
      );
      if (!signed(activeBytes, signature)) {
        throw const FormatException('组件签名无效');
      }
      final manifest = jsonDecode(utf8.decode(activeBytes)) as Map;
      final name = manifest['patchedSha256'];
      if (name is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) {
        final candidate = Directory('${root.path}/$name');
        if (await verify(candidate, manifest)) selected = candidate;
      }
    } catch (_) {
      /* Use the packaged component if an update is incomplete. */
    }
    _updating ??= update(root, bundled).whenComplete(() => _updating = null);
    unawaited(_updating!);
    return selected;
  }

  static Future<bool> verify(Directory directory, Map manifest) async {
    for (final entry in files.entries) {
      final bytes = await File('${directory.path}/${entry.key}').readAsBytes();
      if (sha256.convert(bytes).toString() != manifest[entry.value]) {
        return false;
      }
    }
    return true;
  }

  static Future<void> update(
    Directory root,
    Map bundled, {
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final checked = File('${root.path}/checked');
      if (await checked.exists() &&
          DateTime.now().difference(await checked.lastModified()) <
              const Duration(hours: 6)) {
        return;
      }
      Future<List<int>> get(String url) async {
        final response = await httpClient
            .send(http.Request('GET', Uri.parse(url)))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw HttpException('组件更新 HTTP ${response.statusCode}');
        }
        final bytes = BytesBuilder(copy: false);
        var length = 0;
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 15),
        )) {
          bytes.add(chunk);
          length += chunk.length;
          if (length > 16 * 1024 * 1024) {
            throw const FormatException('组件文件过大');
          }
        }
        return bytes.takeBytes();
      }

      await checked.writeAsString('checking', flush: true);
      final commit = jsonDecode(
        utf8.decode(
          await get('https://api.github.com/repos/$repository/commits/main'),
        ),
      ) as Map;
      final revision = commit['sha'];
      if (revision is! String ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)) {
        throw const FormatException('组件版本无效');
      }
      final base =
          'https://raw.githubusercontent.com/$repository/$revision/mobile';
      final rawManifest = await get('$base/manifest.json');
      final signatureText = utf8.decode(await get('$base/manifest.sig')).trim();
      if (!signed(rawManifest, base64Decode(signatureText))) {
        throw const FormatException('组件发布者签名无效');
      }
      final manifest = jsonDecode(utf8.decode(rawManifest)) as Map;
      for (final field in files.values) {
        if (manifest[field] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(manifest[field])) {
          throw const FormatException('组件摘要无效');
        }
      }
      final rejected = File('${root.path}/rejected');
      if (await rejected.exists() &&
          await rejected.readAsString() == manifest['patchedSha256']) {
        return;
      }
      final directory = Directory('${root.path}/${manifest['patchedSha256']}');
      await directory.create(recursive: true);
      for (final entry in files.entries) {
        final file = File('${directory.path}/${entry.key}');
        if (await file.exists() &&
            sha256.convert(await file.readAsBytes()).toString() ==
                manifest[entry.value]) {
          continue;
        }
        final bytes = await get('$base/${entry.key}');
        if (sha256.convert(bytes).toString() != manifest[entry.value]) {
          throw const FormatException('组件摘要不一致');
        }
        await file.writeAsBytes(bytes, flush: true);
      }
      if (!await verify(directory, manifest)) {
        throw const FormatException('组件校验失败');
      }
      final pending = File('${root.path}/active.json.tmp');
      await pending.writeAsBytes(rawManifest, flush: true);
      await File('${root.path}/active.sig')
          .writeAsString(signatureText, flush: true);
      final active = File('${root.path}/active.json');
      if (await active.exists()) await active.delete();
      await pending.rename(active.path);
      await checked.writeAsString(revision, flush: true);
    } catch (error) {
      LumeLog.info('内置弹幕更新未完成，继续使用已验证组件：$error');
    } finally {
      if (client == null) httpClient.close();
    }
  }
}
