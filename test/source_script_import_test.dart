import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_script.dart';

/// 图源脚本导入的纯 Dart 验证（不需要真机、不需要 QuickJS 引擎）：
/// 元信息解析、BOM 剥离、非法 id 识别与导入失败诊断。
///
/// 关于任务书里的「type」：LumeSource 元信息里**没有** type 字段——脚本属于哪个
/// 板块（小说 / 漫画 / 视频 / 猫源）由**导入入口**在导入时决定（`Section` 传入
/// 注册表），脚本本身只声明 id / name / version。因此这里的断言是 id / name /
/// version 三个字段，以及这三者在带 BOM 与不带 BOM 时行为一致。
void main() {
  /// 一份"合法的普通 UTF-8（无 BOM）图源脚本"。
  const script = '''
// LumeSource: {"id":"lume-demo","name":"演示源","version":"1.2.3"}
//
// 每个图源在独立 JSContext 中运行；网络请求一律经 fetch 桥接到 Dart 层发出。
var LumeSource = {
  id: 'lume-demo',
  name: '演示源',
  version: '1.2.3',
  async categories() { return [{ id: 'c1', title: '分类一' }]; }
};
''';

  group('1) 普通 UTF-8（无 BOM）脚本', () {
    test('头部元信息解析出 id / name / version', () {
      expect(script.startsWith('\uFEFF'), isFalse, reason: '这份脚本本身没有 BOM');

      final metadata = SourceMetadata.parseHeader(script);

      expect(metadata, isNotNull);
      expect(metadata!.id, 'lume-demo');
      expect(metadata.name, '演示源');
      expect(metadata.version, '1.2.3');
    });

    test('id 通过白名单校验（导入不会被拦）', () {
      expect(SourceMetadata.idIssue('lume-demo'), isNull);
    });

    test('同一份脚本可以被导入到任意板块：元信息与板块无关', () {
      // 元信息解析不接收板块参数——同一份脚本文本在四个板块里解析结果一致，
      // 归属由导入入口决定（这是"脚本不含 type 字段"的直接体现）。
      final forNovel = SourceMetadata.parseHeader(script);
      final forCat = SourceMetadata.parseHeader(script);
      expect(forNovel?.id, forCat?.id);
      expect(forNovel?.name, forCat?.name);
    });
  });

  group('2) 同一份脚本的 UTF-8 BOM 版本', () {
    const bom = '\uFEFF';

    test('stripScriptBom 正确移除开头的 \\uFEFF，正文一字不动', () {
      final withBom = '$bom$script';

      expect(withBom.startsWith(bom), isTrue, reason: '前置条件：确实带了 BOM');
      final cleaned = stripScriptBom(withBom);

      expect(cleaned.startsWith(bom), isFalse, reason: 'BOM 必须被移除');
      expect(cleaned.contains(bom), isFalse);
      expect(cleaned.length, script.length, reason: '只少了 BOM 那一个字符');
      expect(cleaned, script, reason: '正文不许多一个字符、也不许少一个');
    });

    test('元信息同样解析成功（BOM 不再让正则失配）', () {
      final withBom = '$bom$script';

      // 解析器内部会先剥 BOM：对带 BOM 的原文与剥好的文本都成立。
      final fromRaw = SourceMetadata.parseHeader(withBom);
      final fromCleaned = SourceMetadata.parseHeader(stripScriptBom(withBom));

      expect(fromRaw, isNotNull, reason: '带 BOM 的合法脚本不该被误报「缺少元信息」');
      expect(fromRaw!.id, 'lume-demo');
      expect(fromRaw.name, '演示源');
      expect(fromCleaned?.id, fromRaw.id);
      expect(fromCleaned?.version, '1.2.3');
    });

    test('剥离顺序：先 stripScriptBom 再匹配（对多字节正文也成立）', () {
      final withBom = '$bom// LumeSource: {"id":"bom-demo","name":"带 BOM 的中文源"}\n'
          'var x = "猫源😺";';
      expect(SourceMetadata.parseHeader(withBom)?.name, '带 BOM 的中文源');
      expect(SourceMetadata.parseHeader(withBom)?.id, 'bom-demo');
    });
  });

  group('3) id 含非法字符（长破折号等）', () {
    const longDash = '\u2014'; // 长破折号 U+2014

    test('解析器识别非法字符：返回 null 并点名到字符与码位', () {
      final badScript =
          '// LumeSource: {"id":"lume${longDash}demo","name":"坏 id 源"}';

      // 解析器不产出元信息（非法 id 一律拒绝）。
      expect(SourceMetadata.parseHeader(badScript), isNull);

      // 诊断接口点名到字符与码位——这正是"抛出对应错误"给用户看到的内容。
      final issue = SourceMetadata.idIssue('lume${longDash}demo');
      expect(issue, isNotNull);
      expect(issue, contains(longDash), reason: '点名那个非法字符');
      expect(issue, contains('U+2014'), reason: '给出码位，便于定位');
    });

    test('导入失败文案：指出检查 // LumeSource 元信息与 id 字符合法性', () {
      final badScript =
          '// LumeSource: {"id":"lume${longDash}demo","name":"坏 id 源"}';

      final message = SourceMetadata.describeImportFailure(
        null,
        script: badScript,
      );

      expect(message, contains('lume${longDash}demo'), reason: '把问题 id 原样回显');
      expect(message, contains('U+2014'));
      expect(message, contains('// LumeSource'), reason: '告诉用户去检查哪一行');
      expect(message, contains('英文字母、数字'));
      expect(message, contains('下划线'));
    });

    test('全角符号同样被识别（不只是长破折号）', () {
      const fullWidthDot = '\uFF0E'; // 全角句点
      final issue = SourceMetadata.idIssue('lume${fullWidthDot}demo');
      expect(issue, contains(fullWidthDot));
      expect(issue, contains('U+FF0E'));
      expect(
        SourceMetadata.parseHeader(
          '// LumeSource: {"id":"lume${fullWidthDot}demo","name":"x"}',
        ),
        isNull,
      );
    });

    test('运行时 LumeSource.id 非法：走同一条诊断（头部没声明时也拦得住）', () {
      final message = SourceMetadata.describeImportFailure(
        <String, Object?>{'id': 'lume${longDash}demo', 'name': '坏 id 源'},
      );

      expect(message, contains('源 id 不合法'));
      expect(message, contains('U+2014'));
    });

    test('完全没有元信息：提示补齐头部声明或运行时字段', () {
      final message = SourceMetadata.describeImportFailure(const <String, Object?>{});

      expect(message, contains('缺少 LumeSource 元信息'));
      expect(message, contains('id'));
      expect(message, contains('name'));
    });
  });
}
