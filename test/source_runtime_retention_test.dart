import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/js/sandbox/sandbox_result.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_runtime_pins.dart';

class _Engine implements SourceEngine {
  @override
  String get id => 'fake';
  bool disposed = false;
  @override
  Future<bool> loadScript(String script) async => true;
  @override
  Future<Set<String>?> contractMethods() async => {'home'};
  @override
  String? get loadFailure => null;
  @override
  Future<Map<String, Object?>?> metadata() async => null;
  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) =>
      throw UnimplementedError();
  @override
  void dispose() => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('lume-runtime-retention');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    CatEngines.debugPlatformOverride = 'android';
    SourceEngineRegistry.register(
      CatEngineKind.quickjs,
      ({required sourceId, required http, required section}) async => _Engine(),
    );
  });
  tearDown(() async {
    SourceRegistry.close(Section.cat);
    await SectionScope.closeAll();
    SourceEngineRegistry.reset();
    CatEngines.debugPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    root.deleteSync(recursive: true);
  });
  test('内存压力回收闲置引擎，保护当前源、播放下载引用和在飞调用；旧适配器可重开', () async {
    final scope = await SectionScope.open(Section.cat);
    final db = await SectionDatabase.open(scope);
    for (final id in ['current', 'playing', 'idle']) {
      db.upsertSource(
        id: id,
        name: id,
        version: '1',
        section: 'cat',
        script: 'var source = {};',
      );
    }
    db.setSetting(SourceRegistry.currentSourceKey, 'current');
    final registry = await SourceRegistry.open(Section.cat);
    final current = (await registry.engineFor('current'))! as _Engine;
    final playing = (await registry.engineFor('playing'))! as _Engine;
    final idle = (await registry.engineFor('idle'))! as _Engine;
    final release = SourceRuntimePins.retain(Section.cat, 'playing');
    await registry.withLease(() async {
      SourceRegistry.trimIdleRuntimes();
      expect(idle.disposed, false);
    });
    SourceRegistry.trimIdleRuntimes();
    expect(idle.disposed, true);
    expect(current.disposed, false);
    expect(playing.disposed, false);
    final rebuilt = (await registry.engineFor('idle'))! as _Engine;
    expect(identical(rebuilt, idle), false);
    release();
    SourceRegistry.trimIdleRuntimes();
    expect(playing.disposed, true);
    expect(current.disposed, false);
    expect(rebuilt.disposed, true);
  });
}
