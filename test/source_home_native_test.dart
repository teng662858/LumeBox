import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_home_page.dart';

import 'support/fake_source_manager.dart';

/// 样板脚本驱动的业务页联调：把 `assets/js/example_source.js` 载入真实 QuickJS
/// 沙箱，经 [JsDataSource] 适配器接到小说页与漫画页上，走通分类 → 列表 → 搜索。
///
/// 这是 iOS 之外的替代验证——脚本语法、契约字段名、适配器解析、异常归一与页面
/// 粘合全部在真实引擎上被证明一致；iOS 真机联调仍留待有 Mac 设备后进行。
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言，测试进程同样适用。
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎 · 样板脚本驱动板块业务页', () {
    final script = File('assets/js/example_source.js').readAsStringSync();

    /// 沙箱与图源调用都活在真实事件轮上，因此在测试体内创建（与页面同一时区），
    /// 再用 [settle] 的真实异步窗口推进——这与 iOS 上页面直连引擎的时序一致。
    Future<LumeSandbox> bootSandbox() async {
      final sandbox = LumeSandbox.create(id: 'example-source');
      addTearDown(sandbox.dispose);
      final loaded = await sandbox.load(script);
      expect(
        loaded.isOk,
        isTrue,
        reason: '样板脚本必须能在真实引擎里载入: ${loaded.error}',
      );
      return sandbox;
    }

    /// 真实引擎的调用链要经真实事件轮推进，`pumpAndSettle` 的假时钟驱不动它：
    /// 页面的一次加载往往串起多次引擎调用（打开图源 → 取分类 → 取列表），
    /// 因此交替放行多轮真实异步与帧渲染，直到链路走完。
    Future<void> settle(WidgetTester tester) async {
      for (var round = 0; round < 3; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
    }

    /// 用样板脚本造一个板块内的图源，并交给业务页。
    FakeSourceManager managerFor(Section section, LumeSandbox sandbox) =>
        FakeSourceManager(
          sources: <SourceDescriptor>[
            SourceDescriptor(
              id: 'lume-example',
              name: 'Lume Box 示例源',
              version: '2.0.0',
              enabled: true,
            ),
          ],
          opened: <String, DataSource>{
            'lume-example': JsDataSource(
              id: 'lume-example',
              name: 'Lume Box 示例源',
              section: section,
              runtime: _SandboxRuntime(sandbox),
            ),
          },
        );

    Future<void> runBoardFlow(WidgetTester tester, Section section) async {
      await tester.binding.setSurfaceSize(const ui.Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 一个图源一个沙箱：每个板块各起一个运行时，与生产一致。
      final sandbox = await bootSandbox();
      final manager = managerFor(section, sandbox);
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: SourceHomePage(section: section, manager: manager),
        ),
      );
      await settle(tester);

      expect(
        find.text('Lume Box 示例源'),
        findsOneWidget,
        reason: '${section.label}：图源条应显示当前图源',
      );
      expect(find.text('分类一'), findsOneWidget);
      expect(find.text('分类二'), findsOneWidget);
      expect(find.text('最新 · 示例条目 1'), findsOneWidget);

      // 分类代理。
      await tester.tap(find.text('分类一'));
      await settle(tester);
      expect(find.text('分类：cat-1 · 示例条目 1'), findsOneWidget);

      // 搜索代理。
      await tester.enterText(find.byType(TextField), '关键字');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('搜索：关键字 · 示例条目 1'), findsOneWidget);
    }

    testWidgets(
      '小说业务页：样板脚本驱动分类 / 列表 / 搜索',
      (tester) => runBoardFlow(tester, Section.novel),
    );

    testWidgets(
      '漫画业务页：样板脚本驱动分类 / 列表 / 搜索',
      (tester) => runBoardFlow(tester, Section.comic),
    );
  }, skip: skipReason);
}

/// 测试专用：把底层沙箱适配成数据源运行时端口（与 js_source_native_test 一致）。
class _SandboxRuntime implements JsSourceRuntime {
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
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
