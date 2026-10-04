import '../db/section_database.dart';
import '../db/source_record.dart';
import '../net/lume_http.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'cat_engines.dart';
import 'lume_js_engine.dart';
import 'source_engine.dart';
import 'source_script.dart';

/// 图源导入结果：成功携带落库记录，失败携带可读原因。
///
/// 只表达「校验与落库」这一步的结论，不含任何展示口径；上层据此组织提示。
class SourceImportOutcome {
  const SourceImportOutcome.success(this.record) : message = null;

  const SourceImportOutcome.failure(this.message) : record = null;

  final SourceRecord? record;

  /// 失败原因（成功时为 null）。
  final String? message;

  bool get isSuccess => record != null;
}

/// 板块级图源注册表。
///
/// 每个板块各自持有一份：图源记录、JS 引擎、HTTP 客户端全部在板块内闭环，
/// 不存在跨板块的共享状态。图源记录另带归属板块标记（见 [SourceRecord.section]）：
/// 标记与本板块不符的记录在列出、加载、启停、删除四条路径上都被当作不存在，
/// 脚本因此只可能从本板块的库里读出来执行。
class SourceRegistry {
  SourceRegistry._(this.section, this._database, this._http);

  final Section section;
  final SectionDatabase _database;
  final LumeHttp _http;

  static final Map<String, SourceRegistry> _registries =
      <String, SourceRegistry>{};

  /// 引擎表：存端口而不是具体引擎——猫源在 Android 上可能是 Node-Mobile。
  final Map<String, SourceEngine> _engines = <String, SourceEngine>{};

  /// 当前图源的设置键。板块级设置，落在本板块库里。
  static const String currentSourceKey = 'current_source';

  static Future<SourceRegistry> open(Section section) async {
    final existing = _registries[section.id];
    if (existing != null) return existing;
    final scope = await SectionScope.open(section);
    final registry = SourceRegistry._(
      section,
      await SectionDatabase.open(scope),
      LumeHttp(),
    );
    _registries[section.id] = registry;
    return registry;
  }

  /// 本板块在当前平台是否有可用引擎。
  ///
  /// 猫源在 Android 上也有引擎（QuickJS / Node-Mobile 二选一，见 [CatEngines]）；
  /// 其余板块维持既有口径（仅 iOS）。
  bool get _engineAvailable =>
      section == Section.cat ? CatEngines.available : LumeJsEngine.isSupported;

  /// 本板块的图源记录。归属标记不符的记录一律不返回。
  List<SourceRecord> get sources =>
      _database.sources().where(_belongs).toList(growable: false);

  /// 本板块的单条图源。不存在或归属不符时返回 null。
  SourceRecord? source(String sourceId) {
    final record = _database.source(sourceId);
    return record != null && _belongs(record) ? record : null;
  }

  /// 板块内当前图源：选择过且仍在用、仍启用的那一个；否则回退到排序后
  /// 第一个启用的图源。板块内没有启用图源时返回 null。
  ///
  /// 图源被停用或删除后不会留下脏值——选择失效即自动回退。
  SourceRecord? currentSource() {
    final enabled =
        sources.where((record) => record.enabled).toList(growable: false);
    if (enabled.isEmpty) return null;
    final selected = _database.setting(currentSourceKey);
    if (selected != null) {
      for (final record in enabled) {
        if (record.id == selected) return record;
      }
    }
    return enabled.first;
  }

  /// 设定当前图源。只接受本板块且已启用的图源，成功返回该记录。
  SourceRecord? selectSource(String sourceId) {
    final record = source(sourceId);
    if (record == null || !record.enabled) return null;
    _database.setSetting(currentSourceKey, record.id);
    return record;
  }

  /// 校验脚本并把元信息写入本板块数据库。
  ///
  /// 失败返回带可读原因的失败结果：平台无引擎、脚本载入失败（语法错误或运行
  /// 异常）、脚本缺少 `LumeSource` 元信息（id / name）或 id 非法。
  Future<SourceImportOutcome> import(String script) async {
    if (!_engineAvailable) {
      LumeLog.warn('[${section.id}] 当前平台不提供图源引擎');
      return const SourceImportOutcome.failure('当前平台不提供图源引擎');
    }
    final probe = await SourceEngineRegistry.create(
      kind: CatEngineSettings.engineKindFor(section, _database),
      sourceId: 'probe${DateTime.now().microsecondsSinceEpoch}',
      http: _http,
      section: section,
    );
    if (probe == null) {
      return const SourceImportOutcome.failure('当前平台不提供该图源引擎（引擎未集成或原生不可用）');
    }
    try {
      if (!await probe.loadScript(script)) {
        return const SourceImportOutcome.failure('脚本载入失败：语法错误或运行异常');
      }
      final metadata = SourceMetadata.parse(await probe.metadata());
      if (metadata == null) {
        return const SourceImportOutcome.failure(
          '脚本缺少 LumeSource 元信息（id / name），或 id 非法',
        );
      }
      _database.upsertSource(
        id: metadata.id,
        name: metadata.name,
        version: metadata.version,
        section: section.id,
        script: script,
      );
      release(metadata.id);
      final record = _database.source(metadata.id);
      if (record == null) {
        return const SourceImportOutcome.failure('图源写入本板块库失败');
      }
      return SourceImportOutcome.success(record);
    } finally {
      probe.dispose();
    }
  }

  void remove(String sourceId) {
    if (!_owns(sourceId)) return;
    release(sourceId);
    _database.deleteSource(sourceId);
  }

  void setEnabled(String sourceId, bool enabled) {
    if (!_owns(sourceId)) return;
    if (!enabled) release(sourceId);
    _database.setSourceEnabled(sourceId, enabled);
  }

  /// 取得图源运行时，按需创建并载入脚本。图源之间不共享引擎。
  ///
  /// 返回端口而不是具体引擎：猫源在 Android 上可能是 Node-Mobile，
  /// 调用方（数据源适配层）只依赖 [SourceEngine] 的四套能力。
  Future<SourceEngine?> engineFor(String sourceId) async {
    final existing = _engines[sourceId];
    if (existing != null) return existing;
    final record = _database.source(sourceId);
    if (record == null || !_belongs(record) || !record.enabled) return null;
    if (!_engineAvailable) return null;
    // 运行时分支：猫源按自己的选择取引擎（Android 可二选一），其余板块恒为 QuickJS。
    final engine = await SourceEngineRegistry.create(
      kind: CatEngineSettings.engineKindFor(section, _database),
      sourceId: sourceId,
      http: _http,
      section: section,
    );
    if (engine == null) {
      LumeLog.warn('[${section.id}] 图源引擎不可用: $sourceId');
      return null;
    }
    if (!await engine.loadScript(record.script)) {
      engine.dispose();
      LumeLog.warn('[${section.id}] 图源脚本载入失败: $sourceId');
      return null;
    }
    _engines[sourceId] = engine;
    return engine;
  }

  /// 记录是否归属本板块。不符的记一条告警，调用方按「不存在」处理。
  bool _belongs(SourceRecord record) {
    if (record.section == section.id) return true;
    LumeLog.warn(
      '[${section.id}] 拒绝跨板块记录: ${record.id} 归属「${record.section}」',
    );
    return false;
  }

  /// 库里存在且归属本板块。
  bool _owns(String sourceId) => source(sourceId) != null;

  /// 释放单个图源运行时。超时/内存超限后可据此重建。
  void release(String sourceId) => _engines.remove(sourceId)?.dispose();

  /// 关闭整个板块：释放引擎、HTTP 客户端与数据库。
  static void close(Section section) => _registries[section.id]?.dispose();

  void dispose() {
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
    _http.dispose();
    _database.dispose();
    _registries.remove(section.id);
  }
}
