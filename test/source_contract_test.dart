import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/db/source_record.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

void main() {
  test('四大板块标识唯一', () {
    final ids = Section.values.map((section) => section.id).toSet();
    expect(ids.length, Section.values.length);
    expect(ids, containsAll(<String>['novel', 'comic', 'video', 'cat']));
  });

  group('图源元信息校验', () {
    test('接受合法元信息', () {
      final metadata = SourceMetadata.parse(<String, Object?>{
        'id': 'lume-example',
        'name': 'Lume Box 示例源',
        'version': '1.0.0',
      });
      expect(metadata, isNotNull);
      expect(metadata!.id, 'lume-example');
      expect(metadata.version, '1.0.0');
    });

    test('拒绝非法 id 与缺失字段', () {
      expect(
        SourceMetadata.parse(<String, Object?>{'id': 'bad id', 'name': 'x'}),
        isNull,
      );
      expect(
        SourceMetadata.parse(<String, Object?>{'id': '', 'name': 'x'}),
        isNull,
      );
      expect(SourceMetadata.parse(<String, Object?>{'name': 'x'}), isNull);
      expect(SourceMetadata.parse('not a map'), isNull);
    });
  });

  group('内容模型解析', () {
    test('过滤缺字段的条目', () {
      final items = parseItems(<Object?>[
        <String, Object?>{'id': 'a', 'title': '条目 A'},
        <String, Object?>{'id': 'b'},
        'x',
      ]);
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('视频式条目：url 兼作 id，name 兼作标题', () {
      final items = parseItems(<Object?>[
        <String, Object?>{'title': '测试视频', 'url': 'https://example.com/a.mp4'},
        <String, Object?>{'name': '备用写法', 'url': 'https://example.com/b.mp4'},
        <String, Object?>{'title': '没有地址也没有 id'},
      ]);
      expect(items.length, 2);
      expect(items.first.id, 'https://example.com/a.mp4');
      expect(items.first.title, '测试视频');
      expect(items.last.title, '备用写法');
    });

    test('章节缺标题时回退到 id', () {
      final chapters = parseChapters(<Object?>[
        <String, Object?>{'id': 'c1'},
      ]);
      expect(chapters.single.title, 'c1');
    });

    test('非列表输入返回空集合', () {
      expect(parseItems(null), isEmpty);
      expect(parseChapters(<String, Object?>{'id': 'x'}), isEmpty);
    });

    test('分类缺标题时回退到 id，缺 id 则丢弃', () {
      final categories = parseCategories(<Object?>[
        <String, Object?>{'id': 'c1', 'title': '分类一'},
        <String, Object?>{'id': 'c2'},
        <String, Object?>{'title': '无 id'},
        'x',
      ]);
      expect(categories.length, 2);
      expect(categories.first.title, '分类一');
      expect(categories.last.title, 'c2');
      expect(parseCategories(null), isEmpty);
    });
  });

  group('列表信封解析', () {
    test('接受信封与裸数组两种形状', () {
      final envelope = parseSourceList(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{'id': 'a', 'title': '条目 A'},
        ],
        'hasMore': true,
      });
      expect(envelope.items.single.id, 'a');
      expect(envelope.hasMore, isTrue);

      final bare = parseSourceList(<Object?>[
        <String, Object?>{'id': 'b', 'title': '条目 B'},
      ]);
      expect(bare.items.single.id, 'b');
      expect(bare.hasMore, isFalse);
    });

    test('接受函数式脚本的 list 信封', () {
      // 函数式脚本（顶层 getList）常用 {list: [...], hasMore} 表达列表。
      final envelope = parseSourceList(<String, Object?>{
        'list': <Object?>[
          <String, Object?>{'title': '测试视频', 'url': 'https://example.com/a.mp4'},
        ],
        'hasMore': false,
      });
      expect(envelope.items.single.title, '测试视频');
      expect(envelope.items.single.id, 'https://example.com/a.mp4');
    });

    test('items 优先于 list，两者都缺则为空', () {
      final both = parseSourceList(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{'id': 'a', 'title': '条目 A'},
        ],
        'list': <Object?>[
          <String, Object?>{'id': 'b', 'title': '条目 B'},
        ],
      });
      expect(both.items.single.id, 'a');
      expect(parseSourceList(<String, Object?>{'hasMore': true}).isEmpty, isTrue);
    });

    test('无法识别时返回空列表', () {
      expect(parseSourceList(null).isEmpty, isTrue);
      expect(parseSourceList('不是列表').isEmpty, isTrue);
    });
  });

  group('章节内容解析', () {
    test('文本 / 图片 / 视频三类载荷', () {
      expect(
        ChapterContent.parse(<String, Object?>{'kind': 'text', 'text': '正文'}),
        isA<TextContent>(),
      );

      final images = ChapterContent.parse(<String, Object?>{
        'kind': 'images',
        'images': <Object?>['a.jpg', 'b.jpg'],
      });
      expect(images, isA<ImageContent>());
      expect((images! as ImageContent).images, <String>['a.jpg', 'b.jpg']);

      final video = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.invalid/v.mp4',
        'headers': <String, Object?>{'Referer': 'https://example.invalid'},
      });
      expect(video, isA<VideoContent>());
      final videoContent = video! as VideoContent;
      expect(videoContent.url.scheme, 'https');
      expect(videoContent.headers['Referer'], 'https://example.invalid');
    });

    test('裸字符串与裸数组按内容推断，空值视为暂无内容', () {
      expect(ChapterContent.parse('正文'), isA<TextContent>());
      expect(ChapterContent.parse(<Object?>['a.jpg']), isA<ImageContent>());
      expect(ChapterContent.parse(null), isNull);
      expect(ChapterContent.parse(''), isNull);
      expect(ChapterContent.parse(<String, Object?>{'kind': 'text', 'text': '  '}), isNull);
      expect(ChapterContent.parse(<String, Object?>{'kind': 'images', 'images': <Object?>[]}), isNull);
    });

    test('不符合契约时抛 FormatException', () {
      expect(
        () => ChapterContent.parse(<String, Object?>{'kind': 'pdf'}),
        throwsFormatException,
      );
      expect(
        () => ChapterContent.parse(<String, Object?>{'kind': 'video', 'url': ''}),
        throwsFormatException,
      );
      expect(() => ChapterContent.parse(42), throwsFormatException);
    });
  });

  group('镜像声明（mirrors）', () {
    test('头部注释与运行时对象两处都认，头部优先', () {
      const script = '''
// LumeSource: {"id":"mirror-src","name":"镜像源","version":"1.0.0","mirrors":["https://main.example","https://m1.example"]}
var LumeSource = { list: function () {} };
''';
      final header = SourceMetadata.parseHeader(script);
      expect(header?.mirrors, <String>['https://main.example', 'https://m1.example']);

      final runtime = SourceMetadata.parse(<String, Object?>{
        'id': 'mirror-src',
        'name': '镜像源',
        'mirrors': <Object?>['https://runtime.example'],
      });
      expect(runtime?.mirrors, <String>['https://runtime.example']);

      final merged = SourceMetadata.merge(header, runtime);
      expect(merged?.mirrors, header!.mirrors, reason: '头部优先');
      // 头部没声明时用运行时的。
      final onlyRuntime = SourceMetadata.merge(
        SourceMetadata.parseHeader('// LumeSource: {"id":"x","name":"X"}'),
        runtime,
      );
      expect(onlyRuntime?.mirrors, <String>['https://runtime.example']);
    });

    test('非法项丢掉、重复去掉、最多 3 个', () {
      final mirrors = SourceSiteConfig.normalizeMirrors(<Object?>[
        'https://main.example',
        '  ',
        'ftp://example.com',
        'javascript:alert(1)',
        'https://m1.example',
        '//m2.example',
        'https://main.example', // 重复
        'https://m2.example',
        'https://m3.example', // 第 4 条：丢掉
        'https://user:pass@m4.example',
      ]);
      expect(mirrors, <String>[
        'https://main.example',
        'https://m1.example',
        'https://m2.example',
      ]);
      expect(SourceSiteConfig.normalizeMirrors('https://x.example'), isEmpty);
      expect(SourceSiteConfig.normalizeMirrors(null), isEmpty);
    });

    test('尾斜杠去掉；http 也认', () {
      expect(
        SourceSiteConfig.normalizeMirrors(<Object?>[
          'https://main.example/',
          'http://m1.example//',
        ]),
        <String>['https://main.example', 'http://m1.example'],
      );
    });
  });

  group('换网址解析优先级', () {
    const mirrors = <String>['https://main.example', 'https://m1.example'];

    test('自定义域名 > 选中镜像 > 主站', () {
      expect(
        const SourceSiteConfig(
          mirrors: mirrors,
          mirrorIndex: 1,
          domainOverride: 'https://custom.example',
        ).resolvedDomain,
        'https://custom.example',
      );
      expect(
        const SourceSiteConfig(mirrors: mirrors, mirrorIndex: 1).resolvedDomain,
        'https://m1.example',
      );
      expect(
        const SourceSiteConfig(mirrors: mirrors).resolvedDomain,
        'https://main.example',
      );
    });

    test('自定义域名缺 scheme 时补 https、去尾斜杠', () {
      expect(
        const SourceSiteConfig(domainOverride: 'custom.example/').resolvedDomain,
        'https://custom.example',
      );
      expect(
        const SourceSiteConfig(domainOverride: '   ').resolvedDomain,
        '',
        reason: '只有空白等于没填',
      );
      // 非法输入当作没填（界面在此之前已经拦下）。
      expect(
        const SourceSiteConfig(domainOverride: '不是地址').resolvedDomain,
        '',
      );
    });

    test('选中下标越界回落到列表内的镜像，列表为空时 domain 是空串', () {
      expect(
        const SourceSiteConfig(mirrors: mirrors, mirrorIndex: 9).resolvedDomain,
        'https://m1.example',
      );
      expect(
        const SourceSiteConfig(mirrorIndex: 2).resolvedDomain,
        '',
        reason: '脚本没声明镜像 → 脚本自己回落到默认地址',
      );
      expect(SourceSiteConfig.none.resolvedDomain, '');
    });

    test('domainIssue 只对非法输入给原因', () {
      expect(SourceSiteConfig.domainIssue(''), isNull);
      expect(SourceSiteConfig.domainIssue('example.com'), isNull);
      expect(SourceSiteConfig.domainIssue('https://example.com/a/b'), isNull);
      expect(SourceSiteConfig.domainIssue('ftp://example.com'), isNotNull);
      expect(SourceSiteConfig.domainIssue('https://example.com?q=1'), isNotNull);
    });
  });

  group('配置 JSON 往返与老行默认值', () {
    test('SourceSiteConfig 往返保真（含镜像归一）', () {
      const config = SourceSiteConfig(
        mirrors: <String>['https://main.example', 'https://m1.example'],
        mirrorIndex: 1,
        domainOverride: 'https://custom.example',
        account: 'reader',
        password: 'secret',
      );
      final restored = SourceSiteConfig.fromJson(config.toJson());
      expect(restored.mirrors, config.mirrors);
      expect(restored.mirrorIndex, 1);
      expect(restored.domainOverride, 'https://custom.example');
      expect(restored.account, 'reader');
      expect(restored.password, 'secret');
      expect(restored.resolvedDomain, config.resolvedDomain);
    });

    test('缺字段 / 坏 JSON 落到默认值', () {
      expect(SourceSiteConfig.fromJson(null).mirrors, isEmpty);
      expect(SourceSiteConfig.fromJson('不是 JSON').mirrors, isEmpty);
      final partial = SourceSiteConfig.fromJson(<String, Object?>{'mirrors': null});
      expect(partial.mirrors, isEmpty);
      expect(partial.mirrorIndex, 0);
      expect(partial.resolvedDomain, '');
    });

    test('发给脚本的快照带齐字段（domain 已解析、cookie 一并给出）', () {
      const config = SourceSiteConfig(
        mirrors: <String>['https://main.example', 'https://m1.example'],
        mirrorIndex: 1,
      );
      final json = config.toScriptJson(cookie: 'sid=1');
      expect(json['domain'], 'https://m1.example');
      expect(json['mirrors'], config.mirrors);
      expect(json['mirrorIndex'], 1);
      expect(json['customDomain'], '');
      expect(json['account'], '');
      expect(json['password'], '');
      expect(json['cookie'], 'sid=1');
    });

    test('老库行（没有 site_config 列）读出来是默认配置', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      // 旧 schema 的 source 表：没有任何换网址 / 账号登入列。
      db.execute('''
CREATE TABLE source (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL DEFAULT '',
  section TEXT NOT NULL DEFAULT '', script TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL
);
INSERT INTO source (id, name, version, section, script, enabled, updated_at)
VALUES ('old', '老源', '1.0.0', 'novel', 'var x = 1;', 1, 0);
''');
      final record = SourceRecord.fromRow(db.select('SELECT * FROM source').first);
      expect(record.siteConfig.mirrors, isEmpty);
      expect(record.siteConfig.mirrorIndex, 0);
      expect(record.siteConfig.domainOverride, '');
      expect(record.siteConfig.account, '');
      expect(record.siteConfig.password, '');
      expect(record.siteConfig.resolvedDomain, '');
    });
  });
}
