import '../../core/source/source.dart';

/// 视频板块的「可播放地址」判定：图源条目 / 章节内容 → 播放器认识的地址。
///
/// 判定保持纯函数，便于单独验证：
/// - [directAddress]：条目自带的地址（列表里的 `url`、或 id 本身就是地址）；
/// - [contentAddress]：章节内容里的视频载荷（`{kind: 'video', url}`）。
class SourcePlayback {
  SourcePlayback._();

  /// 播放内核认识的协议白名单。白名单之外的一律不当地址——
  /// 纯 id（如 `12345`）因此不会被误判成播放地址。
  static const Set<String> schemes = <String>{
    'http',
    'https',
    'file',
    'rtmp',
    'rtmps',
    'rtsp',
    'udp',
    'tcp',
  };

  /// 字符串 → 可播放地址。不是地址时返回 null。
  static Uri? directAddress(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    // 绝对路径先判：`D:\a.mp4` 会被 URI 解析器认成 scheme 'd'，不拦下来就漏了。
    if (_looksLikeFilePath(text)) return Uri.file(text);
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) return null;
    return schemes.contains(uri.scheme.toLowerCase()) ? uri : null;
  }

  /// 章节内容 → 可播放地址（只有视频载荷可播，文本 / 图片返回 null）。
  static Uri? contentAddress(ChapterContent? content) =>
      content is VideoContent ? content.url : null;

  /// 本地文件的绝对路径判定（POSIX 与 Windows 两种写法）。
  /// 相对路径不认——图源条目里的纯 id 落到这里只会是 id，不是文件。
  static bool _looksLikeFilePath(String text) {
    if (text.startsWith('/') || text.startsWith(r'\')) return true;
    return _driveLetter.hasMatch(text);
  }

  static final RegExp _driveLetter = RegExp(r'^[A-Za-z]:[\\/]');
}
