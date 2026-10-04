import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_error.dart';

/// 播放失败文案归一：界面上不能再出现 `PlatformException(VideoError, …)` 这种
/// 英文载荷（用户截图里的原样）。
void main() {
  group('PlayerErrorText.describe', () {
    test('用户实测的那条 HTTP 404 变成一句中文', () {
      const raw = 'PlatformException(VideoError, Failed to load video: '
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
        '打开失败：服务器拒绝访问（HTTP 403）：多半需要请求头或已防盗链',
      );
      expect(
        PlayerErrorText.describe('server said HTTP 500'),
        '打开失败：服务器出错（HTTP 500）',
      );
      expect(
        PlayerErrorText.describe('status code 401'),
        contains('HTTP 401'),
      );
    });

    test('常见原生错误按模式翻译', () {
      expect(
        PlayerErrorText.describe('Error: The Internet connection appears to be offline.'),
        '打开失败：网络不可用或域名解析失败',
      );
      expect(
        PlayerErrorText.describe('A server with the specified hostname could not be found'),
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
