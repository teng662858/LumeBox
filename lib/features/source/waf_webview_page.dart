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

  /// 用指定 UA 打开页面（App 的请求 UA）。
  ///
  /// Cloudflare 把 `cf_clearance` 绑在「IP + UA」上：验证时与后续 API 用同一个 UA
  /// 才认，因此两边必须对齐（不传就用 WKWebView 默认 UA）。
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

  WebViewController? _controller;
  String _title = '请稍候…';
  int _progress = 0;
  bool _collecting = false;

  /// 自动模式的轮询计时器：定时看 Cloudflare 的放行 Cookie 到了没有。
  Timer? _autoPoll;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 校验靠的是真实浏览器环境：保留默认 UA（WKWebView 的 UA 就是 Safari 系），
      // 不伪装、也不注入任何脚本——注入反而会被 CF 识别。
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) => setState(() => _progress = value),
          onPageStarted: (_) => setState(() => _progress = 0),
          onPageFinished: (url) async {
            final title = await _controller?.getTitle();
            // UA 与 cf_clearance 绑定：验证用哪个 UA，后续 API 就得用哪个，
            // 因此把网页视图里的真实 UA 记下来（用户口径 2：拿到验证后的请求头）。
            final ua = await _controller?.runJavaScriptReturningResult(
              'navigator.userAgent',
            );
            widget.onUserAgent?.call('$ua'.replaceAll('"', '').trim());
            if (!mounted) return;
            setState(() => _title = (title == null || title.trim().isEmpty)
                ? widget.sourceName
                : title.trim());
            if (widget.auto) _startAutoPoll();
          },
          onWebResourceError: (error) => LumeLog.info(
            '[waf] 网页视图加载出错：${error.description}',
          ),
        ),
      );
    final ua = widget.userAgentOverride?.trim();
    if (ua != null && ua.isNotEmpty) {
      // 与 App 的请求 UA 对齐：不然验完拿到的 Cookie 在 API 请求里照样不认。
      // **必须在 loadRequest 之前**设好，否则第一次加载用的还是默认 UA。
      unawaited(_controller!.setUserAgent(ua));
    }
    unawaited(_controller!.loadRequest(Uri.parse(widget.url)));
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
                          '完成页面上的验证后，点左上角 ✕ 关闭（会自动取回会话）',
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
                  : WebViewWidget(controller: controller),
            ),
            if (_collecting)
              const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }
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
          onCollected: (cookies) => collected = cookies,
          // 手动验证同样要存 UA：cf_clearance 与 UA 绑定，不存的话后续 API
          // 请求用的是另一个 UA，等于白验（用户反馈「验完还是被拦」）。
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
