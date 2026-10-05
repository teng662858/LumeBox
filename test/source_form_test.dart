import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/source/source_form.dart';

/// 图源可视化编辑器的表单 → 脚本生成与反解。
///
/// 编辑器定位是「新建图源的脚手架」：生成一份能跑的函数式脚本，反解只认自己
/// 生成的东西（带表单标记），不猜任意脚本的写法。
void main() {
  const base = SourceFormDraft(
    id: 'demo-site',
    name: '示例站',
    baseUrl: 'https://example.com',
    listPath: '/api/list',
    detailPath: '/api/detail',
  );

  group('表单校验', () {
    test('合法表单通过', () {
      expect(base.validate(), isNull);
    });

    test('id 缺失或含非法字符给出可读原因', () {
      expect(
        base.copyWith(id: '').validate(),
        contains('请填写图源 id'),
      );
      expect(
        base.copyWith(id: 'bad id!').validate(),
        contains('只允许英文字母'),
      );
      // 长破折号这类易混字符也要拦下（与导入口径一致）。
      expect(base.copyWith(id: 'demo—site').validate(), contains('只允许'));
    });

    test('名称与地址必填，地址要有协议', () {
      expect(base.copyWith(name: '  ').validate(), contains('请填写图源名称'));
      expect(base.copyWith(baseUrl: '').validate(), contains('请填写站点地址'));
      expect(
        base.copyWith(baseUrl: 'example.com').validate(),
        contains('http:// 或 https://'),
      );
    });

    test('JSON 模式必须有标题字段', () {
      expect(
        base.copyWith(jsonTitleField: '  ').validate(),
        contains('标题字段'),
      );
      // HTML 模式不需要字段名。
      expect(
        base
            .copyWith(
              jsonTitleField: '',
              listTemplate: SourceListTemplate.html,
            )
            .validate(),
        isNull,
      );
    });
  });

  group('脚本生成', () {
    test('头部带元信息与表单标记（供反解）', () {
      final script = base.buildScript();
      expect(script, contains('// LumeSource:'));
      expect(script, contains('"id":"demo-site"'));
      expect(script, contains(SourceFormDraft.marker));
    });

    test('生成函数式契约的五个入口', () {
      final script = base.buildScript();
      for (final fn in <String>[
        'async function getList(page)',
        'async function getSearch(keyword, page)',
        'async function getDetail(id)',
        'async function getChapters(id)',
        'async function getContent(id, chapterId)',
      ]) {
        expect(script, contains(fn), reason: '缺少 $fn');
      }
    });

    test('地址与路径被写进脚本，末尾斜杠被规范化', () {
      final script = base
          .copyWith(baseUrl: 'https://example.com/')
          .buildScript();
      expect(script, contains("var BASE = 'https://example.com'"));
      expect(script, contains("url('/api/list'"));
    });

    test('JSON 字段路径：点路径转成属性访问', () {
      final script = base.copyWith(jsonListField: 'data.list').buildScript();
      expect(script, contains('data.data.list'), reason: '点路径要展开');
    });

    test('非法标识符字段名用方括号写法', () {
      final script = base.copyWith(jsonTitleField: 'vod-name').buildScript();
      expect(script, contains("['vod-name']"));
    });

    test('请求头：每行 Name: Value 转成对象', () {
      final script = base
          .copyWith(headers: 'Referer: https://example.com\nX-Token: abc123')
          .buildScript();
      expect(script, contains('"Referer":"https://example.com"'));
      expect(script, contains('"X-Token":"abc123"'));
    });

    test('请求头里的空行与无冒号行被忽略', () {
      final script = base
          .copyWith(headers: '\n随便一行\nGood: yes\n\n')
          .buildScript();
      // 只看生成到代码里的 HEADERS 对象：表单标记里的原文不算数。
      final headersLine = script
          .split('\n')
          .firstWhere((line) => line.startsWith('var HEADERS'));
      expect(headersLine, contains('"Good":"yes"'));
      expect(headersLine, isNot(contains('随便一行')));
    });

    test('单引号与反斜杠被转义（不会生成语法错误的脚本）', () {
      // 单引号进 BASE 的单引号字符串：必须转义，否则脚本语法就错了。
      final quoted = base
          .copyWith(baseUrl: "https://example.com/it's")
          .buildScript();
      final baseLine =
          quoted.split('\n').firstWhere((line) => line.startsWith('var BASE'));
      expect(baseLine, contains(r"\'"));

      // 反斜杠同样要转义（Windows 风格路径 / 正则片段常带）。
      final slashed =
          base.copyWith(baseUrl: r'https://example.com/a\b').buildScript();
      final slashedLine = slashed
          .split('\n')
          .firstWhere((line) => line.startsWith('var BASE'));
      expect(slashedLine, contains(r'\\'));
    });

    test('HTML 模式：生成正则抓链接的写法', () {
      final script = base
          .copyWith(listTemplate: SourceListTemplate.html)
          .buildScript();
      expect(script, contains('pattern.exec(html)'));
      expect(script, contains('<a[^>]+href'));
    });
  });

  group('反解（只认自己生成的脚本）', () {
    test('生成的脚本能反解回同样的表单', () {
      final draft = base.copyWith(
        jsonListField: 'data.list',
        jsonCoverField: 'pic',
        searchKeywordParam: 'kw',
        headers: 'A: 1',
      );
      final restored = SourceFormDraft.parse(draft.buildScript());
      expect(restored, isNotNull);
      expect(restored!.id, draft.id);
      expect(restored.name, draft.name);
      expect(restored.baseUrl, draft.baseUrl);
      expect(restored.listPath, draft.listPath);
      expect(restored.detailPath, draft.detailPath);
      expect(restored.jsonListField, 'data.list');
      expect(restored.jsonCoverField, 'pic');
      expect(restored.searchKeywordParam, 'kw');
      expect(restored.headers, 'A: 1');
    });

    test('非编辑器生成的脚本返回 null（不假装能还原）', () {
      expect(
        SourceFormDraft.parse('var LumeSource = { id: "x", name: "y" };'),
        isNull,
      );
      expect(SourceFormDraft.parse(''), isNull);
    });

    test('标记在但 JSON 坏了：返回 null 而不是抛错', () {
      expect(
        SourceFormDraft.parse('// ${SourceFormDraft.marker} {坏 JSON'),
        isNull,
      );
    });
  });

  group('列表来源形态', () {
    test('id 往返与未知值回退', () {
      for (final template in SourceListTemplate.values) {
        expect(SourceListTemplate.fromId(template.id), template);
      }
      expect(SourceListTemplate.fromId('nope'), SourceListTemplate.json);
      expect(SourceListTemplate.fromId(''), SourceListTemplate.json);
    });
  });
}
