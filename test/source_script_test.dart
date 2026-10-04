import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_script.dart';

/// 图源脚本文本的预处理验证：UTF-8 BOM 剥离 + 头部元信息（`// LumeSource`）
/// 正则解析。带 BOM 的合法脚本不再被误报「缺少元信息」是这里的核心回归。
void main() {
  group('BOM 剥离', () {
    test('去掉开头的 \\uFEFF，正文一字不动', () {
      expect(stripScriptBom('\uFEFFvar a = 1;'), 'var a = 1;');
      expect(stripScriptBom('\uFEFF\uFEFFvar a = 1;'), 'var a = 1;');
      expect(stripScriptBom('var a = 1;'), 'var a = 1;');
      expect(stripScriptBom(''), '');
    });

    test('只剥开头：脚本中间出现的 \\uFEFF 属于正文', () {
      const text = 'var a = "\uFEFF";';
      expect(stripScriptBom(text), text);
    });
  });

  group('头部元信息解析', () {
    test('行注释 JSON 声明', () {
      final metadata = SourceMetadata.parseHeader(
        '// LumeSource: {"id":"lume-example","name":"示例源","version":"1.0.0"}\n'
        'var LumeSource = {id: "lume-example"};',
      );

      expect(metadata, isNotNull);
      expect(metadata!.id, 'lume-example');
      expect(metadata.name, '示例源');
      expect(metadata.version, '1.0.0');
    });

    test('核心回归：带 BOM 的脚本照样解析出头部元信息', () {
      final metadata = SourceMetadata.parseHeader(
        '\uFEFF// LumeSource: {"id":"bom.source","name":"带 BOM 的源","version":"2.0.0"}\n'
        'var LumeSource = {id: "bom.source"};',
      );

      expect(metadata, isNotNull, reason: 'BOM 不许再让元信息正则失配');
      expect(metadata!.id, 'bom.source');
      expect(metadata.name, '带 BOM 的源');
      expect(metadata.version, '2.0.0');
    });

    test('块注释 / @ 前缀 / = 分隔符都认', () {
      final metadata = SourceMetadata.parseHeader(
        '/* @LumeSource = {"id":"blk.src","name":"块注释源","version":"0.1.0"} */\n'
        'var LumeSource = {};',
      );

      expect(metadata?.id, 'blk.src');
      expect(metadata?.name, '块注释源');
    });

    test('key=value 列表写法', () {
      final metadata = SourceMetadata.parseHeader(
        '// LumeSource: id=kv.src, name=KV 源, version=3.0.0\nvar x = 1;',
      );

      expect(metadata?.id, 'kv.src');
      expect(metadata?.name, 'KV 源');
      expect(metadata?.version, '3.0.0');
    });

    test('没有声明、声明不合法、id 非法时返回 null（退回运行时元信息）', () {
      expect(
        SourceMetadata.parseHeader('var LumeSource = {id:"x"};'),
        isNull,
        reason: '没有头部注释',
      );
      expect(
        SourceMetadata.parseHeader('// LumeSource: hello world'),
        isNull,
        reason: '声明里没有 id / name',
      );
      expect(
        SourceMetadata.parseHeader('// LumeSource: {"id":"","name":"空 id"}'),
        isNull,
        reason: 'id 不能为空',
      );
      expect(
        SourceMetadata.parseHeader('// LumeSource: {"id":"非法 id","name":"x"}'),
        isNull,
        reason: 'id 只允许字母数字与 . _ -',
      );
    });

    test('内置示例脚本：声明可解析，且文本本身不带 BOM', () {
      final text = File('assets/js/example_source.js').readAsStringSync();

      expect(stripScriptBom(text), text);
      final metadata = SourceMetadata.parseHeader(text);
      expect(metadata?.id, 'lume-example');
      expect(metadata?.name, 'Lume Box 示例源');
      expect(metadata?.version, '2.0.0');
    });
  });
}
