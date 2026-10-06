import 'dart:async';

import '../session/section.dart';
import 'data_source.dart';
import 'source_models.dart';

/// 数据源的简单模拟实现：不联网、不跑脚本，只产出确定性数据。
///
/// 它存在的意义有两个：一是让接口层在没有图源运行时的平台（Windows /
/// Android）也能被完整验证——测试里由它驱动真实页面走通整条链路；二是给
/// 后续真实图源一份结构清晰的对照样例。四个板块共用同一套接口，只有
/// 分类文案、内容类型不同。
class MockDataSource implements DataSource {
  const MockDataSource({
    required this.section,
    this.latency = Duration.zero,
    this.fail = false,
  });

  @override
  final Section section;

  /// 每次调用的人工延迟，用于观察加载态；测试默认零延迟。
  final Duration latency;

  /// 打开后所有调用都抛 [SourceException]，用于验证失败路径。
  final bool fail;

  static const int chapterCount = 5;

  static const Map<Section, List<String>> _categoryLabels =
      <Section, List<String>>{
    Section.novel: <String>['玄幻', '都市', '科幻'],
    Section.comic: <String>['热血', '恋爱', '悬疑'],
    Section.video: <String>['电影', '剧集', '短片'],
    Section.cat: <String>['推荐', '关注', '默认'],
  };

  @override
  String get id => 'lume.mock.${section.id}';

  @override
  String get name => '${section.label}模拟源';

  @override
  Future<List<SourceCategory>> categories() async {
    await _tick();
    return <SourceCategory>[
      for (final (index, label) in _labels().indexed)
        SourceCategory(id: '${section.id}-c${index + 1}', title: label),
    ];
  }

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async {
    await _tick();
    final trimmedKeyword = keyword?.trim() ?? '';
    final trimmedCategory = categoryId?.trim() ?? '';
    final scope = trimmedKeyword.isNotEmpty
        ? '搜索 $trimmedKeyword'
        : trimmedCategory.isEmpty
            ? '最新'
            : _categoryTitle(trimmedCategory);
    final effectivePage = page < 1 ? 1 : page;
    return SourceList(
      items: <SourceItem>[
        for (var index = 1; index <= 3; index++)
          SourceItem(
            id: '${section.id}-$effectivePage-$index',
            title: '$scope · 模拟条目 $index',
            subtitle: '模拟数据 · 第 $effectivePage 页',
          ),
      ],
      hasMore: effectivePage < 2,
    );
  }

  @override
  Future<SourceDetail?> detail(String itemId) async {
    await _tick();
    final id = itemId.trim();
    if (id.isEmpty) return null;
    return SourceDetail(
      id: id,
      title: '模拟作品 $id',
      subtitle: '${section.label} · 模拟数据',
      description: '数据源抽象接口层的模拟实现，用于验证分类、列表、详情、'
          '章节与内容链路；不包含任何真实抓取逻辑。',
    );
  }

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    await _tick();
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
    await _tick();
    switch (section) {
      case Section.novel:
        return TextContent(
          '模拟正文：$itemId / $chapterId。真实源按所属板块返回文本、'
          '图片列表或视频地址之一。',
        );
      case Section.comic:
        return ImageContent(<String>[
          for (var index = 1; index <= 3; index++)
            'https://example.invalid/mock/$chapterId/$index.jpg',
        ]);
      case Section.video:
      case Section.cat:
        // 猫源可以返回任意一种内容，模拟实现统一按视频处理。
        return VideoContent(url: Uri.parse('https://example.invalid/mock/$chapterId.mp4'));
    }
  }

  List<String> _labels() => _categoryLabels[section] ?? const <String>[];

  String _categoryTitle(String categoryId) {
    final labels = _labels();
    for (final (index, label) in labels.indexed) {
      if ('${section.id}-c${index + 1}' == categoryId) return label;
    }
    return categoryId;
  }

  Future<void> _tick() async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    if (fail) {
      throw const SourceException(SourceErrorKind.callFailed, '模拟源被配置为失败');
    }
  }
}
