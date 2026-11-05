import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Device-only read credentials. Never place these in subscription URLs or backups.
class PrivateGithubSubscription {
  const PrivateGithubSubscription({
    required this.owner,
    required this.repository,
    required this.ref,
    required this.token,
  });
  final String owner, repository, ref, token;

  static const channel = MethodChannel('lumebox/source_repository');
  static Future<PrivateGithubSubscription?>? _cached;
  static http.Client? _sharedClient;
  @visibleForTesting
  static http.Client Function() clientFactory = http.Client.new;
  @visibleForTesting
  static void resetForTesting() {
    _sharedClient?.close();
    _sharedClient = null;
    _cached = null;
    clientFactory = http.Client.new;
  }

  static Future<PrivateGithubSubscription?> load() => _cached ??= _read();
  static Future<PrivateGithubSubscription?> _read() async {
    try {
      final text = await channel.invokeMethod<String>('privateRead') ?? '';
      if (text.isEmpty) return null;
      final data = jsonDecode(text);
      if (data is! Map) return null;
      return PrivateGithubSubscription(
        owner: '${data['owner'] ?? ''}',
        repository: '${data['repository'] ?? ''}',
        ref: '${data['ref'] ?? ''}',
        token: '${data['token'] ?? ''}',
      ).validated();
    } on MissingPluginException {
      return null;
    }
  }

  PrivateGithubSubscription validated() {
    final name = RegExp(r'^[A-Za-z0-9_.-]+$');
    if (!name.hasMatch(owner) ||
        !name.hasMatch(repository) ||
        owner == '.' ||
        owner == '..' ||
        repository == '.' ||
        repository == '..' ||
        ref.isEmpty ||
        ref.contains(RegExp(r'[\x00-\x20\x7f]')) ||
        token.isEmpty ||
        token.contains(RegExp(r'\s'))) {
      throw const FormatException('请填写有效的仓库、分支和只读 Token');
    }
    return this;
  }

  static Future<void> save(PrivateGithubSubscription value) async {
    value.validated();
    await channel.invokeMethod<void>(
      'privateWrite',
      jsonEncode({
        'owner': value.owner,
        'repository': value.repository,
        'ref': value.ref,
        'token': value.token,
      }),
    );
    _cached = Future.value(value);
  }

  static Future<void> clear() async {
    await channel.invokeMethod<void>('privateWrite', '');
    _cached = Future.value(null);
  }

  bool targetsRepository(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return false;
    }
    final p = uri.pathSegments;
    if (uri.host == 'lume-sources.pages.dev' &&
        owner.toLowerCase() == 'teng662858' &&
        repository.toLowerCase() == 'lumebox-sources') {
      return true;
    }
    if ((uri.host == 'raw.githubusercontent.com' || uri.host == 'github.com') &&
        p.length >= 2) {
      return p[0].toLowerCase() == owner.toLowerCase() &&
          p[1].toLowerCase() == repository.toLowerCase();
    }
    if (uri.host == 'cdn.jsdelivr.net' && p.length >= 3 && p[0] == 'gh') {
      return p[1].toLowerCase() == owner.toLowerCase() &&
          p[2].split('@').first.toLowerCase() == repository.toLowerCase();
    }
    return false;
  }

  /// Only an exact repository and configured ref can use the credential.
  Uri? apiFor(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasPort) {
      return null;
    }
    final parts = uri.pathSegments;
    List<String>? tail;
    if (uri.host == 'raw.githubusercontent.com' &&
        !uri.hasQuery &&
        parts.length >= 4 &&
        parts[0].toLowerCase() == owner.toLowerCase() &&
        parts[1].toLowerCase() == repository.toLowerCase()) {
      tail = parts.sublist(2);
    } else if (uri.host == 'cdn.jsdelivr.net' &&
        !uri.hasQuery &&
        parts.length >= 4 &&
        parts[0] == 'gh' &&
        parts[1].toLowerCase() == owner.toLowerCase() &&
        parts[2].split('@').first.toLowerCase() == repository.toLowerCase() &&
        parts[2].substring(parts[2].indexOf('@') + 1) == ref &&
        parts[2].contains('@')) {
      tail = [...ref.split('/'), ...parts.skip(3)];
    } else if (uri.host == 'lume-sources.pages.dev' &&
        !uri.hasQuery &&
        parts.isNotEmpty &&
        owner.toLowerCase() == 'teng662858' &&
        repository.toLowerCase() == 'lumebox-sources') {
      tail = [...ref.split('/'), ...parts];
    } else if (uri.host == 'github.com' &&
        !uri.hasQuery &&
        parts.length >= 5 &&
        parts[0].toLowerCase() == owner.toLowerCase() &&
        parts[1].toLowerCase() == repository.toLowerCase() &&
        parts[2] == 'blob') {
      tail = parts.sublist(3);
    }
    if (tail == null) return null;
    final refParts = ref.split('/');
    if (tail.length >= 2 && tail[0] == 'refs' && tail[1] == 'heads') {
      tail = tail.sublist(2);
    }
    if (tail.length <= refParts.length ||
        !List.generate(
          refParts.length,
          (i) => tail![i] == refParts[i],
        ).every((x) => x)) {
      return null;
    }
    final path = tail.sublist(refParts.length);
    if (path.any(
      (part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.contains('/') ||
          part.contains('\\'),
    )) {
      return null;
    }
    return Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: ['repos', owner, repository, 'contents', ...path],
      queryParameters: {'ref': ref},
    );
  }

  Future<Uint8List> download(Uri api, {http.Client? client}) async {
    if (api.scheme != 'https' ||
        api.host != 'api.github.com' ||
        api.hasPort ||
        api.userInfo.isNotEmpty) {
      throw const FormatException('私有订阅地址无效');
    }
    final network = client ?? (_sharedClient ??= clientFactory());
    final request = http.Request('GET', api)..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github.raw+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'LumeBox-Private-Subscription',
    });
    final response = await network
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError(
        response.statusCode == 401 ||
                response.statusCode == 403 ||
                response.statusCode == 404
            ? '私有仓库读取失败，请检查 Token、仓库访问权限、分支及文件路径'
            : '私有仓库读取失败（HTTP ${response.statusCode}）',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      bytes.add(part);
      if (bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('私有订阅文件超过 8 MB');
      }
    }
    return bytes.takeBytes();
  }
}
