import '../net/waf.dart';
import '../net/secure_connection_failure.dart';
import 'data_source.dart';

/// 页面状态分类：业务页、浏览面、详情页与管理页共用同一套状态。
///
/// 这里只做「异常 → 状态」的归一，不持有任何状态、不认识沙箱与数据库，
/// 也不涉及任何板块差异。展示层拿到分类后只负责选视图，不再自行判断原因。
enum SourceStateKind {
  /// 加载中。
  loading('loading', '正在加载…'),

  /// 空数据：板块内没有图源，或图源没有给出内容。
  empty('empty', '暂无内容'),

  /// 图源禁用：图源不存在、已停用，或其运行时已经释放。
  disabled('disabled', '源已停用'),

  /// 脚本报错：脚本 bug、返回格式不符契约。
  scriptError('scriptError', '源脚本报错'),

  /// 脚本**没有实现**这个入口（例如只有 getList 没有 getContent）。
  ///
  /// 与「脚本报错」分开：这不是坏掉，是这个源不支持该功能——给用户的下一步
  /// 是「换个源」，而不是「去修脚本」。
  missingEntry('missingEntry', '这个源没有提供该功能'),

  /// 调用超时：脚本在预算内没跑完（多半是站点慢或网络差）。
  ///
  /// 与「脚本报错」分开：这时脚本本身没写错，用户的下一步是重试 / 放宽沙箱
  /// 超时（设置 → 沙箱设置），而不是换源。
  timeout('timeout', '请求超时'),

  /// 网络异常：图源的 HTTP 请求没能完成。
  networkError('networkError', '网络异常'),

  /// A DNS lookup failed; this alone does not prove the domain has expired.
  addressUnavailable('addressUnavailable', '站点地址无法解析'),

  verificationRequired('verificationRequired', '站点需要网页验证'),

  /// Parsing failed, without evidence that the request was a WAF challenge.
  pageUnrecognized('pageUnrecognized', '页面内容未能识别'),

  /// 就绪：可以正常展示内容。
  ready('ready', '');

  const SourceStateKind(this.id, this.label);

  /// 稳定标识，用于日志与测试断言。
  final String id;

  /// 中文短标签：加载态直接用它做文案，其余状态作为提示标题的默认值。
  final String label;

  String? get recoveryHint => switch (this) {
    addressUnavailable => '请检查网络和源设置中的站点地址，地址可能已变更。',
    verificationRequired => '站点返回了网页验证提示，完成验证后再重试。',
    pageUnrecognized => '可能是页面结构变化或返回了非预期内容，请更新源后重试。',
    timeout => '请求未在时限内完成，请稍后重试或检查网络。',
    networkError => '请求未能正常完成，请检查网络或站点服务后重试。',
    missingEntry => '该源未提供此入口，请使用它支持的浏览方式。',
    _ => null,
  };
}

/// 把异常归一成页面状态。
///
/// - `notFound` / `unsupported` → 图源禁用（图源用不了；平台无运行时的情形
///   在进入页面时就被骨架拦下，正常不会走到这里）；
/// - `network` → 网络异常，明确的 DNS / 验证提示继续细分；
/// - 其余调用失败按原始原因细分；没有可靠特征时按脚本报错兜底。
SourceStateKind stateForError(Object error) {
  if (error is! SourceException) return classifyCallFailure('$error');
  return switch (error.kind) {
    SourceErrorKind.notFound => SourceStateKind.disabled,
    SourceErrorKind.unsupported => SourceStateKind.disabled,
    SourceErrorKind.network => switch (classifyCallFailure(error.message)) {
      SourceStateKind.addressUnavailable => SourceStateKind.addressUnavailable,
      SourceStateKind.verificationRequired =>
        SourceStateKind.verificationRequired,
      _ => SourceStateKind.networkError,
    },
    SourceErrorKind.callFailed => classifyCallFailure(error.message),
  };
}

/// 调用失败再细分（真机反馈：三种情况原先都归到「源脚本报错」一个标题下，
/// 分不清该换源、该重试、还是该改脚本）。
///
/// 判据是沙箱给出的**原文**：
/// - 「源脚本没有实现 xxx 方法…」来自桥接层的派发器（脚本没写这个入口）；
/// - 「…超时…」来自预算判定（超时 / 调用超时 / 执行超时）；
/// - 网页验证、DNS、页面解析及 HTTP / 连接失败按明确特征细分；
/// - 无法识别的失败仍归脚本报错，不猜测站点已失效。
///
/// 为什么按文本而不是加一个错误码：这些文案由**沙箱内的 JS**产出，跨 FFI 回来
/// 只剩字符串；为它单开一条错误码通道要动桥接协议，收益不值这个风险。文案本身
/// 是稳定契约（有成套测试盯着），因此这里按文本判定是安全的。
SourceStateKind classifyCallFailure(String message) {
  if (message.contains('没有实现')) return SourceStateKind.missingEntry;
  // Explicit script bugs must not be disguised as connectivity or parser errors.
  if (RegExp(
    r'\b(?:TypeError|ReferenceError|SyntaxError)\b',
    caseSensitive: false,
  ).hasMatch(message)) {
    return SourceStateKind.scriptError;
  }
  if (wafKindOf(message) == WafFailureKind.webView) {
    return SourceStateKind.verificationRequired;
  }
  if (secureConnectionFailureOf(message) != null) {
    return SourceStateKind.networkError;
  }
  if (RegExp(
    r'ENOTFOUND|EAI_AGAIN|Failed host lookup|无法解析(?:主机|域名)|域名解析失败|DNS(?: lookup| resolution)? failed',
    caseSensitive: false,
  ).hasMatch(message)) {
    return SourceStateKind.addressUnavailable;
  }
  if (message.contains('超时') || message.toLowerCase().contains('timeout')) {
    return SourceStateKind.timeout;
  }
  if (RegExp(r'没有解析到|未解析到|没解析出|未能解析|页面结构.{0,8}(?:变化|改变)|站点改版')
      .hasMatch(message)) {
    return SourceStateKind.pageUnrecognized;
  }
  if (RegExp(
    r'网络请求失败|ECONNREFUSED|ECONNRESET|SocketException|Connection refused|HTTP[ /]?(?:403|404|410|429|5\d\d)(?!\d)',
    caseSensitive: false,
  ).hasMatch(message)) {
    return SourceStateKind.networkError;
  }
  return SourceStateKind.scriptError;
}
