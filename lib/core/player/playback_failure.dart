enum PlaybackFailureKind {
  network,
  login,
  membership,
  forbidden,
  invalidSource,
  decoder,
  unknown,
}

class PlaybackFailure {
  const PlaybackFailure(this.kind, this.title, this.hint);
  final PlaybackFailureKind kind;
  final String title, hint;
  bool get offerUpdate =>
      kind == PlaybackFailureKind.invalidSource ||
      kind == PlaybackFailureKind.unknown;

  static PlaybackFailure from(Object error) {
    final text = '$error'.toLowerCase();
    bool matches(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(text);
    if (matches(
      r'会员|付费|购买|订阅后|vip\b|members? only|subscription required|payment required|\b402\b',
    )) {
      return const PlaybackFailure(
        PlaybackFailureKind.membership,
        '源站要求会员或购买',
        '请打开源站查看当前账号的播放权限；重试不会改变会员或付费限制。',
      );
    }
    if (matches(
      r'需要登录|请.*登录|未登录|登录.*失效|token.*expir|login required|sign.?in required|unauthorized|\b401\b',
    )) {
      return const PlaybackFailure(
        PlaybackFailureKind.login,
        '需要登录或会话已过期',
        '请打开源站完成登录，再回到这里重试。',
      );
    }
    if (matches(
      r'need_webview_verify|captcha|cloudflare|人机|验证|\b403\b|forbidden',
    )) {
      return const PlaybackFailure(
        PlaybackFailureKind.forbidden,
        '源站拒绝了访问',
        '可能需要网页验证、防盗链请求头或更换网络；HTTP 403 本身不能证明需要登录。',
      );
    }
    if (matches(r'\b404\b|\b410\b')) {
      return const PlaybackFailure(
        PlaybackFailureKind.invalidSource,
        '源或播放地址可能已失效',
        '站点找不到这个资源；可更新源或打开源站检查内容是否已下架。',
      );
    }
    if (matches(r'https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?/')) {
      return const PlaybackFailure(
        PlaybackFailureKind.invalidSource,
        '源的本地播放服务不可用',
        '该源返回了本机代理地址；服务可能未启动、已退出或请求失败。请检查源的兼容性，或使用源站支持的播放方式。',
      );
    }
    if (matches(
      r'time.?out|timed out|超时|socketexception|network|网络|连接|connection|dns|handshake|握手|\b5\d\d\b',
    )) {
      return const PlaybackFailure(
        PlaybackFailureKind.network,
        '网络请求未完成',
        '检查网络后重试；播放地址过期时，重试会重新向源请求地址。',
      );
    }
    if (matches(
      r'\b404\b|\b410\b|源不可用|源.*失效|脚本|scripterror|runtimeerror|typeerror|syntaxerror|解析失败|未返回.*地址|没有.*地址|格式.*不正确|已下架|取不到',
    )) {
      return const PlaybackFailure(
        PlaybackFailureKind.invalidSource,
        '源或播放地址可能已失效',
        '可更新源脚本后重试；本地导入的源需要选择同一源的新版本文件。',
      );
    }
    if (matches(r'codec|decoder|decode|unsupported|编码|解码|格式不支持')) {
      return const PlaybackFailure(
        PlaybackFailureKind.decoder,
        '当前内核不支持这个视频',
        '可切换播放内核，或选择另一条线路。',
      );
    }
    return const PlaybackFailure(
      PlaybackFailureKind.unknown,
      '暂时无法播放',
      '可以重试、打开源站检查内容，或更新源后再试。',
    );
  }
}
