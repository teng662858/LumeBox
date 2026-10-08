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

  /// 手动验证窗是否正开着（含选地址那一步）。
  ///
  /// **同一时刻只允许一个验证窗**（真机反馈「半屏窗口里又套了一层小圆角弹窗」：
  /// 用户点了手动的【网页视图】，背后的页面重拉又触发了自动小窗，两个窗口叠在一起）。
  /// 手动窗开着时，自动路径直接按「没通过」返回，界面照旧给错误卡与出口。
  static bool _manualOpen = false;

  /// 手动流程开始（弹窗/选地址之前调用）。
  static void beginManual() => _manualOpen = true;

  /// 手动流程结束（**无论有没有拿到会话**都要调）。
  ///
  /// 没拿到会话时还会给这个源压一小段冷却：刚关掉的窗口马上又弹一个一模一样的小窗，
  /// 用户只会觉得「关不掉」。冷却期内自动路径不弹窗（页面上的【网页视图】按钮照常可用）。
  static void endManual({Section? section, String? sourceId, bool collected = false}) {
    _manualOpen = false;
    if (collected || section == null || sourceId == null) return;
    _cooldown['${section.id}/${sourceId.trim()}'] = DateTime.now();
  }

  /// 「刚手动关过一次、没拿到会话」的时间戳（按板块 + 源）。
  static final Map<String, DateTime> _cooldown = <String, DateTime>{};

  /// 冷却时长：够用户看清错误卡并决定下一步，又不至于把后续的正常自动校验永久挡掉。
  static const Duration cooldown = Duration(seconds: 90);

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
    // 同一时刻只允许一个验证窗：手动窗开着、或刚手动关掉没拿到会话（冷却中），
    // 自动路径都不再弹第二个窗。
    if (_manualOpen) {
      LumeLog.info('[waf] 手动验证窗正开着，自动校验不重复弹窗：$key');
      return Future<bool>.value(false);
    }
    final until = _cooldown[key];
    if (until != null) {
      if (DateTime.now().difference(until) < cooldown) {
        LumeLog.info('[waf] 刚手动关过一次（冷却中），自动校验不弹窗：$key');
        return Future<bool>.value(false);
      }
      _cooldown.remove(key);
    }
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

  /// 仅测试用：清掉钩子、在飞记录、手动窗状态与冷却。
  static void resetForTesting() {
    _handler = null;
    _running.clear();
    _manualOpen = false;
    _cooldown.clear();
  }
}
