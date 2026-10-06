import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/util/lume_log.dart';

/// JS 图源适配器冒烟安全测试的公共装置。
///
/// 三件事：
/// 1. 原生桥解析与装配（Windows 取构建产物，其余平台走进程镜像）；
/// 2. 样板脚本读取（`assets/test_sources/*.js`，测试从磁盘读，不进 App 资源包）；
/// 3. 「可能永不返回」的沙箱调用隔离观测装置（见 [runSandboxCallInWorker]）。

/// 样板脚本目录。测试从磁盘读取，因此这些脚本不会被编进 App 资源包。
const String fixtureDir = 'assets/test_sources';

/// 读一份样板脚本。
String fixture(String name) =>
    File('$fixtureDir/$name').readAsStringSync();

/// 解析 quickjs 原生桥。找不到返回 null（整组用例跳过）。
///
/// Windows 下必须取 `flutter build windows` 的产物；其余平台桥与 quickjs
/// 一起编入进程镜像。
DynamicLibrary? resolveBridge() {
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

/// 装配原生桥。返回是否可用。
///
/// `reclaimRuntime = false`：断言型构建下释放 JSRuntime 会触发 quickjs 的
/// 泄漏断言并 abort 进程（已实测，见 [Qjs.reclaimRuntime]），测试进程同样适用。
bool installBridge() {
  final bridge = resolveBridge();
  if (bridge == null) return false;
  Qjs.overrideLibrary(bridge);
  Qjs.reclaimRuntime = false;
  return Qjs.isAvailable;
}

/// 冒烟测试统一用严格策略：3 秒墙钟预算（任务书要求的 3–5 秒区间下沿），
/// 预算池更小，脚本抛错即销毁上下文。
SandboxPolicy smokePolicy({bool allowHostAccess = true}) =>
    SandboxPolicy.strict.copyWith(allowHostAccess: allowHostAccess);

/// 打开一个真实图源引擎并载入样板脚本。
///
/// 走的是生产路径（[LumeJsEngine]）：一个图源独占一个 JSRuntime + JSContext，
/// 垫片按板块注入，宿主能力（HTTP / 沙盒文件 IO）按图源隔离。
Future<LumeJsEngine> openEngine({
  required String sourceId,
  required String script,
  Section section = Section.novel,
}) async {
  final engine = await LumeJsEngine.create(
    sourceId: sourceId,
    http: LumeHttp(),
    section: section,
  );
  final loaded = await engine.loadScript(script);
  if (!loaded) {
    final reason = engine.lastLoadFailure;
    engine.dispose();
    throw StateError('样板脚本载入失败（$sourceId）: $reason');
  }
  return engine;
}

/// 非 iOS 平台驱动真实引擎所需的开关（与既有原生用例同一套做法）。
void enableEngineOnThisPlatform() {
  LumeJsEngine.debugSupportedOverride = true;
}

void restoreEnginePlatformGate() {
  LumeJsEngine.debugSupportedOverride = null;
}

/// 把板块目录重定向到临时目录，并确保板块作用域已就绪。
///
/// 板块库与缓存落在 `getApplicationSupportDirectory()/sections/<id>/`，
/// 测试里必须换到临时目录，否则会写进真实用户目录。
Future<void> installTempSectionRoot(Directory root) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => call.method == 'getApplicationSupportDirectory'
        ? root.path
        : null,
  );
}

/// 打开（必要时创建）某板块的作用域目录。
Future<SectionScope> ensureSectionScope(Section section) =>
    SectionScope.open(section);

/// 从日志快照里挑出包含 [needle] 的条目文本。
List<String> logLinesContaining(String needle) => LumeLog.snapshot
    .map((entry) => '[${entry.level.id}] ${entry.message}')
    .where((line) => line.contains(needle))
    .toList(growable: false);

/// 一次「隔离观测」的运行结果。
///
/// [completed] 为 false 表示 [budget] 内没等到收尾报告——即被测脚本把调用线程
/// 独占住且**没有被回收**。[events] 保留了 worker 沿途发回的进度，
/// 便于在报告里区分「没启动」与「启动后卡死」。
class SandboxWorkerRun {
  SandboxWorkerRun({
    required this.completed,
    required this.events,
    required this.waited,
    required this.isolate,
  });

  /// worker 是否在预算内正常收尾。
  final bool completed;

  /// worker 沿途发回的事件（按发生顺序）。
  final List<Map<String, Object?>> events;

  /// 主 isolate 实际等待的时长。
  final Duration waited;

  /// 被观测的 worker；调用方负责回收（[kill]）。
  final Isolate isolate;

  /// 收尾报告；[completed] 为 false 时是 null。
  Map<String, Object?>? get report =>
      completed ? events.lastWhere((e) => e['phase'] == 'done') : null;

  /// worker 是否已经进到「开始调用脚本」这一步。
  bool get armed => events.any((event) => event['phase'] == 'armed');

  void kill() => isolate.kill(priority: Isolate.immediate);
}

/// 在独立 isolate 里驱动一次沙箱调用，用于观测「可能永不返回」的失控脚本。
///
/// 为什么必须开 isolate：纯 CPU 死循环会独占调用线程。若直接在主 isolate 里跑，
/// 测试进程自己就会卡死——连「预期它超时」这个结论都观测不到。独立 isolate 让
/// 观测方始终活着，从而能给出「到点仍未回收」这个判定。
///
/// 注意：原生中断通路不可用时，卡死在原生调用里的 isolate 无法被真正回收
/// （已实测：`Isolate.kill` 之后进程里仍留着这个线程）。因此本装置只用于**观测**，
/// 用完必须 [SandboxWorkerRun.kill]，且同一测试进程内不要反复制造这种泄漏。
Future<SandboxWorkerRun> runSandboxCallInWorker({
  required String script,
  required String method,
  Object? argument,
  Duration budget = const Duration(seconds: 20),
  Duration policyTimeout = const Duration(seconds: 3),
}) async {
  final receive = ReceivePort();
  final events = <Map<String, Object?>>[];
  final done = Completer<void>();
  receive.listen((message) {
    if (message is Map) {
      events.add(Map<String, Object?>.from(message));
      if (message['phase'] == 'done' && !done.isCompleted) done.complete();
    }
  });
  final isolate = await Isolate.spawn(
    sandboxWorkerMain,
    <Object?>[
      receive.sendPort,
      _bridgePath() ?? '',
      script,
      method,
      argument,
      policyTimeout.inMilliseconds,
    ],
  );
  final sw = Stopwatch()..start();
  var completed = true;
  try {
    await done.future.timeout(budget);
  } on TimeoutException {
    completed = false;
  }
  sw.stop();
  return SandboxWorkerRun(
    completed: completed,
    events: events,
    waited: sw.elapsed,
    isolate: isolate,
  );
}

/// worker 侧的桥路径。Windows 下 worker 需要自己打开同一个库。
String? _bridgePath() {
  if (!Platform.isWindows) return null;
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

/// worker 入口：在独立 isolate 里建沙箱、载脚本、调方法，全程向观测方汇报。
///
/// 必须是顶层函数（`Isolate.spawn` 要求）。刻意不 import 测试框架：
/// 这里只做观测，判定留在主 isolate 的用例里。
Future<void> sandboxWorkerMain(List<Object?> args) async {
  final send = args[0] as SendPort;
  final libraryPath = args[1] as String;
  final script = args[2] as String;
  final method = args[3] as String;
  final argument = args[4];
  final timeoutMs = args[5] as int;

  final report = <String, Object?>{};
  try {
    final bridge = libraryPath.isEmpty
        ? DynamicLibrary.process()
        : DynamicLibrary.open(libraryPath);
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;

    final policy = SandboxPolicy.strict.copyWith(
      timeout: Duration(milliseconds: timeoutMs),
    );
    final sandbox = LumeSandbox.create(id: 'worker', policy: policy);
    report['sandboxSupported'] = true;

    final loaded = await sandbox.load(script);
    report['loaded'] = loaded.isOk;
    report['generation'] = sandbox.generation;

    // 关键节点：脚本已就位，接下来这一句可能就是永不返回的那一句。
    send.send(<String, Object?>{'phase': 'armed'});

    final sw = Stopwatch()..start();
    final result = await sandbox.call('LumeSource.$method', argument);
    sw.stop();

    report['phase'] = 'done';
    report['elapsedMs'] = sw.elapsedMilliseconds;
    report['ok'] = result.isOk;
    report['errorKind'] = result.error?.kind.id;
    report['error'] = result.error?.message;
    report['generation'] = sandbox.generation;
    // 失控之后是否还能重建并正常干活（要求 1 的后半句）。
    //
    // 代数必须在**这次探针之后**再读：回收只销毁旧上下文，新上下文是下一次
    // 操作时按需创建的，因此「刚回收完」这一刻代数还没涨——重建过才涨。
    final probe = await sandbox.call('LumeSource.detail', <String, Object?>{'id': 'x'});
    report['rebuiltOk'] = probe.isOk;
    report['generationAfter'] = sandbox.generation;
    report['liveContexts'] = SandboxContext.liveCount;
    sandbox.dispose();
    report['liveAfterDispose'] = SandboxContext.liveCount;
  } catch (error) {
    report['phase'] = 'done';
    report['threw'] = '$error';
  }
  send.send(report);
}
