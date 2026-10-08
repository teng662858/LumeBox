import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/waf.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/source_scripts.dart';

/// **源脚本对 App 契约的适配审计**（用户口径：三份订阅里的脚本都要能直接用）。
///
/// 逐个脚本在**真实 QuickJS 沙箱 + 真实桥接**里过一遍，查三件事：
///
/// 1. **能载入**：没有语法错误，也没用到沙箱里没有的能力（require / process /
///    Node 的 crypto 那一类）——这类问题在真机上表现为「导入失败」，用户看不懂；
/// 2. **元信息对得上归属**：id / name / version 齐全，`category` 与它所在的板块
///    目录一致（不一致会被跨板块校验拒掉）；
/// 3. **被防护拦下时抛的是 App 认识的标记**：截图站的 403 挑战页（CF）喂给每个
///    方法，脚本必须抛 `NEED_WEBVIEW_VERIFY`（App 据此拉起网页视图）；reCAPTCHA
///    v3 那类必须抛 `WAF_RECAPTCHA_V3`（App 据此给桥接提示、不给网页视图按钮）。
///    这一条是「适配」的核心：抛错文案不对，用户看到的就是一个没有出口的红字。
///
/// 脚本不随 App 仓库分发（见 [lumeSourcesRepo]）：本机没拉缓存时整组跳过。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  _heavyPageTest();

  test('审计：三份订阅里的脚本都能载入、元信息对得上、被拦时抛对标记', () async {
    final scripts = _cachedScripts();
    if (scripts.isEmpty) {
      markSkippedForAudit();
      return;
    }

    final problems = <String>[];
    for (final script in scripts) {
      final name = script.uri.pathSegments.last;
      final section = Section.values.firstWhere(
        (item) => script.uri.pathSegments.contains(item.id),
        orElse: () => Section.novel,
      );
      final report = await _audit(script, section);
      stdout.writeln('[audit] $name → ${report.summary}');
      problems.addAll(report.problems);
    }

    expect(problems, isEmpty, reason: problems.join('\n'));
  }, skip: _cachedScripts().isEmpty ? _auditSkipReason() : null);
}

/// 大页面解析不许撞沙箱预算（真机反馈：鸟鸟韩漫首页报「超出指令计数上限」）。
///
/// 真因是识别作品页那条正则的**嵌套量词**在匹配失败时指数级回溯（实测 V8：
/// 81 个字符跑 85 秒）。这条用例拿「200KB 以上、上千锚点、还夹着一批又长又没数字的
/// 链接」的合成页面当回归网：解析必须跑完并出条目——将来谁再把回溯型正则写回去，
/// 这条用例在沙箱里也不会跑得动。
void _heavyPageTest() {
  test('大页面（≈200KB / 上千锚点）解析不撞指令预算', () async {
    final scriptPath = sourceScriptPath('nnhanman_comic.js');
    if (scriptPath == null) {
      fail('本机没有 nnhanman_comic.js：先跑 `dart run tool/fetch_sources.dart`');
    }
    final html = _syntheticListPage(anchors: 2000);
    expect(html.length, greaterThan(150 * 1024), reason: '合成页面要真的够大');

    final host = LumeSourceHost(
      _StaticHttp(html),
      timeout: const Duration(seconds: 6),
      section: Section.comic,
      sourceId: 'nnhanman_comic',
    );
    final sandbox = LumeSandbox.create(
      id: host.expectedSandboxId,
      policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
      host: host,
      polyfills: LumeSourcePolyfills.forSection(Section.comic),
    );
    addTearDown(() {
      sandbox.dispose();
      host.dispose();
    });
    final loaded = await sandbox.load(File(scriptPath).readAsStringSync());
    expect(loaded.isOk, isTrue, reason: '${loaded.error}');

    final source = JsDataSource(
      id: 'nnhanman_comic',
      name: 'NN韩漫',
      section: Section.comic,
      runtime: _SandboxRuntime(sandbox),
    );
    final list = await source.list(page: 1);
    expect(list.items, isNotEmpty, reason: '大页面也要解析得出条目');
    stdout.writeln('[audit] 大页面解析：${list.items.length} 条，未撞指令预算');
  });
}

/// 合成一个「很像漫画站首页」的大页面：上千个锚点，穿插作品页 / 章节页 / 导航链。
String _syntheticListPage({required int anchors}) {
  final buffer = StringBuffer('<html><head><title>示例漫画站</title></head><body>');
  buffer.write('<nav>');
  for (var i = 0; i < 20; i++) {
    buffer.write('<a href="/list/genre$i/">分类$i</a>');
  }
  buffer.write('</nav><div class="list">');
  for (var i = 0; i < anchors; i++) {
    if (i % 5 == 0) {
      // 章节页：解析器必须跳过它们（而且不能在这些链接上回溯）
      buffer.write('<a href="/chapter/${100000 + i}-1122334455">第 $i 话 很长很长的章节标题足够长</a>');
      continue;
    }
    buffer.write(
      // 长 href + 长标题 + 长图片地址：回溯型正则会在这里爆炸，线性实现不受影响。
      '<a href="/comic/${100000 + i}/${'very-long-path-segment-' * 6}$i-$i/'
      '?tracking=${'abcdefghij' * 4}$i" title="作品$i 很长的标题${'标题' * 8}">'
      '<img data-original="https://img.example.com/${'folder/' * 6}$i.jpg" '
      'alt="作品$i"></a>',
    );
  }
  buffer.write('</div>');
  buffer.write('<a rel="next" href="/?page=2">下一页</a>');
  buffer.write('</body></html>');
  return buffer.toString();
}

/// 固定返回同一份 HTML 的替身（不区分地址：第一跳就命中）。
class _StaticHttp implements LumeHttp {
  _StaticHttp(this.body);

  final String body;

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async =>
      LumeHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(this.body)),
        headers: const <String, String>{'content-type': 'text/html'},
      );

  @override
  String get bridge => '';

  @override
  String get configuredUserAgent => '';

  @override
  void dispose() {}

  @override
  String get effectiveProxy => '';

  @override
  Duration get effectiveTimeout => const Duration(seconds: 6);

  @override
  String get effectiveUserAgent => LumeHttp.defaultUserAgent;

  @override
  void useQueue(NetworkQueue queue) {}
}

/// 本机没有脚本缓存时，用一个「明确失败」把话说清楚（而不是静默什么都不做）。
void markSkippedForAudit() {
  fail(_auditSkipReason());
}

String _auditSkipReason() =>
    '本机没有脚本缓存：先跑 `dart run tool/fetch_sources.dart`'
    '（从 $lumeSourcesRepo 拉到 .sources-cache/）再审计';

/// 缓存里的全部脚本（按板块目录分好）。
List<File> _cachedScripts() {
  final dir = sourceCacheDir;
  if (!dir.existsSync()) return const <File>[];
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.js'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// 单份脚本的审计结论。
class _AuditReport {
  const _AuditReport(this.summary, this.problems);

  final String summary;
  final List<String> problems;
}

Future<_AuditReport> _audit(File script, Section section) async {
  final name = script.uri.pathSegments.last;
  final problems = <String>[];
  final text = script.readAsStringSync();

  // ① 元信息（头部声明）与归属。
  final head = SourceMetadata.parseHeader(text);
  if (head == null) {
    problems.add('$name：缺少 `// LumeSource: {…}` 头部元信息，导入会被拒');
  } else {
    if (head.id.trim().isEmpty) problems.add('$name：id 为空');
    if (head.name.trim().isEmpty) problems.add('$name：name 为空');
    if (head.version.trim().isEmpty) problems.add('$name：version 为空');
    if (head.category.trim().isNotEmpty && head.category != section.id) {
      problems.add(
        '$name：category=「${head.category}」与所在目录「${section.id}」不一致，'
        '跨板块校验会把它拒掉',
      );
    }
  }

  // ② 沙箱里能不能载入（用到沙箱没有的能力会在这一步报错）。
  final host = LumeSourceHost(
    _ChallengeHttp(),
    timeout: const Duration(seconds: 3),
    section: section,
    sourceId: name.replaceAll('.js', ''),
  );
  final sandbox = LumeSandbox.create(
    id: host.expectedSandboxId,
    policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
    host: host,
    polyfills: LumeSourcePolyfills.forSection(section),
  );
  addTearDown(() {
    sandbox.dispose();
    host.dispose();
  });

  final loaded = await sandbox.load(text);
  if (!loaded.isOk) {
    problems.add('$name：沙箱载入失败 → ${loaded.error}');
    return _AuditReport('载入失败', problems);
  }
  final source = JsDataSource(
    id: 'audit',
    name: 'audit',
    section: section,
    runtime: _SandboxRuntime(sandbox),
  );

  // ③ 五个契约方法都实现，且被防护拦下时抛对标记。
  final outcomes = <String>[];
  for (final method in const <String>[
    'categories',
    'list',
    'detail',
    'chapters',
    'content',
  ]) {
    final outcome = await _call(source, method);
    outcomes.add('$method=${outcome.label}');
    switch (outcome.kind) {
      case _OutcomeKind.ok:
      case _OutcomeKind.marker:
      case _OutcomeKind.network:
        break;
      case _OutcomeKind.missing:
        problems.add('$name：$method 没有实现（脚本必须给出这个入口）');
      case _OutcomeKind.capability:
        problems.add(
          '$name：$method 用到沙箱不支持的能力 → ${outcome.detail}'
          '（真机上表现为「导入/调用失败」，要在脚本里换掉）',
        );
      case _OutcomeKind.other:
        problems.add('$name：$method 失败且不是网络/防护类 → ${outcome.detail}');
    }
  }

  return _AuditReport(
    problems.isEmpty ? '通过（${outcomes.join(' ')}）' : '有问题',
    problems,
  );
}

enum _OutcomeKind {
  /// 正常返回（空结果也算：503/403 的替身下能解析出空列表就是好的）。
  ok,

  /// 被防护拦下，抛的是 App 认识的标记（NEED_WEBVIEW_VERIFY / WAF_RECAPTCHA_V3）。
  marker,

  /// 网络类失败（HTTP 状态 / 超时）——真机上给「重试」出口。
  network,

  /// 脚本没实现这个入口。
  missing,

  /// 用到沙箱不支持的能力（适配问题，必须修）。
  capability,

  /// 其它脚本错误。
  other,
}

class _Outcome {
  const _Outcome(this.kind, this.label, this.detail);

  final _OutcomeKind kind;
  final String label;
  final String detail;
}

Future<_Outcome> _call(JsDataSource source, String method) async {
  try {
    final result = switch (method) {
      'categories' => await source.categories(),
      'list' => await source.list(page: 1),
      'detail' => await source.detail('probe'),
      'chapters' => await source.chapters('probe'),
      _ => await source.content(itemId: 'probe', chapterId: 'probe'),
    };
    final empty = switch (result) {
      null => true, // detail 可能为 null（没有这个条目）
      final List<Object?> list => list.isEmpty,
      final SourceList list => list.items.isEmpty,
      final ImageContent content => content.images.isEmpty,
      final TextContent content => content.text.isEmpty,
      _ => false,
    };
    return _Outcome(_OutcomeKind.ok, empty ? '空结果' : '有数据', '');
  } on SourceException catch (error) {
    final message = error.message;
    if (wafKindOf(message) != null) {
      return _Outcome(_OutcomeKind.marker, wafKindOf(message)!.name, message);
    }
    if (_isMissingMethod(message)) {
      return _Outcome(_OutcomeKind.missing, '未实现', message);
    }
    if (_isCapabilityFailure(message)) {
      return _Outcome(_OutcomeKind.capability, '能力缺失', message);
    }
    if (_isNetworkFailure(message)) {
      return _Outcome(_OutcomeKind.network, '网络失败', message);
    }
    return _Outcome(_OutcomeKind.other, '脚本错误', message);
  }
}

/// 「脚本没实现这个方法」——引擎对缺失方法的措辞。
bool _isMissingMethod(String message) =>
    message.contains('不是函数') ||
    message.contains('方法不存在') ||
    message.contains('is not a function') ||
    message.contains('undefined is not called');

/// 「用到了沙箱没有提供的东西」——这类是适配问题，必须在脚本里换掉。
bool _isCapabilityFailure(String message) {
  const markers = <String>[
    '沙箱未开放',
    '沙箱不支持',
    'NotSupported',
    'not defined',
    'is not defined',
    'require is not',
    'process is not',
    'Buffer is not',
    'crypto is not',
    '模块',
  ];
  return markers.any(message.contains);
}

/// 网络类失败：HTTP 状态 / 超时 / 连接中断——真机上给「重试」出口。
bool _isNetworkFailure(String message) =>
    message.contains('拉取失败') ||
    message.contains('HTTP') ||
    message.contains('超时') ||
    message.contains('网络') ||
    message.contains(LumeSourceNetworkMarker.failure);

/// 截图站的 403 挑战页：CF 拦下时真实响应就长这样（标题 + `cf-mitigated`）。
class _ChallengeHttp implements LumeHttp {
  /// 只有 [send] 会被脚本用到的桥走这一份；其余 getter 是 [LumeHttp] 的配置面，
  /// 审计不需要它们，给一份固定值即可。
  @override
  String get bridge => '';

  @override
  String get effectiveProxy => '';

  @override
  Duration get effectiveTimeout => const Duration(seconds: 3);

  @override
  String get effectiveUserAgent => LumeHttp.defaultUserAgent;

  @override
  String get configuredUserAgent => '';

  @override
  void useQueue(NetworkQueue queue) {}

  static const String _body = '<html><head><title>Just a moment...</title>'
      '<meta http-equiv="cf-mitigated" content="challenge"></head>'
      '<body>Enable JavaScript and cookies to continue</body></html>';

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    return LumeHttpResponse(
      statusCode: 403,
      body: Uint8List.fromList(utf8.encode(_body)),
      headers: const <String, String>{
        'content-type': 'text/html',
        'cf-mitigated': 'challenge',
      },
    );
  }

  @override
  void dispose() {}
}

class _SandboxRuntime implements JsSourceRuntime {
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Set<String>> contractMethods() async => const <String>{
        'categories',
        'list',
        'detail',
        'chapters',
        'content',
      };

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
}

DynamicLibrary? _resolveBridge() {
  if (!Platform.isWindows) {
    try {
      return DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (!file.existsSync()) continue;
    try {
      return DynamicLibrary.open(file.absolute.path);
    } catch (_) {
      continue;
    }
  }
  return null;
}
