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

  /// 脚本报错：脚本 bug、执行超时、返回格式不符契约。
  scriptError('scriptError', '源脚本报错'),

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
    SourceErrorKind.callFailed => SourceStateKind.scriptError,
  };
}
