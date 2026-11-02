import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../js/source_script.dart';

class RepositoryFailure implements Exception {
  const RepositoryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// This credential never enters source scripts, subscription backups or logs.
class RepositoryCredentialStore {
  static const channel = MethodChannel('lumebox/source_repository');
  Future<Map<String, dynamic>> load() async {
    final text = await channel.invokeMethod<String>('read') ?? '';
    return text.isEmpty
        ? {}
        : Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  Future<void> save(Map<String, dynamic> value) =>
      channel.invokeMethod<void>('write', jsonEncode(value));
  Future<void> clear() => channel.invokeMethod<void>('write', '');
}

class RepositorySource {
  const RepositorySource(this.id, this.name, this.version, this.paths);
  final String id, name, version;
  final List<String> paths;
}

class RepositorySnapshot {
  const RepositorySnapshot(this.head, this.tree, this.files, this.sources);
  final String head, tree;
  final Map<String, String> files;
  final List<RepositorySource> sources;
}

class RepositoryOperation {
  const RepositoryOperation(this.branch, this.commit);
  final String branch, commit;
  Map<String, String> toJson() => {'branch': branch, 'commit': commit};
  static RepositoryOperation? parse(Object? value) =>
      value is Map && value['branch'] is String && value['commit'] is String
      ? RepositoryOperation(
          value['branch'] as String,
          value['commit'] as String,
        )
      : null;
}

class RepositoryPublication {
  const RepositoryPublication(
    this.status, {
    this.url = '',
    this.finished = false,
  });
  final String status, url;
  final bool finished;
}

/// Only the official source repository and API host receive this token.
/// A candidate branch triggers validation/build/publication; main is never forced.
class GithubSourceRepository {
  GithubSourceRepository(this.token, {http.Client? client})
    : _client = client ?? http.Client();
  static const repository = 'teng662858/LumeBox-Sources';
  static const kinds = {
    'comic': '漫画',
    'photo': '美图',
    'movie': '影视',
    'video': '视频与直播',
    'audiobook': '有声小说',
  };
  final String token;
  final http.Client _client;
  void close() => _client.close();

  Future<Map<String, dynamic>> _api(
    String method,
    String path, [
    Object? body,
  ]) async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$repository${path.isEmpty ? '' : '/$path'}',
    );
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2026-03-10',
      'User-Agent': 'LumeBox-Source-Manager',
    });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final bytes = BytesBuilder();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        bytes.add(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw const RepositoryFailure('GitHub 响应超过大小限制');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RepositoryFailure(switch (response.statusCode) {
          401 => 'GitHub 授权已失效，请重新填写令牌',
          403 => 'GitHub 拒绝访问：请检查仓库写入权限、Actions 读取权限或请求限额',
          404 => '找不到仓库或发布流程，请检查授权范围',
          409 || 422 => '仓库已变动或分支受保护，请刷新后重试',
          _ => 'GitHub 请求失败（${response.statusCode}），请稍后重试',
        });
      }
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(bytes.takeBytes())) as Map,
      );
    } on RepositoryFailure {
      rethrow;
    } catch (_) {
      throw const RepositoryFailure('无法完成 GitHub 请求，请检查网络后刷新；提交可能已被接收');
    }
  }

  Future<void> connect() async {
    if (token.trim().isEmpty || RegExp(r'\s').hasMatch(token)) {
      throw const RepositoryFailure('请输入有效的 GitHub 令牌');
    }
    final repo = await _api('GET', '');
    if ((repo['permissions'] as Map?)?['push'] != true) {
      throw const RepositoryFailure('此账号没有源仓库写入权限');
    }
    await _api(
      'GET',
      'contents/.github/workflows/app-source-publish.yml?ref=main',
    );
    await _api(
      'GET',
      'actions/workflows/app-source-publish.yml/runs?per_page=1',
    );
  }

  Future<RepositorySnapshot> snapshot() async {
    final ref = await _api('GET', 'git/ref/heads/main');
    final head = (ref['object'] as Map)['sha'] as String;
    final commit = await _api('GET', 'git/commits/$head');
    final tree = (commit['tree'] as Map)['sha'] as String;
    final listing = await _api('GET', 'git/trees/$tree?recursive=1');
    if (listing['truncated'] == true) {
      throw const RepositoryFailure('仓库目录不完整，已停止操作，请稍后重试');
    }
    final files = <String, String>{
      for (final item in (listing['tree'] as List).cast<Map>())
        if (item['type'] == 'blob' && item['mode'] == '100644')
          item['path'] as String: item['sha'] as String,
    };
    final catalogSha = files['metadata/catalog.json'];
    if (catalogSha == null) throw const RepositoryFailure('仓库缺少源目录');
    final blob = await _api('GET', 'git/blobs/$catalogSha');
    final catalog = jsonDecode(
      utf8.decode(
        base64Decode((blob['content'] as String).replaceAll(RegExp(r'\s'), '')),
      ),
    ) as Map;
    final sources = <RepositorySource>[];
    for (final row in (catalog['sources'] as List).cast<Map>()) {
      final paths = <String>[
        row['path'] as String,
        ...(row['aliases'] as List? ?? []).cast<String>(),
      ];
      if (paths.any((path) => !validPath(path) || !files.containsKey(path))) {
        throw const RepositoryFailure('仓库源目录与文件不同步，请等待发布完成再刷新');
      }
      sources.add(
        RepositorySource(
          '${row['id']}',
          '${row['name']}',
          '${row['version']}',
          paths,
        ),
      );
    }
    return RepositorySnapshot(head, tree, files, sources);
  }

  static bool validPath(String path) =>
      path.split('/').length == 2 &&
      kinds.containsKey(path.split('/').first) &&
      !RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(path) &&
      RegExp(r'^[^/]+/[^/]+\.(js|py)$').hasMatch(path) &&
      !path.split('/').last.startsWith('.');

  static SourceMetadata validateUpload(String path, Uint8List bytes) {
    if (!validPath(path)) {
      throw const RepositoryFailure('请选择内容分类，文件须为 .js 或 .py，名称不能含路径');
    }
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      throw const RepositoryFailure('源文件不能为空或超过 4MB');
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw const RepositoryFailure('请先将源文件保存为 UTF-8 编码');
    }
    // Match the publishing generator's JSON header, not a runtime-only object.
    final match = RegExp(
      r'^\s*(?://|#)\s*@?LumeSource\s*[:=]\s*(\{[^\n]+\})',
      multiLine: true,
    ).firstMatch(text);
    Map meta;
    try {
      meta = jsonDecode(match?.group(1) ?? '') as Map;
    } catch (_) {
      throw const RepositoryFailure('源文件需要合法的 LumeSource JSON 元数据头');
    }
    final parsed = SourceMetadata.parseHeader(text);
    if (parsed == null ||
        SourceMetadata.idIssue(meta['id']?.toString()) != null ||
        parsed.name.trim().isEmpty ||
        parsed.version.trim().isEmpty) {
      throw const RepositoryFailure('源的 id、名称或版本无效');
    }
    final kind = path.split('/').first;
    final category = kind == 'comic' || kind == 'photo' ? 'comic' : 'video';
    if (!((category == 'comic' ? ['comic', 'photo'] : ['video', 'audiobook'])
            .contains(meta['category'])) ||
        !['movie', 'adult'].contains(meta['contentCategory'])) {
      throw const RepositoryFailure(
        '请补齐与所选目录相符的 category 和 contentCategory（movie/adult）',
      );
    }
    if (kind == 'audiobook' &&
        meta['mediaType'] != 'audio' &&
        meta['category'] != 'audiobook' &&
        !parsed.id.endsWith('_audiobook')) {
      throw const RepositoryFailure('有声源需要 mediaType: audio 或 audiobook 分类');
    }
    if (kind == 'movie' && meta['contentCategory'] != 'movie') {
      throw const RepositoryFailure('影视目录仅接收 contentCategory: movie 的源');
    }
    return parsed;
  }

  Future<RepositoryOperation> add(
    RepositorySnapshot snapshot,
    String path,
    Uint8List bytes,
  ) async {
    final meta = validateUpload(path, bytes);
    if (snapshot.files.containsKey(path) ||
        snapshot.sources.any((s) => s.id == meta.id)) {
      throw const RepositoryFailure('仓库已有同路径或同 ID 的源，请先核对，不能重复新增');
    }
    final blob = await _api('POST', 'git/blobs', {
      'content': base64Encode(bytes),
      'encoding': 'base64',
    });
    return _candidate(snapshot, [
      {'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']},
    ], '新增 ${meta.name}');
  }

  Future<RepositoryOperation> remove(
    RepositorySnapshot snapshot,
    RepositorySource source,
  ) async {
    if (!snapshot.sources.contains(source) ||
        source.paths.any((p) => !validPath(p))) {
      throw const RepositoryFailure('请刷新仓库后重新选择源');
    }
    return _candidate(snapshot, [
      for (final path in source.paths)
        {'path': path, 'mode': '100644', 'type': 'blob', 'sha': null},
    ], '删除 ${source.name}');
  }

  Future<RepositoryOperation> _candidate(
    RepositorySnapshot snapshot,
    List<Map<String, Object?>> entries,
    String message,
  ) async {
    final tree = await _api('POST', 'git/trees', {
      'base_tree': snapshot.tree,
      'tree': entries,
    });
    final commit = await _api('POST', 'git/commits', {
      'message': 'LumeBox: $message',
      'tree': tree['sha'],
      'parents': [snapshot.head],
    });
    final random = Random.secure();
    final branch =
        'lumebox/manage-${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final operation = RepositoryOperation(branch, commit['sha'] as String);
    await _api('POST', 'git/refs', {
      'ref': 'refs/heads/$branch',
      'sha': operation.commit,
    });
    return operation;
  }

  Future<RepositoryPublication> publication(
    RepositoryOperation operation,
  ) async {
    final response = await _api(
      'GET',
      'actions/workflows/app-source-publish.yml/runs?head_sha=${Uri.encodeQueryComponent(operation.commit)}&per_page=10',
    );
    final runs = (response['workflow_runs'] as List).cast<Map>();
    if (runs.isEmpty) return const RepositoryPublication('已提交，等待 GitHub 启动发布');
    final run = runs.first;
    final url = '${run['html_url'] ?? ''}';
    if (run['status'] != 'completed') {
      return RepositoryPublication('正在校验、更新订阅并核对双线路', url: url);
    }
    return RepositoryPublication(
      run['conclusion'] == 'success'
          ? '已发布：GitHub 与国内 CDN 内容核对通过'
          : '发布未完成，请查看 GitHub 流程；main 可能已更新，先刷新核对再重试',
      url: url,
      finished: true,
    );
  }
}
