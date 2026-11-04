import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../js/source_script.dart';
import 'source_content_category.dart';
import 'source_media_hints.dart';
import 'source_package.dart';

class SourceScriptPresentation {
  const SourceScriptPresentation({
    required this.runtimeKind,
    required this.mediaKind,
    required this.contentCategory,
    this.mixedContent = false,
    required this.siteUrl,
    required this.iconUrl,
    this.network = '',
  });
  final String runtimeKind, mediaKind, contentCategory, siteUrl, iconUrl;
  final bool mixedContent;

  /// 脚本声明的站点网络要求（direct / proxy / 空）。
  final String network;

  factory SourceScriptPresentation.fromScript(String script) =>
      SourceScriptPresentation(
        runtimeKind: SourcePackage.kindOf(script).name,
        mediaKind: SourceMediaHints.fromScript(script),
        contentCategory: SourceContentCategories.fromScript(script),
        mixedContent: SourceContentCategories.mixedFromScript(script),
        siteUrl: siteUrlFromScript(script),
        iconUrl: _iconUrl(script),
        network: (SourceMetadata.parseHeader(script)?.network ?? '').trim(),
      );

  static String siteUrlFromScript(String script) {
    // 站点根有两种写法：单值（`BASE_URL = 'https://a.com'` / `H.base="https://a.com"`）
    // 与主机列表（`var HOSTS = ['https://a.com', 'https://a.net']`，多域名备用）。
    // 两种都要认：源站地址是「取源图标」「报错时告诉用户打开的是哪个站」的依据，
    // 认不出来这些源就只能永远显示首字母。
    final single = RegExp(
      r'''\b(?:BASE_URL|BASE|HOST|baseURL|baseUrl|base_url|base|host|H\.base)\s*[:=]\s*['"](https?://[^'"]+)''',
    ).firstMatch(script);
    final host =
        single?.group(1) ??
        _firstHost(script) ??
        SourceMetadata.parseHeader(script)?.mirrors.firstOrNull;
    final uri = Uri.tryParse(host ?? '');
    return uri != null && uri.host.isNotEmpty && uri.userInfo.isEmpty
        ? uri.origin
        : '';
  }

  /// `HOSTS = ['https://a.com', …]` / `HOSTS = ["https://a.com"]` 里的第一个主机。
  static String? _firstHost(String script) {
    final match = RegExp(r'''HOSTS\s*=\s*\[\s*['"](https?://[^'"]+)''')
        .firstMatch(script);
    return match?.group(1);
  }

  static String _iconUrl(String script) {
    final match = RegExp(
      r'^\s*(?://\s*@?|#\s*)LumeSource\s*[:=]\s*(\{[^\n]+\})',
      multiLine: true,
    ).firstMatch(script);
    if (match == null) return '';
    try {
      final metadata = jsonDecode(match.group(1)!) as Map<String, dynamic>;
      final value = metadata['icon'] ?? metadata['iconUrl'];
      if (value is! String) return '';
      final declared = Uri.tryParse(value.trim());
      final site = Uri.tryParse(siteUrlFromScript(script));
      final uri = declared == null
          ? null
          : (site?.hasScheme == true ? site!.resolveUri(declared) : declared);
      return uri != null &&
              {'http', 'https'}.contains(uri.scheme) &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty
          ? uri.toString()
          : '';
    } on Object {
      return '';
    }
  }
}

List<SourceScriptPresentation> _parsePresentations(List<String> scripts) =>
    scripts.map(SourceScriptPresentation.fromScript).toList(growable: false);

/// Cache only script-derived presentation, never mutable source settings.
class SourcePresentationCache {
  SourcePresentationCache({
    this.maxEntries = 512,
    this.maxCharacters = 8 * 1024 * 1024,
  });
  final int maxEntries, maxCharacters;
  final _entries = <String, ({String script, SourceScriptPresentation info})>{};
  int _characters = 0, _generation = 0;
  Future<void>? _pending;

  SourceScriptPresentation? _cached(String key, String script) {
    final entry = _entries[key];
    return entry != null && entry.script == script ? entry.info : null;
  }

  void _remember(String key, String script, SourceScriptPresentation info) {
    final previous = _entries.remove(key);
    if (previous != null) _characters -= previous.script.length;
    if (script.length > maxCharacters) return;
    _entries[key] = (script: script, info: info);
    _characters += script.length;
    while (_entries.length > maxEntries || _characters > maxCharacters) {
      _characters -= _entries.remove(_entries.keys.first)!.script.length;
    }
  }

  SourceScriptPresentation read(String key, String script) {
    final cached = _cached(key, script);
    if (cached != null) return cached;
    final info = SourceScriptPresentation.fromScript(script);
    _remember(key, script, info);
    return info;
  }

  Future<List<SourceScriptPresentation>> prepare(
    List<({String key, String script})> scripts,
  ) async {
    while (_pending != null) {
      await _pending;
    }
    final known = <String, SourceScriptPresentation>{};
    final missing = <({String key, String script})>[];
    for (final item in scripts) {
      final cached = _cached(item.key, item.script);
      if (cached == null) {
        missing.add(item);
      } else {
        known[item.key] = cached;
      }
    }
    if (missing.isEmpty) {
      return scripts.map((s) => known[s.key]!).toList(growable: false);
    }
    final generation = _generation;
    final work = compute(
      _parsePresentations,
      missing.map((s) => s.script).toList(growable: false),
    );
    final task = work.then((infos) {
      for (var i = 0; i < missing.length; i++) {
        known[missing[i].key] = infos[i];
        if (generation == _generation) {
          _remember(missing[i].key, missing[i].script, infos[i]);
        }
      }
    });
    _pending = task;
    try {
      await task;
    } finally {
      if (identical(_pending, task)) _pending = null;
    }
    // Even catalogs larger than the bounded cache never fall back to parsing
    // evicted entries synchronously on the UI isolate.
    return scripts.map((s) => known[s.key]!).toList(growable: false);
  }

  void remove(String key) {
    final entry = _entries.remove(key);
    if (entry != null) _characters -= entry.script.length;
  }

  void clearSection(String section) {
    _generation++;
    for (final key
        in _entries.keys.where((k) => k.startsWith('$section/')).toList()) {
      remove(key);
    }
  }
}
