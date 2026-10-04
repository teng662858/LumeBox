import 'package:flutter_test/flutter_test.dart';

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
}
