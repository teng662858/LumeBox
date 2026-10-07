import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/net/waf.dart';
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
  });

  /// 要打开的源站地址（通常是失败请求的 origin）。
  final String url;

  /// 图源名（顶栏标题里给出上下文）。
  final String sourceName;

  /// 取回 Cookie 后的落盘回调（宿主负责写进该图源的会话存储）。
  final void Function(Map<String, String> cookies) onCollected;

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
            if (!mounted) return;
            setState(() => _title = (title == null || title.trim().isEmpty)
                ? widget.sourceName
                : title.trim());
          },
          onWebResourceError: (error) => LumeLog.info(
            '[waf] 网页视图加载出错：${error.description}',
          ),
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
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
    Navigator.of(context).pop(cookies.length);
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
Future<Map<String, String>?> showWafWebView({
  required BuildContext context,
  required String url,
  required String sourceName,
}) {
  Map<String, String>? collected;
  return Navigator.of(context)
      .push<int>(
        MaterialPageRoute<int>(
          fullscreenDialog: true,
          builder: (_) => WafWebViewPage(
            url: url,
            sourceName: sourceName,
            onCollected: (cookies) => collected = cookies,
          ),
        ),
      )
      .then((count) => count == null ? null : (collected ?? <String, String>{}));
}

/// 从一个失败地址里取 origin（网页视图默认打开它）。
String? originOf(String? url) {
  final uri = Uri.tryParse(url ?? '');
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return '${uri.scheme}://${uri.host}';
}

/// 失败的请求地址（图源契约没有暴露，这里从错误文本里捞；捞不到就用图源站点的
/// 常见入口：让用户自己在网页里点一下也能过校验）。
String? urlFromFailure(String? message) {
  final text = message ?? '';
  // 只取「http(s)://…」这一截：到空白 / 引号 / 括号为止（含全角括号）。
  final match = RegExp('https?://[^\\s"\')\\uFF09]+').firstMatch(text);
  return match?.group(0);
}

/// WAF 判定与失败文本的桥（页面用它决定要不要显示【网页视图】）。
bool shouldOfferWebView(String? failureMessage) =>
    looksLikeWafFailure(failureMessage);
