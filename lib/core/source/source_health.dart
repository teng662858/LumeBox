import 'dart:async';
import 'dart:io';

import '../net/ios_verified_webview.dart';
import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../net/network_cancellation.dart';
import '../net/network_queue.dart';
import '../net/waf.dart';
import '../session/section.dart';
import 'source.dart';

enum SourceHealthIssue {
  none,
  dependency,
  verification,
  authentication,
  site,
  parsing,
  image,
  empty,
  timeout,
  unsupported,
  cancelled,
  unknown;

  String get label => switch (this) {
    none => '通过',
    dependency => '缺少依赖',
    verification => '需要网页验证',
    authentication => '需要登录或授权',
    site => '站点或网络异常',
    parsing => '源解析异常',
    image => '图片域名单独异常',
    empty => '没有内容',
    timeout => '请求超时',
    unsupported => '运行环境不支持',
    cancelled => '已取消',
    unknown => '需要进一步检查',
  };
  String get suggestion => switch (this) {
    dependency => '导入包含依赖文件的完整源包；原生依赖需要安装包提供支持。',
    verification => '打开对应网页完成验证；图片域名的验证可能与主站不同。',
    authentication => '检查这个源的登录状态、账号和作者授权。',
    site => '检查系统网络；站点维护或 5xx 错误可稍后重测。',
    parsing => '站点可能改版；更新源脚本，或在更新后出错时恢复上一版。',
    image => '主站已有内容，但图片地址无法正常读取；检查图片验证、防盗链和签名有效期。',
    empty => '先换一个分类；首页没有推荐不代表整个源不可用。',
    timeout => '检查网络后重测；等待仍受总超时限制。',
    unsupported => '检查安装包是否包含这个源需要的运行环境。',
    _ => '',
  };
}

class SourceHealthStep {
  const SourceHealthStep(
    this.title,
    this.message, {
    this.issue = SourceHealthIssue.none,
    this.running = false,
  });
  final String title, message;
  final SourceHealthIssue issue;
  final bool running;
}

/// Small live probes. Never plays media, modifies selection, or downloads a book.
class SourceHealthCheck {
  SourceHealthCheck({
    required this.manager,
    required this.section,
    required this.descriptor,
    NetworkSender? sender,
    this.onChanged,
    this.budget = const Duration(seconds: 40),
  }) : sender = sender ?? LumeNet.queue.send;
  final SourceManager manager;
  final Section section;
  final SourceDescriptor descriptor;
  final NetworkSender sender;
  final Duration budget;
  final void Function(List<SourceHealthStep>)? onChanged;
  final cancellation = NetworkCancellation();
  final _steps = <SourceHealthStep>[];
  List<SourceHealthStep> get steps => List.unmodifiable(_steps);
  void cancel() => cancellation.cancel();
  void _notify() => onChanged?.call(steps);

  Future<void> _step(
    String title,
    Future<String> Function() action, {
    bool image = false,
  }) async {
    cancellation.check();
    final index = _steps.length;
    _steps.add(SourceHealthStep(title, '正在检查…', running: true));
    _notify();
    try {
      final message = await action();
      cancellation.check();
      _steps[index] = SourceHealthStep(title, message);
    } catch (error) {
      if (cancellation.isCancelled) rethrow;
      _steps[index] = SourceHealthStep(
        title,
        safeMessage(error),
        issue: classify(error, image: image),
      );
    }
    _notify();
  }

  Future<List<SourceHealthStep>> run() async {
    final timer = Timer(
      budget,
      () => cancellation.cancel(TimeoutException('体检超过 ${budget.inSeconds} 秒')),
    );
    try {
      await cancellation.run(() => cancellation.guard(_inspect()));
    } catch (error) {
      final index = _steps.indexWhere((step) => step.running);
      final result = SourceHealthStep(
        '体检结束',
        safeMessage(error),
        issue: classify(error),
      );
      if (index < 0) {
        _steps.add(result);
      } else {
        _steps[index] = result;
      }
      _notify();
    } finally {
      timer.cancel();
    }
    return steps;
  }

  Future<void> _inspect() async {
    DataSource? source;
    await _step('运行环境与依赖', () async {
      if (!manager.runtimeAvailable) throw UnsupportedError('当前安装包没有源运行环境');
      source = manager is SourceInspectionManager
          ? await (manager as SourceInspectionManager).openForInspection(
              descriptor.id,
            )
          : await manager.open(descriptor.id);
      if (source == null) {
        final reason = manager is SourceInspectionManager
            ? await (manager as SourceInspectionManager).sourceLoadFailure(
                descriptor.id,
              )
            : null;
        throw StateError(reason ?? '源脚本载入失败，请检查依赖与运行环境');
      }
      return '脚本已载入；后续调用还会检查延迟加载的依赖。';
    });
    if (source == null) return;
    final data = source!;
    List<SourceCategory> categories = [];
    await _step('分类接口', () async {
      categories = await data.categories();
      return '返回 ${categories.length} 个分类';
    });
    if (data is HomeCapable) {
      await _step('首页推荐', () async {
        final homeSource = data as HomeCapable;
        if (!await homeSource.supportsHome()) return '未提供首页接口，继续检查分类内容。';
        final home = await homeSource.home();
        final count =
            home.items.length +
            home.boards.fold<int>(0, (sum, board) => sum + board.items.length);
        return count == 0 ? '没有首页推荐，继续检查分类内容。' : '返回 $count 条首页内容';
      });
    }
    List<SourceItem> items = [];
    await _step('分类列表', () async {
      Object? lastError;
      final List<String?> categoryIds = categories.isEmpty
          ? [null]
          : categories.take(2).map((c) => c.id).toList();
      for (final id in categoryIds) {
        cancellation.check();
        try {
          final page = await data.list(categoryId: id, page: 1);
          if (page.items.isNotEmpty) {
            items = page.items;
            break;
          }
        } catch (error) {
          cancellation.check();
          lastError = error;
        }
      }
      if (items.isEmpty) throw lastError ?? const _EmptyHealthResult();
      return '返回 ${items.length} 条内容';
    });
    if (items.isEmpty) return;
    final item = items.first;
    await _step('搜索接口', () async {
      final results = await data.list(keyword: item.title, page: 1);
      if (results.items.isEmpty) throw const _EmptyHealthResult();
      return '以一个列表条目的标题试搜，返回 ${results.items.length} 条；不代表所有关键词都可用。';
    });
    if (item.cover?.isNotEmpty == true) {
      await _step('封面图片', () async {
        final uri = Uri.tryParse(item.cover!);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('封面地址无效');
        }
        var headers = <String, String>{
          'User-Agent':
              WafSessions.userAgentFor(section, descriptor.id) ??
              LumeHttp.defaultUserAgent,
          'Accept': 'image/*',
          if (descriptor.siteUrl.isNotEmpty) 'Referer': descriptor.siteUrl,
          for (final entry in item.coverHeaders.entries)
            if (!entry.key.toLowerCase().startsWith('x-lume-'))
              entry.key: entry.value,
        };
        if (Platform.isIOS) {
          headers = await IosVerifiedWebView.resourceHeaders(
            uri.toString(),
            headers,
          );
        }
        final response = await sender(
          NetworkRequest(
            url: uri.toString(),
            headers: headers,
            source: descriptor.id,
            maxBytes: 32768,
            timeout: const Duration(seconds: 8),
            cancellation: cancellation,
            reuseVerifiedSession: true,
          ),
        );
        final body = String.fromCharCodes(response.body.take(16000));
        if (WafDetector.isChallenge(
          statusCode: response.statusCode == 200 ? 403 : response.statusCode,
          headers: response.headers,
          body: body,
        )) {
          throw const _ImageHealthFailure('图片域名需要单独网页验证');
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _ImageHealthFailure('图片返回 HTTP ${response.statusCode}');
        }
        final contentType =
            response.headers.entries
                .where((e) => e.key.toLowerCase() == 'content-type')
                .firstOrNull
                ?.value
                .toLowerCase() ??
            '';
        if (response.body.isEmpty ||
            contentType.contains('json') ||
            contentType.startsWith('text/') ||
            RegExp(
              r'^\s*(<!doctype html|<html)',
              caseSensitive: false,
            ).hasMatch(body)) {
          throw const _ImageHealthFailure('图片地址返回了空内容、网页或非图片数据');
        }
        return '图片域名可读取（仅检查前 32KB，未验证完整图片解码）';
      }, image: true);
    }
    await _step('详情解析', () async {
      if (await data.detail(item.id) == null) {
        throw const FormatException('没有解析出作品详情');
      }
      return '详情可读取';
    });
    List<SourceChapter> chapters = [];
    await _step('目录／选集', () async {
      chapters = await data.chapters(item.id);
      if (chapters.isEmpty) throw const _EmptyHealthResult();
      return '返回 ${chapters.length} 个章节／剧集';
    });
    if (chapters.isEmpty) return;
    await _step('正文／播放地址解析', () async {
      final content = await data.content(
        itemId: item.id,
        chapterId: chapters.first.id,
      );
      if (content is ImageContent && content.images.isNotEmpty) {
        return '解析出 ${content.images.length} 张正文图片地址，未下载整章。';
      }
      if (content is TextContent && content.text.trim().isNotEmpty) {
        return '已读取文本正文，未启动朗读或下载整本。';
      }
      if (content is VideoContent && content.url.hasScheme) {
        return '播放地址已解析，未实际起播；解码与防盗链仍需播放时验证。';
      }
      throw const FormatException('没有解析出可用正文或播放地址');
    });
  }

  static SourceHealthIssue classify(Object error, {bool image = false}) {
    if (error is NetworkCancelled) return SourceHealthIssue.cancelled;
    if (error is TimeoutException) return SourceHealthIssue.timeout;
    if (error is _EmptyHealthResult) return SourceHealthIssue.empty;
    if (image || error is _ImageHealthFailure) return SourceHealthIssue.image;
    final text = '$error'.toLowerCase();
    if (RegExp(
      r'modulenotfound|importerror|no module named|缺少依赖|缺少模块|cannot find module',
    ).hasMatch(text)) {
      return SourceHealthIssue.dependency;
    }
    if (RegExp(r'need_webview_verify|verification|captcha|cloudflare|验证码|人机校验')
        .hasMatch(text)) {
      return SourceHealthIssue.verification;
    }
    if (RegExp(r'http[_ :]*401|需要登录|需要授权|未授权').hasMatch(text)) {
      return SourceHealthIssue.authentication;
    }
    if (error is UnsupportedError ||
        text.contains('不支持') ||
        text.contains('没有源运行环境')) {
      return SourceHealthIssue.unsupported;
    }
    if (RegExp(r'timeout|超时').hasMatch(text)) return SourceHealthIssue.timeout;
    if (RegExp(
          r'socketexception|连接失败|网络请求失败|系统网络请求失败|http[_ :]*(403|404|410|429|5\d\d)',
        ).hasMatch(text) ||
        error is SourceException && error.kind == SourceErrorKind.network) {
      return SourceHealthIssue.site;
    }
    if (error is FormatException ||
        RegExp(r'jsondecode|syntaxerror|typeerror|keyerror|解析|字段|脚本载入')
            .hasMatch(text)) {
      return SourceHealthIssue.parsing;
    }
    return SourceHealthIssue.unknown;
  }

  static String safeMessage(Object error) => '$error'
      .replaceAllMapped(RegExp(r'https?://[^\s<>"\x27]+'), (match) {
        final uri = Uri.tryParse(match[0]!);
        return uri == null
            ? '[地址已隐藏]'
            : uri.replace(userInfo: '', query: '', fragment: '').toString();
      })
      .replaceAllMapped(
        RegExp(
          r'(cookie|authorization|token|password)\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}=[已隐藏]',
      );
}

class _EmptyHealthResult implements Exception {
  const _EmptyHealthResult();
  @override
  String toString() => '接口可以调用，但没有返回内容';
}

class _ImageHealthFailure implements Exception {
  const _ImageHealthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
