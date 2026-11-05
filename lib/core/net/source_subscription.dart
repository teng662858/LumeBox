import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../util/lume_log.dart';
import '../util/md5.dart';
import 'lume_http.dart';
import '../source/source_package.dart';
import '../source/tvbox_config.dart';
import '../source/source_subscription_catalog.dart';
import '../source/kazumi_rule.dart';
import '../source/source_bundle.dart';
import '../js/module_script.dart';
import '../js/rex_widget.dart';
import 'rex_collection.dart';
import 'private_github_subscription.dart';

/// 一次订阅拉取的结果。
///
/// 同时带字节与文本：文本用于「是不是脚本 / 是不是地址清单」的判断，
/// 字节用于 `.js.md5` 约定的校验（必须校验原始字节，不能拿解码后的字符串算）。
class SourceFetchResult {
  const SourceFetchResult({required this.bytes, required this.text});

  final Uint8List bytes;
  final String text;
}

/// 订阅地址的解析：把「一个订阅链接」变成「若干份图源脚本」。
///
/// 三种形态（与图源导入的约定一致）：
/// 1. **`.js.md5` 校验清单**：正文是 MD5 十六进制，脚本实体在去掉 `.md5` 的地址上
///    ——按字节核对 MD5，不符即抛错（不静默导入来路不明的脚本）；
/// 2. **正文就是脚本**：直接收下；
/// 3. **地址清单**：一行一个 http(s) 地址（`#` 开头是注释），逐个再拉一层，
///    递归用 `visited` 挡住互相引用的清单。
///
/// 这一层刻意从 UI 里抽出来：导入弹窗与「更新订阅源」共用同一套解析，两处的
/// 行为不会走偏（更新时同样会校验 MD5）。
class SourceSubscription {
  final _downloads =
      <
        String,
        Future<({SourceFetchResult? value, Object? error, StackTrace? stack})>
      >{};
  final _downloadWaiters = Queue<Completer<void>>();
  int _activeDownloads = 0;

  Future<({SourceFetchResult? value, Object? error, StackTrace? stack})>
  _startDownload(String url) async {
    // The official repository is a static file host, not a scraped site.
    // Keep general source hosts at four while allowing six official downloads.
    final limit = SubscriptionCatalog.officialPath(url) == null ? 4 : 6;
    if (_activeDownloads >= limit) {
      final ready = Completer<void>();
      _downloadWaiters.add(ready);
      await ready.future;
    } else {
      _activeDownloads++;
    }
    try {
      return (value: await fetch(url), error: null, stack: null);
    } catch (error, stack) {
      // Capture errors immediately: a prefetched sibling may be consumed later.
      return (value: null, error: error, stack: stack);
    } finally {
      if (_downloadWaiters.isEmpty) {
        _activeDownloads--;
      } else {
        _downloadWaiters.removeFirst().complete();
      }
    }
  }

  Future<SourceFetchResult> _download(String url) async {
    final pending = _downloads.remove(url) ?? _startDownload(url);
    final result = await pending;
    if (result.error != null) {
      Error.throwWithStackTrace(result.error!, result.stack!);
    }
    return result.value!;
  }

  Iterable<String> _siblings(
    List<String> urls,
    Set<String> visited,
    int budget,
  ) sync* {
    for (var i = 0; i < urls.length; i++) {
      // Tiny/custom import limits preserve strictly lazy expansion. Normal
      // subscriptions keep a bounded twelve-entry window so slower early files
      // do not leave download slots idle; parsing stays ordered.
      if (maxScripts >= defaultMaxScripts) {
        for (var j = i; j < urls.length && j < i + 12 && j < budget; j++) {
          final url = urls[j];
          if (!visited.contains(url)) {
            _downloads.putIfAbsent(url, () => _startDownload(url));
          }
        }
      }
      yield urls[i];
    }
  }

  static const defaultMaxScripts = 2000;
  SourceSubscription({
    required this.fetch,
    this.maxScripts = defaultMaxScripts,
    this.onSkip,
    this.strictManifest = false,
    this.section,
  });

  /// 拉取动作（URL → 字节 + 文本）。默认走宿主网络层。
  final Future<SourceFetchResult> Function(String url) fetch;

  /// 单次订阅最多收多少份脚本（防止清单无限展开）。
  final int maxScripts;
  final bool strictManifest;

  /// A total subscription is expanded only for its importing section.
  final String? section;
  bool complete = true;

  /// 清单里的**某一条**拉不到时的回调（地址 + 原因）。
  ///
  /// 真机反馈：漫画 / 视频板块的订阅整批导入失败，报「订阅拉取失败：
  /// Bad state: HTTP 404」——清单里有一行指向已被删掉的脚本，而展开清单时
  /// 任何一条失败都会把整次解析打断，其余源也一起进不来。**一条坏条目不该让
  /// 整批失败**：现在跳过它并回调告知（界面照常显示「其余都导入成功 + 哪几条
  /// 没拉到」）。注意只有**清单里的条目**这样处理；用户手输的那条地址拉不到
  /// 仍然照旧报错——那是他真正要拉的东西。
  final void Function(String url, Object error)? onSkip;

  /// 默认实现：走宿主网络层（统一队列 / UA / 代理 / 重试）。
  factory SourceSubscription.viaHttp({
    int maxScripts = defaultMaxScripts,
    void Function(String url, Object error)? onSkip,
  }) {
    return SourceSubscription(
      maxScripts: maxScripts,
      onSkip: onSkip,
      fetch: (url) async {
        final http = LumeHttp(source: '订阅拉取');
        try {
          return await fetchSubscription(http, url);
        } finally {
          // 每次拉取用完即关：订阅拉取是低频操作，不需要长期持有连接池。
          http.dispose();
        }
      },
    );
  }

  /// Preserve the saved/origin URL. Only public raw GitHub downloads get a CDN
  /// retry after transport failure or server overload; a real 404 stays a 404.
  static Future<SourceFetchResult> fetchSubscription(
    LumeHttp http,
    String url, {
    bool force = false,
  }) async {
    url = SubscriptionCatalog.migrateUrl(url);
    final credentials = await PrivateGithubSubscription.load();
    final privateApi = credentials?.apiFor(url);
    if (privateApi != null) {
      final bytes = await credentials!.download(privateApi);
      return SourceFetchResult(
        bytes: bytes,
        text: stripBomText(utf8.decode(bytes, allowMalformed: true)),
      );
    }
    if (credentials?.targetsRepository(url) == true) {
      throw const FormatException('私有订阅地址的分支或路径不匹配，请检查私有仓库设置');
    }
    url = SubscriptionCatalog.migrateUrl(url);
    final headers = force ? const {'Cache-Control': 'no-cache'} : null;
    Future<LumeHttpResponse> send(String target) async {
      final current = await _currentCdnManifest(http, target, headers);
      return current ?? await http.send(url: target, headers: headers);
    }

    LumeHttpResponse response;
    try {
      response = await send(url);
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw LumeHttpException('HTTP ${response.statusCode}');
      }
    } on LumeHttpException {
      final alternate = SubscriptionCatalog.officialPath(url) == null
          ? githubCdnUrl(url)
          : null;
      if (alternate == null) rethrow;
      LumeLog.info('[订阅] GitHub 原始地址暂不可达，尝试 CDN：$url');
      response = await send(alternate);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}（$url）');
    }
    return SourceFetchResult(
      bytes: response.body,
      text: stripBomText(response.text),
    );
  }

  /// Saved official CDN subscriptions are logical lists. Resolve their latest
  /// hash snapshot from the current total manifest on every sync, so a previous
  /// immutable snapshot cannot pin the phone to sources already removed.
  static Future<LumeHttpResponse?> _currentCdnManifest(
    LumeHttp http,
    String url,
    Map<String, String>? headers,
  ) async {
    final prefix = '${SubscriptionCatalog.cdnBase}subscriptions/cdn/';
    if (!url.startsWith(prefix)) return null;
    final name = url.substring(prefix.length);
    if (!const [
      'comic.txt',
      'comics.txt',
      'photo.txt',
      'movie.txt',
      'video.txt',
      'videos.txt',
      'audiobook.txt',
    ].contains(name)) {
      return null;
    }
    try {
      final response = await http.send(
        url: SubscriptionCatalog.totalCdnUrl,
        headers: headers,
      );
      if (response.statusCode != 200) throw const FormatException('CDN 总订阅不可用');
      final total = jsonDecode(stripBomText(response.text));
      if (total is! Map ||
          total['format'] != 'lume.total-subscription' ||
          total['version'] != 1 ||
          total['sections'] is! Map) {
        throw const FormatException('CDN 总订阅格式无效');
      }
      final sections = total['sections'] as Map;
      if (name == 'comics.txt' || name == 'videos.txt') {
        final section = name == 'comics.txt' ? 'comic' : 'video';
        final entries = sections[section];
        if (entries is! List ||
            entries.isEmpty ||
            !entries.every(
              (entry) => entry is String && entry.startsWith(prefix),
            )) {
          throw const FormatException('CDN 分类清单无效');
        }
        return LumeHttpResponse(
          statusCode: 200,
          headers: const {},
          body: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': 'lume.total-subscription',
                'version': 1,
                'sections': {section: entries},
              }),
            ),
          ),
        );
      }
      for (final entries in sections.values.whereType<List>()) {
        for (final entry in entries.whereType<String>()) {
          if (entry.startsWith(prefix) &&
              SubscriptionCatalog.migrateUrl(entry) == url &&
              entry != url) {
            return await http.send(url: entry, headers: headers);
          }
        }
      }
    } catch (_) {
      throw StateError('无法获取当前 CDN 总订阅，已保留旧源，请稍后同步');
    }
    throw StateError('当前 CDN 总订阅未包含此分类，已保留旧源');
  }

  static String? githubCdnUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'raw.githubusercontent.com' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final parts = uri.pathSegments.toList();
    if (parts.length < 4) return null;
    if (parts.length >= 6 &&
        parts[2] == 'refs' &&
        (parts[3] == 'heads' || parts[3] == 'tags')) {
      parts.removeRange(2, 4);
    }
    return SubscriptionCatalog.migrateUrl(
      Uri(
        scheme: 'https',
        host: 'cdn.jsdelivr.net',
        pathSegments: [
          'gh',
          parts[0],
          '${parts[1]}@${parts[2]}',
          ...parts.skip(3),
        ],
      ).toString(),
    );
  }

  /// 地址清单 → 脚本清单。
  Future<List<String>> resolve(List<String> urls) async =>
      (await resolveRefs(urls))
          .map((ref) => ref.script)
          .toList(growable: false);

  /// 地址清单 → 「脚本 + 它自己的来源地址」清单。
  ///
  /// **为什么每条都要留自己的地址**：一个订阅链接（清单）里往往有几份脚本，
  /// 而「更新订阅源」是**按图源**去重取它自己那一份的。以前每条都记清单地址，
  /// 更新时只能拿到清单里的第一条 → 第二个源永远更新不了（真机报「换了源 id」）。
  Future<List<SourceScriptRef>> resolveRefs(List<String> urls) async {
    complete = true;
    final refs = <SourceScriptRef>[];
    final visited = <String>{};
    try {
      for (final url in urls) {
        if (refs.length >= maxScripts) {
          complete = false;
          break;
        }
        refs.addAll(
          await scriptRefsAt(url, visited, remaining: maxScripts - refs.length),
        );
      }
      return refs;
    } finally {
      // Finish the small prefetch window before the caller closes its client.
      // Captured errors remain per-entry failures, never unhandled futures.
      final pending = _downloads.values.toList();
      _downloads.clear();
      await Future.wait(pending);
    }
  }

  /// 单个订阅地址 → 脚本清单（0..n 条）。
  Future<List<String>> scriptsAt(String url, Set<String> visited) async =>
      (await scriptRefsAt(
        url,
        visited,
      )).map((ref) => ref.script).toList(growable: false);

  /// 单个订阅地址 → 「脚本 + 来源地址」清单。
  ///
  /// 来源地址的口径：**能让「更新」重新拿到同一份脚本的那一个**——
  /// `.js.md5` 是校验清单的地址（更新时重新核对 MD5），清单里的一行是那一行
  /// 自己的地址（不是清单地址），正文即脚本时就是它自己。
  Future<List<SourceScriptRef>> scriptRefsAt(
    String url,
    Set<String> visited, {
    int? remaining,
  }) async {
    final budget = remaining ?? maxScripts;
    if (budget <= 0) {
      complete = false;
      return [];
    }
    if (!visited.add(url)) return const <SourceScriptRef>[];
    if (visited.length > maxScripts * 2) {
      complete = false;
      return const <SourceScriptRef>[];
    }
    final download = await _download(url);
    final total = _totalUrls(download.text);
    if (total != null) {
      final refs = <SourceScriptRef>[];
      for (final nested in total) {
        if (refs.length >= budget) {
          complete = false;
          break;
        }
        try {
          refs.addAll(
            await scriptRefsAt(
              nested,
              visited,
              remaining: budget - refs.length,
            ),
          );
        } catch (error) {
          complete = false;
          onSkip?.call(nested, error);
        }
      }
      return refs;
    }
    final kazumiIndex = KazumiRule.indexUrls(download.text, url);
    if (kazumiIndex != null) {
      final refs = <SourceScriptRef>[];
      for (final item in _siblings(kazumiIndex, visited, budget)) {
        if (refs.length >= budget) {
          complete = false;
          break;
        }
        try {
          refs.addAll(
            await scriptRefsAt(item, visited, remaining: budget - refs.length),
          );
        } catch (error) {
          complete = false;
          onSkip?.call(item, error);
        }
      }
      return refs;
    }
    if (RexCollection.matches(download.text)) {
      return _collection(
        RexCollection.parse(download.text, origin: url),
        visited,
        budget,
      );
    }

    // TVBox is a data configuration, not JavaScript or a bag of arbitrary URLs.
    Object? tvboxJson;
    try {
      tvboxJson = jsonDecode(stripBomText(download.text));
    } catch (_) {}
    if (tvboxJson is Map &&
        (tvboxJson['sites'] is List || tvboxJson['lives'] is List)) {
      if (section != null && section != 'video') {
        throw const FormatException('TVBox 配置请导入视频板块');
      }
      final config = TvBoxConfig.parse(download.text, origin: url);
      final refs = <SourceScriptRef>[];
      for (final entry in config.entries) {
        if (!entry.supported) {
          complete = false;
          onSkip?.call(entry.name, FormatException(entry.reason));
          continue;
        }
        if (refs.length >= budget) {
          complete = false;
          break;
        }
        try {
          final script = entry.kind == TvBoxKind.python
              ? entry.pythonScript((await _download(entry.api)).bytes)
              : entry.script;
          refs.add(SourceScriptRef(script: script, url: url));
        } catch (error) {
          complete = false;
          onSkip?.call(entry.name, error);
        }
      }
      return refs;
    }

    // 形态一：`.js.md5` 约定。
    final expected = Md5.parseHex(download.text);
    if (expected != null) {
      final target = scriptUrlFor(url);
      if (target == null) return const <SourceScriptRef>[];
      final entity = await fetch(target);
      // 注意用 hex（先摘要再转十六进制），不是 toHex（那是原始字节的十六进制）。
      final actual = Md5.hex(entity.bytes);
      if (actual != expected) {
        throw StateError('MD5 校验不一致（清单 $expected，实际 $actual）');
      }
      // 记**校验清单**的地址：更新时重新核对 MD5 才是它存在的意义。
      return <SourceScriptRef>[
        SourceScriptRef(
          script: await _moduleDependencies(
            SourcePackage.fromBytes(
              entity.bytes,
              name: Uri.parse(target).pathSegments.lastOrNull ?? '',
              originUrl: url,
            ),
            target,
          ),
          url: url,
        ),
      ];
    }

    // 形态二：正文就是脚本。
    if (looksLikeScript(download.text) ||
        Uri.parse(url).path.toLowerCase().endsWith('.py') ||
        SourceBundle.isZip(download.bytes)) {
      return <SourceScriptRef>[
        SourceScriptRef(
          script: await _moduleDependencies(
            SourcePackage.prepare(
              SourcePackage.fromBytes(download.bytes, originUrl: url),
              originUrl: url,
            ),
            url,
          ),
          url: url,
        ),
      ];
    }

    // 形态三：地址清单，逐个再拉。
    final refs = <SourceScriptRef>[];
    if (strictManifest) {
      for (final raw in const LineSplitter().convert(download.text)) {
        final line = raw.trim();
        // 注释两种都认：`#` 与 `//`。**这条必须留着 `//`**——源仓库的清单是三份
        // 只认 `#` 时整份清单会被判成「非地址内容」，同步直接失败
        // （真机表现：明明推送了新增源，「更新已保存的订阅」后一个都没多）。
        if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
          continue;
        }
        final uri = Uri.tryParse(line);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            line.contains(' ')) {
          throw const FormatException('订阅清单包含非地址内容，保留现有源');
        }
      }
    }
    final nested = urlsIn(download.text, limit: maxScripts + 1);
    if (nested.length > maxScripts) complete = false;
    for (final item in _siblings(nested, visited, budget)) {
      if (refs.length >= budget) {
        complete = false;
        break;
      }
      try {
        refs.addAll(
          await scriptRefsAt(item, visited, remaining: budget - refs.length),
        );
      } catch (error) {
        complete = false;
        // 这一条拉不到（脚本被删 / 地址写错 / 临时 404）：跳过它，其余照常。
        onSkip?.call(item, error);
        LumeLog.warn('订阅条目拉取失败，已跳过：$item（$error）');
      }
    }
    return refs;
  }

  Future<List<SourceScriptRef>> resolveCollectionText(String text) {
    complete = true;
    return _collection(RexCollection.parse(text), <String>{}, maxScripts);
  }

  List<String>? _totalUrls(String text) {
    final clean = stripBomText(text).trim();
    if (!clean.startsWith('{')) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(clean);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['format'] != 'lume.total-subscription') {
      return null;
    }
    final sections = decoded['sections'];
    if (decoded['version'] != 1 || sections is! Map || sections.isEmpty) {
      throw const FormatException('总订阅格式错误，保留现有源');
    }
    final urls = <String>{};
    for (final entry in sections.entries) {
      if (entry.key == 'novel') continue;
      if (!['comic', 'video'].contains(entry.key)) {
        throw const FormatException('总订阅包含未知板块，保留现有源');
      }
      if (section != null && entry.key != section) continue;
      if (entry.value is! List || (entry.value as List).length > 100) {
        throw const FormatException('总订阅板块地址格式错误，保留现有源');
      }
      for (final raw in entry.value as List) {
        if (raw is Map && raw['enabled'] != null && raw['enabled'] is! bool) {
          throw const FormatException('总订阅启用状态格式错误，保留现有源');
        }
        if (raw is Map && raw['enabled'] == false) continue;
        final url = raw is String
            ? raw
            : raw is Map
            ? raw['url']
            : null;
        if (url is! String ||
            !isHttpUrl(url) ||
            Uri.tryParse(url)?.host.isEmpty != false ||
            Uri.parse(url).userInfo.isNotEmpty) {
          throw const FormatException('总订阅包含无效地址，保留现有源');
        }
        urls.add(url);
      }
    }
    return urls.toList();
  }

  Future<List<SourceScriptRef>> _collection(
    RexCollection collection,
    Set<String> visited,
    int budget,
  ) async {
    final refs = <SourceScriptRef>[];
    for (final entry in collection.entries) {
      if (refs.length >= budget) {
        complete = false;
        break;
      }
      try {
        for (final ref in await scriptRefsAt(
          entry.url,
          visited,
          remaining: budget - refs.length,
        )) {
          var script = ref.script;
          if (RexWidget.isEncrypted(script)) {
            final metadata = jsonEncode({
              'id': RexWidget.identity(entry.id.isEmpty ? ref.url : entry.id),
              'name': entry.title,
              'version': entry.version,
              'category': 'video',
            });
            script = script.replaceFirst(
              RegExp(r'^// LumeSource: [^\n]*', multiLine: true),
              '// LumeSource: $metadata',
            );
          }
          refs.add(
            SourceScriptRef(script: script, url: ref.url, label: entry.title),
          );
        }
      } catch (error) {
        complete = false;
        onSkip?.call(entry.url, FormatException('${entry.title}：$error'));
      }
    }
    return refs;
  }

  Future<String> _moduleDependencies(String script, String origin) async {
    // Classic Widgets may contain an inactive UMD require('crypto') branch.
    // It must not be mistaken for an actual ESM dependency.
    if (RexWidget.matches(script)) return script;
    if (SourcePackage.kindOf(script) != SourcePackageKind.module ||
        SourceBundle.parse(script) != null) {
      return script;
    }
    if (ModuleScript.dependencies(script).isEmpty) return script;
    final base = Uri.parse(origin);
    final entry = SourceBundle.checkedPath(
      base.path.replaceFirst(RegExp(r'^/'), ''),
    );
    final files = <String, List<int>>{entry: utf8.encode(script)};
    final locations = <String, String>{entry: base.toString()};
    var total = files[entry]!.length;
    Future<void> visit(String path, String text) async {
      for (final dependency in ModuleScript.dependencies(text)) {
        if (ModuleScript.builtins.contains(dependency)) continue;
        if (!dependency.startsWith('.')) {
          throw FormatException('订阅模块依赖须为相对路径；$dependency 请放入 ZIP 源包');
        }
        final target = Uri.parse(locations[path]!).resolve(dependency);
        if (target.origin != base.origin || target.fragment.isNotEmpty) {
          throw const FormatException('模块依赖不能跨订阅站点或携带 fragment；请使用 ZIP 源包');
        }
        final name = SourceBundle.checkedPath(
          target.path.replaceFirst(RegExp(r'^/'), ''),
        );
        if (files.containsKey(name)) {
          if (locations[name] != target.toString()) {
            throw const FormatException('同名模块带有不同查询参数；请使用 ZIP 源包');
          }
          continue;
        }
        if (files.length >= SourceBundle.maxFiles) {
          throw const FormatException('模块依赖超过 256 个文件');
        }
        final reply = await fetch(target.toString());
        total += reply.bytes.length;
        if (total > SourceBundle.maxBytes) {
          throw const FormatException('模块依赖合计超过 8MB');
        }
        files[name] = reply.bytes;
        locations[name] = target.toString();
        if (!name.endsWith('.json')) {
          await visit(name, utf8.decode(reply.bytes));
        }
      }
    }

    await visit(entry, script);
    return SourcePackage.fromBundle(
      SourceBundle(entry, 'module', 'lume', files, {}),
      originUrl: origin,
    );
  }

  /// `.js.md5` 约定：清单地址去掉 `.md5` 后缀就是脚本实体地址。
  static String? scriptUrlFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final path = uri.path;
    if (!path.toLowerCase().endsWith('.md5')) return null;
    final target = path.substring(0, path.length - 4);
    if (target.isEmpty) return null;
    return uri.replace(path: target).toString();
  }

  /// 从文本里挑出 http(s) 地址：一行一个，忽略空行与 `#` 开头的注释行。
  ///
  /// 订阅文本本身就是脚本（含 `LumeSource`）时不算地址清单。
  static List<String> urlsIn(String text, {required int limit}) {
    if (limit <= 0 || looksLikeScript(text)) return const <String>[];
    final urls = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (!isHttpUrl(trimmed)) continue;
      urls.add(trimmed);
      if (urls.length >= limit) break;
    }
    return urls;
  }

  /// 是不是图源脚本：认头部元信息声明，也认脚本里的 `LumeSource` 全局对象。
  static bool looksLikeScript(String text) =>
      SourceMetadataHeader.hasHeader(text) ||
      RegExp(
        r'^\s*(?:(?:var|let|const)\s+)?LumeSource\s*=',
        multiLine: true,
      ).hasMatch(text) ||
      SourcePackage.looksLikeScript(text);

  static bool isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}

/// 一份脚本 + **它自己的来源地址**（订阅里的每一条都按这个地址更新）。
class SourceScriptRef {
  const SourceScriptRef({
    required this.script,
    required this.url,
    this.label = '',
  });

  /// 脚本文本。
  final String script;

  /// 这一份的来源地址：`.js.md5` 是校验清单地址；清单里的一行是那一行自己的地址
  ///（不是清单地址——否则更新时只会拿到清单的第一条）；正文即脚本时就是它自己。
  final String url;
  final String label;
}

/// 去掉脚本文本开头的 UTF-8 BOM。
String stripBomText(String text) {
  var value = text;
  while (value.startsWith('\uFEFF')) {
    value = value.substring(1);
  }
  return value;
}

/// 头部元信息的最小判定（避免 core/net 依赖 js 层的完整解析器）。
class SourceMetadataHeader {
  SourceMetadataHeader._();

  static final RegExp _pattern = RegExp(
    r'^[ \t]*//[ \t]*@?LumeSource\b',
    multiLine: true,
  );

  static bool hasHeader(String script) => _pattern.hasMatch(script);
}

/// 供订阅解析直接使用的 HTTP 客户端类型（避免调用方再引 http 包）。
typedef SourceHttpClient = http.Client;
