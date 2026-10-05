import 'dart:convert';

import '../js/source_registry.dart';
import '../session/section.dart';
import '../util/lume_log.dart';
import 'lume_sources.dart';

/// 图源备份包：四个板块的图源清单 + 元信息。
///
/// 备份**只含脚本与元数据**，不含缓存、Cookie、阅读记录等敏感数据（文档要求
/// 「排除缓存、Cookie 等敏感数据」）。
///
/// 网络覆盖（UA / 代理）与 Cookie 的处理：
/// - `userAgent` / `proxy` 属于用户对该图源的配置，随备份走；
/// - `cookie` **不写入备份**——它是登录态凭据，导出文件可能被分享，带上它等于
///   泄露账号。恢复时该字段留空（用户需要时自己重填）。
class SourceBackup {
  const SourceBackup({
    required this.version,
    required this.createdAt,
    required this.sections,
  });

  /// 备份格式版本：将来格式变化时据此兼容。
  static const int currentVersion = 1;

  static const String fileExtension = 'lumesources.json';

  final int version;
  final DateTime createdAt;

  /// 板块 id → 该板块的图源条目。
  final Map<String, List<SourceBackupEntry>> sections;

  /// 备份里的图源总数。
  int get totalCount =>
      sections.values.fold(0, (sum, entries) => sum + entries.length);

  Map<String, Object?> toJson() => <String, Object?>{
        'format': 'lume.sources',
        'version': version,
        'createdAt': createdAt.toIso8601String(),
        'sections': <String, Object?>{
          for (final entry in sections.entries)
            entry.key: <Object?>[for (final item in entry.value) item.toJson()],
        },
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析备份文本。格式不符时抛 [FormatException]（带可读原因）。
  static SourceBackup decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (error) {
      throw FormatException('不是合法的 JSON：$error');
    }
    if (json is! Map) throw const FormatException('备份内容不是对象');
    if (json['format'] != 'lume.sources') {
      throw const FormatException('不是 Lume Box 图源备份（缺少 format 标记）');
    }
    final version = json['version'];
    if (version is! int || version > currentVersion) {
      throw FormatException('备份版本不支持：$version（当前支持到 $currentVersion）');
    }

    final rawSections = json['sections'];
    if (rawSections is! Map) throw const FormatException('备份缺少 sections');

    final sections = <String, List<SourceBackupEntry>>{};
    for (final entry in rawSections.entries) {
      final sectionId = '${entry.key}';
      final rawList = entry.value;
      if (rawList is! List) continue;
      final items = <SourceBackupEntry>[];
      for (final raw in rawList) {
        final parsed = SourceBackupEntry.parse(raw);
        if (parsed != null) items.add(parsed);
      }
      sections[sectionId] = items;
    }

    final createdAt =
        DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now();
    return SourceBackup(version: version, createdAt: createdAt, sections: sections);
  }
}

/// 备份里的一条图源。
class SourceBackupEntry {
  const SourceBackupEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.script,
    required this.enabled,
    this.originUrl = '',
    this.userAgent = '',
    this.proxy = '',
  });

  final String id;
  final String name;
  final String version;
  final String script;
  final bool enabled;

  /// 订阅来源地址（订阅导入的图源才有）。
  final String originUrl;

  /// 图源级 UA / 代理（不含 Cookie，见 [SourceBackup] 的说明）。
  final String userAgent;
  final String proxy;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'version': version,
        'script': script,
        'enabled': enabled,
        if (originUrl.isNotEmpty) 'originUrl': originUrl,
        if (userAgent.isNotEmpty) 'userAgent': userAgent,
        if (proxy.isNotEmpty) 'proxy': proxy,
      };

  static SourceBackupEntry? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    final script = '${json['script'] ?? ''}';
    if (id.isEmpty || script.trim().isEmpty) return null;
    return SourceBackupEntry(
      id: id,
      name: '${json['name'] ?? id}',
      version: '${json['version'] ?? ''}',
      script: script,
      enabled: json['enabled'] != false,
      originUrl: '${json['originUrl'] ?? ''}',
      userAgent: '${json['userAgent'] ?? ''}',
      proxy: '${json['proxy'] ?? ''}',
    );
  }
}

/// 一次恢复的结果。
class SourceRestoreResult {
  const SourceRestoreResult({
    required this.imported,
    required this.updated,
    required this.failed,
    required this.skipped,
  });

  /// 新导入的图源数（原本没有）。
  final int imported;

  /// 覆盖更新的图源数（原本已有同 id）。
  final int updated;

  /// 恢复失败数（脚本不合法、引擎拒绝等）。
  final int failed;

  /// 跳过的条目数（备份里归属板块非法等）。
  final int skipped;

  int get total => imported + updated + failed + skipped;

  String describe() => '恢复完成：新增 $imported'
      '${updated > 0 ? ' · 覆盖 $updated' : ''}'
      '${failed > 0 ? ' · 失败 $failed' : ''}'
      '${skipped > 0 ? ' · 跳过 $skipped' : ''}';
}

/// 图源备份与恢复（文档第 4 条：批量备份 / 恢复图源）。
///
/// 备份是**纯读取**：只读四个板块的图源记录，不动任何状态。
/// 恢复走的是与导入完全相同的校验路径（脚本载入 → 元信息 → 落库），因此坏脚本
/// 进不来；单个条目失败不中断其余恢复。
///
/// 隔离：每个板块只写自己的库（备份里板块 id 非法或平台无运行时即跳过），
/// 不会把 A 板块的图源写进 B 板块。
class SourceBackupService {
  SourceBackupService({this.runtimeAvailableFor});

  /// 平台运行时判定（测试可注入）；为空时用 [LumeSources.runtimeAvailableFor]。
  final bool Function(Section section)? runtimeAvailableFor;

  bool _available(Section section) =>
      runtimeAvailableFor?.call(section) ?? LumeSources.runtimeAvailableFor(section);

  /// 导出备份：四个板块的全部图源（只读）。
  ///
  /// 某个板块的库打不开时该板块留空并记日志，不阻断其余板块。
  Future<SourceBackup> export() async {
    final sections = <String, List<SourceBackupEntry>>{};
    for (final section in Section.values) {
      if (!_available(section)) {
        sections[section.id] = const <SourceBackupEntry>[];
        continue;
      }
      try {
        final registry = await SourceRegistry.open(section);
        sections[section.id] = <SourceBackupEntry>[
          for (final record in registry.sources)
            SourceBackupEntry(
              id: record.id,
              name: record.name,
              version: record.version,
              script: record.script,
              enabled: record.enabled,
              originUrl: record.originUrl,
              userAgent: record.network.userAgent,
              proxy: record.network.proxy,
            ),
        ];
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
        LumeLog.warn('[${section.id}] 备份跳过该板块：$error');
        sections[section.id] = const <SourceBackupEntry>[];
      }
    }
    return SourceBackup(
      version: SourceBackup.currentVersion,
      createdAt: DateTime.now(),
      sections: sections,
    );
  }

  /// 恢复备份：按板块逐个导入。
  ///
  /// 同 id 的图源按**覆盖**处理（备份里的脚本与配置优先）；单个失败不中断。
  Future<SourceRestoreResult> restore(SourceBackup backup) async {
    var imported = 0;
    var updated = 0;
    var failed = 0;
    var skipped = 0;

    for (final entry in backup.sections.entries) {
      final section = _sectionOf(entry.key);
      if (section == null || !_available(section)) {
        skipped += entry.value.length;
        continue;
      }

      final registry = await SourceRegistry.open(section);
      final existing = <String>{for (final record in registry.sources) record.id};

      for (final item in entry.value) {
        try {
          final outcome = await registry.import(
            item.script,
            originUrl: item.originUrl,
          );
          final record = outcome.record;
          if (record == null) {
            failed++;
            LumeLog.warn('[${section.id}] 恢复失败 ${item.id}: ${outcome.message}');
            continue;
          }
          // 启停状态与网络覆盖属于备份里的用户配置，恢复时一并写回。
          registry.setEnabled(record.id, item.enabled);
          if (item.userAgent.isNotEmpty || item.proxy.isNotEmpty) {
            registry.setSourceNetwork(
              record.id,
              userAgent: item.userAgent,
              cookie: '',
              proxy: item.proxy,
            );
          }
          if (existing.contains(record.id)) {
            updated++;
          } else {
            imported++;
          }
        } catch (error, stackTrace) {
          failed++;
          LumeLog.error(error, stackTrace);
        }
      }
    }

    return SourceRestoreResult(
      imported: imported,
      updated: updated,
      failed: failed,
      skipped: skipped,
    );
  }

  static Section? _sectionOf(String id) {
    for (final section in Section.values) {
      if (section.id == id) return section;
    }
    return null;
  }
}
