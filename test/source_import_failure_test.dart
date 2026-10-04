import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 导入失败的提示口径（用户反馈：只看到一句「脚本载入失败：语法错误、运行异常，
/// 或用到了沙箱不支持的能力」，得翻运行日志才知道真实原因）。
///
/// 这里在**真实引擎**上驱动整条导入链路（含元信息解析与落库），确认：
/// - 沙箱给出的具体原因（点名 dns / 语法错误）原样进到提示里；
/// - 用到 socket / 进程 / 端口这类能力时，再补一句「自建服务端程序不是图源脚本」的定向说明；
/// - 合法脚本照旧导入成功。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言，测试进程同样适用。
    Qjs.reclaimRuntime = false;
  }

  final available = Qjs.isAvailable;
  final skipReason =
      available ? null : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_import_failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 猫源在 Android 上就有引擎（QuickJS 二选一），配合下面的引擎覆盖，
    // 这套用例在非 iOS 的平台也能跑真实沙箱。
    CatEngines.debugPlatformOverride = 'android';
    LumeJsEngine.debugSupportedOverride = true;
  });

  tearDown(() async {
    SourceRegistry.close(Section.cat);
    SourceRegistry.close(Section.video);
    await SectionScope.closeAll();
    CatEngines.debugPlatformOverride = null;
    LumeJsEngine.debugSupportedOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SourceRegistry> openRegistry(Section section) async {
    await SectionScope.open(section);
    return SourceRegistry.open(section);
  }

  test('猫源脚本 require dns：提示点名 dns，并说明自建服务端程序不是图源脚本', () async {
    final registry = await openRegistry(Section.cat);
    final outcome = await registry.import('''
// LumeSource: {"id":"cat-dns","name":"猫源服务","version":"1.0.0"}
var dns = require('dns');
function getList(page) { return { list: [] }; }
''');

    expect(outcome.isSuccess, isFalse);
    final message = outcome.message!;
    expect(message, contains('脚本载入失败：'), reason: '保留「导入失败」的稳定前缀');
    expect(message, contains('dns'), reason: '必须点名是哪个能力不支持');
    expect(
      message,
      contains('自建服务端程序'),
      reason: '这类脚本（node 服务端）要给一句「App 跑不了它」的定向说明',
    );
    expect(registry.sources, isEmpty, reason: '失败不落库');
  }, skip: skipReason);

  test('语法错误：提示带上引擎给出的 SyntaxError 原文', () async {
    final registry = await openRegistry(Section.video);
    final outcome = await registry.import('''
// LumeSource: {"id":"broken","name":"有语法错的源","version":"1.0.0"}
async function getList( { return 1 }
''');

    expect(outcome.isSuccess, isFalse);
    expect(outcome.message, contains('SyntaxError'));
    expect(
      outcome.message,
      isNot(contains('自建服务端程序')),
      reason: '语法错误不该带上服务端说明',
    );
  }, skip: skipReason);

  test('没有运行时报错的环境能力：函数式脚本照旧导入成功并落库', () async {
    final registry = await openRegistry(Section.video);
    final outcome = await registry.import('''
// LumeSource: {"id":"demo-video","name":"公开样片测试源","version":"1.0.0"}
async function getList(page) {
  return { list: [{ title: '测试视频', url: 'https://example.com/demo.mp4' }] };
}
''');

    expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '');
    expect(outcome.record!.id, 'demo-video');
    expect(
      registry.sources.map((item) => item.id),
      contains('demo-video'),
    );
  }, skip: skipReason);
}

/// Windows 下取构建产物，其他平台走进程镜像（与 sandbox_native_test 一致）。
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
