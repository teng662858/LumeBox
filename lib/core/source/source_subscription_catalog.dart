import '../session/section.dart';

enum SubscriptionRoute {
  github('GitHub 原站'),
  cdn('国内 CDN'),
  cloudflare('Cloudflare');

  const SubscriptionRoute(this.label);
  final String label;
}

class SubscriptionCatalog {
  static const availableRoutes = [
    SubscriptionRoute.github,
    SubscriptionRoute.cloudflare,
  ];
  static const base =
      'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/';
  static const cdnBase =
      'https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/';
  static const pagesBase = 'https://lume-sources.pages.dev/';
  static const totalPagesUrl = '${pagesBase}subscriptions/all.json';
  static const totalUrl = '${base}subscriptions/all.json';
  static const totalCdnUrl = '${cdnBase}subscriptions/cdn/all.json';
  static const audiobooksUrl = '${base}subscriptions/audiobook.txt';
  static String mixedFor(SubscriptionRoute route) =>
      _routeUrl('subscriptions/mixed.txt', route);
  static const sections = [Section.comic, Section.video];
  static const names = {
    Section.comic: 'subscriptions/comics.txt',
    Section.video: 'subscriptions/videos.txt',
  };
  static String totalFor(SubscriptionRoute route) => switch (route) {
    SubscriptionRoute.github => totalUrl,
    SubscriptionRoute.cdn => totalCdnUrl,
    SubscriptionRoute.cloudflare => totalPagesUrl,
  };

  static String _routeUrl(
    String path,
    SubscriptionRoute route,
  ) => switch (route) {
    SubscriptionRoute.github => '$base$path',
    SubscriptionRoute.cdn =>
      '$cdnBase${path.replaceFirst('subscriptions/', 'subscriptions/cdn/')}',
    SubscriptionRoute.cloudflare => '$pagesBase$path',
  };

  static String sectionUrl(
    Section section, {
    bool cdn = false,
    SubscriptionRoute? route,
  }) => _routeUrl(
    names[section]!,
    route ?? (cdn ? SubscriptionRoute.cdn : SubscriptionRoute.github),
  );

  static String audiobookFor(SubscriptionRoute route) =>
      _routeUrl('subscriptions/audiobook.txt', route);

  static const legacyPaths = {
    "video/A123TV.js": "movie/A123TV.js",
    "video/华视影院.js": "movie/华视影院.js",
    "video/播剧网.js": "movie/播剧网.js",
    "video/欧乐影院.js": "movie/欧乐影院.js",
    "video/短剧网.js": "movie/短剧网.js",
    "video/飞流视频.js": "movie/飞流视频.js",
    "video/饭搭子影视.js": "movie/饭搭子影视.js",
    "video/夜读小说听书.js": "audiobook/夜读小说听书.js",
    "video/小黄书听书.js": "audiobook/小黄书听书.js",
    'all': 'subscriptions/all.json',
    'comics': 'subscriptions/comics.txt',
    'photos': 'subscriptions/comics.txt',
    'comic/sources.js': 'subscriptions/comics.txt',
    'comic/sources.txt': 'subscriptions/comics.txt',
    'photo/sources.txt': 'subscriptions/comics.txt',
    '漫画订阅.js': 'subscriptions/comics.txt',
    'videos': 'subscriptions/videos.txt',
    'movies': 'subscriptions/videos.txt',
    'video/sources.js': 'subscriptions/videos.txt',
    'video/sources.txt': 'subscriptions/videos.txt',
    'movie/sources.txt': 'subscriptions/videos.txt',
    '视频订阅.js': 'subscriptions/videos.txt',
    'audiobooks': 'subscriptions/audiobook.txt',
    'videos-hd': 'subscriptions/legacy/videos-hd.txt',
    'videos-hd-cdn': 'subscriptions/legacy/videos-hd-cdn.txt',
    'videos-18plus': 'subscriptions/legacy/videos-18plus.txt',
    'videos-18plus-cdn': 'subscriptions/legacy/videos-18plus-cdn.txt',
  };

  /// Only migrate exact paths in our official repository, never arbitrary URLs.
  static String migrateUrl(String url) {
    // Retire only this project's old CDN URLs. Preserve third-party URLs and
    // signed/query URLs, whose semantics cannot safely be inferred.
    if (url.startsWith(cdnBase) && !url.contains('?') && !url.contains('#')) {
      var path = url.substring(cdnBase.length);
      try {
        path = Uri.decodeFull(path);
      } on ArgumentError {
        return url;
      }
      path = path.replaceFirst('subscriptions/cdn/', 'subscriptions/');
      path = path.replaceFirstMapped(
        RegExp(
          r'^(subscriptions/(?:comic|comics|photo|novel|movie|video|videos|audiobook|mixed))\.[0-9a-f]{8}\.txt$',
        ),
        (match) => '${match[1]}.txt',
      );
      if (path.startsWith('subscriptions/legacy/')) {
        path = path.replaceFirst('-cdn.txt', '.txt');
      }
      return migrateUrl('$base$path');
    }
    for (final prefix in [base, cdnBase, pagesBase]) {
      if (!url.startsWith(prefix)) continue;
      final rawPath = url.substring(prefix.length);
      String path;
      try {
        path = rawPath.contains('%') ? Uri.decodeFull(rawPath) : rawPath;
      } on ArgumentError {
        return url;
      }
      if (prefix == cdnBase) {
        final snapshot = RegExp(
          r'^subscriptions/cdn/(comic|comics|photo|novel|movie|video|videos|audiobook|mixed)\.[0-9a-f]{8}\.txt$',
        ).firstMatch(path);
        if (snapshot != null) {
          return '${cdnBase}subscriptions/cdn/${snapshot[1]}.txt';
        }
      }
      if (prefix == cdnBase &&
          RegExp(
            r'^subscriptions/(?:all\.json|(?:comic|comics|photo|novel|movie|video|videos|audiobook|mixed)\.txt)$',
          ).hasMatch(path)) {
        return '$prefix${path.replaceFirst('subscriptions/', 'subscriptions/cdn/')}';
      }
      final target = legacyPaths[path];
      if (target != null) {
        if (prefix == cdnBase && target.startsWith('subscriptions/')) {
          final cdnTarget = target.startsWith('subscriptions/legacy/')
              ? (target.endsWith('-cdn.txt')
                    ? target
                    : target.replaceFirst('.txt', '-cdn.txt'))
              : target.replaceFirst('subscriptions/', 'subscriptions/cdn/');
          return '$prefix$cdnTarget';
        }
        return '$prefix$target';
      }
    }
    return url;
  }

  static String canonical(String url, Section section) {
    return migrateUrl(url);
  }

  /// 三条官方线路指向同一份仓库文件；比较时忽略 URL 编码差异。
  static String? officialPath(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.userInfo.isNotEmpty || uri.scheme != 'https') {
      return null;
    }
    final parts = uri.pathSegments;
    if (uri.host == 'lume-sources.pages.dev') {
      return parts.length >= 2 ? parts.join('/') : null;
    }
    if (parts.length < 4) return null;
    final raw =
        uri.host == 'raw.githubusercontent.com' &&
        parts[0] == 'teng662858' &&
        parts[1] == 'LumeBox-Sources' &&
        parts[2] == 'main';
    final cdn =
        uri.host == 'cdn.jsdelivr.net' &&
        parts[0] == 'gh' &&
        parts[1] == 'teng662858' &&
        parts[2] == 'LumeBox-Sources@main';
    if (!raw && !cdn) return null;
    final path = parts.skip(3).join('/');
    return path.startsWith('subscriptions/cdn/')
        ? path.replaceFirst('subscriptions/cdn/', 'subscriptions/')
        : path;
  }

  static bool sameSourceUrl(String a, String b) {
    if (a == b) return true;
    final path = officialPath(a);
    return path != null && path == officialPath(b);
  }

  static bool validUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }
}
