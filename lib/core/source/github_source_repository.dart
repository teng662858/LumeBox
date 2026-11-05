import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../js/source_script.dart';
import 'source_import_routing.dart';

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
  const RepositoryOperation(
    this.branch,
    this.commit, {
    this.installPaths = const [],
    this.addedNames = const [],
    this.removedNames = const [],
    this.removedPaths = const [],
    this.manual = false,
    this.dispatched = false,
  });
  final String branch, commit;
  final List<String> installPaths;
  final List<String> addedNames, removedNames, removedPaths;
  final bool manual, dispatched;
  Map<String, Object> toJson() => {
    'branch': branch,
    'commit': commit,
    if (manual) 'manual': true,
    if (dispatched) 'dispatched': true,
    if (installPaths.isNotEmpty) 'installPaths': installPaths,
    if (addedNames.isNotEmpty) 'addedNames': addedNames,
    if (removedNames.isNotEmpty) 'removedNames': removedNames,
    if (removedPaths.isNotEmpty) 'removedPaths': removedPaths,
  };
  static RepositoryOperation? parse(Object? value) =>
      value is Map && value['branch'] is String && value['commit'] is String
      ? RepositoryOperation(
          value['branch'] as String,
          value['commit'] as String,
          addedNames:
              (value['addedNames'] is List
                      ? value['addedNames'] as List
                      : const [])
                  .whereType<String>()
                  .toList(),
          removedNames:
              (value['removedNames'] is List
                      ? value['removedNames'] as List
                      : const [])
                  .whereType<String>()
                  .toList(),
          removedPaths:
              (value['removedPaths'] is List
                      ? value['removedPaths'] as List
                      : const [])
                  .whereType<String>()
                  .where(GithubSourceRepository.validPath)
                  .toList(),
          manual: value['manual'] == true,
          dispatched: value['dispatched'] == true,
          installPaths:
              (value['installPaths'] is List
                      ? value['installPaths'] as List
                      : const [])
                  .whereType<String>()
                  .where(GithubSourceRepository.validPath)
                  .toList(),
        )
      : null;
}

class RepositoryPublication {
  const RepositoryPublication(
    this.status, {
    this.url = '',
    this.finished = false,
    this.succeeded = false,
    this.started = false,
  });
  final String status, url;
  final bool finished;
  final bool succeeded;
  final bool started;
}

class RepositoryUpload {
  const RepositoryUpload(this.path, this.bytes, this.metadata);
  final String path;
  final Uint8List bytes;
  final SourceMetadata metadata;
}

/// Only the official source repository and API host receive this token.
/// A draft branch is submitted first; publication is dispatched separately.
class GithubSourceRepository {
  GithubSourceRepository(this.token, {http.Client? client})
    : _client = client ?? http.Client();
  static const repository = 'teng662858/LumeBox-Sources';
  static const kinds = {
    'comic': '漫画',
    'photo': '美图',
    'novel': '小说',
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
          403 => 'GitHub 拒绝访问：请检查仓库与 Actions 的读写权限或请求限额',
          404 => '找不到仓库或发布流程，请检查授权范围',
          409 || 422 => '仓库已变动或分支受保护，请刷新后重试',
          _ => 'GitHub 请求失败（${response.statusCode}），请稍后重试',
        });
      }
      final payload = bytes.takeBytes();
      if (payload.isEmpty) return {};
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(payload)) as Map);
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
    final category = ['comic', 'photo', 'novel', 'audiobook'].contains(kind)
        ? 'comic'
        : 'video';
    if (!((category == 'comic'
                ? [
                    'comic',
                    'photo',
                    'novel',
                    if (kind == 'audiobook') ...['audiobook', 'video'],
                  ]
                : ['video', 'audiobook'])
            .contains(meta['category'])) ||
        category == 'video' &&
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

  static RepositoryUpload prepareUpload(
    String name,
    Uint8List bytes, {
    String fallbackKind = 'video',
    String? contentCategory,
  }) {
    if (bytes.length > 4 * 1024 * 1024) {
      throw const RepositoryFailure('源文件不能超过 4MB');
    }
    final text = utf8.decode(bytes);
    final match = RegExp(
      r'^\s*(?://|#)\s*@?LumeSource\s*[:=]\s*(\{[^\n]+\})',
      multiLine: true,
    ).firstMatch(text);
    if (match == null) {
      throw const RepositoryFailure('此文件没有仓库源声明；REX 等模块请使用“添加到本机”，无需上传 GitHub');
    }
    final meta = Map<String, dynamic>.from(jsonDecode(match[1]!) as Map);
    var kind = SourceImportRouting.repositoryKind(text, fallback: fallbackKind);
    meta['category'] = switch (kind) {
      'audiobook' => 'comic',
      'photo' => 'photo',
      'novel' => 'novel',
      'comic' => 'comic',
      _ => 'video',
    };
    if (kind == 'audiobook') meta['mediaType'] = 'audio';
    if (!['movie', 'adult'].contains(meta['contentCategory']) &&
        contentCategory != null) {
      meta['contentCategory'] = contentCategory;
    }
    if (kind == 'video' && meta['contentCategory'] == 'movie') kind = 'movie';
    final start = text.indexOf(match[1]!, match.start);
    final prepared = text.replaceRange(
      start,
      start + match[1]!.length,
      jsonEncode(meta),
    );
    final path = '$kind/$name';
    final encoded = Uint8List.fromList(utf8.encode(prepared));
    return RepositoryUpload(path, encoded, validateUpload(path, encoded));
  }

  Future<String> readSource(
    RepositorySnapshot snapshot,
    RepositorySource source,
  ) async {
    final path = source.paths.first;
    if (!validPath(path) || !snapshot.files.containsKey(path)) {
      throw const RepositoryFailure('请刷新仓库后重试');
    }
    final blob = await _api('GET', 'git/blobs/${snapshot.files[path]}');
    try {
      final bytes = base64Decode(
        '${blob['content']}'.replaceAll(RegExp(r'\s'), ''),
      );
      if (bytes.length > 4 * 1024 * 1024) throw const FormatException();
      return utf8.decode(bytes);
    } catch (_) {
      throw const RepositoryFailure('仓库源文件格式无效或超过 4MB');
    }
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
    return _candidate(
      snapshot,
      [
        {'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']},
      ],
      '新增 ${meta.name}',
      installPaths: [path],
    );
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

  /// Submit all staged changes as one candidate commit and one publication.
  Future<RepositoryOperation> applyBatch(
    RepositorySnapshot snapshot, {
    required List<RepositoryUpload> additions,
    required List<RepositorySource> removals,
  }) async {
    if (additions.isEmpty && removals.isEmpty) {
      throw const RepositoryFailure('没有待提交的源');
    }
    final removedPaths = <String>{};
    final removedIds = <String>{};
    for (final source in removals) {
      if (!snapshot.sources.contains(source) ||
          !removedIds.add(source.id) ||
          source.paths.any(
            (p) => !validPath(p) || !snapshot.files.containsKey(p),
          )) {
        throw const RepositoryFailure('仓库源已变化，请刷新后重新选择');
      }
      removedPaths.addAll(source.paths);
    }
    final paths = <String>{};
    final ids = <String>{};
    for (final upload in additions) {
      final meta = validateUpload(upload.path, upload.bytes);
      if (!paths.add(upload.path) ||
          !ids.add(meta.id) ||
          snapshot.files.containsKey(upload.path) ||
          snapshot.sources.any((s) => s.id == meta.id)) {
        throw const RepositoryFailure('待添加的源存在重复 ID 或路径，请核对后重试');
      }
    }
    if (removedPaths.length + additions.length > 20) {
      throw const RepositoryFailure('一次最多提交 20 个源文件（包括别名），请分批操作');
    }
    final entries = <Map<String, Object?>>[
      for (final path in removedPaths.difference(paths))
        {'path': path, 'mode': '100644', 'type': 'blob', 'sha': null},
    ];
    for (final upload in additions) {
      final blob = await _api('POST', 'git/blobs', {
        'content': base64Encode(upload.bytes),
        'encoding': 'base64',
      });
      entries.add({
        'path': upload.path,
        'mode': '100644',
        'type': 'blob',
        'sha': blob['sha'],
      });
    }
    return _candidate(
      snapshot,
      entries,
      '批量更新源（新增 ${additions.length}，删除 ${removals.length}）',
      installPaths: additions.map((upload) => upload.path).toList(),
    );
  }

  Future<RepositoryOperation> _candidate(
    RepositorySnapshot snapshot,
    List<Map<String, Object?>> entries,
    String message, {
    List<String> installPaths = const [],
  }) async {
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
        'lumebox/draft-${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final operation = RepositoryOperation(
      branch,
      commit['sha'] as String,
      installPaths: installPaths,
      manual: true,
    );
    await _api('POST', 'git/refs', {
      'ref': 'refs/heads/$branch',
      'sha': operation.commit,
    });
    return operation;
  }

  Future<void> dispatchPublication(RepositoryOperation operation) async {
    if (!operation.manual ||
        !RegExp(r'^lumebox/draft-[0-9a-f]{24}$').hasMatch(operation.branch) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(operation.commit)) {
      throw const RepositoryFailure('提交信息无效，请刷新后重试');
    }
    await _api('POST', 'actions/workflows/app-source-publish.yml/dispatches', {
      'ref': operation.branch,
      'inputs': {
        'candidate_branch': operation.branch,
        'candidate_sha': operation.commit,
      },
    });
  }

  Future<RepositoryPublication> publication(
    RepositoryOperation operation,
  ) async {
    final response = await _api(
      'GET',
      'actions/workflows/app-source-publish.yml/runs?head_sha=${Uri.encodeQueryComponent(operation.commit)}&per_page=10',
    );
    final runs = (response['workflow_runs'] as List).cast<Map>();
    final eligible = operation.manual
        ? runs.where((run) => run['event'] == 'workflow_dispatch').toList()
        : runs.toList();
    if (eligible.isEmpty) {
      // A workflow dispatched on main uses main's SHA rather than the input
      // candidate SHA. Check ancestry without mistaking another run for ours.
      if (operation.manual &&
          RegExp(r'^[0-9a-f]{40}$').hasMatch(operation.commit)) {
        final comparison = await _api(
          'GET',
          'compare/${operation.commit}...main',
        );
        if (comparison['status'] == 'ahead' ||
            comparison['status'] == 'identical') {
          return const RepositoryPublication(
            '已发布到仓库：main 已包含此提交；线路核对请查看 GitHub 发布流程',
            finished: true,
            succeeded: true,
            started: true,
          );
        }
      }
      return RepositoryPublication(
        operation.dispatched ? '已启动发布，等待 GitHub 工作流' : '已提交，等待手动发布',
      );
    }
    final run = eligible.first;
    final url = '${run['html_url'] ?? ''}';
    if (run['status'] != 'completed') {
      return RepositoryPublication('正在校验、更新并核对订阅', url: url, started: true);
    }
    return RepositoryPublication(
      run['conclusion'] == 'success'
          ? '已发布：订阅内容核对通过'
          : '发布未完成，请查看 GitHub 流程；main 可能已更新，先刷新核对再重试',
      url: url,
      finished: true,
      succeeded: run['conclusion'] == 'success',
      started: true,
    );
  }
}
