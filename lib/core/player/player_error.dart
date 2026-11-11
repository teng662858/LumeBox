/// 播放失败文案归一：把内核吐出来的原始异常翻译成一句能读懂的话。
///
/// 各内核的错误原文形态完全不同——AVPlayer 是
/// `PlatformException(VideoError, Failed to load video: … (CoreMediaErrorDomain
/// error -12938 - HTTP 404: File Not Found), null, null)` 这种英文载荷，MPV 是
/// 原生错误串。直接贴到界面上，用户看到的就是一串英文与错误码。这里按「能认出来
/// 的模式」翻译成中文短句，认不出来时至少把 `PlatformException(...)` 的包装
/// 噪声去掉。
///
/// 边界：**只改展示文案**。原始文本仍由调用方写进运行日志（`LumeLog`），
/// 排查问题不缺料。
class PlayerErrorText {
  PlayerErrorText._();

  /// Check both native errors and their UI translations at recovery boundaries.
  static bool needsAlternativeKernel(Object? raw) {
    final text = '${raw ?? ''}';
    if (_httpStatus(text) case final status? when status >= 400) return false;
    final lower = text.toLowerCase();
    return [
      '-12939',
      '-12847',
      '-12848',
      '-11828',
      'averrorfileformatnotrecognized',
      'cannot open',
      'this media may be damaged',
      'this media format is not supported',
      '该视频的格式或编码不被当前内核支持',
      '当前内核无法打开该媒体',
      'byte range',
      'no content length',
      '服务器不支持分段请求',
      'server is not correctly configured',
    ].any(lower.contains);
  }

  /// 归一为一句可读文案。输入为空时给一句兜底。
  static String describe(Object? raw) {
    final text = '${raw ?? ''}'.trim();
    if (text.isEmpty) return '打开失败：内核没有给出原因';

    final status = _httpStatus(text);
    if (status != null) return '打开失败：${_httpHint(status)}';

    final lower = text.toLowerCase();
    for (final rule in _rules) {
      if (rule.matches(lower)) return '打开失败：${rule.hint}';
    }
    return '打开失败：${_strip(text)}';
  }

  /// 认不出来的原文：剥掉 PlatformException 包装与尾部占位，留一句能读的。
  static String _strip(String text) {
    var value = text;
    final wrapper = RegExp(r'^PlatformException\([^,]*,\s*').firstMatch(value);
    if (wrapper != null) {
      value = value.substring(wrapper.end);
    }
    value = value.replaceAll(RegExp(r',\s*null,\s*null\)\s*$'), '');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.endsWith(')')) value = value.substring(0, value.length - 1);
    if (value.length <= 120) return value;
    return '${value.substring(0, 117)}...';
  }

  /// 从原文里抽 HTTP 状态码（AVPlayer 会带 `HTTP 404`，也有 `status code 404` 的写法）。
  static int? _httpStatus(String text) {
    for (final pattern in <RegExp>[
      RegExp(r'\bHTTP[ /]?(\d{3})\b'),
      RegExp(r'\bstatus(?:\s*code)?[ :=]+(\d{3})\b', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final code = int.tryParse(match.group(1)!);
      if (code != null && code >= 100 && code <= 599) return code;
    }
    return null;
  }

  static String _httpHint(int status) {
    if (status == 401) return '服务器要鉴权（HTTP 401）：地址可能已失效';
    if (status == 403) {
      // 真机反馈里 403 有两种成因：地址缺防盗链请求头，或**站点按网络出口拦截**
      // （同一地址直连 200、走代理/VPN 就 403／567）。文案两种都要提到，
      // 否则用户只会反复点重试。
      return '服务器拒绝访问（HTTP 403）：可能是缺防盗链请求头，'
          '也可能是站点按网络出口（代理 / VPN 的地区）拦截——换直连或换线路再试';
    }
    if (status == 404 || status == 410) return '服务器上找不到这个视频（HTTP $status）';
    if (status >= 500) return '服务器出错（HTTP $status）';
    if (status >= 400) return '服务器拒绝了请求（HTTP $status）';
    return '服务器返回 HTTP $status';
  }

  /// 常见原生错误的特征 → 中文短句（按顺序匹配，越具体越靠前）。
  static final List<_Rule> _rules = <_Rule>[
    _Rule(<String>[
      '-11828',
      'averrorfileformatnotrecognized',
    ], '当前内核无法打开该媒体封装；请更换 MPV 或 MDK 内核'),
    _Rule(<String>[
      'osstatus error -12848',
      'this media may be damaged',
    ], '当前内核无法打开该媒体，可能是封装、编码或数据不完整；请更换内核或线路'),
    _Rule(<String>[
      'connection appears to be offline',
      'not connected to the internet',
      'network connection was lost',
      'nodename nor servname provided',
      'could not be found',
      'hostname could not be found',
      'unable to resolve',
    ], '网络不可用或域名解析失败'),
    _Rule(<String>['timed out', 'timeout', 'timed-out'], '加载超时：网络太慢或地址不可达'),
    _Rule(<String>[
      'unsupported',
      'not supported',
      'cannot decode',
      'decoder',
      'mediacodec',
      'codec',
      'format error',
    ], '该视频的格式或编码不被当前内核支持'),
    // -12939「byte range and no content length - error code is 200」：服务器接了
    // Range 请求却回 200 且不给 Content-Length（分块流 / 站点自己的 PHP 播放口），
    // AVPlayer 直接放弃。不是地址错，也不是网络断——换内核（MPV 的 ffmpeg 能吃
    // 这种流）通常就能播，所以文案要给出下一步动作（真机：Hanime1 过完验证卡在这）。
    _Rule(<String>[
      'byte range and no content length',
      'no content length',
      'server is not correctly configured',
    ], '服务器不支持分段请求（AVPlayer 播不了这种流）：换 MPV 内核通常可播'),
    _Rule(<String>[
      'cancelled',
      'canceled',
      'aborted',
      'operation stopped',
    ], '已取消加载'),
    _Rule(<String>['permission', 'denied'], '没有权限访问该地址'),
    _Rule(<String>['no such file', 'file not found', 'enoent'], '本地文件不存在'),
  ];
}

/// 一条匹配规则：命中任一特征即采用该文案。
class _Rule {
  const _Rule(this.needles, this.hint);

  final List<String> needles;
  final String hint;

  bool matches(String lowerText) =>
      needles.any((needle) => lowerText.contains(needle));
}
