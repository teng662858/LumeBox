import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/playback_session.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/source_playback.dart';

/// 清晰度候选线路的**图源契约**与播放会话通道的契约（第 5 项的收尾两块）。
///
/// 清晰度这条口径是用户点名的：**清晰度由图源数据决定，播放器只消费地址、
/// 不生成清晰度**——因此这里验的是「图源怎么写、我们怎么读」，而不是分辨率推断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('清晰度：图源给多条线路', () {
    test('标准写法：url + qualities（label/url 一一对应）', () {
      final content = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/1080.mp4',
        'headers': <String, Object?>{'Referer': 'https://example.com/'},
        'qualities': <Object?>[
          <String, Object?>{
            'label': '1080P',
            'url': 'https://example.com/1080.mp4',
          },
          <String, Object?>{
            'label': '720P',
            'url': 'https://example.com/720.mp4',
          },
        ],
      });

      expect(content, isA<VideoContent>());
      final video = content! as VideoContent;
      expect(video.url.toString(), 'https://example.com/1080.mp4');
      expect(video.qualities, hasLength(2));
      expect(video.qualities.first.label, '1080P');
      expect(video.hasQualities, isTrue);
    });

    test('别名与兜底：levels 键、name/quality 标签、缺标签时「线路 N」', () {
      final video = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/a.mp4',
        'levels': <Object?>[
          <String, Object?>{'name': '超清', 'playUrl': 'https://example.com/a.mp4'},
          <String, Object?>{'quality': '高清', 'src': 'https://example.com/b.mp4'},
          <String, Object?>{'url': 'https://example.com/c.mp4'},
        ],
      })! as VideoContent;

      expect(
        video.qualities.map((quality) => quality.label).toList(),
        <String>['超清', '高清', '线路 3'],
        reason: '不编造分辨率：图源没给标签就按顺序编号',
      );
    });

    test('非法条目跳过：没有地址 / 地址没有协议', () {
      final video = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/a.mp4',
        'qualities': <Object?>[
          <String, Object?>{'label': '坏的', 'url': 'not-a-url'},
          <String, Object?>{'label': '没地址'},
          <String, Object?>{'label': '好的', 'url': 'https://example.com/b.mp4'},
        ],
      })! as VideoContent;

      expect(video.qualities, hasLength(1));
      expect(video.qualities.single.label, '好的');
    });

    test('只给 qualities 不给 url：用第一条当默认地址', () {
      final video = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'qualities': <Object?>[
          <String, Object?>{'label': '线路一', 'url': 'https://example.com/1.mp4'},
          <String, Object?>{'label': '线路二', 'url': 'https://example.com/2.mp4'},
        ],
      })! as VideoContent;

      expect(video.url.toString(), 'https://example.com/1.mp4');
    });

    test('单条 / 没有 qualities：hasQualities 为假（按钮届时弹提示）', () {
      final single = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/a.mp4',
        'qualities': <Object?>[
          <String, Object?>{'label': '唯一', 'url': 'https://example.com/a.mp4'},
        ],
      })! as VideoContent;
      expect(single.qualities, hasLength(1));
      expect(single.hasQualities, isFalse);

      final none = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/a.mp4',
      })! as VideoContent;
      expect(none.qualities, isEmpty);
      expect(none.hasQualities, isFalse);
    });

    test('逐线路请求头为空时继承主 headers（防盗链头往往只写一处）', () {
      final video = ChapterContent.parse(<String, Object?>{
        'kind': 'video',
        'url': 'https://example.com/a.mp4',
        'headers': <String, Object?>{'Referer': 'https://example.com/'},
        'qualities': <Object?>[
          <String, Object?>{'label': '继承', 'url': 'https://example.com/a.mp4'},
          <String, Object?>{
            'label': '自带',
            'url': 'https://example.com/b.mp4',
            'headers': <String, Object?>{'Referer': 'https://other/'},
          },
        ],
      })! as VideoContent;

      final merged = SourcePlayback.contentQualities(video);
      expect(
        merged.first.headers,
        <String, String>{'Referer': 'https://example.com/'},
        reason: '没写头的线路继承主地址的头，否则切线路就 403',
      );
      expect(
        merged.last.headers,
        <String, String>{'Referer': 'https://other/'},
        reason: '自己写了头的线路用自己的',
      );
    });
  });

  group('播放会话通道：后台音频 + 锁屏控制', () {
    const methods = MethodChannel(MethodChannelPlaybackBackend.methodChannelName);
    const events = MethodChannel(MethodChannelPlaybackBackend.eventChannelName);

    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger()
        ..setMockMethodCallHandler(methods, null)
        ..setMockMethodCallHandler(events, null);
    });

    test('通道名固定（原生 Swift 按这两个名字注册）', () {
      expect(MethodChannelPlaybackBackend.methodChannelName, 'lumebox/playback');
      expect(
        MethodChannelPlaybackBackend.eventChannelName,
        'lumebox/playback/events',
      );
    });

    test('原生未接入：isSupported 降级为 false，其余调用静默', () async {
      final backend = MethodChannelPlaybackBackend();
      expect(await backend.isSupported(), isFalse);
      await backend.start(title: '标题');
      await backend.update(playing: true);
      await backend.stop();
    });

    test('会话往返：start / update / stop 的参数形状固定', () async {
      final calls = <MethodCall>[];
      messenger().setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return call.method == 'isSupported' ? true : null;
      });

      final session = PlaybackSession(backend: MethodChannelPlaybackBackend());
      await session.start(
        title: '示例影片',
        subtitle: '第 1 集',
        duration: const Duration(minutes: 45),
        speed: 1.25,
      );
      await session.update(playing: true, duration: const Duration(minutes: 45));
      // 跨过 5 秒节流线的进度才会过通道（见下一个用例）。
      await session.update(position: const Duration(seconds: 6));
      await session.stop();

      expect(
        calls.map((call) => call.method).toList(),
        <String>['isSupported', 'start', 'update', 'update', 'stop'],
      );
      final start = calls[1].arguments as Map<Object?, Object?>;
      expect(start['title'], '示例影片');
      expect(start['subtitle'], '第 1 集');
      expect(start['durationMs'], 45 * 60 * 1000);
      expect(start['speed'], 1.25);

      final progress = calls[2].arguments as Map<Object?, Object?>;
      expect(
        progress.containsKey('positionMs'),
        isFalse,
        reason: '只传变化项：没给进度就不写这个键，原生沿用上次的值',
      );
      expect(progress['playing'], true);
      expect(progress['durationMs'], 45 * 60 * 1000);

      final later = calls[3].arguments as Map<Object?, Object?>;
      expect(later['positionMs'], 6000);
    });

    test('进度节流：小挪动整条丢掉，跨过 5 秒才同步', () async {
      final positions = <Object?>[];
      messenger().setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'update') {
          positions.add((call.arguments as Map<Object?, Object?>)['positionMs']);
        }
        return call.method == 'isSupported' ? true : null;
      });

      final session = PlaybackSession(backend: MethodChannelPlaybackBackend());
      await session.start(title: '标题');
      // 只带进度、且不足 5 秒：整条丢掉（系统播放条不需要秒级精度）。
      await session.update(position: const Duration(seconds: 2));
      await session.update(position: const Duration(seconds: 4));
      expect(positions, isEmpty);

      // 跨过 5 秒：同步一次。
      await session.update(position: const Duration(seconds: 7));
      expect(positions, <Object?>[7000]);

      // 播放状态变化时即使进度没动也要同步（暂停了播放条要停住）。
      await session.update(position: const Duration(seconds: 7), playing: false);
      expect(positions.length, 2);
    });

    test('会话没开始时 update 不过通道（避免给系统播放条塞空数据）', () async {
      final calls = <String>[];
      messenger().setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return call.method == 'isSupported' ? true : null;
      });

      final session = PlaybackSession(backend: MethodChannelPlaybackBackend());
      await session.update(playing: true, position: const Duration(seconds: 30));
      expect(calls, isEmpty);
    });

    test('事件解码：五种系统控件指令，未知载荷过滤', () {
      expect(
        MethodChannelPlaybackBackend.decodeEvent(<String, Object?>{'command': 'play'}),
        PlaybackSessionCommand.play,
      );
      expect(
        MethodChannelPlaybackBackend.decodeEvent(
          <String, Object?>{'command': 'next'},
        ),
        PlaybackSessionCommand.next,
      );
      expect(
        MethodChannelPlaybackBackend.decodeEvent(<String, Object?>{'command': 'nope'}),
        isNull,
      );
      expect(MethodChannelPlaybackBackend.decodeEvent('play'), isNull);
    });

    test('不支持的后端：全部空操作，不抛异常', () async {
      const backend = UnsupportedPlaybackSessionBackend();
      expect(await backend.isSupported(), isFalse);
      final session = PlaybackSession(backend: backend);
      await session.start(title: '标题');
      expect(session.isActive, isFalse);
      await session.update(playing: true);
      await session.stop();
      expect(await session.commands.isEmpty, isTrue);
    });
  });
}
