import '../source/source_extension_settings.dart';

import 'dart:async';

import '../source/source_preferences.dart';
import '../source/source_site_config.dart';
import '../cache/section_memory_cache.dart';
import '../db/section_database.dart';
import '../db/source_record.dart';
import '../net/lume_http.dart';
import '../net/waf.dart';
import '../net/network_settings.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'cat_engines.dart';
import 'lume_js_engine.dart';
import 'source_engine.dart';
import 'source_script.dart';
import '../source/source_package.dart';
import '../source/kazumi_rule.dart';
import 'python_source_engine.dart';
import 'rex_widget_host.dart';

/// 图源导入结果：成功携带落库记录，失败携带可读原因。
///
/// 只表达「校验与落库」这一步的结论，不含任何展示口径；上层据此组织提示。
class SourceImportOutcome {
  const SourceImportOutcome.success(this.record, {String? note})
    : message = note;

  const SourceImportOutcome.failure(this.message) : record = null;

  final SourceRecord? record;

  /// 失败原因，或成功时需要展示的兼容性说明。
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
  Future<void> _mutations = Future<void>.value();
  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _mutations = _mutations.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Map<String, dynamic>? previousSource(String id) =>
      _owns(id) ? _database.previousSource(id) : null;
  Future<SourceImportOutcome> restorePrevious(String id) => _mutate(() async {
    final old = previousSource(id);
    final active = source(id);
    if (old == null || active == null) {
      return const SourceImportOutcome.failure('没有可恢复的上一版');
    }
    final result = await _importValidated(
      old['script'] as String,
      originUrl: active.originUrl,
      rememberPrevious: false,
      rejectedScript: active.script,
      restoredName: active.name,
    );
    if (result.isSuccess) {
      _database.clearSourceFailure(id);
    }
    return result;
  });

  final Section section;
  final SectionDatabase _database;

  /// 共享 HTTP 客户端：用于导入校验与不带图源覆盖的场景。
  final LumeHttp _http;

  /// 图源 → 带该图源网络覆盖（UA / Cookie / 代理）的 HTTP 客户端。
  /// 惰性创建、随图源释放；不同图源之间不共享 Cookie。
  final Map<String, LumeHttp> _httpBySource = <String, LumeHttp>{};

  static final Map<String, SourceRegistry> _registries =
      <String, SourceRegistry>{};

  /// 引擎表：存端口而不是具体引擎——猫源在 Android 上可能是 Node-Mobile。
  final Map<String, SourceEngine> _engines = <String, SourceEngine>{};

  /// 当前图源的设置键。板块级设置，落在本板块库里。
  static const String currentSourceKey = 'current_source';

  static final Map<String, Future<SourceRegistry>> _opening = {};
  static String rewriteExisting(
    Section section,
    String sourceId,
    String url, {
    String? kind,
  }) =>
      _registries[section.id]?.rewriteSourceUrl(sourceId, url, kind: kind) ??
      SourcePreferences.read(section, sourceId).rewrite(url);

  static Future<SourceRegistry> open(Section section) {
    final existing = _registries[section.id];
    if (existing != null) {
      existing._closeRequested = false;
      return Future.value(existing);
    }
    return _opening.putIfAbsent(section.id, () => _open(section));
  }

  static Future<SourceRegistry> _open(Section section) async {
    try {
      final scope = await SectionScope.open(section);
      final registry = SourceRegistry._(
        section,
        await SectionDatabase.open(scope),
        LumeHttp(),
      );
      _registries[section.id] = registry;
      return registry;
    } finally {
      _opening.remove(section.id);
    }
  }

  /// 本板块在当前平台是否有可用引擎。
  ///
  /// 猫源在 Android 上也有引擎（QuickJS / Node-Mobile 二选一，见 [CatEngines]）；
  /// 其余板块维持既有口径（仅 iOS）。
  bool get _engineAvailable =>
      section == Section.cat ? CatEngines.available : LumeJsEngine.isSupported;

  /// 取某图源的 HTTP 客户端：带该图源的 UA / Cookie / 代理覆盖。
  ///
  /// 覆盖项为空即继承全局设置（文档要求单图源配置优先于全局）。
  /// 客户端按图源缓存：同一图源的多条请求共用连接池，Cookie 不跨图源。
  LumeHttp httpFor(String sourceId) {
    final existing = _httpBySource[sourceId];
    if (existing != null) return existing;
    final record = source(sourceId);
    final client = LumeHttp(
      profile: record?.network ?? NetworkProfile.none,
      rewriteUrl: (url) => rewriteSourceUrl(sourceId, url),
      source: sourceId,
      // 「网页视图」过完 Cloudflare 校验后存下的会话 Cookie：该图源的所有请求
      // 自动带上（用户口径第 4 条）。没存过就是 null，行为与从前完全一致。
      sessionCookies: () => WafSessions.cookiesFor(section, sourceId),
      // 验证时用的那个 UA 同样要用在后续请求上：cf_clearance 绑 IP + UA，
      // 换了 UA 等于没验（真机反馈「验完还是被拦」）。
      sessionUserAgent: () => WafSessions.userAgentFor(section, sourceId),
      // 桥接服务地址（用户口径 2.2）：脚本用 `LumeSource.bridge` 转发请求，
      // 宿主把它随图源记录一起给引擎（见 LumeJsEngine.create 的 bridge 参数）。
      bridge: record?.network.bridge ?? '',
    );
    _httpBySource[sourceId] = client;
    return client;
  }

  /// 更新单图源网络覆盖并释放它的运行时（引擎 + HTTP 客户端）。
  ///
  /// 引擎持有创建时的客户端；只移除 HTTP 表项会让启用中的源继续使用已释放实例。
  /// 这里**不动** WAF 会话：会话是用户手动过校验换来的凭据，与 UA/代理无关。
  void setSourceNetwork(
    String sourceId, {
    required String userAgent,
    required String cookie,
    required String proxy,
    String bridge = '',
    bool allowBadCertificate = false,
  }) {
    if (!_owns(sourceId)) return;
    _database.setSourceNetwork(
      sourceId,
      userAgent: userAgent.trim(),
      cookie: cookie.trim(),
      proxy: proxy.trim(),
      bridge: bridge.trim(),
      allowBadCertificate: allowBadCertificate,
    );
    // The engine owns the LumeHttp instance it was created with. Removing only
    // the client leaves an enabled source pointing at a disposed client until
    // process restart, so invalidate the pair as one runtime unit.
    release(sourceId);
  }

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
    final enabled = sources
        .where((record) => record.enabled)
        .toList(growable: false);
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
  /// 文本预处理：读进来的脚本先剥掉 UTF-8 BOM，再做头部元信息正则、再交给
  /// 引擎执行，落库的也是剥离后的文本（带 BOM 的合法脚本因此不再误报）。
  ///
  /// 失败返回带可读原因的失败结果：平台无引擎、脚本载入失败（语法错误或运行
  /// 异常）、脚本缺少 `LumeSource` 元信息（id / name）或 id 非法。
  Future<SourceImportOutcome> import(
    String script, {
    String originUrl = '',
    bool preserveLocalSources = false,
  }) => _mutate(
    () => _importValidated(
      script,
      originUrl: originUrl,
      preserveLocalSources: preserveLocalSources,
    ),
  );

  Future<SourceImportOutcome> _importValidated(
    String script, {
    String originUrl = '',
    bool preserveLocalSources = false,
    bool rememberPrevious = true,
    String? rejectedScript,
    String? restoredName,
  }) async {
    if (!_engineAvailable) {
      LumeLog.warn('[${section.id}] 当前平台不提供源引擎');
      return const SourceImportOutcome.failure('当前平台不提供源引擎');
    }
    final text = stripScriptBom(
      SourcePackage.prepare(script, originUrl: originUrl),
    );
    final probe = await SourceEngineRegistry.createForScript(
      script: text,
      kind: CatEngineSettings.engineKindFor(section, _database),
      sourceId: 'probe${DateTime.now().microsecondsSinceEpoch}',
      http: _http,
      section: section,
    );
    if (probe == null) {
      return const SourceImportOutcome.failure('当前平台不提供该源引擎（引擎未集成或原生不可用）');
    }
    try {
      if (!await probe.loadScript(text)) {
        // 引擎给出的原因（沙箱点名了哪个模块不支持 / 语法错在哪儿）直接带给用户：
        // 「脚本载入失败」一句话解决不了问题，用户需要知道该改哪里。
        final reason = probe.loadFailure?.trim();
        LumeLog.warn('[${section.id}] 脚本载入失败: ${reason ?? '（引擎未给出原因）'}');
        return SourceImportOutcome.failure(
          describeLoadFailure(reason, script: text),
        );
      }
      // 先确认「这是不是一份图源脚本」：五个契约方法一个都没有，说明它根本不是
      // 给本 App 用的脚本（典型是别的客户端的扩展程序包：自带本地服务端与自有
      // 宿主桥，只有它自己的 App 认得）。这一步必须在读元信息之前——这类脚本
      // 一般也没有 id / name，先报「读不到 id」会把真正的原因盖掉。
      final provided = await probe.contractMethods();
      if (provided != null && provided.isEmpty) {
        LumeLog.warn('[${section.id}] 脚本没有任何图源入口，判定为非源脚本');
        return SourceImportOutcome.failure(describeNotASourceScript());
      }

      // 元信息：头部声明优先，退回运行时 LumeSource；两者都不合法时给出
      // 点名到字符的失败原因（哪个 id、哪个字符不合规），而不是一句笼统的报错。
      // 两处声明做合并而不是二选一：category 常常只写在运行时对象上，
      // 头部命中就整体采用会让这类脚本绕过板块校验。
      final rawMetadata = await probe.metadata();
      final metadata = SourceMetadata.merge(
        SourceMetadata.parseHeader(text),
        SourceMetadata.parse(rawMetadata),
      );
      if (metadata == null) {
        return SourceImportOutcome.failure(
          SourceMetadata.describeImportFailure(rawMetadata, script: text),
        );
      }
      // 板块归属校验：脚本自报的 category 必须与本板块一致，否则在解析阶段
      // 直接拒绝——跨板块混用图源在这里被拦下，不会落库、不会进入运行期。
      final mismatch = metadata.sectionMismatch(section);
      if (mismatch != null) {
        LumeLog.warn('[${section.id}] 拒绝跨板块源 ${metadata.id}：$mismatch');
        return SourceImportOutcome.failure(mismatch);
      }
      final previous = source(metadata.id);
      if (rememberPrevious && _database.isRejectedSource(metadata.id, text)) {
        return const SourceImportOutcome.failure(
          '此脚本版本已回滚，已保留当前版本；等待源作者发布新版本后再更新',
        );
      }
      if (preserveLocalSources &&
          previous != null &&
          previous.originUrl.isEmpty) {
        return SourceImportOutcome.failure(
          '订阅源 ${metadata.id} 与手动导入的源同名，已保留手动源',
        );
      }
      await RexWidgetSettings.saveDefinitions(
        section,
        metadata.id,
        rawMetadata?['widgetParameters'],
      );
      _database.upsertSource(
        id: metadata.id,
        name: restoredName ?? metadata.name,
        version: metadata.version,
        section: section.id,
        script: text,
        rememberPrevious: rememberPrevious,
        rejectedScript: rejectedScript,
        // 站点镜像**由脚本声明**（身份声明的 `mirrors`），导入 / 更新时整体替换；
        // 同一份配置里的用户字段（选中下标 / 自定义域名 / 账号密码）由库层保留。
        mirrors: metadata.mirrors,
        images: metadata.images,
        video: metadata.video,
        settings: metadata.settings,
        commonSettings: metadata.commonSettings,
      );
      // 订阅来源：记在库里供「更新订阅源」重新拉取；本地导入留空。
      // 覆盖导入（更新）时也照写——来源地址属于用户配置，不随脚本内容丢失。
      if (originUrl.trim().isNotEmpty) {
        _database.setSourceOrigin(metadata.id, originUrl);
      }
      release(metadata.id);
      final record = _database.source(metadata.id);
      if (record == null) {
        return const SourceImportOutcome.failure('源写入本板块库失败');
      }
      final warnings = rawMetadata?['compatibilityWarnings'];
      return SourceImportOutcome.success(
        record,
        note: warnings is List && warnings.isNotEmpty
            ? warnings.join('\n')
            : null,
      );
    } on FormatException catch (error) {
      return SourceImportOutcome.failure('源设置声明无效：${error.message}');
    } finally {
      probe.dispose();
    }
  }

  /// 脚本载入失败的展示口径：**引擎给了具体原因就用它**（沙箱会点名「哪个模块不
  /// 支持」「语法错在哪一行」「加载超时」），引擎没说才回落到笼统提示。
  ///
  /// 脚本用到了 socket / 进程 / 端口这类沙箱按设计不提供的能力时，再加一句定向
  /// 说明：Node 服务端程序（`node index.js` 那种自建服务）不是图源脚本，App 里
  /// 跑不了它——省得用户在「导入失败」上反复试。
  /// 「这不是本 App 的图源脚本」的统一文案。
  ///
  /// 触发条件：脚本载入成功，但五个契约方法（getList / getDetail /
  /// getCategories / getChapters / getContent 或其别名）一个都没有。
  /// 这类脚本常见于「另一个客户端的扩展程序包」——它们自带本地服务端
  /// （因此会 require http2 / net 这类模块）并靠自己的宿主桥与宿主通信，
  /// 本 App 既没有端口也没有那套桥，无法运行。
  static String describeNotASourceScript() {
    return '这不是本 App 的图源脚本：脚本里没有任何图源入口'
        '（getList / getDetail / getCategories / getChapters / getContent 一个都没有）。\n'
        '它更像是别的客户端的扩展程序包——那种包自带本地服务端、靠它自己的宿主桥通信，'
        '只有那个 App 能运行它。\n'
        '本 App 的图源脚本只需要提供 getList / getDetail / getContent 这类函数，'
        '网络请求用 fetch 或 LumeSource.http（由 App 代为发出）。';
  }

  /// Node 打包程序的指纹（在脚本**原文**里找）。
  ///
  /// 为什么按内容判而不是按报错文案：真机上那份 6MB 订阅的失败文案只有一句
  /// `TypeError: not a function`（加行号），一个字都没提 Node——而它的正文里
  /// 到处都是 `process.hrtime.bigint()` / `require(` / `module.exports`。
  /// 导入阶段是**唯一**能读到完整脚本的地方，因此在这里定性最准。
  /// 只用**高置信**指纹：`require('dns')` 这种「顺手 require 一个模块」的普通
  /// 图源脚本不能被误判成 Node 程序（那份脚本的真实原因是沙箱不支持 dns，
  /// 报错要照旧点名 dns）。真正打包过的程序一定带 process.* / module.exports。
  static final RegExp _nodeBundlePattern = RegExp(
    r'process\.hrtime|process\.env|process\.nextTick|process\.pid|process\.cwd|'
    r'module\.exports|__dirname|require\.main|Buffer\.from',
    caseSensitive: false,
  );

  /// Venera 那套源的特征：脚本用 `document.querySelectorAll` 这类**网页 DOM**
  /// 当前兼容层支持 HtmlDocument 常用选择器；完整浏览器 DOM 与 cheerio 不在契约内。
  static final RegExp _veneraPattern = RegExp(
    r'querySelectorAll|querySelector\(|cheerio|\.innerHTML|document\.createElement',
    caseSensitive: false,
  );

  static String describeLoadFailure(String? reason, {String? script}) {
    final detail = reason?.trim() ?? '';
    // 内容指纹优先：这类脚本「跑不起来」的原因不在报错文案里，而在它是不是
    // 本 App 的图源脚本。先按内容定性，再按文案兜底。
    if (script != null && _veneraPattern.hasMatch(script)) {
      return 'HTML 源解析失败：当前兼容层支持 Venera 常用 HtmlDocument 选择器，'
          '但不提供完整浏览器 DOM、cheerio 或任意伪类。请检查所用 API、选择器与源版本。\n'
          '引擎原文：$detail';
    }
    if (detail.isNotEmpty && _veneraPattern.hasMatch(detail)) {
      return 'HTML 解析接口或选择器不受当前兼容层支持，请检查源版本和请求返回的正文。\n'
          '引擎原文：$detail';
    }
    if (script != null && _nodeBundlePattern.hasMatch(script)) {
      return '这不是本 App 的图源脚本：脚本正文里用到了只有真 Node 才有的能力'
          '（process.hrtime / require / module.exports / 网络服务等）——'
          '它是一份**打包过的 Node 程序**（或别的客户端的扩展包），App 里跑不起来。\n'
          '两条出路：① 换一份直接抓接口的图源脚本（getList / getDetail / getContent + fetch）；'
          '② 让它跑在电脑 / NAS 上，App 侧用薄壳脚本经 LumeSource.http 转发'
          '（写法见 assets/test_sources/catvod_bridge_source.dart 同目录的示例）。\n'
          '引擎原文：$detail';
    }
    if (detail.isEmpty) {
      return '脚本载入失败：语法错误、运行异常，或用到了沙箱不支持的能力'
          '（如 child_process / 自建 HTTP 服务）';
    }
    final message = '脚本载入失败：$detail';
    if (!_serverCapabilityPattern.hasMatch(detail)) return message;
    return '$message\n'
        '（这像是**打包过的 Node 程序 / 自建服务端程序**（用到 process.hrtime / require / socket 这类'
        '只有真 Node 才有的能力），不是本 App 的图源脚本，App 里跑不起来；'
        '出路：① 换一份直接抓接口的图源脚本（getList / getDetail / getContent + fetch）；'
        '② 这个服务跑在电脑 / NAS 上，App 侧用薄壳脚本经 LumeSource.http 转发'
        '（写法见 assets/test_sources/catvod_bridge_source.js））';
  }

  /// 运行期失败的定向说明（探索页 / 详情页的错误卡用）。
  ///
  /// 与 [describeLoadFailure] 的区别：导入期失败可以整段替换文案；运行期失败
  /// （源已经在库里、某次调用报错）**必须保留引擎原文**，只在其后追加一句能定性的
  /// 说明——真机那条「cannot read property 'querySelectorAll' of null」就是典型：
  /// 原文只有一句英文 TypeError，用户完全不知道发生了什么。
  static String describeRuntimeFailure(String detail) {
    final text = detail.trim();
    if (text.isEmpty) return text;
    if (text.contains('超出指令预算') || text.contains('指令计数上限')) {
      return '$text\n'
          '（这个源在一次调用里做了太多运算——最常见的是正则回溯（嵌套量词套长文本）'
          '或对整页 HTML 反复遍历。把运行日志发回来收敛脚本；'
          '也可以把「设置 → 沙箱设置」的超时调大一档：指令预算按它同向放大。）';
    }
    if (_veneraPattern.hasMatch(text)) {
      return '$text\n'
          '（这个源用到了**网页 DOM 解析**：querySelectorAll / cheerio / innerHTML——'
          '当前 Venera 兼容层支持 HtmlDocument 常用选择器。请先检查返回正文和节点是否为空，'
          '再核对所用 API；完整浏览器 DOM、cheerio 与任意伪类不受支持。）';
    }
    return text;
  }

  /// 服务端能力特征：socket / 端口 / 进程 / 线程这类「跑服务」才需要的东西。
  ///
  /// 两侧必须是词边界：这些词都是常见英文子串（`net` ⊂ internet / network /
  /// magnet，`dns` ⊂ 无但 `net` 已足够），不加边界会把普通的语法错误也判成
  /// 「自建服务端程序」——用户按提示去改网络写法，而真正的问题是少了个括号。
  /// 边界用「非标识符字符」而不是 `\b`：`net::ERR_` 与 `net.createServer` 里
  /// 紧邻的是 `:` 与 `.`，两者都要能命中。
  static final RegExp _serverCapabilityPattern = RegExp(
    r'(?<![A-Za-z0-9_$])'
    r'(net|tls|http2|dgram|dns|child_process|worker_threads|cluster|createServer|listen'
    // Node 打包程序的典型指纹：实测 9280.kstore.vip 那份 6MB 订阅就死在
    // `process.hrtime.bigint` 不是函数（真 Node 才有）。
    r'|hrtime|nextTick|setImmediate)'
    r'(?![A-Za-z0-9_$])',
    caseSensitive: false,
  );

  /// 重命名：只改库里的展示名（脚本、版本、启停状态与运行时都不动）。
  ///
  /// 展示名与脚本里声明的 `LumeSource.name` 可以不同——这正是重命名的意义：
  /// 用户按自己的习惯命名，脚本本身保持原样，更新脚本时也不会被覆盖。
  void rename(String sourceId, String name) {
    final record = source(sourceId);
    if (record == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == record.name) return;
    _database.upsertSource(
      id: record.id,
      name: trimmed,
      version: record.version,
      section: section.id,
      script: record.script,
      // 重命名不是「脚本变了」：镜像表原样带回去，不重新读脚本声明
      // （否则运行期才声明 mirrors 的源会在重命名时把镜像丢掉）。
      mirrors: record.siteConfig.mirrors,
    );
  }

  /// 保存单图源的「换网址 / 账号登入」（镜像选择、自定义域名、登录账号）。
  ///
  /// 保存单图源的站点配置并释放对应运行时。
  ///
  /// 每次调用会注入新快照，但脚本可能在初始化时把域名复制到自身全局状态；
  /// 释放并重建可确保自定义域名、镜像和账号状态同时更新，不留旧 JSContext。
  void setSourceSiteConfig(String sourceId, SourceSiteConfig config) {
    if (!_owns(sourceId)) return;
    _database.setSourceSiteConfig(sourceId, config);
    release(sourceId);
  }

  /// 本源当前解析后的脚本配置快照（脚本读到的 `LumeSource.config`）。
  ///
  /// Cookie 取自单图源网络覆盖：它是脚本索要的凭据之一，与「网络配置」里那份
  /// 是同一份数据（不存在第二份 Cookie）。
  Map<String, Object?> scriptConfigFor(String sourceId) {
    final record = source(sourceId);
    final site = record?.siteConfig ?? SourceSiteConfig.none;
    final legacy = SourcePreferences.read(section, sourceId);
    final effective = site.hasCustomDomain || legacy.customOrigin.isEmpty
        ? site
        : site.copyWith(domainOverride: legacy.customOrigin);
    return effective.toScriptJson(cookie: record?.network.cookie ?? '');
  }

  String rewriteSourceUrl(String sourceId, String url, {String? kind}) {
    final record = source(sourceId);
    if (record == null) {
      return SourcePreferences.read(section, sourceId).rewrite(url);
    }
    final legacy = SourcePreferences.read(section, sourceId);
    var site = record.siteConfig;
    if (!site.hasCustomDomain && legacy.customOrigin.isNotEmpty) {
      site = site.copyWith(domainOverride: legacy.customOrigin);
    }
    final routed = site.rewriteUrl(url, kind: kind);
    if (routed != url) return routed;
    // Migrate the old settings-page override without applying it after a newer
    // custom address from the unified site settings.
    if (!record.siteConfig.hasCustomDomain) return legacy.rewrite(url);
    if (legacy.originalOrigin.isNotEmpty) {
      return SourceRoute(
        urls: [legacy.originalOrigin],
        custom: site.resolvedDomain,
      ).rewrite(url);
    }
    return url;
  }

  /// 导出脚本原文：图源不存在或跨板块时返回 null。
  String? scriptOf(String sourceId) => source(sourceId)?.script;

  /// 设置图源分组（空串取消分组）。只改分组名，不碰脚本与运行时。
  ///
  /// 分组是**展示归类**，不改变归属板块：一个源的分组名只在本板块的库里，
  /// 跨板块看不到也改不到（`_owns` 已经拦住了跨板块 id）。
  void setGroup(String sourceId, String group) {
    if (!_owns(sourceId)) return;
    _database.setSourceGroup(sourceId, group);
  }

  /// 记录一次失败：计数 +1，达到阈值即标记失效。
  ///
  /// 只记账，不改变启停状态——失效的源仍可手动浏览（用户可能想亲眼看看），
  /// 只是**不再参与自动重试**（批量测试 / 批量刷新会跳过它）。
  void recordFailure(String sourceId) {
    if (!_owns(sourceId)) return;
    _database.recordSourceFailure(sourceId, threshold: brokenThreshold);
    final record = source(sourceId);
    if (record != null && record.isBroken) {
      LumeLog.warn(
        '[${section.id}] 源连续失败 ${record.failureCount} 次，已标记为失效'
        '（不再自动重试）：$sourceId',
      );
    }
  }

  /// 手动恢复：清零失败计数并解除失效标记。
  void clearFailure(String sourceId) {
    if (!_owns(sourceId)) return;
    _database.clearSourceFailure(sourceId);
    LumeLog.info('[${section.id}] 源已恢复（失败计数清零）：$sourceId');
  }

  /// 连续失败多少次标记为失效。
  ///
  /// 取 3：一次失败可能是站点临时抽风或网络抖动，连错三次才值得判定「这个源
  /// 坏了」。阈值不宜太小（误判会把好源停掉自动流程），也不宜太大（对一个
  /// 已死的源多打好几次目标站）。
  static const int brokenThreshold = 3;

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
    if (existing is QuickJsSourceEngine && existing.engine.isPoisoned ||
        existing is PythonSourceEngine && existing.isPoisoned) {
      release(sourceId);
    } else if (existing != null) {
      return existing;
    }
    if (_disposed) return null;
    final pending = _loadingEngines[sourceId];
    if (pending != null) return pending;
    final epoch = _engineEpochs[sourceId] ?? 0;
    final future = _loadEngine(sourceId, epoch);
    _loadingEngines[sourceId] = future;
    try {
      return await future;
    } finally {
      if (identical(_loadingEngines[sourceId], future)) {
        _loadingEngines.remove(sourceId);
      }
    }
  }

  final Map<String, Future<SourceEngine?>> _loadingEngines = {};
  final _loadFailures = <String, String>{};
  String? loadFailureFor(String id) => _loadFailures[id];
  final Map<String, int> _engineEpochs = {};
  bool get isDisposed => _disposed;
  Future<SourceEngine?> _loadEngine(String sourceId, int epoch) async {
    final record = _database.source(sourceId);
    if (record == null || !_belongs(record) || !record.enabled) return null;
    if (!_engineAvailable) return null;
    // 运行时分支：猫源按自己的选择取引擎（Android 可二选一），其余板块恒为 QuickJS。
    final engine = await SourceEngineRegistry.createForScript(
      script: record.script,
      kind: CatEngineSettings.engineKindFor(section, _database),
      sourceId: sourceId,
      http: httpFor(sourceId),
      section: section,
    );
    if (engine == null) {
      _loadFailures[sourceId] = '当前安装包不支持该源运行环境';
      LumeLog.warn('[${section.id}] 源引擎不可用: $sourceId');
      return null;
    }
    if (_disposed || (_engineEpochs[sourceId] ?? 0) != epoch) {
      engine.dispose();
      return null;
    }
    if (!await engine.loadScript(
      KazumiRule.upgradeAdapter(stripScriptBom(record.script)),
    )) {
      _loadFailures[sourceId] = engine.loadFailure ?? '源脚本载入失败';
      // 运行时载入失败的原因同样记全：日志是用户排查「图源为什么打不开」的入口。
      LumeLog.warn(
        '[${section.id}] 源脚本载入失败: $sourceId'
        '${engine.loadFailure == null ? '' : '：${engine.loadFailure}'}',
      );
      engine.dispose();
      return null;
    }
    if (_disposed || (_engineEpochs[sourceId] ?? 0) != epoch) {
      engine.dispose();
      return null;
    }
    _engines[sourceId] = engine;
    _loadFailures.remove(sourceId);
    return engine;
  }

  /// 记录是否归属本板块。不符的记一条告警，调用方按「不存在」处理。
  bool _belongs(SourceRecord record) {
    if (record.section == section.id) return true;
    LumeLog.warn('[${section.id}] 拒绝跨板块记录: ${record.id} 归属「${record.section}」');
    return false;
  }

  /// 库里存在且归属本板块。
  bool _owns(String sourceId) => source(sourceId) != null;

  /// 释放单个图源运行时（引擎 + 它专属的 HTTP 客户端）。
  /// 超时 / 内存超限 / 停用 / 删除后据此重建。
  void release(String sourceId) {
    _engineEpochs[sourceId] = (_engineEpochs[sourceId] ?? 0) + 1;
    _loadingEngines.remove(sourceId);
    _engines.remove(sourceId)?.dispose();
    _httpBySource.remove(sourceId)?.dispose();
    // 运行时没了，它之前的读结果（分类 / 详情 / 章节）也一并作废：
    // 覆盖导入换了脚本、删除换了图源，旧输出不能再被读出来。
    SectionMemoryCache.instance.removeSource(section, sourceId);
  }

  /// 关闭整个板块：释放引擎、HTTP 客户端与数据库。
  static void close(Section section) =>
      _registries[section.id]?._requestClose();

  int _leases = 0;
  bool _closeRequested = false;
  Future<T> withLease<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('图源板块已关闭');
    _leases++;
    try {
      return await operation();
    } finally {
      _leases--;
      if (_leases == 0 && _closeRequested) dispose();
    }
  }

  void _requestClose() {
    _closeRequested = true;
    if (_leases == 0) dispose();
  }

  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
    for (final client in _httpBySource.values) {
      client.dispose();
    }
    _httpBySource.clear();
    _http.dispose();
    _database.dispose();
    if (identical(_registries[section.id], this)) {
      _registries.remove(section.id);
    }
  }
}
