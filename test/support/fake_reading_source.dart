import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

/// 阅读体系测试用的数据源替身：不联网、不跑脚本，只产出确定性内容。
///
/// 它替代的是「网络 + 沙箱」这一段，接口语义与正式实现一致（空结果不算失败、
/// 失败抛 [SourceException]），因此用它驱动的页面测试与真机走的是同一条代码路径。
/// 生产代码里没有任何替身入口——它只存在于测试目录。
class FakeReadingDataSource implements DataSource {
  FakeReadingDataSource({
    required this.section,
    this.chapterCount = 5,
    this.paragraphs = 24,
    this.imageCount = 6,
    this.fail = false,
  });

  @override
  final Section section;

  /// 章节数量。
  final int chapterCount;

  /// 小说正文的段落数（用来撑出多页）。
  final int paragraphs;

  /// 漫画章节的图片数量。
  final int imageCount;

  /// 为真时所有调用都抛 [SourceException]，用于验证失败路径。
  final bool fail;

  /// 图片地址：指向不可达域名，页面只会走到占位与失败态。
  static const String imageHost = 'https://example.invalid/fake';

  @override
  String get id => 'fake.${section.id}';

  @override
  String get name => '${section.label}测试源';

  @override
  Future<List<SourceCategory>> categories() async {
    _tick();
    return <SourceCategory>[
      SourceCategory(id: '${section.id}-c1', title: '分类一'),
      SourceCategory(id: '${section.id}-c2', title: '分类二'),
    ];
  }

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async {
    _tick();
    return SourceList(
      items: <SourceItem>[
        for (var index = 1; index <= 4; index++)
          SourceItem(
            id: 'item-$index',
            title: '测试作品 $index',
            subtitle: '${section.label} · 第 $page 页',
          ),
      ],
      hasMore: page < 2,
    );
  }

  @override
  Future<SourceDetail?> detail(String itemId) async {
    _tick();
    if (itemId.isEmpty) return null;
    return SourceDetail(
      id: itemId,
      title: '测试作品 $itemId',
      subtitle: '${section.label} · 测试源',
      description: '用于阅读体系测试的确定性内容。',
    );
  }

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    _tick();
    return <SourceChapter>[
      for (var index = 1; index <= chapterCount; index++)
        SourceChapter(id: '$itemId-c$index', title: '第 $index 章'),
    ];
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    _tick();
    return switch (section) {
      Section.novel => TextContent(chapterText(itemId, chapterId)),
      Section.comic => ImageContent(<String>[
          for (var index = 1; index <= imageCount; index++)
            '$imageHost/$chapterId/$index.jpg',
        ]),
      Section.video || Section.cat =>
        VideoContent(url: Uri.parse('$imageHost/$chapterId.mp4')),
    };
  }

  /// 小说章节正文：段落够多，保证在小视口下也能分出多页。
  String chapterText(String itemId, String chapterId) => <String>[
        for (var index = 1; index <= paragraphs; index++)
          '第$index段：这是用于验证小说阅读器的正文，需要足够长才能折行，'
              '也需要足够多的段落才能分出多页。$itemId / $chapterId。',
      ].join('\n');

  void _tick() {
    if (fail) {
      throw const SourceException(SourceErrorKind.callFailed, '测试源被配置为失败');
    }
  }
}
