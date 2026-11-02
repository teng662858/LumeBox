import 'source_subscription_catalog.dart';
import '../js/source_script.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/lume_http.dart';
import '../net/source_subscription.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'source.dart';

class SavedSourceSubscription {
  SavedSourceSubscription(
    this.url, {
    this.enabled = true,
    this.checkedAt,
    this.error = '',
    Map<String, String>? members,
    Set<String>? excludedIds,
  }) : members = members ?? {},
       excludedIds = excludedIds ?? {};
  final String url;
  bool enabled;
  DateTime? checkedAt;
  String error;
  Map<String, String> members;
  final Set<String> excludedIds;
  Map<String, Object?> toJson() => {
    'url': url,
    'enabled': enabled,
    'checkedAt': checkedAt?.toIso8601String(),
    'error': error,
    'members': members,
    'excludedIds': excludedIds.toList(),
  };
}

class SubscriptionSyncResult {
  int added = 0, updated = 0, removed = 0;
  int checked = 0, unchanged = 0, skipped = 0;
  String message = '';
  final List<String> errors = [];
  bool get changed => added + updated + removed > 0;
  String get summary => message.isNotEmpty
      ? message
      : '${checked > 0 ? '已检查 $checked 个订阅 · ' : ''}'
            '新增 $added · 更新 $updated · 移除 $removed'
            '${unchanged > 0 ? ' · 无变化 $unchanged' : ''}'
            '${skipped > 0 ? ' · 未到检查时间 $skipped' : ''}'
            '${errors.isEmpty ? '' : ' · 失败 ${errors.length}'}';
}

/// 地址与清单成员按板块落盘。网络/校验/导入不完整时禁止执行移除。
class SourceSubscriptionSync {
  SourceSubscriptionSync({
    required this.section,
    required this.manager,
    required this.file,
    this.fetch,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final Section section;
  final SourceManager manager;
  final File file;
  final Future<SourceFetchResult> Function(String url)? fetch;
  final DateTime Function() _clock;
  final List<SavedSourceSubscription> subscriptions = [];
  bool _migrated = false;
  static final Map<Section, Future<SubscriptionSyncResult>> _running = {};
  static final Set<Section> _forcedRunning = {};
  static final Map<Section, Future<SubscriptionSyncResult>> _pendingForced = {};
  static final Map<Section, ValueNotifier<int>> _revisions = {};
  static final _progress = <Section, ValueNotifier<String>>{};
  static ValueNotifier<String> progress(Section section) =>
      _progress.putIfAbsent(section, () => ValueNotifier(''));
  static final Map<Section, ValueNotifier<int>> _changeCounts = {};
  static final Map<Section, File> _noticeFiles = {};
  static final Map<Section, Map<String, Map<String, String>>> _changes = {};
  static Map<String, String>? notice(Section section, String id) =>
      _changes[section]?[id];
  static List<Map<String, String>> notices(Section section) =>
      List.unmodifiable(
        _changes[section]?.values ?? const <Map<String, String>>[],
      );
  static void recordChange(
    Section section,
    String id,
    String name,
    String status,
  ) {
    _recordChanges(section, [
      {'id': id, 'name': name, 'status': status},
    ]);
  }

  static void _recordChanges(
    Section section,
    Iterable<Map<String, String>> changes, {
    bool notifyRevision = true,
  }) {
    if (changes.isEmpty) return;
    final entries = _changes.putIfAbsent(section, () => {});
    for (final change in changes) {
      entries[change['id']!] = change;
    }
    final count = changeCount(section);
    if (count.value != entries.length) {
      count.value = entries.length;
    } else {
      final file = _noticeFiles[section];
      if (file != null) _saveChanges(section, file);
      if (notifyRevision) revision(section).value++;
    }
  }

  static void acknowledge(Section section) => changeCount(section).value = 0;
  static void _saveChanges(Section section, File file) {
    try {
      file.parent.createSync(recursive: true);
      final detail = File('${file.path}.json');
      final temporary = File('${detail.path}.tmp');
      temporary.writeAsStringSync(
        jsonEncode(_changes[section] ?? {}),
        flush: true,
      );
      temporary.renameSync(detail.path);
    } catch (error) {
      LumeLog.warn('订阅源变动详情保存失败：$error');
    }
  }

  static ValueNotifier<int> changeCount(Section section) =>
      _changeCounts.putIfAbsent(section, () {
        final count = ValueNotifier(0);
        count.addListener(() {
          if (count.value == 0) _changes[section]?.clear();
          final file = _noticeFiles[section];
          if (file == null) return;
          try {
            file.parent.createSync(recursive: true);
            final temporary = File('${file.path}.tmp');
            temporary.writeAsStringSync('${count.value}', flush: true);
            temporary.renameSync(file.path);
            _saveChanges(section, file);
          } catch (error) {
            LumeLog.warn('订阅提示保存失败：$error');
          }
        });
        return count;
      });
  static void attachNoticeFile(Section section, File file) {
    if (_noticeFiles[section]?.path == file.path) return;
    _noticeFiles[section] = file;
    try {
      final details = File('${file.path}.json');
      final decoded = details.existsSync()
          ? jsonDecode(details.readAsStringSync())
          : {};
      _changes[section] = decoded is Map
          ? decoded.map(
              (key, value) =>
                  MapEntry('$key', Map<String, String>.from(value as Map)),
            )
          : {};
      changeCount(section).value = file.existsSync()
          ? int.tryParse(file.readAsStringSync()) ?? 0
          : 0;
    } catch (_) {
      changeCount(section).value = 0;
    }
  }

  static ValueNotifier<int> revision(Section section) =>
      _revisions.putIfAbsent(section, () => ValueNotifier(0));

  static Future<SourceSubscriptionSync> open(
    Section section, {
    SourceManager? manager,
  }) async {
    final scope = await SectionScope.open(section);
    attachNoticeFile(section, File(scope.resolve('subscription-changes.txt')));
    final service = SourceSubscriptionSync(
      section: section,
      manager: manager ?? LumeSources.manager(section),
      file: File(scope.resolve('subscriptions.json')),
    );
    await service.load();
    if (service.manager.runtimeAvailable) await service._migrate();
    return service;
  }

  static Map<String, dynamic> validateDocument(Object? data) {
    if (data is! Map || data['subscriptions'] is! List) {
      throw const FormatException('订阅配置必须包含 subscriptions 数组');
    }
    for (final row in data['subscriptions'] as List) {
      if (row is! Map ||
          row['url'] is! String ||
          !SubscriptionCatalog.validUrl(row['url'] as String) ||
          row['enabled'] != null && row['enabled'] is! bool ||
          row['error'] != null && row['error'] is! String ||
          row['excludedIds'] != null &&
              (row['excludedIds'] is! List ||
                  (row['excludedIds'] as List).any((v) => v is! String)) ||
          row['members'] != null &&
              (row['members'] is! Map ||
                  (row['members'] as Map).entries.any(
                    (e) => e.key is! String || e.value is! String,
                  ))) {
        throw const FormatException('订阅记录的地址、启用状态、成员或排除列表格式错误');
      }
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> load() async {
    subscriptions.clear();
    if (!file.existsSync()) return;
    final data = validateDocument(jsonDecode(file.readAsStringSync()));
    _migrated = data['migrationVersion'] == 3;
    var normalized = false;
    for (final raw in (data['subscriptions'] as List? ?? [])) {
      if (raw is! Map || !_validUrl('${raw['url']}')) continue;
      final original = '${raw['url']}';
      final url = SubscriptionCatalog.canonical(original, section);
      normalized = normalized || url != original;
      final record = SavedSourceSubscription(
        url,
        enabled: raw['enabled'] != false,
        checkedAt: DateTime.tryParse('${raw['checkedAt']}'),
        error: '${raw['error'] ?? ''}',
        excludedIds: (raw['excludedIds'] as List? ?? [])
            .whereType<String>()
            .toSet(),
        members: (raw['members'] as Map? ?? {}).map(
          (key, value) => MapEntry('$key', '$value'),
        ),
      );
      final existing = subscriptions.where((s) => s.url == url).firstOrNull;
      if (existing == null) {
        if (url != original) record.checkedAt = null;
        subscriptions.add(record);
      } else {
        normalized = true;
        existing.members.addAll(record.members);
        existing.excludedIds.addAll(record.excludedIds);
        existing.enabled = existing.enabled || record.enabled;
        existing.checkedAt = null;
      }
    }
    if (normalized) await save();
  }

  Future<void> save() async {
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'migrated': _migrated,
        'migrationVersion': _migrated ? 3 : 0,
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
      }),
      flush: true,
    );
    temp.renameSync(file.path);
  }

  Future<void> register(Iterable<String> urls) async {
    for (final raw in urls) {
      final url = SubscriptionCatalog.canonical(raw.trim(), section);
      if (!_validUrl(url)) throw const FormatException('订阅地址须为完整 HTTP(S) 地址');
      final existing = subscriptions
          .where((record) => record.url == url)
          .firstOrNull;
      if (existing == null) {
        subscriptions.add(SavedSourceSubscription(url));
      } else {
        existing.excludedIds.clear();
        existing.checkedAt = null;
      }
    }
    await save();
  }

  static bool _validUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  Future<void> _migrate() async {
    if (_migrated) return;
    const prefix =
        'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/';
    // Saved roots already define ownership. Recover script URLs only when no roots exist.
    for (final source
        in subscriptions.isEmpty
            ? await manager.list()
            : const <SourceDescriptor>[]) {
      // 旧版本只保存脚本地址，官方清单可确定恢复；自定义清单需要首次保存根地址。
      if (!source.subscribed || !_validUrl(source.originUrl)) continue;
      final url = source.originUrl.startsWith('$prefix${section.id}/')
          ? '$prefix${SubscriptionCatalog.names[section] ?? '${section.id}/sources.txt'}'
          : source.originUrl;
      var record = subscriptions.where((s) => s.url == url).firstOrNull;
      if (record == null) {
        record = SavedSourceSubscription(url);
        subscriptions.add(record);
      }
      record.members[source.id] = source.originUrl;
    }
    // Upgrade once: fetch revised source scripts without waiting out the old interval.
    for (final record in subscriptions) {
      record.checkedAt = null;
    }
    _migrated = true;
    await save();
  }

  Future<void> _recoverMembers() async {
    final sources = await manager.list();
    for (final source in sources) {
      if (!source.subscribed ||
          subscriptions.any((s) => s.members.containsKey(source.id))) {
        continue;
      }
      final exact = subscriptions
          .where(
            (s) => SubscriptionCatalog.sameSourceUrl(s.url, source.originUrl),
          )
          .firstOrNull;
      if (exact != null) {
        exact.members[source.id] = source.originUrl;
        continue;
      }
      final sourcePath = SubscriptionCatalog.officialPath(source.originUrl);
      final folders = switch (section) {
        Section.comic => ['comic/', 'photo/'],
        Section.video => ['video/', 'movie/', 'audiobook/'],
        _ => <String>[],
      };
      if (sourcePath == null || !folders.any(sourcePath.startsWith)) continue;
      final owners = subscriptions.where((record) {
        final path = SubscriptionCatalog.officialPath(record.url);
        return path == SubscriptionCatalog.names[section] ||
            path ==
                SubscriptionCatalog.names[section]?.replaceFirst(
                  'subscriptions/',
                  'subscriptions/cdn/',
                ) ||
            path == 'subscriptions/all.json' ||
            path == 'subscriptions/cdn/all.json';
      }).toList();
      if (owners.isEmpty) continue;
      // 优先沿用原线路；只恢复明确属于官方完整订阅的旧源。
      final owner =
          owners
              .where(
                (s) =>
                    s.url.startsWith(SubscriptionCatalog.cdnBase) ==
                    source.originUrl.startsWith(SubscriptionCatalog.cdnBase),
              )
              .firstOrNull ??
          owners.first;
      owner.members[source.id] = source.originUrl;
    }
  }

  Future<SubscriptionSyncResult> sync({bool force = false}) async {
    final result = SubscriptionSyncResult();
    final changes = <Map<String, String>>[];
    var downloaded = 0;
    if (!manager.runtimeAvailable) {
      return result..errors.add('当前平台无法运行 JS 源，订阅未同步');
    }
    await _migrate();
    await _recoverMembers();
    if (!subscriptions.any((s) => s.enabled)) {
      return result..message = '没有已启用的订阅，请先添加订阅地址';
    }
    final http = LumeHttp(source: '${section.label}订阅自动同步');
    final fetcher =
        fetch ??
        (String url) =>
            SourceSubscription.fetchSubscription(http, url, force: force);
    try {
      for (final record in subscriptions.where((s) => s.enabled)) {
        final interval = record.error.isEmpty
            ? const Duration(hours: 6)
            : const Duration(minutes: 30);
        if (!force &&
            record.checkedAt != null &&
            _clock().difference(record.checkedAt!) < interval) {
          result.skipped++;
          continue;
        }
        result.checked++;
        record.checkedAt = _clock();
        final previousErrors = result.errors.length;
        try {
          final resolver = SourceSubscription(
            section: section.id,
            maxScripts: SourceSubscription.defaultMaxScripts,
            strictManifest: true,
            onSkip: (url, error) => result.errors.add('$url: $error'),
            fetch: (url) async {
              progress(section).value =
                  '正在下载 · 已完成 $downloaded 个文件 · ${Uri.tryParse(url)?.pathSegments.lastOrNull ?? "订阅"}';
              final value = await fetcher(url);
              downloaded++;
              progress(section).value = '已下载 $downloaded 个文件';
              return value;
            },
          );
          final refs = await resolver.resolveRefs([record.url]);
          final before = {for (final s in await manager.list()) s.id: s};
          final next = <String, String>{
            for (final entry in record.members.entries)
              if (record.excludedIds.contains(entry.key))
                entry.key: entry.value,
          };
          var complete = resolver.complete;
          var processed = 0;
          for (final ref in refs) {
            try {
              processed++;
              final declaredName =
                  SourceMetadata.parseHeader(ref.script)?.name ?? '源脚本';
              progress(section).value =
                  '正在校验 $processed/${refs.length} · $declaredName';
              // Yield to Flutter between scripts so the progress can be painted.
              await Future<void>.delayed(Duration.zero);
              final declaredId = SourceMetadata.parseHeader(ref.script)?.id;
              if (record.excludedIds.contains(declaredId) ||
                  record.members.entries.any(
                    (entry) =>
                        record.excludedIds.contains(entry.key) &&
                        entry.value == ref.url,
                  )) {
                continue;
              }
              final old = before.values
                  .where(
                    (s) =>
                        SubscriptionCatalog.sameSourceUrl(s.originUrl, ref.url),
                  )
                  .firstOrNull;
              if (old != null &&
                  await manager.exportScript(old.id) == ref.script) {
                next[old.id] = ref.url;
                result.unchanged++;
                continue;
              }
              final imported = manager is SubscriptionImportManager
                  ? await (manager as SubscriptionImportManager)
                        .importSubscription(ref.script, originUrl: ref.url)
                  : await manager.importScript(ref.script, originUrl: ref.url);
              final descriptor = imported.descriptor;
              if (descriptor == null) {
                complete = false;
                result.errors.add('${ref.url}: ${imported.message}');
                continue;
              }
              next[descriptor.id] = ref.url;
              if (before.containsKey(descriptor.id)) {
                result.updated++;
                changes.add({
                  'id': descriptor.id,
                  'name': descriptor.name,
                  'status':
                      '已更新 ${sourceVersionChange(before[descriptor.id]!.version, descriptor.version)}',
                });
              } else {
                result.added++;
                changes.add({
                  'id': descriptor.id,
                  'name': descriptor.name,
                  'status': '已新增',
                });
              }
            } catch (error) {
              complete = false;
              result.errors.add('${ref.url}: $error');
            }
          }
          if (complete) {
            for (final old in record.members.entries) {
              if (next.containsKey(old.key)) continue;
              if (subscriptions.any(
                (s) => s != record && s.members.containsKey(old.key),
              )) {
                continue;
              }
              final existing = before[old.key];
              if (existing == null ||
                  (!SubscriptionCatalog.sameSourceUrl(
                        existing.originUrl,
                        old.value,
                      ) &&
                      !SubscriptionCatalog.sameSourceUrl(
                        existing.originUrl,
                        record.url,
                      ))) {
                continue;
              }
              await manager.remove(old.key);
              result.removed++;
              changes.add({
                'id': existing.id,
                'name': existing.name,
                'status': '已移除',
              });
            }
            record.members = next;
            record.error = '';
          } else {
            record.members = {...record.members, ...next};
            record.error = '清单未完整同步，已保留旧源';
            if (result.errors.length == previousErrors) {
              result.errors.add('${record.url}: ${record.error}');
            }
          }
        } catch (error) {
          record.error = '$error';
          result.errors.add('${record.url}: $error');
        }
        await save();
      }
    } finally {
      http.dispose();
      progress(section).value = '';
      // Persist and invalidate once per batch. Per-source revisions repeatedly
      // cancel and restart the visible page while a large subscription updates.
      _recordChanges(section, changes, notifyRevision: false);
      if (result.changed) revision(section).value++;
    }
    if (result.changed || result.errors.isNotEmpty) {
      LumeLog.info('[订阅] ${section.label}: ${result.summary}');
    }
    return result;
  }

  static Future<SubscriptionSyncResult> refresh(
    Section section, {
    bool force = false,
    SourceManager? manager,
    Future<SourceFetchResult> Function(String url)? fetch,
  }) {
    // 桌面版是 UI 骨架，测试的运行时覆盖不应启动真实后台 IO。
    if (!Platform.isIOS &&
        !Platform.isAndroid &&
        (manager == null || fetch == null)) {
      return Future.value(
        SubscriptionSyncResult()
          ..message = force ? '当前桌面平台无法运行 JS 源，订阅未同步' : '',
      );
    }
    SectionScope.registerShutdownHook('subscription-sync', () async {
      await Future.wait({..._running.values, ..._pendingForced.values});
      for (final section in Section.values) {
        LumeSources.manager(section).close();
      }
    });
    final active = _running[section];
    if (active != null) {
      if (!force || _forcedRunning.contains(section)) return active;
      // A manual refresh must not inherit a background task's cooldown skip.
      return _pendingForced.putIfAbsent(section, () async {
        try {
          await active;
          return await refresh(
            section,
            force: true,
            manager: manager,
            fetch: fetch,
          );
        } finally {
          _pendingForced.remove(section);
        }
      });
    }
    if (force) _forcedRunning.add(section);
    return _running[section] = _refresh(section, force, manager, fetch);
  }

  static Future<SubscriptionSyncResult> _refresh(
    Section section,
    bool force,
    SourceManager? manager,
    Future<SourceFetchResult> Function(String url)? fetch,
  ) async {
    try {
      final service = await open(section, manager: manager);
      if (fetch == null) return await service.sync(force: force);
      final injected = SourceSubscriptionSync(
        section: section,
        manager: service.manager,
        file: service.file,
        fetch: fetch,
      );
      await injected.load();
      return await injected.sync(force: force);
    } catch (error) {
      final result = SubscriptionSyncResult();
      result.errors.add('$error');
      LumeLog.warn('[订阅] ${section.label}自动同步失败: $error');
      return result;
    } finally {
      _running.remove(section);
      _forcedRunning.remove(section);
    }
  }

  static Future<void> remember(
    Section section,
    Iterable<String> urls, {
    SourceManager? manager,
  }) async {
    await waitForIdle(section);
    await (await open(section, manager: manager)).register(urls);
  }

  /// Serializes destructive source maintenance with automatic subscription sync.
  static Future<T> maintenance<T>(
    Section section,
    Future<T> Function() action,
  ) async {
    while (_running[section] != null) {
      await _running[section];
    }
    final completion = Completer<SubscriptionSyncResult>();
    _running[section] = completion.future;
    try {
      return await action();
    } finally {
      completion.complete(SubscriptionSyncResult());
      if (identical(_running[section], completion.future)) {
        _running.remove(section);
      }
      revision(section).value++;
    }
  }

  Future<void> markRemoved(Iterable<SourceDescriptor> removed) async {
    for (final source in removed) {
      for (final record in subscriptions) {
        if (record.members.containsKey(source.id) ||
            record.url == source.originUrl) {
          record.members[source.id] = source.originUrl;
          record.excludedIds.add(source.id);
        }
      }
    }
    await save();
  }

  Future<void> clearSavedSubscriptions() async {
    subscriptions.clear();
    _migrated = true;
    await save();
  }

  static Future<void> waitForIdle(Section section) async {
    while (_running[section] != null || _pendingForced[section] != null) {
      await (_pendingForced[section] ?? _running[section]);
    }
  }
}
