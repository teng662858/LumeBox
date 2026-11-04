import 'source_subscription_catalog.dart';
export 'source_subscription_catalog.dart';

import 'dart:convert';

import '../net/lume_http.dart';
import '../net/source_subscription.dart';
import '../session/section.dart';
import 'source.dart';
import 'source_subscription_sync.dart';

class TotalSubscription {
  TotalSubscription(this.entries);
  static const format = 'lume.total-subscription';
  final Map<Section, List<({String url, bool enabled})>> entries;
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'format': format,
    'version': 1,
    'sections': {
      for (final entry in entries.entries)
        entry.key.id: [
          for (final item in entry.value)
            {'url': item.url, 'enabled': item.enabled},
        ],
    },
  });
  factory TotalSubscription.decode(String text) {
    final data = jsonDecode(stripBomText(text));
    if (data is! Map ||
        data['format'] != format ||
        data['version'] != 1 ||
        data['sections'] is! Map) {
      throw const FormatException('不是支持的 LumeBox 总订阅文件');
    }
    final entries = <Section, List<({String url, bool enabled})>>{};
    for (final entry in (data['sections'] as Map).entries) {
      if (entry.key == 'novel') continue;
      final section = SubscriptionCatalog.sections
          .where((s) => s.id == entry.key)
          .firstOrNull;
      if (section == null || entry.value is! List) {
        throw const FormatException('总订阅板块格式错误');
      }
      if ((entry.value as List).length > 100) {
        throw const FormatException('单个版块最多100个订阅地址');
      }
      final seen = <String>{};
      entries[section] = [
        for (final raw in entry.value as List)
          (() {
            final url = raw is String
                ? raw
                : raw is Map && raw['url'] is String
                ? raw['url'] as String
                : '';
            if (!SubscriptionCatalog.validUrl(url)) {
              throw const FormatException('总订阅中包含无效的 HTTP(S) 地址');
            }
            final canonical = SubscriptionCatalog.canonical(url, section);
            if (!seen.add(canonical)) throw const FormatException('总订阅包含重复地址');
            if (raw is Map &&
                raw['enabled'] != null &&
                raw['enabled'] is! bool) {
              throw const FormatException('订阅启用状态格式错误');
            }
            return (
              url: canonical,
              enabled: raw is! Map || raw['enabled'] != false,
            );
          })(),
      ];
    }
    if (entries.isEmpty) throw const FormatException('总订阅未包含任何版块');
    return TotalSubscription(entries);
  }
}

class TotalSubscriptionService {
  TotalSubscriptionService({this.managers = const {}, this.fetch});
  final Map<Section, SourceManager> managers;
  final Future<SourceFetchResult> Function(String url)? fetch;
  Future<TotalSubscription> read(String input) async {
    final text = stripBomText(input).trim();
    if (text.startsWith('{')) return TotalSubscription.decode(text);
    if (!SubscriptionCatalog.validUrl(text)) {
      throw const FormatException('请粘贴总订阅地址或总订阅 JSON');
    }
    if (fetch != null) {
      return TotalSubscription.decode(
        (await fetch!(SubscriptionCatalog.migrateUrl(text))).text,
      );
    }
    final http = LumeHttp(source: '总订阅导入');
    try {
      final response = await SourceSubscription.fetchSubscription(http, text);
      return TotalSubscription.decode(response.text);
    } finally {
      http.dispose();
    }
  }

  Future<TotalSubscription> export() async {
    final entries = <Section, List<({String url, bool enabled})>>{};
    for (final section in SubscriptionCatalog.sections) {
      await SourceSubscriptionSync.waitForIdle(section);
      final service = await SourceSubscriptionSync.open(
        section,
        manager: managers[section],
      );
      entries[section] = [
        for (final record in service.subscriptions)
          (url: record.url, enabled: record.enabled),
      ];
    }
    return TotalSubscription(entries);
  }

  Future<Map<Section, SubscriptionSyncResult>> import(
    TotalSubscription total, {
    bool installAll = false,
  }) async {
    total = TotalSubscription.decode(total.encode());
    final results = <Section, SubscriptionSyncResult>{};
    for (final entry in total.entries.entries) {
      try {
        results[entry.key] = await SourceSubscriptionSync.maintenance(
          entry.key,
          () async {
            final stored = await SourceSubscriptionSync.open(
              entry.key,
              manager: managers[entry.key],
            );
            for (final item in entry.value) {
              final existing = stored.subscriptions
                  .where((s) => s.url == item.url)
                  .firstOrNull;
              if (existing == null) {
                stored.subscriptions.add(
                  SavedSourceSubscription(item.url, enabled: item.enabled),
                );
              } else {
                existing.enabled = item.enabled;
                existing.checkedAt = null;
              }
            }
            await stored.save();
            final service = SourceSubscriptionSync(
              section: entry.key,
              manager: stored.manager,
              file: stored.file,
              fetch: fetch,
            );
            await service.load();
            if (!stored.manager.runtimeAvailable) {
              return SubscriptionSyncResult()
                ..errors.add('订阅地址已保存，当前平台无法运行 JS 源');
            }
            return service.sync(
              force: true,
              installNewFor: installAll
                  ? entry.value
                        .where((item) => item.enabled)
                        .map((item) => item.url)
                        .toSet()
                  : const {},
            );
          },
        );
      } catch (error) {
        results[entry.key] = SubscriptionSyncResult()..errors.add('$error');
      }
    }
    return results;
  }
}
