import '../../core/net/site_session_pool.dart';
import '../../core/net/source_request_log.dart';
import '../../core/net/waf.dart';
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
    // 判定必须**带媒体后缀**（见 [_looksLikeFilePath]）：图源条目 id 大量是
    // `/watch?v=123`、`/9434719.html`、`/album/1` 这种站内路径，早先一律当成
    // 本地文件，起播就变成打开一个不存在的 file:// —— 真机表现是
    // 「播放连接中断 + 未知错误 -17913」且日志里地址域名空白（H動漫網中过）。
    if (_looksLikeFilePath(text)) return Uri.file(text);
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) return null;
    if (!schemes.contains(uri.scheme.toLowerCase())) return null;
    return uri;
  }

  /// A catalogue entry can be an absolute webpage URL. It must still go through
  /// chapters/content; only the parsed content URL is handed to the decoder.
  static Uri? itemAddress(String? value) {
    final uri = directAddress(value);
    if (uri == null) return null;
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      final media = RegExp(
        r'\.(?:m3u8|mp4|m4v|mkv|webm|mov|avi|flv|mpd|ts|mp3|m4a|aac|flac|ogg|opus|wav)$',
        caseSensitive: false,
      ).hasMatch(uri.path);
      final download = RegExp(
        r'/download\.(?:php|ashx)$',
        caseSensitive: false,
      ).hasMatch(uri.path);
      final type =
          uri.queryParameters['response-content-type'] ??
          uri.queryParameters['mime'] ??
          '';
      if (!media &&
          !download &&
          !type.startsWith('video/') &&
          !type.startsWith('audio/')) {
        return null;
      }
    }
    return uri;
  }

  /// 章节内容 → 可播放地址（只有视频载荷可播，文本 / 图片返回 null）。
  ///
  /// Preserve the source's scheme, port and signature; HTTPS is not interchangeable.
  static Uri? contentAddress(ChapterContent? content) => content is VideoContent
      ? highestQuality(content)?.url ?? content.url
      : null;

  static VideoQuality? highestQuality(VideoContent content) {
    VideoQuality? best;
    var rank = 0;
    for (final quality in content.qualities) {
      final score = quality.resolutionRank;
      if (score > rank) {
        best = quality;
        rank = score;
      }
    }
    return best;
  }

  /// 播放时要带的请求头（`VideoContent.headers`，防盗链用的 Referer / UA 等）。
  ///
  /// 为什么必须传下去：真机反馈「同一个源电脑上立刻能播、iPhone 上要等一两分钟」
  /// —— 图源给的地址多带防盗链头，丢掉它们 CDN 会回 403，随后网络队列按退避
  /// 反复重试，累积起来正是那个量级。此前两处起播点都只取了地址、把请求头留在了
  /// `VideoContent` 里（AVPlayer 与 MPV 两条内核通路本来都支持携带它们）。
  static Map<String, String> contentHeaders(
    ChapterContent? content, {
    DataSource? source,
  }) {
    if (content is! VideoContent) return const {};
    final quality = highestQuality(content);
    return _verifiedHeaders(
      quality == null ? content.headers : _qualityHeaders(content, quality),
      quality?.url ?? content.url,
      source,
    );
  }

  /// 带上该源「验证过的会话」：验证时的 UA，以及 **源站自己域名上的** Cookie。
  ///
  /// 为什么 Cookie 也要带（真机反馈 hanime1 这类站「播放链接中断」）：CF 站点的
  /// 媒体地址常常就在主站域名下，只带 UA 不带 `cf_clearance` 照样被拦；而网页
  /// 验证拿到的会话本来就存在库里，只拿它取图片就太浪费了。
  ///
  /// **只发给源站自己的域名**（[SourceRequestLog.ownsHost]）：独立图床 / 媒体 CDN
  /// 一枚都不带——把主站会话泄漏给第三方域名比拿不到画面更糟。
  static Map<String, String> _verifiedHeaders(
    Map<String, String> original,
    Uri? uri,
    DataSource? source,
  ) {
    if (source == null ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme)) {
      return original;
    }
    // UA 一直跟着走（验证时的 UA 与 cf_clearance 绑定，换回脚本里那个 UA 等于没验）；
    // Cookie 只发给源站自己的域名。
    final ua =
        WafSessions.userAgentFor(source.section, source.id)?.trim() ?? '';
    final owned = SourceRequestLog.ownsHost(source.id, uri.toString());
    final cookies = owned
        ? (WafSessions.cookiesFor(source.section, source.id)?.trim() ?? '')
        : '';

    final result = Map<String, String>.of(original);
    if (ua.isNotEmpty) {
      result.removeWhere((key, _) => key.toLowerCase() == 'user-agent');
      result['User-Agent'] = ua;
    }
    if (cookies.isNotEmpty &&
        !result.keys.any((key) => key.toLowerCase() == 'cookie')) {
      result['Cookie'] = cookies;
    }
    return SiteSessionPool.shared.headersFor(
      uri.toString(),
      result,
      referer:
          SiteSessionPool.shared.pageForSource(source.id) ??
          SourceRequestLog.lastFor(source.id, quiet: true),
    );
  }

  /// 候选清晰度线路（图源给了多条时才非空）。
  ///
  /// 逐线路的请求头为空时**继承主 headers**：图源往往只在一处写防盗链头，
  /// 若按「线路自己的 headers 优先、没有就空」处理，切一条线路就 403。
  static List<VideoQuality> contentQualities(
    ChapterContent? content, {
    DataSource? source,
  }) {
    if (content is! VideoContent) return const <VideoQuality>[];
    return <VideoQuality>[
      for (final quality in content.qualities)
        VideoQuality(
          label: quality.label,
          url: quality.url,
          height: quality.height,
          headers: _verifiedHeaders(
            _qualityHeaders(content, quality),
            quality.url,
            source,
          ),
        ),
    ];
  }

  static Map<String, String> _qualityHeaders(
    VideoContent content,
    VideoQuality quality,
  ) {
    if (quality.headers.isNotEmpty) return quality.headers;
    final from = content.url, to = quality.url;
    if (from.scheme == to.scheme &&
        from.host == to.host &&
        from.port == to.port) {
      return content.headers;
    }
    const privateHeaders = {
      'cookie',
      'authorization',
      'proxy-authorization',
      'host',
    };
    return {
      for (final entry in content.headers.entries)
        if (!privateHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  /// 本地文件的绝对路径判定（POSIX 与 Windows 两种写法）。
  ///
  /// **必须带媒体后缀**才算本地文件：条目 id 是**站内路径**（`/watch?v=123`、
  /// `/9434719.html`、`/album/1`、`/book/1248`）的和本地文件长得一模一样，
  /// 只看「以 / 开头」就会把整个图源误判成本地播放（起播必失败，报错里连域名
  /// 都没有）。带 `file://` scheme 的地址走 [schemes] 白名单，不经过这里。
  static bool _looksLikeFilePath(String text) {
    if (_driveLetter.hasMatch(text)) return true;
    if (!(text.startsWith('/') || text.startsWith(r'\'))) return false;
    final path = text.split('?').first.split('#').first;
    return _mediaExtension.hasMatch(path);
  }

  /// 本地媒体 / 字幕文件后缀（判「这是文件还是站内路径」用）。
  static final RegExp _mediaExtension = RegExp(
    r'\.(?:mp4|m4v|mov|mkv|webm|avi|flv|wmv|ts|m3u8|mpd|mp3|m4a|aac|flac|wav|'
    r'ogg|opus|ape|srt|ass|ssa|vtt)$',
    caseSensitive: false,
  );

  static final RegExp _driveLetter = RegExp(r'^[A-Za-z]:[\\/]');
}
