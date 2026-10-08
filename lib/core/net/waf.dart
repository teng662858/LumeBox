import 'dart:convert';

import '../reading/reading.dart';
import '../session/section.dart';
import 'source_request_log.dart';
import '../util/lume_log.dart';

/// Cloudflare / WAF 拦截的识别与会话（Cookie）保存（用户要求）。
///
/// ## 这套机制解决什么
///
/// 有些源站挂了 Cloudflare 的人机校验（「Just a moment…」/ 1020 / cf_clearance）：
/// 直接请求只会拿到一张挑战页，脚本解析出空数据。用户要的是**在 App 内置网页视图
/// 里手动过校验，再把会话取回来复用**——不是把分类写死，也不是放弃这家源。
///
/// ## 只对「需要校验」的源启用（用户口径第 7 条）
///
/// 普通源一次都不该走这条路：识别只看**明确的 WAF 指纹**（状态码 + 响应头 +
/// 页面特征），识别不出就按原来的直连逻辑走，行为不变。
class WafDetector {
  WafDetector._();

  /// 明确的 WAF 指纹：状态码 / 响应头 / 页面文本三选一命中即算。
  ///
  /// 只用**高置信**标记：`cf-mitigated` / `cf-chl` / `__cf_chl` 是 Cloudflare
  /// 挑战的铁证；`just a moment` 与 `attention required` 是它的挑战页标题。
  /// 不用「403 就算」这种粗判定——403 也可能是防盗链，把用户引到网页视图是错的。
  static bool isChallenge({
    required int statusCode,
    Map<String, String> headers = const <String, String>{},
    String body = '',
  }) {
    if (statusCode != 403 && statusCode != 503 && statusCode != 429) {
      return false;
    }
    final headerText = headers.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n')
        .toLowerCase();
    if (headerText.contains('cf-mitigated') ||
        headerText.contains('__cf_chl') ||
        headerText.contains('cf-chl') ||
        headerText.contains('challenge-platform')) {
      return true;
    }
    final text = body.toLowerCase();
    return text.contains('need_webview_verify') ||
      text.contains('waf_recaptcha_v3') ||
      text.contains('just a moment') ||
        text.contains('attention required') ||
        text.contains('__cf_chl') ||
        text.contains('cf-chl-') ||
        // 挑战页里的脚本/iframe 地址（实测最常见的一条）。
        text.contains('challenge-platform') ||
        text.contains('checking your browser');
  }
}

/// 某个图源的 WAF 会话：从网页视图取回来的整套 Cookie。
///
/// 存在**图源自己的配置存储**里（`reading.db` 的 reading_setting 表，键按图源
/// id 分开）——与用户口径第 3 条一致；同一板块的其它源互不可见，清缓存也不会
/// 碰它（它不是可再生的缓存，是用户手动过校验换来的凭证）。
class WafSessionStore {
  WafSessionStore(this.library);

  final ReadingLibrary library;

  /// 键前缀（后面接图源 id）。
  static const String keyPrefix = 'waf.cookies.';

  static String keyFor(String sourceId) => '$keyPrefix$sourceId';

  /// 读取某图源保存的 Cookie 串（`a=1; b=2`）；没有则返回 null。
  String? cookieHeader(String sourceId) {
    final raw = library.setting(keyFor(sourceId));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final pairs = <String>[];
        decoded.forEach((name, value) {
          final key = '$name'.trim();
          final text = '$value';
          if (key.isNotEmpty && text.isNotEmpty) pairs.add('$key=$text');
        });
        return pairs.isEmpty ? null : pairs.join('; ');
      }
    } catch (error) {
      LumeLog.warn('[waf] $sourceId 的会话读取失败：$error');
    }
    return null;
  }

  /// 保存 Cookie 表（网页视图关闭时调用）。
  ///
  /// 合并语义：同名的覆盖、新的追加——用户在网页里刷新过校验，新的
  /// `cf_clearance` 必须盖掉旧的，否则等于没更新。
  String? save(String sourceId, Map<String, String> cookies) {
    if (cookies.isEmpty) return cookieHeader(sourceId);
    final merged = <String, String>{};
    final existing = cookieHeader(sourceId);
    if (existing != null) {
      for (final part in existing.split(';')) {
        final index = part.indexOf('=');
        if (index <= 0) continue;
        merged[part.substring(0, index).trim()] = part.substring(index + 1).trim();
      }
    }
    cookies.forEach((name, value) {
      if (name.trim().isNotEmpty && value.isNotEmpty) {
        merged[name.trim()] = value;
      }
    });
    library.setSetting(keyFor(sourceId), jsonEncode(merged));
    LumeLog.info('[waf] $sourceId 保存会话 Cookie ${merged.length} 项');
    return merged.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  }

  /// 清掉某图源的会话（网页视图里被拒 / 用户手动重置时用）。
  void clear(String sourceId) => library.setSetting(keyFor(sourceId), '');

  /// 网页视图那套请求头里的 UA（键前缀后的 id）。
  ///
  /// Cloudflare 的 `cf_clearance` 与「IP + UA」绑定：验证用哪个 UA，后续请求就得
  /// 用哪个 UA，否则 Cookie 带上了也照样 403。网页视图里读到什么就存什么。
  static const String uaKeyPrefix = 'waf.ua.';

  String? userAgent(String sourceId) {
    final raw = library.setting('$uaKeyPrefix$sourceId');
    return raw == null || raw.trim().isEmpty ? null : raw.trim();
  }

  void saveUserAgent(String sourceId, String? userAgent) {
    final text = (userAgent ?? '').trim();
    if (text.isEmpty || text == 'null') return;
    library.setSetting('$uaKeyPrefix$sourceId', text);
  }

  /// 当前保存了多少项（设置页与提示文案用）。
  int countOf(String sourceId) {
    final header = cookieHeader(sourceId);
    if (header == null) return 0;
    return header.split(';').where((part) => part.trim().isNotEmpty).length;
  }
}

/// WAF 会话在「图源 → 请求头」这条链路上的落点：由数据源在发请求前合并。
///
/// 为什么单独一个函数而不是塞进脚本里：Cookie 是**宿主凭据**，脚本不该也不
/// 需要知道它从哪来；脚本只管照常 fetch，宿主负责带上（用户口径第 4 条）。
String? mergeCookieHeader({
  required String? existing,
  required String? wafCookies,
}) {
  final left = existing?.trim() ?? '';
  final right = wafCookies?.trim() ?? '';
  if (left.isEmpty) return right.isEmpty ? null : right;
  if (right.isEmpty) return left;
  // 合并去重：以 WAF 会话为准（它是最新过校验的那一份）。
  final merged = <String, String>{};
  for (final part in <String>[...left.split(';'), ...right.split(';')]) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    merged[part.substring(0, index).trim()] = part.substring(index + 1).trim();
  }
  return merged.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}

/// 从失败信息里认出「WAF 挑战」这一类（供页面决定要不要显示【网页视图】）。
///
/// 识别口径与 [WafDetector] 一致，但这里看的是**归一化后的错误文本**：脚本
/// 抛出的 `拉取失败：HTTP 403` 一路传上来，宿主据此判断。
bool looksLikeWafFailure(String? message) {
  final text = (message ?? '').toLowerCase();
  if (text.isEmpty) return false;
  return text.contains('just a moment') ||
      text.contains('__cf_chl') ||
      text.contains('cf-chl') ||
      text.contains('cf-mitigated') ||
      text.contains('challenge') ||
      // 云盾 / 长亭等国内 WAF 的常见字样。
      text.contains('waf') ||
      text.contains('security check') ||
      text.contains('人机验证');
}

/// 板块：会话存储按板块打开（与图源配置同库）。
Future<WafSessionStore> openWafSessionStore(Section section) async {
  final library = await ReadingLibrary.open(section);
  return WafSessionStore(library);
}

/// 会话的**同步查询入口**（给网络层用：请求前现取一次 Cookie）。
///
/// 为什么不做成「注册式」：板块库的打开时机分散在页面与预加载里，漏挂一处就是
/// 「验证完了却不生效」。这里按板块惰性取**已打开**的库（[ReadingLibrary.find]），
/// 库没打开就等于没有会话——语义简单，且不会顺手把库打开。
class WafSessions {
  WafSessions._();

  static final Map<String, WafSessionStore> _stores = <String, WafSessionStore>{};

  /// 某板块的会话存储（库没打开时为 null）。
  static WafSessionStore? storeOf(Section section) {
    final cached = _stores[section.id];
    if (cached != null) return cached;
    final library = ReadingLibrary.find(section);
    if (library == null) return null;
    final store = WafSessionStore(library);
    _stores[section.id] = store;
    return store;
  }

  /// 取某图源保存的会话 Cookie 串；没有则 null。
  static String? cookiesFor(Section section, String sourceId) =>
      storeOf(section)?.cookieHeader(sourceId);

  /// 保存（网页视图关闭时调用）；库没打开则返回 null。
  static String? save(Section section, String sourceId, Map<String, String> cookies) =>
      storeOf(section)?.save(sourceId, cookies);

  /// 某个图源当前有没有会话（页面据此显示「已取回会话」）。
  static int countFor(Section section, String sourceId) =>
      storeOf(section)?.countOf(sourceId) ?? 0;

  /// 取某图源验证时用的 UA（没有则 null，网络层按原口径用全局 UA）。
  static String? userAgentFor(Section section, String sourceId) =>
      storeOf(section)?.userAgent(sourceId);

  /// 保存验证时用的 UA。
  static void saveUserAgent(Section section, String sourceId, String? userAgent) =>
      storeOf(section)?.saveUserAgent(sourceId, userAgent);

  /// 仅测试用：丢掉缓存句柄。
  static void resetForTesting() => _stores.clear();
}

/// 脚本抛出的**固定标记**对应的处理方式（用户口径 2.1 / 2.2）。
enum WafFailureKind {
  /// 有可复用会话（cf_clearance 那类）：走内置网页视图取 Cookie。
  webView,

  /// 放行绑定浏览器会话 / IP 信誉，导不出可复用 Cookie（reCAPTCHA v3 等）：
  /// 只能配「外部无头浏览器桥接服务」，**不展示网页视图按钮**。
  bridge,
}

/// 从失败信息里判定走哪条路；null 表示不是 WAF 问题（普通失败只有「重试」）。
///
/// 两类识别顺序：**脚本的固定标记优先**（`NEED_WEBVIEW_VERIFY` /
/// `WAF_RECAPTCHA_V3`，用户口径就是这么定的），认不出标记再退回指纹兜底
/// （老的源没升级、或者 WAF 用别的方式拦），那一刻按「网页视图」处理。
WafFailureKind? wafKindOf(String? message) {
  final text = (message ?? '').toUpperCase();
  if (text.isEmpty) return null;
  if (text.contains('WAF_RECAPTCHA_V3')) return WafFailureKind.bridge;
  if (text.contains('NEED_WEBVIEW_VERIFY')) return WafFailureKind.webView;
  return looksLikeWafFailure(message) ? WafFailureKind.webView : null;
}

/// 需要外部桥接时的统一文案（用户口径 2.2.4）。
const String wafBridgeHint =
    '该站点需要配置外部无头浏览器桥接服务，APP 无法直接访问。\n'
    '（在「源管理 → 网络配置 → 桥接服务地址」里填一个已过验证的 Playwright / '
    'Puppeteer 桥地址；普通 HTTP 代理无效。）';

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

/// 弹「网页视图」时要打开的地址：**统一兜底链**，四层依次尝试。
///
/// 1. 失败文案里的 URL（脚本把地址写进报错文案时）；
/// 2. **该图源最近请求过的地址**（见 [SourceRequestLog]——只要报的是 WAF 错，
///    就一定发过请求；这条与脚本写法、导入方式都无关，是最可靠的一层）；
/// 3. 图源的订阅地址；
/// 4. 源 id 里带的域名（导入器允许 `www.example.com_备注` 这种写法）。
///
/// 都没有才返回 null（调用方给一句可操作提示，不再静默退出）。
String? resolveWebViewOrigin({
  String? failureMessage,
  String? sourceId,
  String? originUrl,
}) {
  final fromMessage = originOf(urlFromFailure(failureMessage));
  if (fromMessage != null) return fromMessage;
  final fromLog = originOf(SourceRequestLog.lastFor(sourceId ?? ''));
  if (fromLog != null) return fromLog;
  final fromOrigin = originOf(originUrl);
  if (fromOrigin != null) return fromOrigin;
  final id = (sourceId ?? '').trim();
  if (id.isNotEmpty) {
    final head = id.split('_').first.trim();
    if (head.contains('.')) {
      final uri = Uri.tryParse('https://$head');
      if (uri != null && uri.host.contains('.')) return 'https://${uri.host}';
    }
  }
  return null;
}
