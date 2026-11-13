import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_episode_catalog.dart';
import 'package:lume_box/features/video/direct_video_source.dart';

void main() {
  test('换线路按中文季数和集数匹配，不把第二季当成第一季', () {
    const second = SourceChapter(id: 'cn', title: '第2季 第03集');
    const first = SourceChapter(id: 's1', title: 'S01E03');
    const matching = SourceChapter(id: 's2', title: 'Drama.S02E03.mkv');
    expect(VideoEpisodeCatalog.matchingIndex(second, [first, matching]), 1);
    expect(VideoEpisodeCatalog.matchingIndex(second, [first]), -1);
    expect(VideoEpisodeCatalog.episodeKey(second), '2:3');
    expect(VideoEpisodeCatalog.episodeNumber('第二季 第十一話'), (season: 2, episode: 11));
    expect(VideoEpisodeCatalog.episodeNumber('第２季 第０３集'), (season: 2, episode: 3));
    expect(VideoEpisodeCatalog.episodeNumber('Season 2 Episode 3'), (season: 2, episode: 3));
  });
  test('跨线路只匹配明确同集，兼容文件名但不混淆季数和重复集数', () {
    const current = SourceChapter(id: 'a', title: '第2集');
    const file = SourceChapter(
      id: 'b',
      title: 'Drama.S01E02.2160p.WEB-DL.mkv [1GB]',
    );
    expect(VideoEpisodeCatalog.matchingIndex(current, [file]), 0);
    expect(VideoEpisodeCatalog.displayLabel(file, 8), '第 02 集');
    expect(
      VideoEpisodeCatalog.matchingIndex(current, [
        const SourceChapter(id: 'c', title: 'S02E02'),
      ]),
      -1,
    );
    expect(
      VideoEpisodeCatalog.matchingIndex(current, [
        file,
        const SourceChapter(id: 'd', title: 'E02'),
      ]),
      -1,
    );
    expect(
      VideoEpisodeCatalog.matchingIndex(current, [
        const SourceChapter(id: 'd', title: '第3集'),
      ]),
      -1,
    );
  });
  test('兼容明确线路、Kazumi标题前缀和猫源flag，并保留原始章节ID', () {
    final chapters = [
      const SourceChapter(id: 'a1', title: '第1集', line: '线路A'),
      const SourceChapter(id: 'a2', title: '第2集', line: '线路A'),
      const SourceChapter(id: 'b1', title: '线路B · 第1集'),
      const SourceChapter(id: 'b2', title: '线路B · 第2集'),
      SourceChapter(
        id: jsonEncode({'flag': '线路C', 'url': 'original'}),
        title: '线路C · 正片',
      ),
    ];
    expect(VideoEpisodeCatalog.group(chapters).keys, ['线路A', '线路B', '线路C']);
    expect(VideoEpisodeCatalog.forChapter(chapters, 'b1').map((e) => e.id), [
      'b1',
      'b2',
    ]);
    expect(VideoEpisodeCatalog.labelOf(chapters[2]), '第1集');
    expect(VideoEpisodeCatalog.labelOf(chapters.last), '正片');
  });

  test('解析详情中的分集线路与真实缩略图，缺少线路时只给默认线路', () {
    final detail = SourceDetail.parse({
      'id': 'm',
      'title': '影片',
      'episodes': [
        {
          'id': 'e',
          'title': '正片',
          'route': '高清',
          'thumbnail': 'https://fixture.test/frame.jpg',
        },
      ],
    })!;
    expect(detail.chapters.single.line, '高清');
    expect(detail.chapters.single.cover, 'https://fixture.test/frame.jpg');
    expect(
      VideoEpisodeCatalog.group([
        const SourceChapter(id: 'single', title: '正片'),
      ]).keys,
      ['默认线路'],
    );
  });

  test('网页捕获保留防盗链请求头且只暴露一集正片', () async {
    final source = DirectVideoSource(
      id: 'web',
      name: '网页',
      title: '影片',
      uri: Uri.parse('https://fixture.test/movie.m3u8'),
      headers: {'Referer': 'https://fixture.test/page'},
    );
    final chapters = await source.chapters('capture');
    expect(chapters, hasLength(1));
    expect(chapters.single.title, '正片');
    final content = await source.content(
      itemId: 'capture',
      chapterId: chapters.single.id,
    ) as VideoContent;
    expect(content.headers['Referer'], 'https://fixture.test/page');
  });

  test('网页整剧保留全部选集，首播复用地址，切集与重试重新解析', () async {
    final resolved = <int>[];
    final source = DirectVideoSource(
      id: 'web',
      name: '网页',
      title: '兰香如故',
      uri: Uri.parse('https://fixture.test/12.m3u8'),
      selected: 11,
      episodes: List.generate(
        47,
        (i) => SourceChapter(id: 'e$i', title: '第${i + 1}集', line: '4K'),
      ),
      resolveEpisode: (index) async {
        resolved.add(index);
        return VideoContent(
          url: Uri.parse('https://fixture.test/${index + 1}.m3u8'),
        );
      },
    );
    final chapters = await source.chapters('drama');
    expect(chapters, hasLength(47));
    expect(VideoEpisodeCatalog.forChapter(chapters, 'e11'), hasLength(47));
    expect(
      (await source.content(
        itemId: 'drama',
        chapterId: 'e11',
      ) as VideoContent).url.path,
      '/12.m3u8',
    );
    expect(resolved, isEmpty);
    expect(
      (await source.content(
        itemId: 'drama',
        chapterId: 'e12',
      ) as VideoContent).url.path,
      '/13.m3u8',
    );
    await source.content(itemId: 'drama', chapterId: 'e11');
    expect(resolved, [12, 11]);
    await expectLater(
      source.content(itemId: 'drama', chapterId: 'missing'),
      throwsFormatException,
    );
  });
}
