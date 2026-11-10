import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_error.dart';

/// 播放失败文案归一：界面上不能再出现 `PlatformException(VideoError, …)` 这种
/// 英文载荷（用户截图里的原样）。
void main() {
  group('PlayerErrorText.describe', () {
    test('媒体打开失败保留恢复建议，不把未确认的问题说成文件已损坏', () {
      expect(
        PlayerErrorText.describe(
          'Cannot Open: This media may be damaged. (OSStatus error -12848.)',
        ),
        '打开失败：当前内核无法打开该媒体，可能是封装、编码或数据不完整；请更换内核或线路',
      );
    });
    test('用户实测的那条 HTTP 404 变成一句中文', () {
      const raw =
          'PlatformException(VideoError, Failed to load video: '
          'The requested URL was not found on this server.: The operation '
          'couldn\u2019t be completed. (CoreMediaErrorDomain error -12938 - '
          'HTTP 404: File Not Found), null, null)';

      final text = PlayerErrorText.describe(raw);
      expect(text, '打开失败：服务器上找不到这个视频（HTTP 404）');
      expect(text, isNot(contains('PlatformException')));
      expect(text, isNot(contains('CoreMediaErrorDomain')));
    });

    test('各类 HTTP 状态码给对应说法', () {
      expect(
        PlayerErrorText.describe('failed: HTTP 403 forbidden'),
        '打开失败：服务器拒绝访问（HTTP 403）：可能是缺防盗链请求头，'
        '也可能是站点按网络出口（代理 / VPN 的地区）拦截——换直连或换线路再试',
      );
      expect(
        PlayerErrorText.describe('server said HTTP 500'),
        '打开失败：服务器出错（HTTP 500）',
      );
      expect(PlayerErrorText.describe('status code 401'), contains('HTTP 401'));
    });

    test('常见原生错误按模式翻译', () {
      expect(
        PlayerErrorText.describe(
          'Error: The Internet connection appears to be offline.',
        ),
        '打开失败：网络不可用或域名解析失败',
      );
      // 真机：Hanime1 过完网页验证后 AVPlayer 报的这条（服务器接了 Range 请求
      // 却回 200 且不给 Content-Length）——要给出「换 MPV 内核」这个下一步。
      expect(
        PlayerErrorText.describe(
          'Failed to load video: Operation Stopped: The server is not correctly '
          'configured.: The operation couldn’t be completed. '
          '(CoreMediaErrorDomain error -12939 - byte range and no content length '
          '- error code is 200)',
        ),
        '打开失败：服务器不支持分段请求（AVPlayer 播不了这种流）：换 MPV 内核通常可播',
      );
      expect(
        PlayerErrorText.describe(
          'A server with the specified hostname could not be found',
        ),
        '打开失败：网络不可用或域名解析失败',
      );
      expect(
        PlayerErrorText.describe('CoreMediaErrorDomain: operation timed out'),
        '打开失败：加载超时：网络太慢或地址不可达',
      );
      expect(
        PlayerErrorText.describe('Decoder error: unsupported format'),
        '打开失败：该视频的格式或编码不被当前内核支持',
      );
    });

    test('认不出来的原文也要剥掉包装噪声，并截断', () {
      final stripped = PlayerErrorText.describe(
        'PlatformException(VideoError, Something strange happened here, null, null)',
      );
      expect(stripped, '打开失败：Something strange happened here');

      final long = PlayerErrorText.describe('x' * 400);
      expect(long.length, lessThanOrEqualTo('打开失败：'.length + 120));
      expect(long, endsWith('...'));
    });

    test('空输入给兜底文案', () {
      expect(PlayerErrorText.describe(null), '打开失败：内核没有给出原因');
      expect(PlayerErrorText.describe('   '), '打开失败：内核没有给出原因');
    });
  });
}
