import 'dart:async';

import '../session/section.dart';
import '../util/lume_log.dart';
import 'waf.dart';

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
///
/// ## 硬规则：**验证窗只在用户显式发起的那一次尝试后打开**
///
/// 被动加载一律不弹：切图源、切页签、板块预热、首页 / 分类 / 筛选页自己拉的那
/// 一次，失败就照常给错误卡（【重试】+【网页视图】）——**绝不自己弹窗**。
/// 只有用户点了【重试】、页面先把这一次尝试 [arm] 起来（三个页面里的
/// `_retryWithWaf`），这一次尝试仍被 WAF 拦下时才允许弹窗。
///
/// 理由（真机反馈）：验证窗是对「正在做的事」的打断，只有用户自己按下重试，这个
/// 打断才是他要的；被动加载时（例如刚切完一个图源）蹦出一个 320×420 的小窗，
/// 用户只会觉得「切个源就弹窗、还关不干净」。
///
/// 其余几条闸门一个都没少：手动窗开着不弹、刚关掉没拿到会话的窗有冷却、同一个源
/// 并发失败共用同一次校验、已有会话不重复弹（重试本身就会带上那份 Cookie）。
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

  /// 用户**显式发起的这一次尝试**的许可（板块 + 源 → 许可时间）。
  ///
  /// [arm] 写入、[run] 消费（读一次就清掉，一次性）。没被 arm 过 = 被动加载，
  /// [run] 直接按「不弹窗」返回——见类文档里那条硬规则。
  static final Map<String, DateTime> _armed = <String, DateTime>{};

  /// 许可的有效期：一次尝试的请求最长也就几十秒，过期即作废。
  ///
  /// 少了这一条会漏一个被动弹窗：用户点了【重试】而这一次**成功**了（许可没被
  /// 用掉），几十秒后切源 / 切页签撞上标记，就会弹出一个他没要的窗。调用方在
  /// 尝试收尾时还会主动 [disarm]，这里是双保险。
  static const Duration armTtl = Duration(seconds: 60);

  /// 「刚关过一次、没拿到会话」的时间戳（按板块 + 源）。
  static final Map<String, DateTime> _cooldown = <String, DateTime>{};

  /// 冷却时长：够用户看清错误卡并决定下一步，又不至于把后续的正常自动校验永久挡掉。
  static const Duration cooldown = Duration(seconds: 90);

  /// 板块 + 源 的唯一键（板块内的源 id 可能重名，会话与计数都按这个键分家）。
  static String _keyOf(Section section, String sourceId) =>
      '${section.id}/${sourceId.trim()}';

  /// 用户显式发起一次尝试（页面上的【重试】）：**这一次**若仍被 WAF 拦下，允许
  /// 弹出自动验证小窗。被动加载（切源 / 下拉刷新 / 板块预热）不调用它。
  static void arm({required Section section, required String sourceId}) {
    final key = _keyOf(section, sourceId);
    _armed[key] = DateTime.now();
    LumeLog.info('[waf] 已武装自动校验（用户点了重试）：$key');
  }

  /// 撤回许可：用户发起的那一次尝试已经收尾（成功或已按失败呈现）。
  ///
  /// 收尾后立刻撤回，是为了不让许可「留在空气里」——否则用户这一次重试成功之后，
  /// 下一次**被动**加载撞上标记时会把那张过期的许可用掉，弹出一个他没要的窗。
  static void disarm({required Section section, required String sourceId}) =>
      _armed.remove(_keyOf(section, sourceId));

  /// 许可还新鲜吗（纯函数：只判时间差，便于单测）。
  static bool armIsFresh(DateTime armedAt, DateTime now) =>
      now.difference(armedAt) < armTtl;

  /// 冷却还在吗（同样的纯函数口径）。
  static bool cooldownActive(DateTime at, DateTime now) =>
      now.difference(at) < cooldown;

  /// 手动流程开始（弹窗/选地址之前调用）。
  static void beginManual() => _manualOpen = true;

  /// 手动流程结束（**无论有没有拿到会话**都要调）。
  ///
  /// 没拿到会话时还会给这个源压一小段冷却：刚关掉的窗口马上又弹一个一模一样的小窗，
  /// 用户只会觉得「关不掉」。冷却期内自动路径不弹窗（页面上的【网页视图】按钮照常可用）。
  static void endManual({Section? section, String? sourceId, bool collected = false}) {
    _manualOpen = false;
    if (collected || section == null || sourceId == null) return;
    _cooldown[_keyOf(section, sourceId)] = DateTime.now();
  }

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
  ///
  /// 依次五道闸：
  /// 1. 同一个源正在跑 → 复用（脚本并发发请求时只弹一个窗）；
  /// 2. **用户许可**（[arm] 一次性消费）→ 没有就按被动加载处理，不弹；
  /// 3. 手动验证窗正开着 → 不弹第二个；
  /// 4. 冷却中（刚关掉一个没拿到会话的窗）→ 不弹；
  /// 5. 该源**已经有会话** → 不弹（重试本身就会带上那份 Cookie）。
  static Future<bool> run({
    required Section section,
    required String sourceId,
    required String sourceName,
    required String url,
  }) {
    final handler = _handler;
    if (handler == null) return Future<bool>.value(false);
    final key = _keyOf(section, sourceId);

    // 1) 并发去重：已经在跑的这一次（无论它是被哪一次尝试合法起来的）直接复用。
    final existing = _running[key];
    if (existing != null) {
      LumeLog.info('[waf] 复用正在进行的校验：$key');
      return existing;
    }

    // 2) 用户许可：**先消费再判**（一次性）。没有许可就是被动加载——这是一条硬
    //    规则，切图源 / 切页签 / 预热撞上标记时，界面上只出现错误卡。
    final armedAt = _armed.remove(key);
    if (armedAt == null) {
      LumeLog.info('[waf] 这次失败不是用户点出来的（被动加载），不弹自动验证窗：$key');
      return Future<bool>.value(false);
    }
    if (!armIsFresh(armedAt, DateTime.now())) {
      LumeLog.info(
        '[waf] 用户那次尝试的许可已过期（超过 ${armTtl.inSeconds} 秒），不弹窗：$key',
      );
      return Future<bool>.value(false);
    }

    // 3) 同一时刻只允许一个验证窗（用户正对着手动窗时，背后不许再弹一个）。
    if (_manualOpen) {
      LumeLog.info('[waf] 手动验证窗正开着，自动校验不重复弹窗：$key');
      return Future<bool>.value(false);
    }

    // 4) 刚关掉过一个没拿到会话的窗（手动或自动）：冷却期内不再弹——反复点
    //    【重试】不该反复蹦出同一个窗。窗口本身照常可以用页面上的【网页视图】开。
    final until = _cooldown[key];
    if (until != null) {
      if (cooldownActive(until, DateTime.now())) {
        LumeLog.info('[waf] 刚关过一次没拿到会话的窗（冷却中），自动校验不弹窗：$key');
        return Future<bool>.value(false);
      }
      _cooldown.remove(key);
    }

    // 5) 已经有会话：重试本身就会带上它（宿主网络层每次请求现取，见
    //    source_registry 的 sessionCookies），这时再弹窗只是打扰。会话万一已经
    //    过期，页面上还有【网页视图】那条手动出口。
    if (WafSessions.countFor(section, sourceId) > 0) {
      LumeLog.info('[waf] 该源已有会话，重试会带上它，不弹自动验证窗：$key');
      return Future<bool>.value(false);
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
    return future.whenComplete(() => _running.remove(key)).then((passed) {
      // 用户显式发起的这一次没拿到会话（窗被关掉 / 过完还是没 Cookie）：压一段
      // 冷却，免得反复点【重试】就反复弹同一个窗（与手动关掉那条同一口径）。
      if (!passed) _cooldown[key] = DateTime.now();
      return passed;
    });
  }

  /// 仅测试用：清掉钩子、在飞记录、手动窗状态、许可与冷却。
  static void resetForTesting() {
    _handler = null;
    _running.clear();
    _manualOpen = false;
    _armed.clear();
    _cooldown.clear();
  }
}
