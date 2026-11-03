// Explicit Android UI preview. The sample prose is local demonstration data;
// normal App sources and subscriptions are not modified by this entry point.
import 'package:flutter/material.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_detail_page.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MediaLibrary.instance.boot();
  final library = await ReadingLibrary.open(Section.video);
  final source = _PreviewSource();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xff7461a6),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('小说与自动识别预览')),
        body: Builder(
          builder: (context) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '本地示例正文 · 用于检查排版和操作',
                  style: TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 12),
                const Text(
                  '下面的作品从视频详情入口进入，没有声明类型。App 将根据章节正文自动打开小说详情。这里复用正式详情页、阅读器和进度存储。',
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => VideoDetailPage(
                        source: source,
                        item: const SourceItem(
                          id: 'mountain',
                          title: '山间来信（示例正文）',
                        ),
                        library: library,
                        onPlay: (_, _, _, _) async {},
                      ),
                    ),
                  ),
                  child: const Text('打开作品 · 自动识别'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PreviewSource implements DataSource {
  @override
  String get id => 'novel_layout_preview';
  @override
  String get name => '本地排版演示';
  @override
  Section get section => Section.video;
  @override
  Future<List<SourceCategory>> categories() async => [];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(items: [], hasMore: false);
  @override
  Future<SourceDetail?> detail(String itemId) async => SourceDetail(
    id: itemId,
    title: '山间来信（示例正文）',
    author: 'LumeBox 排版演示',
    description: '示例正文仅用于检查小说阅读排版。可以左右翻页、打开目录、调整字号和行距，切换护眼或夜间背景。返回后再次进入可继续阅读。',
  );
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => const [
    SourceChapter(id: 'morning', title: '第一章 · 清晨'),
    SourceChapter(id: 'letter', title: '第二章 · 来信'),
    SourceChapter(id: 'road', title: '第三章 · 归途'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    const paragraphs = [
      '晨光越过山脊的时候，小镇还没有醒来。石桥下的水清得见底，几片落叶沿着水流缓缓转动。林遥推开窗，看见远山被薄雾遮住了一半。',
      '桌上放着一封没有署名的信，信封边缘微微卷起，像是经过了一段漫长的旅途。她把信翻过来，邮戳上那个熟悉的地名，让她想起许多年以前的夏天。',
      '那时的路总显得很长。两个人沿着河岸走，鞋底沾满细碎的泥沙，谁也没有提起终点。山风从树林里穿过，带来雨后草木的气息。',
      '她终于拆开信。纸上的字不多，字迹却十分认真：“如果你还记得那座旧桥，就在春天回来看看吧。桥边的树今年又开花了。”',
      '林遥把信重新折好，放进口袋。街角传来第一声车铃，面包店亮起暖黄的灯。她忽然觉得，有些等待了很久的事，也许只需要从迈出家门开始。',
    ];
    return TextContent(
      List.generate(12, (_) => paragraphs.join('\n\n')).join('\n\n'),
    );
  }
}

Future<void> openNovelReaderPreview(BuildContext context) async {
  final library =
      ReadingLibrary.find(Section.video) ??
      await ReadingLibrary.open(Section.video);
  final source = _PreviewSource();
  final chapters = await source.chapters('mountain');
  if (!context.mounted) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => NovelReaderPage(
        source: source,
        library: library,
        target: ReadingTarget(
          sourceId: source.id,
          itemId: 'mountain',
          title: '山间来信（示例正文）',
        ),
        chapters: chapters,
      ),
    ),
  );
}
