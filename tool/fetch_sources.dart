import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Private source test fixtures: GH_TOKEN/GITHUB_TOKEN or `gh auth login`.
/// Files stay in ignored .sources-cache, never in the App release.
Future<void> main(List<String> args) async {
  final client = http.Client();
  try {
    var token =
        Platform.environment['GH_TOKEN'] ??
        Platform.environment['GITHUB_TOKEN'] ??
        '';
    if (token.trim().isEmpty) {
      try {
        final auth = await Process.run('gh', [
          'auth',
          'token',
          '--hostname',
          'github.com',
        ]).timeout(const Duration(seconds: 10));
        if (auth.exitCode == 0) token = '${auth.stdout}'.trim();
      } on ProcessException {
        // Environment tokens do not require GitHub CLI.
      }
    }
    if (token.trim().isEmpty) {
      throw StateError('请先执行 gh auth login，或设置有源仓库读取权限的 GH_TOKEN');
    }
    final result = await SourceFixtureFetcher(
      client,
      token.trim(),
    ).fetch(Directory('.sources-cache'), report: stdout.writeln);
    stdout.writeln(
      '目录树 ${result.tree}：下载 ${result.ok} 份，失败 ${result.failed} 份',
    );
    if (result.failed != 0) exitCode = 1;
  } catch (error) {
    stderr.writeln('源测试资料下载失败：$error');
    exitCode = 1;
  } finally {
    client.close();
  }
}

class SourceFixtureFetcher {
  SourceFixtureFetcher(this.client, this.token);
  final http.Client client;
  final String token;
  static const _repo = '/repos/teng662858/LumeBox-Sources';
  static const _limit = 64 * 1024 * 1024;
  static final _sha = RegExp(r'^[0-9a-f]{40}$');
  static const _sections = {
    'comic',
    'video',
    'novel',
    'photo',
    'audiobook',
    'movie',
  };

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = Uri.https('api.github.com', '$_repo/$path', query);
    for (var attempt = 0; ; attempt++) {
      try {
        final request = http.Request('GET', uri)..followRedirects = false;
        request.headers.addAll({
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'LumeBox-source-fixtures',
        });
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          if (response.statusCode >= 500 && attempt < 2) continue;
          throw HttpException('GitHub HTTP ${response.statusCode}（请检查源仓库读取权限）');
        }
        final body = BytesBuilder(copy: false);
        await for (final part in response.stream.timeout(
          const Duration(seconds: 20),
        )) {
          if (body.length + part.length > _limit) {
            throw const FormatException('GitHub 响应过大');
          }
          body.add(part);
        }
        return jsonDecode(utf8.decode(body.takeBytes()))
            as Map<String, dynamic>;
      } on TimeoutException {
        if (attempt >= 2) rethrow;
      } on http.ClientException {
        if (attempt >= 2) rethrow;
      }
    }
  }

  static bool _fixture(String path) {
    final parts = path.split('/');
    if (parts.any(
      (p) => p.isEmpty || p == '.' || p == '..' || p.contains(RegExp(r'[\\:]')),
    )) {
      return false;
    }
    return parts.length >= 2 && parts.first == 'snapshots' ||
        parts.length == 2 &&
            _sections.contains(parts.first) &&
            parts.last.endsWith('.js');
  }

  Future<({String tree, int ok, int failed})> fetch(
    Directory root, {
    void Function(String)? report,
  }) async {
    final tree = await _get('git/trees/main', {'recursive': '1'});
    final treeId = tree['sha'];
    if (tree['truncated'] == true ||
        treeId is! String ||
        !_sha.hasMatch(treeId)) {
      throw const FormatException('GitHub 目录树不完整');
    }
    final assets = [
      for (final entry in tree['tree'] as List)
        if (entry is Map &&
            entry['type'] == 'blob' &&
            const {'100644', '100755'}.contains(entry['mode']) &&
            entry['path'] is String &&
            _fixture(entry['path'] as String))
          entry,
    ];
    if (assets.isEmpty) throw const FormatException('源仓库没有脚本或快照');
    var cursor = 0, ok = 0, failed = 0;
    Future<void> worker() async {
      while (cursor < assets.length) {
        final asset = assets[cursor++];
        final path = asset['path'] as String;
        try {
          final sha = asset['sha'];
          if (sha is! String || !_sha.hasMatch(sha)) {
            throw const FormatException('无效文件 SHA');
          }
          // Immutable blob IDs keep all files on the same tree if main moves.
          final blob = await _get('git/blobs/$sha');
          if (blob['encoding'] != 'base64' || blob['content'] is! String) {
            throw const FormatException('GitHub 文件编码无效');
          }
          final bytes = base64.decode(
            (blob['content'] as String).replaceAll(RegExp(r'\s'), ''),
          );
          final digest = sha1.convert([
            ...utf8.encode('blob ${bytes.length}\u0000'),
            ...bytes,
          ]).toString();
          if (digest != sha || bytes.length != asset['size']) {
            throw const FormatException('文件 SHA/长度校验失败');
          }
          final file = File('${root.path}/$path');
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.fetch-tmp');
          try {
            await temporary.writeAsBytes(bytes, flush: true);
            await temporary.rename(file.path);
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
          ok++;
          report?.call('[ok] $path');
        } catch (error) {
          failed++;
          report?.call('[fail] $path：$error');
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return (tree: treeId, ok: ok, failed: failed);
  }
}
