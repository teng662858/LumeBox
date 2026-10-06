import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/source_import_input.dart';
import 'package:lume_box/core/source/source_backup.dart';

/// 导入输入的识别：脚本 / 地址清单 / 裸 MD5 校验值 / 备份 / 认不出。
///
/// 这一层是「本地文件与剪贴板共用的一遍识别」，判定顺序本身就是口径：
/// 备份必须排在脚本之前（备份里带着脚本原文，否则会被当成脚本导入）。
void main() {
  SourceImportInput classify(String text, {String name = '', int urlLimit = 20}) =>
      SourceImportInput.classify(text, name: name, urlLimit: urlLimit);

  group('脚本', () {
    test('头部注释声明的函数式脚本', () {
      final input = classify(
        '// LumeSource: {"id":"demo","name":"演示源","version":"1.0.0"}\n'
        'async function getList(page) { return []; }',
        name: 'demo.js',
      );

      expect(input.kind, SourceImportInputKind.script);
      expect(input.isImportable, isTrue);
      expect(input.text, contains('getList'), reason: '脚本原文原样带出');
      expect(input.name, 'demo.js');
    });

    test('正文含运行时 LumeSource 的脚本', () {
      final input = classify('var LumeSource = {id: "x", name: "y"};');
      expect(input.kind, SourceImportInputKind.script);
    });

    test('带 UTF-8 BOM 的脚本同样认得（判定前先剥 BOM）', () {
      final input = classify(
        '\uFEFF// LumeSource: {"id":"bom","name":"BOM 源"}',
      );
      expect(input.kind, SourceImportInputKind.script);
      expect(
        input.text.startsWith('\uFEFF'),
        isTrue,
        reason: '剥 BOM 由落库前的统一预处理负责，这里不重复动原文',
      );
    });
  });

  group('地址清单', () {
    test('一行一个地址，忽略空行与 # 注释行', () {
      final input = classify(
        'https://example.com/a.js\n'
        '\n'
        '# 这是注释\n'
        'https://example.com/b.js\n',
        name: 'list.txt',
      );

      expect(input.kind, SourceImportInputKind.manifest);
      expect(input.urls, <String>[
        'https://example.com/a.js',
        'https://example.com/b.js',
      ]);
    });

    test('CRLF 清单同样解析', () {
      final input = classify(
        'https://example.com/a.js\r\nhttps://example.com/b.js\r\n',
      );
      expect(input.urls.length, 2);
    });

    test('.js.md5 清单地址也算清单（去掉 .md5 取实体由订阅解析负责）', () {
      final input = classify('https://example.com/cat/index.js.md5');
      expect(input.kind, SourceImportInputKind.manifest);
      expect(input.urls, <String>['https://example.com/cat/index.js.md5']);
    });

    test('清单超过上限时只收前 N 条', () {
      final input = classify(
        List<String>.generate(5, (i) => 'https://example.com/$i.js').join('\n'),
        urlLimit: 3,
      );
      expect(input.urls.length, 3);
    });
  });

  group('裸 MD5 校验值与备份', () {
    test('32 位十六进制（大小写与空白都认）判为校验值，并点名下一步', () {
      final input = classify(
        '  6C7379BC24A23EC5B923ECF6F9C9D331\n',
        name: 'index.js.md5',
      );

      expect(input.kind, SourceImportInputKind.checksum);
      expect(input.isImportable, isFalse);
      expect(input.describeFailure, contains('index.js.md5'));
      expect(input.describeFailure, contains('订阅链接'), reason: '要给出下一步动作');
    });

    test('备份 JSON 优先于脚本判定（备份里带着脚本原文）', () {
      final backup = SourceBackup(
        version: SourceBackup.currentVersion,
        createdAt: DateTime(2026, 10, 6),
        sections: <String, List<SourceBackupEntry>>{
          'novel': <SourceBackupEntry>[
            const SourceBackupEntry(
              id: 'demo',
              name: '演示源',
              version: '1.0.0',
              script: 'var LumeSource = {id: "demo", name: "演示源"};',
              enabled: true,
            ),
          ],
        },
      );

      final input = classify(backup.encode(), name: 'lumesources.json');
      expect(
        input.kind,
        SourceImportInputKind.backup,
        reason: '备份里含 LumeSource，若不先判备份会被当成脚本导入',
      );
      expect(input.describeFailure, contains('恢复源'));
    });
  });

  group('认不出', () {
    test('空文本与纯空白', () {
      expect(classify('').kind, SourceImportInputKind.unknown);
      expect(classify('   \n\t ').kind, SourceImportInputKind.unknown);
    });

    test('既不是脚本也不是地址的普通文本', () {
      final input = classify('今天天气不错', name: 'note.txt');
      expect(input.kind, SourceImportInputKind.unknown);
      expect(input.describeFailure, contains('note.txt'));
      expect(input.describeFailure, contains('没有识别出'));
    });
  });
}
