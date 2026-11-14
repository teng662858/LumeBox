import 'dart:convert';

import 'package:flutter/services.dart';

import '../js/lume_js_engine.dart';
import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../session/section.dart';
import 'music_models.dart';

abstract interface class MusicRuntime {
  Future<Map<String, dynamic>> describe();
  Future<Object?> call(String method, [Map<String, dynamic> args = const {}]);
  void dispose();
}

typedef MusicRuntimeFactory = Future<MusicRuntime> Function(
  String id,
  String script,
  MusicProtocol protocol,
);

class QuickJsMusicRuntime implements MusicRuntime {
  QuickJsMusicRuntime._(this.engine, this.http);
  final LumeJsEngine engine;
  final LumeHttp http;
  static Future<MusicRuntime> create(
    String id,
    String script,
    MusicProtocol protocol,
  ) async {
    final http = LumeHttp(settings: LumeNet.settings, source: '音乐插件 $id');
    LumeJsEngine? engine;
    try {
      engine = await LumeJsEngine.create(
        sourceId: 'music-$id',
        http: http,
        section: Section.cat,
        widgetCompatibility: true,
      );
      final compatibility = await rootBundle.loadString(
        'assets/js/music_compat.js',
      );
      final vendor = await rootBundle.loadString('assets/js/music_vendor.js');
      final executable =
          '$vendor\n$compatibility\n__lumeMusicLoad(${jsonEncode(script)},${jsonEncode(protocol.name)},${jsonEncode(id)});';
      if (!await engine.loadScript(executable)) {
        throw FormatException(engine.lastLoadFailure?.message ?? '音乐插件加载失败');
      }
      return QuickJsMusicRuntime._(engine, http);
    } catch (_) {
      engine?.dispose();
      http.dispose();
      rethrow;
    }
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final result = await engine.callResult('music', {
      'method': method,
      ...args,
    });
    if (!result.isOk) throw StateError(result.error?.message ?? '音乐插件调用失败');
    return result.value;
  }

  @override
  Future<Map<String, dynamic>> describe() async =>
      Map<String, dynamic>.from(await call('describe') as Map);
  @override
  void dispose() {
    engine.dispose();
    http.dispose();
  }
}
