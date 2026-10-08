import '../util/lume_log.dart';

/// 「每个图源最近请求过的地址」——网页视图的地址兜底来源。
///
/// **为什么需要它**：脚本抛 `NEED_WEBVIEW_VERIFY` 时，App 要拿站点 origin 去弹
/// 验证窗。地址有两个来源：脚本把 URL 写进报错文案（新脚本有，**老脚本没有**）、
/// 或者图源的订阅地址（粘贴导入的源没有）。两个都没有时，按钮点了只能给一句
/// 「拿不到源站地址」——用户看到的就是「点了没反应」（真机反馈过两轮）。
///
/// 但有一件事是确定的：**能报 WAF 错误，就说明刚发过一次请求**。网络层每次请求
/// 都记一条（按图源 id），弹窗时取最近的那条即可——与脚本怎么写、怎么导入的都无关。
///
/// 只存最近一条、只在内存里（不落盘）：它是「这一次失败」的上下文，不是配置。
class SourceRequestLog {
  SourceRequestLog._();

  /// 图源 id → 最近一次请求的完整地址。
  static final Map<String, String> _last = <String, String>{};

  /// 记录一次请求（由 [LumeHttp] 在发请求前调用）。
  static void record(String sourceId, String url) {
    final id = sourceId.trim();
    final text = url.trim();
    if (id.isEmpty || text.isEmpty) return;
    // 只记 http(s)：本地 file / data 之类的地址对网页视图没意义。
    if (!text.startsWith('http://') && !text.startsWith('https://')) return;
    _last[id] = text;
  }

  /// 取某图源最近请求过的地址；没有则 null。
  ///
  /// [quiet] 不写日志：界面为了显示「将打开哪个站」这类提示文案会在 build 里
  /// 问一次，那种查询刷日志没有意义（真正的兜底发生在用户点击时）。
  static String? lastFor(String sourceId, {bool quiet = false}) {
    final value = _last[sourceId.trim()];
    if (value == null) return null;
    if (!quiet) LumeLog.info('[waf] 用最近请求过的地址兜底：$value');
    return value;
  }

  /// 仅测试用：清空记录。
  static void resetForTesting() => _last.clear();
}
