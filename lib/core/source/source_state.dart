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

  /// 就绪：可以正常展示内容。
  ready('ready', '');

  const SourceStateKind(this.id, this.label);

  /// 稳定标识，用于日志与测试断言。
  final String id;

  /// 中文短标签：加载态直接用它做文案，其余状态作为提示标题的默认值。
  final String label;
}

/// 把异常归一成页面状态。
///
/// - `notFound` / `unsupported` → 图源禁用（图源用不了；平台无运行时的情形
///   在进入页面时就被骨架拦下，正常不会走到这里）；
/// - `network` → 网络异常；
/// - `callFailed` 与其余异常 → 脚本报错（无非 `SourceException` 的偶发错误，
///   也按脚本报错兜底）。
SourceStateKind stateForError(Object error) {
  if (error is! SourceException) return SourceStateKind.scriptError;
  return switch (error.kind) {
    SourceErrorKind.notFound => SourceStateKind.disabled,
    SourceErrorKind.unsupported => SourceStateKind.disabled,
    SourceErrorKind.network => SourceStateKind.networkError,
    SourceErrorKind.callFailed => classifyCallFailure(error.message),
  };
}

/// 调用失败再细分（真机反馈：三种情况原先都归到「源脚本报错」一个标题下，
/// 分不清该换源、该重试、还是该改脚本）。
///
/// 判据是沙箱给出的**原文**：
/// - 「源脚本没有实现 xxx 方法…」来自桥接层的派发器（脚本没写这个入口）；
/// - 「…超时…」来自预算判定（超时 / 调用超时 / 执行超时）；
/// - 其余仍归脚本报错。
///
/// 为什么按文本而不是加一个错误码：这些文案由**沙箱内的 JS**产出，跨 FFI 回来
/// 只剩字符串；为它单开一条错误码通道要动桥接协议，收益不值这个风险。文案本身
/// 是稳定契约（有成套测试盯着），因此这里按文本判定是安全的。
SourceStateKind classifyCallFailure(String message) {
  if (message.contains('没有实现')) return SourceStateKind.missingEntry;
  if (message.contains('超时') || message.toLowerCase().contains('timeout')) {
    return SourceStateKind.timeout;
  }
  return SourceStateKind.scriptError;
}
