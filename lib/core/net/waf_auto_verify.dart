import 'dart:async';

import '../session/section.dart';
import '../util/lume_log.dart';

/// 自动过 WAF 校验的全局钩子（用户口径 2 / 4）。
///
/// **为什么是一个全局钩子**：需要它的地方在引擎层（JS 脚本的 fetch 被 Cloudflare
/// 拦下，脚本抛 `NEED_WEBVIEW_VERIFY`），那一层没有 BuildContext、也不该认识
/// Navigator；而真正要弹的那个小窗属于界面层。于是界面层在启动时把「怎么办」
/// 注册进来（见 [AppShell]），引擎层只管调用 [run]。
///
/// **为什么在引擎层做**：脚本是「一次调用一组」的——详情、章节、播放地址分三次
/// 请求。校验只在**第一次**失败时做，拿到 Cookie 后**自动重试同一次调用**，后续
/// 调用就都带着会话正常走了（用户口径 3：不要每次都弹）。
class WafAutoVerify {
  WafAutoVerify._();

  /// 界面层注册的处理函数：返回 true 表示拿到了可复用的会话。
  static Future<bool> Function({
    required Section section,
    required String sourceId,
    required String sourceName,
    required String url,
  })? _handler;

  /// 正在跑的验证（按板块 + 源去重）：脚本并发发请求时，多个失败共用同一次验证。
  static final Map<String, Future<bool>> _running = <String, Future<bool>>{};

  static void install(
    Future<bool> Function({
      required Section section,
      required String sourceId,
      required String sourceName,
      required String url,
    }) handler,
  ) {
    _handler = handler;
  }

  static bool get isInstalled => _handler != null;

  /// 跑一次（或复用正在跑的）校验。没装钩子（例如纯单元测试）返回 false，
  /// 调用方按原来的失败处理——不会因为没弹窗就悄悄改变行为。
  static Future<bool> run({
    required Section section,
    required String sourceId,
    required String sourceName,
    required String url,
  }) {
    final handler = _handler;
    if (handler == null) return Future<bool>.value(false);
    final key = '${section.id}/${sourceId.trim()}';
    final existing = _running[key];
    if (existing != null) {
      LumeLog.info('[waf] 复用正在进行的校验：$key');
      return existing;
    }
    final future = handler(
      section: section,
      sourceId: sourceId,
      sourceName: sourceName,
      url: url,
    ).catchError((Object error) {
      LumeLog.warn('[waf] 自动校验失败：$key ($error)');
      return false;
    });
    _running[key] = future;
    return future.whenComplete(() => _running.remove(key));
  }

  /// 仅测试用：清掉钩子与在飞记录。
  static void resetForTesting() {
    _handler = null;
    _running.clear();
  }
}
