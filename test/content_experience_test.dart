import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/experience/offline_policy.dart';
import 'package:lume_box/core/experience/subtitle_service.dart';
import 'package:lume_box/core/player/text_subtitles.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/session/section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final center = ContentCenter.instance;
  const first = ContentRef(Section.video, 'a', '1', '电影');
  const second = ContentRef(Section.comic, 'b', '1', '原著');
  setUp(() {
    AppPreferences.instance.file = null;
    AppPreferences.instance.experience = {};
  });
  test('作品隔离，同名不自动合并，显式关联保留所有版本', () {
    expect(first.key, isNot(second.key));
    center.link('作品', const [first, second]);
    center.link('完整作品', const [
      first,
      ContentRef(Section.video, 'c', '2', '配音版'),
    ]);
    expect(center.related(second), hasLength(3));
    expect(center.rows('groups'), hasLength(1));
    expect(ContentRef.parse(first.toJson())!.key, first.key);
  });
  test('首检仅建基线，重排不报更新，空目录不擦基线', () {
    const one = SourceChapterFact('a', '第一集'),
        two = SourceChapterFact('b', '第二集');
    expect(center.compare(first, [one, two]), isEmpty);
    expect(center.compare(first, [two, one]), isEmpty);
    center.compare(first, []);
    expect(
      center.compare(first, [one, two, const SourceChapterFact('c', '第三集')]),
      hasLength(1),
    );
    expect(center.rows('updates').single['count'], 1);
    center.markRead('${center.rows('updates').single['id']}');
    expect(center.rows('updates').single['read'], true);
  });
  test('隐藏不删除引用，摘录保留时间点和文件夹', () {
    center.hide(first, true);
    expect(center.hidden(first), true);
    center.hide(first, false);
    expect(center.hidden(first), false);
    center.clip(
      first,
      text: '对白',
      folder: '片段',
      seconds: 125,
      chapter: 2,
      chapterId: 'e-37',
    );
    expect(center.rows('clips').single['seconds'], 125);
    expect(center.rows('clips').single['folder'], '片段');
    expect(center.rows('clips').single['chapterId'], 'e-37');
  });
  test('保存无备注的听书书签和漫画页码，保留零时间点和第一页', () {
    center.clip(first, text: '  ', chapter: 1, seconds: 0);
    center.clip(second, text: '', chapter: 2, page: 0);
    expect(center.rows('clips').map((clip) => clip['text']), ['0:00', '第 1 页']);
    expect(center.rows('clips').first['seconds'], 0);
    expect(center.rows('clips').last['page'], 0);
    center.clip(first, text: ' ', chapter: 1);
    expect(center.rows('clips'), hasLength(2));
  });

  test('离线策略不把未知网络当作 Wi-Fi，播放让路及空间阈值生效', () async {
    center.put('wifiOnly', true);
    expect(
      await OfflinePolicy.blocked(
        inspect: () async => {'wifi': false},
        playing: false,
      ),
      contains('Wi-Fi'),
    );
    expect(
      await OfflinePolicy.blocked(
        inspect: () async => {'wifi': true},
        playing: false,
      ),
      isNull,
    );
    center.put('reserveMB', 512);
    expect(
      await OfflinePolicy.blocked(
        inspect: () async => {'wifi': true, 'freeBytes': 1024},
        playing: false,
      ),
      contains('空间'),
    );
    center.put('pauseDuringPlayback', true);
    expect(await OfflinePolicy.blocked(playing: true), contains('播放'));
  });
  test('字幕搜索仅传官方认证，保留文件身份和语言', () async {
    final service = SubtitleService(
      const SubtitleAccount('api', 'token'),
      client: MockClient((request) async {
        expect(request.url.host, 'api.opensubtitles.com');
        expect(request.url.queryParameters['languages'], 'zh-cn,en');
        return http.Response(
          jsonEncode({
            'data': [
              {
                'attributes': {
                  'language': 'zh-cn',
                  'files': [
                    {'file_id': 123, 'file_name': 'movie.srt'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    final results = await service.search('电影', 'zh-cn,en');
    expect(results.single.id, 123);
    expect(results.single.language, 'zh-cn');
    service.close();
  });
  test('双语合并保留错开时间与重叠对白', () {
    final one = TextSubtitles.parse('1\n00:00:01,000 --> 00:00:03,000\n你好\n');
    final two = TextSubtitles.parse(
      '1\n00:00:02,000 --> 00:00:04,000\nHello\n',
    );
    final merged = TextSubtitles.parse(SubtitleService.bilingual(one, two));
    expect(merged.at(const Duration(milliseconds: 2500)), contains('你好'));
    expect(merged.at(const Duration(milliseconds: 2500)), contains('Hello'));
    expect(merged.at(const Duration(milliseconds: 3500)), 'Hello');
    expect(merged.at(Duration.zero), '');
  });
  test('下载的 UTF-16 WebVTT 以 UTF-8 保存并保留扩展名', () async {
    final root = Directory.systemTemp.createTempSync('subtitle-download-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      root.deleteSync(recursive: true);
    });
    const subtitle = 'WEBVTT\r\rNOTE\r00:01.000 --> 00:02.000\r注释示例\r\r'
        '00:01.000 --> 00:02.000\r你好\r';
    final bytes = [
      0xfe, 0xff,
      for (final c in subtitle.codeUnits) ...[c >> 8, c & 255],
    ];
    final service = SubtitleService(
      const SubtitleAccount('api', 'token'),
      client: MockClient((r) async {
        if (r.method == 'POST') {
          return http.Response('{"link":"https://cdn.example/caption"}', 200);
        }
        expect(r.headers.containsKey('Authorization'), false);
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(service.close);
    final file = await service.download(123);
    expect(file.path, endsWith('.vtt'));
    expect(await file.readAsBytes(), utf8.encode(subtitle));
    final imported = (await TextSubtitles.load(file.path))!;
    expect(imported.at(const Duration(seconds: 1)), '你好');
    final bilingual = TextSubtitles.parse(SubtitleService.bilingual(imported,
        TextSubtitles.parse('00:01.000 --> 00:02.000\nHello\n')));
    expect(bilingual.at(const Duration(seconds: 1)), '你好\nHello');
  });
  test('a subtitle download containing only a VTT comment is rejected', () async {
    final service = SubtitleService(
      const SubtitleAccount('api', 'token'),
      client: MockClient((r) async => r.method == 'POST'
          ? http.Response('{"link":"https://cdn.example/caption"}', 200)
          : http.Response.bytes(utf8.encode('WEBVTT\n\nNOTE\n00:01.000 --> 00:02.000\n注释\n'), 200)),
    );
    addTearDown(service.close);
    await expectLater(service.download(456), throwsA(isA<FormatException>()));
  });
  test('双语字幕导出后保留可见的尖括号和实体文本', () {
    final original = TextSubtitles.parse(
      'WEBVTT\n\n00:01.000 --> 00:03.000\n&lt;角色&gt; A &amp; B &amp;lt; &amp;nbsp;\n',
    );
    final merged = SubtitleService.bilingual(original, TextSubtitles([]));
    expect(TextSubtitles.parse(merged).at(const Duration(seconds: 1)),
        '<角色> A & B &lt; &nbsp;');
  });
}
