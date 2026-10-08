import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/net/waf.dart';

// 兼容既有引用：这两个纯字符串工具的**定义**已搬到 core/net/waf.dart
//（引擎层判 WAF 时也要用，core 不能反向依赖界面层），这里原样导出。
export '../../core/net/waf.dart' show originOf, urlFromFailure;
import '../../core/session/section.dart';
import '../../core/source/lume_sources.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';

/// 内置「网页视图」：被 Cloudflare / WAF 拦下时，让用户在 App 内过真人校验
/// （用户要求的流程，参考 AP 漫画那套）。
///
/// 三条要点：
/// - **真 WebView**（WKWebView）：校验是人机交互，必须是真浏览器环境，请求头伪装没用；
/// - **取回整套 Cookie**：关闭时同时取 JS 可见的 `document.cookie` 与**原生 Cookie
///   仓库**（`lumebox/webview` 通道）——`cf_clearance` 是 HttpOnly，只取 JS 那份会漏掉关键的一枚；
/// - **只存会话，不改脚本**：Cookie 交给宿主网络层附加（用户口径第 4 条）。
///
/// ## 页面上要「看得见勾选框」（真机反馈：白屏，没有验证控件）
///
/// 三条口径缺一不可，缺任何一条 CF 都会给一张**渲染不出控件的空页**：
/// 1. **UA 必须是浏览器 UA**：WKWebView 的默认 UA 是 `… Mobile/15E148`（**没有
///    `Safari/…` 这一段**），CF 会把它当非浏览器；这里统一用 App 请求侧的 UA
///    （Safari 形态），顺带满足 `cf_clearance` 绑定 IP + UA 的要求（见 [userAgentOverride]）；
/// 2. **网页内容允许明文 http**：源站正文与挑战页里都有 http 子资源，iOS 的 ATS
///    默认会把它们拦掉 → 白屏（见 `ios/Runner/Info.plist` 的
///    `NSAllowsArbitraryLoadsInWebContent`）；
/// 3. **补齐浏览器请求头**：`Accept-Language` / `Upgrade-Insecure-Requests` 这类
///    默认头缺了，挑战页的脚本可能直接不渲染控件。
///
/// ## UA 必须是**设备自己的** Safari UA（真机反馈：勾选框一闪就跳空白页）
///
/// 真机现象：挑战页的勾选框能瞥见一眼，还没点就自己跳成空白页。CF 会做客户端
/// 一致性检测——UA 里写的系统版本、WebKit 版本与真实环境对不上（或带 WebView
/// 特征），它就认定这是内置控件，**跳过交互直接把人赶走**。
/// 因此这里不再用配置里那串硬编码 UA，而是拿 WKWebView 的**默认 UA**（它带着这台
/// 设备真实的 iOS / WebKit 版本）补上 `Version/… Safari/…` 两段，拼出一个与
/// 本机 Safari 完全一致的 UA（见 [safariUserAgentFrom]）。
///
/// ## 挑战页被跳走时把它拉回来（[._restoreChallengeIfBlanked]）
///
/// 即便 UA 对了，CF 也可能在挑战过期 / 网络抖动时跳到一张空白页。用户口径：
/// 「至少把挑战页保留住，给足时间点勾选框」。这里在页面变成空白且**刚才确实
/// 是挑战页**时，把挑战页重新打开（最多几次），而不是任由用户面对白屏。
///
/// ## 什么时候才读 Cookie
///
/// **只有用户点左上角 ✕ 的那一刻**（手动模式）。中途无论页面跳转多少次都不读
/// Cookie、不关窗、不重置 WebView——用户没说「好了」，验证流程就还没结束。
class WafWebViewPage extends StatefulWidget {
  const WafWebViewPage({
    super.key,
    required this.url,
    required this.sourceName,
    required this.onCollected,
    this.onUserAgent,
    this.userAgentOverride,
    this.auto = false,
    this.compact = false,
  });

  /// 自动模式（用户口径 2 / 4）：脚本抛 `NEED_WEBVIEW_VERIFY` 时由应用自己调起。
  /// 这个模式下**不要求用户点关闭**——一拿到会话就自己收尾关窗。
  final bool auto;

  /// 小悬浮窗布局：只占屏幕一小块（不做全屏页），提示文案也压缩成一行。
  final bool compact;

  /// 用指定 UA 打开页面（**App 请求侧那一个**：图源覆盖 → 全局设置 → 内置默认）。
  ///
  /// 两个理由，缺一不可：
  /// - Cloudflare 把 `cf_clearance` 绑在「IP + UA」上：验证时与后续 API 用同一个
  ///   UA 才认；
  /// - WKWebView 的默认 UA 不带 `Safari/…` 段，CF 会给一张渲染不出控件的空页
  ///   （真机反馈的「白屏、看不到勾选框」）。
  final String? userAgentOverride;

  /// 要打开的源站地址（通常是失败请求的 origin）。
  final String url;

  /// 图源名（顶栏标题里给出上下文）。
  final String sourceName;

  /// 取回 Cookie 后的落盘回调（宿主负责写进该图源的会话存储）。
  final void Function(Map<String, String> cookies) onCollected;

  /// 读到网页视图 UA 后的回调（与 Cookie 一起存：cf_clearance 与 UA 绑定）。
  final ValueChanged<String>? onUserAgent;

  @override
  State<WafWebViewPage> createState() => _WafWebViewPageState();
}

class _WafWebViewPageState extends State<WafWebViewPage> {
  /// 原生 Cookie 仓库通道（iOS 实现；其它平台回落为只取 JS 可见的那份）。
  static const MethodChannel _cookieChannel = MethodChannel('lumebox/webview');

  /// 起播前带上的浏览器请求头（用户口径 1：补齐请求头）。
  ///
  /// 只补「缺了会出问题」的三个：语言（挑战页按它选文案）、Accept（HTML）、
  /// `Upgrade-Insecure-Requests`（老站点的 http 资源升级）。WKWebView 自己会补
  /// `Sec-Fetch-*` / `Accept-Encoding`，这里不重复造。
  static const Map<String, String> _browserHeaders = <String, String>{
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Upgrade-Insecure-Requests': '1',
  };

  WebViewController? _controller;
  String _title = '请稍候…';
  int _progress = 0;
  bool _collecting = false;

  /// 主框架加载失败的原因（空 = 没失败）。有值时页面上给一张可读的失败卡——
  /// 白屏是最没用的失败方式：用户既不知道发生了什么，也不知道下一步做什么。
  String? _loadError;

  /// 刚才这一页是不是 CF 挑战页（用来判断「跳成空白」要不要把挑战页拉回来）。
  bool _challengeSeen = false;

  /// 已经拉回来过几次（防死循环：CF 一直跳走就停手，把白屏如实呈现）。
  int _challengeRestores = 0;

  /// 挑战页最多自动重开几次。
  static const int _maxChallengeRestores = 3;

  /// 是否已经成功加载过至少一次（用来区分「从来没打开」与「打开过、后面的
  /// 导航被取消」——后者不该压失败卡）。
  bool _loadedOnce = false;

  /// 自动模式的轮询计时器：定时看 Cloudflare 的放行 Cookie 到了没有。
  Timer? _autoPoll;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) => setState(() => _progress = value),
          onPageStarted: (url) {
            LumeLog.info('[waf] 网页视图开始加载：$url');
            setState(() {
              _progress = 0;
              _loadError = null;
            });
          },
          onPageFinished: (url) async {
            final title = await _controller?.getTitle();
            // UA 与 cf_clearance 绑定：验证用哪个 UA，后续 API 就得用哪个，
            // 因此把网页视图里的真实 UA 记下来（用户口径 2：拿到验证后的请求头）。
            final ua = await _controller?.runJavaScriptReturningResult(
              'navigator.userAgent',
            );
            widget.onUserAgent?.call('$ua'.replaceAll('"', '').trim());
            if (!mounted) return;
            _loadedOnce = true;
            setState(() {
              _title = (title == null || title.trim().isEmpty)
                  ? widget.sourceName
                  : title.trim();
              // 页面已经能出内容：把可能残留的失败卡撤掉。
              _loadError = null;
            });
            // 真机诊断：CF 挑战页渲染不出来时，日志里要能看出「页面到底有没有内容」
            //（白屏是真机上唯一看不出来的失败）。
            unawaited(_probePage(url));
            if (widget.auto) _startAutoPoll();
          },
          // 4xx / 5xx 不是加载失败（CF 的挑战页本身就是 403/503），但要留证。
          onHttpError: (error) => LumeLog.info(
            '[waf] 网页视图 HTTP ${error.response?.statusCode}：'
            '${error.request?.uri}',
          ),
          onWebResourceError: (error) {
            LumeLog.info(
              '[waf] 网页视图加载出错（主框架=${error.isForMainFrame}）：'
              '${error.errorType} / ${error.description} / ${error.url}',
            );
            // 只在「一次都没成功加载过」时压失败卡：挑战页自己会 reload / 跳转，
            // 那些被取消的导航也会报主框架错误，不该盖住已经出内容的页面。
            if (error.isForMainFrame != true || !mounted || _loadedOnce) return;
            setState(() => _loadError = error.description);
          },
        ),
      );
    unawaited(_boot());
  }

  /// 起播顺序：**先定 UA，再带头加载**（顺序反了第一次加载用的还是 WKWebView
  /// 默认 UA，那就是 CF 给白屏的那一份）。
  Future<void> _boot() async {
    final controller = _controller;
    if (controller == null) return;
    final ua = await _resolveUserAgent(controller);
    if (ua.isNotEmpty) {
      try {
        await controller.setUserAgent(ua);
      } catch (error) {
        LumeLog.warn('[waf] 设置网页视图 UA 失败（用默认 UA 继续）：$error');
      }
    }
    if (!mounted) return;
    LumeLog.info('[waf] 网页视图打开：${widget.url}（UA=$ua）');
    try {
      await controller.loadRequest(
        Uri.parse(widget.url),
        headers: _browserHeaders,
      );
    } catch (error) {
      LumeLog.warn('[waf] 网页视图加载失败：$error');
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  /// 定下这个 WebView 用哪个 UA。
  ///
  /// 两种来源，优先级分明：
  /// 1. **用户显式配过 UA**（图源网络覆盖 / 全局设置里填了 UA）：照用——后续 API
  ///    请求也会用同一个（cf_clearance 绑 IP + UA），用户的选择优先；
  /// 2. 没配过：拿 **WKWebView 的默认 UA**（本机真实的 iOS / WebKit 版本）补上
  ///    `Version/… Safari/…`，拼成与本机 Safari 一致的 UA。
  ///
  /// 第 2 条是关键：写死版本号（或带 WebView 特征）的 UA 会被 CF 识别成内置控件，
  /// 挑战页勾选框一闪就被强制跳走（真机反馈）。
  Future<String> _resolveUserAgent(WebViewController controller) async {
    final configured = widget.userAgentOverride?.trim() ?? '';
    if (configured.isNotEmpty) return configured;
    String fallback = '';
    try {
      fallback = (await controller.getUserAgent())?.trim() ?? '';
    } catch (error) {
      LumeLog.warn('[waf] 读取 WebView 默认 UA 失败：$error');
    }
    if (fallback.isEmpty) return '';
    return safariUserAgentFrom(fallback);
  }

  /// 页面加载完之后取一次正文摘要与挑战标记，写进运行日志。
  ///
  /// 这是给「白屏」留的证据链：正文为空 → 网络/ATS/UA 有问题；正文有内容但没有
  /// 挑战 iframe → 站点没给挑战页；两者都在 → 是控件没画出来（浏览器环境问题）。
  Future<void> _probePage(String url) async {
    Map<String, Object?> probe = const <String, Object?>{};
    try {
      final raw = await _controller?.runJavaScriptReturningResult(
        'JSON.stringify({'
        't:(document.title||"").slice(0,80),'
        'n:((document.body&&document.body.innerText)||"").replace(/\\s+/g," ").slice(0,160),'
        'f:document.querySelectorAll("iframe").length,'
        'c:/challenges\\.cloudflare\\.com|turnstile|cf-chl|challenge-platform|just a moment|请稍候/i'
        '.test(document.documentElement.innerHTML+document.title)'
        '})',
      );
      LumeLog.info('[waf] 网页视图正文摘要（$url）：$raw');
      final decoded = jsonDecode('$raw');
      if (decoded is Map) probe = decoded.cast<String, Object?>();
    } catch (error) {
      LumeLog.info('[waf] 读取网页视图正文失败：$error');
      return;
    }
    if (!mounted) return;
    final body = '${probe['n'] ?? ''}'.trim();
    if (probe['c'] == true) _challengeSeen = true;
    // 挑战页被 CF 自己跳成空白页：把挑战页拉回来，让用户还有机会点勾选框。
    if (_challengeSeen && body.isEmpty) {
      await _restoreChallengeIfBlanked();
    }
  }

  /// 挑战页跳成空白时把它重新打开。
  ///
  /// 用户口径（真机反馈「勾选框一闪就跳空白页，还没点就没了」）：**别让用户面对
  /// 白屏**——只要刚才这一页确实是挑战页、而当前页正文是空的，就把挑战页重新打开，
  /// 给人足够时间完成手动验证。最多重开几次，免得 CF 一直跳走时我们跟着刷个没完。
  ///
  /// 这里**只做重开**：不读 Cookie、不关窗、不重置控制器（用户没点 ✕ 之前，
  /// 验证流程就还没结束）。
  Future<void> _restoreChallengeIfBlanked() async {
    if (_collecting || !mounted) return;
    if (_challengeRestores >= _maxChallengeRestores) {
      LumeLog.warn('[waf] 挑战页已被跳走 $_challengeRestores 次，不再自动重开：'
          '多半是 UA / 网络环境被识别（换网络或更新 App 版本再试）');
      setState(() => _title = '验证页无法停留（可点右上角刷新重试）');
      return;
    }
    _challengeRestores++;
    LumeLog.info('[waf] 挑战页被跳成空白，重新打开第 $_challengeRestores 次：${widget.url}');
    setState(() => _title = '验证页被跳走了，正在重新打开…');
    try {
      await _controller?.loadRequest(
        Uri.parse(widget.url),
        headers: _browserHeaders,
      );
    } catch (error) {
      LumeLog.warn('[waf] 重新打开挑战页失败：$error');
    }
  }

  /// 自动模式轮询：Cloudflare 放行后会写 `cf_clearance`，看到它就自动收尾。
  ///
  /// 之所以轮询而不是只等「用户点关闭」：用户口径 4 要求**大部分场景后台静默完成**
  /// ——校验本来就可能是无感的（IP 信誉 / 无需点选），那就自己关掉，别打扰人。
  void _startAutoPoll() {
    _autoPoll ??= Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (!mounted || _collecting) {
        timer.cancel();
        _autoPoll = null;
        return;
      }
      String cookie = '';
      try {
        cookie = '${await _controller?.runJavaScriptReturningResult('document.cookie')}';
      } catch (_) {
        return;
      }
      final passed = cookie.contains('cf_clearance') ||
          cookie.contains('__cf_bm');
      if (!passed) return;
      timer.cancel();
      _autoPoll = null;
      // 再等一拍：放行后站点往往还会写几枚别的 Cookie。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      await _closeAndCollect();
    });
  }

  @override
  void dispose() {
    _autoPoll?.cancel();
    _autoPoll = null;
    super.dispose();
  }

  /// 关窗：先把 Cookie 取回来再退出（用户口径第 3 条）。
  Future<void> _closeAndCollect() async {
    if (_collecting) return;
    setState(() => _collecting = true);
    final cookies = <String, String>{};

    // 1) JS 可见的那份（非 HttpOnly）。
    try {
      final raw = await _controller?.runJavaScriptReturningResult(
        'document.cookie',
      );
      cookies.addAll(_parseJsCookie('$raw'));
    } catch (error) {
      LumeLog.info('[waf] 读取 document.cookie 失败：$error');
    }

    // 2) 原生 Cookie 仓库（含 HttpOnly 的 cf_clearance——这份才是关键）。
    try {
      final list = await _cookieChannel.invokeMethod<List<Object?>>(
        'allCookies',
        <String, Object?>{'url': widget.url},
      );
      for (final entry in list ?? const <Object?>[]) {
        if (entry is Map) {
          final name = '${entry['name'] ?? ''}'.trim();
          final value = '${entry['value'] ?? ''}';
          if (name.isNotEmpty && value.isNotEmpty) cookies[name] = value;
        }
      }
    } on MissingPluginException {
      LumeLog.info('[waf] 当前平台没有原生 Cookie 通道，只取 JS 可见的 Cookie');
    } catch (error) {
      LumeLog.info('[waf] 读取原生 Cookie 失败：$error');
    }

    if (!mounted) return;
    if (cookies.isEmpty) {
      if (widget.auto) {
        // 自动模式下静默退出：由调用方（引擎层）按原来的失败处理并给出口，
        // 不要在这里插一个「未能读取验证会话」的对话框打断正在进行的解析。
        setState(() => _collecting = false);
        Navigator.of(context).pop(0);
        return;
      }
      // 用户口径 2.1.4：一个 Cookie 都没取到就如实说，别让用户以为已经生效。
      setState(() => _collecting = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('未能读取验证会话'),
          content: const Text(
            '未能读取验证会话，请重新执行网页视图验证。\n\n'
            '（通常是页面还没加载完就关闭了：等验证通过、站点页面真正显示出来后再关。）',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    widget.onCollected(cookies);
    Navigator.of(context).pop();
  }

  /// 解析 `document.cookie` 的返回：可能是裸串，也可能被包成 JSON 字符串。
  static Map<String, String> _parseJsCookie(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const <String, String>{};
    if (text.startsWith('"') && text.endsWith('"') && text.length > 1) {
      try {
        text = jsonDecode(text) as String;
      } catch (_) {
        text = text.substring(1, text.length - 1);
      }
    }
    final result = <String, String>{};
    for (final part in text.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final name = part.substring(0, index).trim();
      final value = part.substring(index + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) result[name] = value;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // 顶栏：左上角关闭（用户口径：点左上角 X 关闭）、中间标题、右上角刷新。
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: LumeTheme.surface,
                border: Border(
                  bottom: BorderSide(color: LumeTheme.hairline),
                ),
              ),
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: _collecting ? null : _closeAndCollect,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(
                          _title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        Text(
                          // 第二行给出**正在验证哪个站**（用户口径：能当场核对地址），
                          // 以及唯一的操作动作——过完校验点左上角 ✕。
                          '${originOf(widget.url) ?? widget.url} · '
                          '完成后点左上角 ✕ 关闭（自动取回会话）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: LumeTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => controller?.reload(),
                  ),
                ],
              ),
            ),
            if (_progress < 100)
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress / 100,
                minHeight: 2,
              ),
            Expanded(
              child: controller == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Stack(
                      children: <Widget>[
                        WebViewWidget(controller: controller),
                        if (_loadError != null) _buildLoadError(controller),
                      ],
                    ),
            ),
            if (_collecting)
              const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }

  /// 主框架加载失败时压在 WebView 上的一张卡：**白屏换成可读原因 + 出口**。
  ///
  /// 真机反馈的「页面空白、看不到勾选框」有一类就是这个：请求根本没到达站点
  ///（代理 / DNS / 超时）。以前这种情况下页面一片白，用户无从判断，只能反复点。
  Widget _buildLoadError(WebViewController controller) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined, size: 34),
              const SizedBox(height: 10),
              const Text(
                '这个地址没打开',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '$_loadError\n\n$_loadErrorHint',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: LumeTheme.muted),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() => _loadError = null);
                  unawaited(controller.reload());
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 加载失败时给一句能照着做的下一步（真机上最常见的是代理没配到网页视图上）。
  String get _loadErrorHint =>
      '网页视图走的是**系统网络**，App 里给这个图源配的代理 / UA 不会作用到它。\n'
      '如果这个站需要代理才能访问，请在「源管理 → 网络配置」确认代理后，'
      '或在系统设置里配好 VPN / 代理再试。';
}

/// 把 WKWebView 的默认 UA 变成**与本机 Safari 一致**的 Safari UA。
///
/// 默认 UA（WKWebView）：
/// `Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15
///  (KHTML, like Gecko) Mobile/15E148`
/// 本机 Safari：
/// `… AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1`
///
/// 只补 `Version/x.y` 与 `Safari/604.1` 两段，其余**原样保留**：这样 UA 里写的
/// iOS 版本、WebKit 版本、`Mobile/15E148` 全都是这台设备真实的值——CF 的客户端
/// 一致性检测挑不出毛病。写死版本号（旧实现是 `iPhone OS 17_0`）在真机上会出现
/// 「挑战页勾选框一闪就被强制跳走」。
///
/// 已经是 Safari UA（带 `Safari/`）就原样返回；解析不出 iOS 版本时退回
/// `Version/17.0 Safari/604.1` 两段通用值（至少不是 WebView 特征）。
String safariUserAgentFrom(String webViewUserAgent) {
  final ua = webViewUserAgent.trim();
  if (ua.isEmpty || ua.contains('Safari/')) return ua;
  // 版本号取 UA 里自报的 iOS 版本：`iPhone OS 18_5` → `18.5`。
  final match = RegExp(r'OS (\d+)_(\d+)').firstMatch(ua);
  final version = match == null ? '17.0' : '${match.group(1)}.${match.group(2)}';
  if (ua.contains('Version/')) {
    return '$ua Safari/604.1';
  }
  if (ua.contains('Mobile/')) {
    return '${ua.replaceFirst('Mobile/', 'Version/$version Mobile/')} Safari/604.1';
  }
  return '$ua Version/$version Mobile/15E148 Safari/604.1';
}

/// 打开网页视图并返回取到的 Cookie（宿主据此写进图源会话存储）。
/// 手动「网页视图」：**半屏弹窗**（用户口径：不要全屏页，别影响主界面操作）。
///
/// - 占屏幕下方约 3/4 高，圆角浮层；用户能看见背后页面，确认「这是在验证哪个站」；
/// - 过完校验点左上角 ✕（或等自动收尾）→ Cookie 原样返回给调用方落库；
/// - 返回 null = 用户直接关掉/没拿到；非空 Map = 至少取到一枚 Cookie。
Future<Map<String, String>?> showWafWebView({
  required BuildContext context,
  required String url,
  required String sourceName,
  Section? section,
  String? sourceId,
  String? userAgent,
}) {
  Map<String, String>? collected;
  return showModalBottomSheet<Map<String, String>>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: WafWebViewPage(
          url: url,
          sourceName: sourceName,
          // 手动验证也要用 App 的 UA：一来 cf_clearance 绑 UA（不带上等于白验），
          // 二来 WKWebView 默认 UA 不带 Safari 段，CF 会给一张没有勾选框的白页。
          userAgentOverride: userAgent,
          onCollected: (cookies) => collected = cookies,
          onUserAgent: (ua) {
            if (section != null && sourceId != null) {
              WafSessions.saveUserAgent(section, sourceId, ua);
            }
          },
        ),
      ),
    ),
  ).then((_) => collected ?? const <String, String>{});
}


/// WAF 判定与失败文本的桥（页面用它决定要不要显示【网页视图】）。
bool shouldOfferWebView(String? failureMessage) =>
    looksLikeWafFailure(failureMessage);

/// 手动「网页视图」的结果。
///
/// 刻意不用 bool：三种结局的后续动作完全不同——「用户取消」不该再弹提示
/// （他刚说过不要），「没取到会话」要教他等页面出内容再关。把它压成一个布尔
/// 就会在这两种情况下给错话（用户口径里「点了没反应」有一半是这类错话）。
enum WafWebViewOutcome {
  /// 窗口开过、会话已落库：调用方可以重拉数据了。
  collected,

  /// 窗口开了，但一个 Cookie 都没取到（多半是没过完校验就关了）。
  emptySession,

  /// 窗口没打开：地址没拿到且用户取消了，或者开窗本身失败（异常已弹窗说明）。
  notOpened,
}

/// 打开验证窗口的函数签名（默认是 [showWafWebView]；测试注入替身用）。
typedef WafWebViewOpener = Future<Map<String, String>?> Function({
  required BuildContext context,
  required String url,
  required String sourceName,
  Section? section,
  String? sourceId,
  String? userAgent,
});

/// 手动「网页视图」的统一入口：首页 / 探索页 / 筛选页三处共用一份流程。
///
/// 真机反馈过三轮「点了没反应」，所以这个函数把三件事钉死，任何一条都不许
/// 静默退出：
/// 1. **地址一定有着落**：先走 [resolveWebViewOrigin] 的四层兜底链，四层全落空
///    就**弹出地址输入框**（预填最可能的那个站）——粘贴导入的源、老脚本、
///    没有订阅地址这些组合都还能过校验；
/// 2. **点了一定有反应**：开窗失败（WebView 插件异常、地址非法）也如实弹窗
///    说明，而不是什么都不发生；
/// 3. **取到会话就落库**：手动验证同样记 UA（`cf_clearance` 绑 IP + UA，
///    不记 UA 等于白验）。
///
/// UA 由调用方通过 [userAgentFor] 解析后传进来（默认走 [LumeSources]）：
/// **验证窗与后续 API 必须同一个 UA**，否则拿回来的 cf_clearance 一样被拒。
Future<WafWebViewOutcome> runWafWebViewFlow({
  required BuildContext context,
  required Section section,
  required String sourceId,
  required String sourceName,
  String? failureMessage,
  String originUrl = '',
  WafWebViewOpener opener = showWafWebView,
  Future<String?> Function(Section section, String sourceId)? userAgentFor,
}) async {
  if (!context.mounted) return WafWebViewOutcome.notOpened;
  var url = resolveWebViewOrigin(
    failureMessage: failureMessage,
    sourceId: sourceId,
    originUrl: originUrl,
  );
  if (url == null || url.trim().isEmpty) {
    LumeLog.info('[waf] $sourceId 的站址四层兜底都没拿到，改问用户要一次');
    url = await askWebViewOrigin(
      context: context,
      sourceName: sourceName,
      initial: guessWebViewAddress(sourceId: sourceId, originUrl: originUrl),
    );
  }
  if (url == null || url.trim().isEmpty) {
    LumeLog.info('[waf] $sourceId 未打开验证窗口（没有地址或用户取消）');
    return WafWebViewOutcome.notOpened;
  }
  // 地址输入框是异步的：用户可能已经离开这个页面了。
  if (!context.mounted) return WafWebViewOutcome.notOpened;

  // 验证窗用与 API 请求同一个 UA（cf_clearance 绑 IP + UA）；解析失败就交给
  // 页面自己的兜底（它会在日志里写明用的是 WKWebView 默认 UA）。
  final ua = await (userAgentFor ?? LumeSources.userAgentFor)(section, sourceId);
  if (!context.mounted) return WafWebViewOutcome.notOpened;

  final Map<String, String>? cookies;
  try {
    cookies = await opener(
      context: context,
      url: url,
      sourceName: sourceName,
      section: section,
      sourceId: sourceId,
      userAgent: ua,
    );
  } catch (error) {
    // 例如 WebView 插件没就绪、地址打不开：这类失败以前就是「点了没反应」，
    // 现在必须留下可读结论。
    LumeLog.warn('[waf] 网页视图打开失败：$error');
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('验证窗口打不开'),
          content: Text(
            '打开 $url 时出错：$error\n\n'
            '可以先在「源管理 → 网络配置」里检查这个源的代理 / UA；'
            '站点本身不可达时也可以先试试【重试】。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
    return WafWebViewOutcome.notOpened;
  }
  if (cookies == null || cookies.isEmpty) {
    LumeLog.info('[waf] $sourceId 的验证窗口开着，但没取到会话');
    return WafWebViewOutcome.emptySession;
  }
  WafSessions.save(section, sourceId, cookies);
  LumeLog.info('[waf] $sourceId 手动验证取回 ${cookies.length} 项 Cookie');
  return WafWebViewOutcome.collected;
}

/// 地址兜底链四层全落空时，问用户要一次源站地址。
///
/// 这是「点了没反应」的最后一根保险绳：粘贴导入（没有订阅地址）、老脚本（报错
/// 文案里没有 URL）、进程刚重启（网络层还没记到请求）——这些组合同时出现时，
/// 用户仍然要有一个办法把验证窗口打开，而不是面对一个死键。
///
/// 返回可打开的 origin；用户明确取消时返回 null。输入看不懂**不会**关掉对话框
/// （就地给一行红字），因此这里不会出现「填了东西却什么都没发生」。
Future<String?> askWebViewOrigin({
  required BuildContext context,
  required String sourceName,
  String initial = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _WafOriginDialog(sourceName: sourceName, initial: initial),
    );

/// 地址输入框本体。
///
/// 做成 State 而不是 `StatefulBuilder` + 局部变量：输入框的 `TextEditingController`
/// 必须在**对话框整段退出动画走完**之后才销毁。早先那版在 `showDialog(…).whenComplete`
/// 里 dispose，退场那一帧还在重建 TextField，直接抛
/// 「A TextEditingController was used after being disposed」（回归用例逮到的）。
class _WafOriginDialog extends StatefulWidget {
  const _WafOriginDialog({required this.sourceName, required this.initial});

  final String sourceName;
  final String initial;

  @override
  State<_WafOriginDialog> createState() => _WafOriginDialogState();
}

class _WafOriginDialogState extends State<_WafOriginDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final url = normalizeWebViewAddress(_controller.text);
    if (url == null) {
      // 输入看不懂就**留在对话框里**给一行提示，绝不「填了却没反应」。
      setState(() => _error = '像这样填：www.example.com');
      return;
    }
    Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('过「${widget.sourceName}」的人机校验'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('这个图源没给出站址，填一次就能打开验证窗口（填站点地址，不是脚本地址）：'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'www.example.com',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('打开')),
      ],
    );
  }
}

/// 自动静默校验（用户口径 2 / 3 / 4）：脚本抛 `NEED_WEBVIEW_VERIFY` 时由应用自己调起。
///
/// - **小悬浮窗**：不做全屏页——一个 320×420 的圆角小窗浮在界面上，用户能继续看
///   当前页面；不需要交互的校验（IP 信誉 / 无感校验）会自己关掉，用户基本无感；
/// - **拿到会话就收尾**：轮询到 `cf_clearance` / `__cf_bm` 就自动收集 Cookie 关窗
///   （见 [_WafWebViewPageState._startAutoPoll]），不需要用户点任何按钮；
/// - **Cookie 与 UA 一起存**：验证用哪个 UA，后续 API 请求就得用哪个（CF 会绑定），
///   因此这里把网页视图的 UA 一并回传，由调用方写进该图源的会话存储。
///
/// 返回 true 表示拿到了可复用的会话（调用方据此重试刚才失败的那次脚本调用）。
Future<bool> showWafAutoVerify({
  required BuildContext context,
  required Section section,
  required String sourceId,
  required String sourceName,
  required String url,
  String? userAgentOverride,
}) async {
  Map<String, String>? collected;
  String? userAgent;
  try {
    await Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: false,
        barrierColor: const Color(0x33000000),
        transitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (context, _, _) => Align(
          // 小窗落在右下角：不遮内容主体，也不是全屏页。
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 12, bottom: 96),
            child: SizedBox(
              width: 320,
              height: 420,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Material(
                  color: LumeTheme.surface,
                  child: WafWebViewPage(
                    url: url,
                    sourceName: sourceName,
                    auto: true,
                    compact: true,
                    userAgentOverride: userAgentOverride,
                    onUserAgent: (value) => userAgent = value,
                    onCollected: (cookies) => collected = cookies,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  } catch (error) {
    LumeLog.warn('[waf] 自动校验窗口异常：$error');
    return false;
  }
  final cookies = collected;
  if (cookies == null || cookies.isEmpty) return false;
  WafSessions.save(section, sourceId, cookies);
  WafSessions.saveUserAgent(section, sourceId, userAgent);
  LumeLog.info('[waf] $sourceId 自动校验完成：${cookies.length} 项 Cookie');
  return true;
}
