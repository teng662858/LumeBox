import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/source_playback.dart';

/// 「条目 / 章节内容 → 可播放地址」的判定（视频板块首页起播的前置规则）。
///
/// 关键约束：**纯 id 不能被当成本地文件**——否则脚本缺方法会被误报成
/// 「文件不存在」，用户就更不知道自己该改哪里了。
void main() {
  group('条目地址判定', () {
    test('网络与流媒体协议按原样收下', () {
      for (final url in <String>[
        'https://example.com/demo.mp4',
        'http://example.com/live.m3u8',
        'rtmp://example.com/live/stream',
        'rtsp://example.com/cam',
      ]) {
        expect(SourcePlayback.directAddress(url)?.toString(), url);
      }
    });

    test('纯 id / 关键词不是地址', () {
      for (final value in <String>[
        '12345',
        'movie-1',
        '',
        '  ',
        'javascript:alert(1)',
        'magnet:?xt=urn:btih:abc',
      ]) {
        expect(
          SourcePlayback.directAddress(value),
          isNull,
          reason: '「$value」不该被当成本地文件或播放地址',
        );
      }
      expect(SourcePlayback.directAddress(null), isNull);
    });

    test('绝对路径按本地文件处理（POSIX 与 Windows 两种写法）', () {
      expect(
        SourcePlayback.directAddress('/var/mobile/Media/a.mp4')?.scheme,
        'file',
      );
      expect(
        SourcePlayback.directAddress(r'D:\media\a.mp4')?.scheme,
        'file',
      );
      expect(SourcePlayback.directAddress('a.mp4'), isNull, reason: '相对路径不认');
    });
  });

  group('章节内容地址判定', () {
    test('只有视频载荷可播放', () {
      expect(
        SourcePlayback.contentAddress(
          VideoContent(url: Uri.parse('https://example.com/e1.mp4')),
        )?.toString(),
        'https://example.com/e1.mp4',
      );
      expect(SourcePlayback.contentAddress(const TextContent('正文')), isNull);
      expect(
        SourcePlayback.contentAddress(
          const ImageContent(<String>['https://example.com/1.jpg']),
        ),
        isNull,
      );
      expect(SourcePlayback.contentAddress(null), isNull);
    });
  });
}
