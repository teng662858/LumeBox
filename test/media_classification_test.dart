import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/media/media_resource_service.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_media_hints.dart';

import 'support/fake_reading_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('有声板块声明直接提供音频类型，显式媒体类型仍优先', () {
    expect(
      SourceMediaHints.fromScript('// LumeSource: {"category":"audiobook"}'),
      'audio',
    );
    expect(
      SourceMediaHints.fromScript(
        '// LumeSource: {"category":"audiobook","mediaType":"video"}',
      ),
      'video',
    );
  });
  late Directory root;
  late MediaLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-media-test-');
    library = MediaLibrary();
    await library.boot(directory: root);
  });
  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });
  test(
    'real audio-only tracks override video origin and misleading filename',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/mediaTracks'),
            (_) async => {'known': true, 'audio': true, 'video': false},
          );
      final entry = await MediaResourceService(library: library).source(
        source: FakeReadingDataSource(section: Section.video),
        item: const SourceItem(id: 'audio', title: '有声书'),
        chapters: const [SourceChapter(id: '1', title: '第1集')],
        firstContent: VideoContent(
          url: Uri.parse('https://audio.example/misleading.mp4'),
        ),
      );
      expect(entry.kind, ResourceKind.audioBook);
      expect(entry.destination, Section.video);
      expect(entry.originSection, Section.video);
      expect(entry.manual, false);
    },
  );
  test('video track wins even when file is named mp3', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => {'known': true, 'audio': true, 'video': true},
        );
    final entry = await MediaResourceService(library: library).source(
      source: FakeReadingDataSource(section: Section.video),
      item: const SourceItem(id: 'video', title: '视频'),
      chapters: const [SourceChapter(id: '1', title: '第1集')],
      firstContent: VideoContent(
        url: Uri.parse('https://video.example/misleading.mp3'),
        audioOnly: true,
      ),
    );
    expect(entry.kind, ResourceKind.video);
    expect(entry.destination, Section.video);
  });

  test('详情已识别音轨时不再等待原生探测', () async {
    var probes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumebox/mediaTracks'), (
          _,
        ) async {
          probes++;
          throw StateError('不应重复探测');
        });
    final entry = await MediaResourceService(library: library).source(
      source: FakeReadingDataSource(section: Section.video),
      item: const SourceItem(id: 'prepared-audio', title: '听书'),
      chapters: const [SourceChapter(id: 'one', title: '第一集')],
      firstContent: VideoContent(url: Uri.parse('https://prepared.test/play')),
      trackInfo: const MediaTrackInfo(known: true, audio: true),
    );
    expect(entry.kind, ResourceKind.audioBook);
    expect(probes, 0);
  });

  test('已识别音频可先建立目录，进入播放页后才解析地址', () async {
    final source = _DeferredAudioSource();
    final entry = await MediaResourceService(library: library).source(
      source: source,
      item: const SourceItem(id: 'deferred', title: '听书'),
      chapters: const [SourceChapter(id: 'chapter', title: '第一集')],
      hint: ResourceKind.audioBook,
      trackInfo: const MediaTrackInfo(known: true, audio: true),
      deferContent: true,
    );
    expect(entry.kind, ResourceKind.audioBook);
    expect(entry.episodes.single.id, 'chapter');
    expect(source.calls, 0);
  });

  test('复用选中集地址和请求头，后续解析仍刷新地址', () async {
    final entry = MediaResource(
      id: 'prepared',
      title: '听书',
      kind: ResourceKind.audioBook,
      destination: Section.video,
      episodes: [
        for (var i = 0; i < 2; i++)
          ResourceEpisode(
            id: '$i',
            title: '$i',
            url: Uri.parse('https://fresh.test/$i.mp3'),
          ),
      ],
    );
    final prepared = ResolvedMedia(
      Uri.parse('https://prepared.test/play'),
      headers: const {'Referer': 'https://book.test/'},
    );
    final tracks = MediaResourceService(library: library)
        .audioTracks(entry, initialIndex: 1, initialMedia: prepared);
    expect((await tracks.first.resolve!()).url, entry.episodes.first.url);
    final selected = await tracks[1].resolve!();
    expect(selected.url, prepared.url);
    expect(selected.headers, prepared.headers);
    expect((await tracks[1].resolve!()).url, entry.episodes[1].url);
  });

  test('audio payload kinds retain audio classification hint', () {
    final content = ChapterContent.parse({
      'kind': 'audio',
      'url': 'https://example.com/audio',
    });
    expect(content, isA<VideoContent>());
    expect((content as VideoContent).audioOnly, true);
    expect(
      const MediaTrackInfo(known: true, audio: true).kind,
      ResourceKind.audioBook,
    );
    expect(const MediaTrackInfo().kind, null);
  });

  test('旧小说库中的成品音频仍保留，文本小说不会恢复', () {
    final entry = MediaResource.fromJson({
      'id': 'old-audio',
      'title': '音频',
      'kind': 'audioBook',
      'destination': 'novel',
      'episodes': [
        {'id': 'one', 'title': '第一集', 'url': 'file:///audio/one.mp3'},
      ],
    });
    expect(entry.destination, Section.video);
    expect(entry.episodes.single.url.toString(), 'file:///audio/one.mp3');
    expect(
      () => MediaResource.fromJson({
        'id': 'old-text',
        'title': '正文',
        'kind': 'textNovel',
        'destination': 'novel',
        'episodes': [],
      }),
      throwsArgumentError,
    );
  });

  test('音频播放队列保留延迟解析地址与请求头', () async {
    final entry = MediaResource(
      id: 'playlist',
      title: '音频合集',
      kind: ResourceKind.audioBook,
      destination: Section.video,
      episodes: [
        ResourceEpisode(
          id: 'one',
          title: '第一集',
          url: Uri.parse('https://example.test/audio.mp3'),
          headers: const {'Referer': 'https://example.test/'},
        ),
      ],
    );
    final tracks = MediaResourceService(library: library).audioTracks(entry);
    expect(tracks.single.album, entry.title);
    final resolved = await tracks.single.resolve!();
    expect(resolved.url, entry.episodes.single.url);
    expect(resolved.headers, entry.episodes.single.headers);
  });
}

class _DeferredAudioSource extends FakeReadingDataSource {
  _DeferredAudioSource() : super(section: Section.video);
  int calls = 0;
  @override
  Future<ChapterContent> content({
    required String itemId,
    required String chapterId,
  }) async {
    calls++;
    throw StateError('应在播放页解析');
  }
}
