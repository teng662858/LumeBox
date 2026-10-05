import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../util/md5.dart';
import 'lume_http.dart';

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
  SourceSubscription({
    required this.fetch,
    this.maxScripts = 20,
  });

  /// 拉取动作（URL → 字节 + 文本）。默认走宿主网络层。
  final Future<SourceFetchResult> Function(String url) fetch;

  /// 单次订阅最多收多少份脚本（防止清单无限展开）。
  final int maxScripts;

  /// 默认实现：走宿主网络层（统一队列 / UA / 代理 / 重试）。
  factory SourceSubscription.viaHttp({int maxScripts = 20}) {
    final http = LumeHttp(source: '订阅拉取');
    return SourceSubscription(
      maxScripts: maxScripts,
      fetch: (url) async {
        try {
          final response = await http.send(url: url);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw StateError('HTTP ${response.statusCode}');
          }
          return SourceFetchResult(
            bytes: response.body,
            text: stripBomText(response.text),
          );
        } finally {
          // 每次拉取用完即关：订阅拉取是低频操作，不需要长期持有连接池。
          http.dispose();
        }
      },
    );
  }

  /// 地址清单 → 脚本清单。
  Future<List<String>> resolve(List<String> urls) async {
    final scripts = <String>[];
    final visited = <String>{};
    for (final url in urls) {
      if (scripts.length >= maxScripts) break;
      scripts.addAll(await scriptsAt(url, visited));
    }
    return scripts;
  }

  /// 单个订阅地址 → 脚本清单（0..n 条）。
  Future<List<String>> scriptsAt(String url, Set<String> visited) async {
    if (!visited.add(url) || visited.length > maxScripts * 2) {
      return const <String>[];
    }
    final download = await fetch(url);

    // 形态一：`.js.md5` 约定。
    final expected = Md5.parseHex(download.text);
    if (expected != null) {
      final target = scriptUrlFor(url);
      if (target == null) return const <String>[];
      final entity = await fetch(target);
      // 注意用 hex（先摘要再转十六进制），不是 toHex（那是原始字节的十六进制）。
      final actual = Md5.hex(entity.bytes);
      if (actual != expected) {
        throw StateError('MD5 校验不一致（清单 $expected，实际 $actual）');
      }
      return <String>[entity.text];
    }

    // 形态二：正文就是脚本。
    if (looksLikeScript(download.text)) return <String>[download.text];

    // 形态三：地址清单，逐个再拉。
    final scripts = <String>[];
    final nested = urlsIn(download.text, limit: maxScripts);
    for (final item in nested) {
      if (scripts.length >= maxScripts) break;
      scripts.addAll(await scriptsAt(item, visited));
    }
    return scripts;
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
      SourceMetadataHeader.hasHeader(text) || text.contains('LumeSource');

  static bool isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
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
