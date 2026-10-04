import 'dart:convert';

/// 沙箱结果的失败分类。前四类会直接导致上下文被销毁重建。
enum SandboxErrorKind {
  /// 超出墙钟预算。
  timeout('timeout', '执行超时'),

  /// 超出指令计数 / 引擎步数 / 微任务轮数预算。
  instructions('instructions', '超出指令预算'),

  /// JS 堆超出内存上限。
  memory('memory', '内存超限'),

  /// 原生库或符号不可用（平台不支持）。
  unsupported('unsupported', '沙箱不可用'),

  /// 宿主代理拒绝了本次调用（含能力未开放）。
  hostDenied('hostDenied', '宿主调用被拒绝'),

  /// JS 侧与 Dart 侧的数据协议异常（结果过大、无法解析等）。
  protocol('protocol', '协议异常'),

  /// 脚本自身抛出的错误。
  script('script', '脚本错误'),

  /// 沙箱（或上下文）已经释放。
  disposed('disposed', '沙箱已释放'),

  /// 引擎级未知错误（原生返回空指针等）。
  engine('engine', '引擎错误');

  const SandboxErrorKind(this.id, this.label);

  /// 稳定标识，用于 JSON 信封与日志。
  final String id;

  /// 中文短标签，用于展示。
  final String label;

  static SandboxErrorKind fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return SandboxErrorKind.engine;
  }

  /// 是否属于「上下文可能已被污染」的错误：这些错误发生后必须销毁上下文。
  bool get poisonsContext => switch (this) {
        SandboxErrorKind.timeout => true,
        SandboxErrorKind.instructions => true,
        SandboxErrorKind.memory => true,
        SandboxErrorKind.protocol => true,
        SandboxErrorKind.engine => true,
        SandboxErrorKind.script => false,
        SandboxErrorKind.hostDenied => false,
        SandboxErrorKind.unsupported => false,
        SandboxErrorKind.disposed => false,
      };
}

/// 沙箱失败的载体。
class SandboxError {
  const SandboxError(this.kind, this.message);

  final SandboxErrorKind kind;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.id,
        'label': kind.label,
        'message': message,
      };

  static SandboxError fromJson(Object? json) {
    if (json is! Map) {
      return const SandboxError(SandboxErrorKind.engine, '未知错误');
    }
    return SandboxError(
      SandboxErrorKind.fromId('${json['kind'] ?? ''}'),
      '${json['message'] ?? ''}',
    );
  }

  @override
  String toString() => '${kind.label}: $message';
}

/// 一次求值 / 调用的结果。
///
/// 对 Dart 侧始终以 JSON 信封形式暴露（[toJson] / [fromJson]），
/// 脚本返回的任何值都先经 JS 的 `JSON.stringify` 再解码为 Dart 对象。
sealed class SandboxResult {
  const SandboxResult();

  bool get isOk;

  /// 成功时的 JSON 解码值；失败时为 null。
  Object? get value;

  /// 失败信息；成功时为 null。
  SandboxError? get error;

  Map<String, Object?> toJson() => isOk
      ? <String, Object?>{'ok': true, 'value': value}
      : <String, Object?>{'ok': false, 'error': error!.toJson()};

  String encode() => jsonEncode(toJson());

  static SandboxResult fromJson(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const SandboxFailure(
        SandboxErrorKind.protocol,
        '结果不是合法 JSON',
      );
    }
    if (decoded is! Map) {
      return const SandboxFailure(SandboxErrorKind.protocol, '结果信封格式错误');
    }
    return decoded['ok'] == true
        ? SandboxSuccess(decoded['value'])
        : SandboxFailure.fromJson(decoded['error']);
  }

  static const SandboxResult success = SandboxSuccess(null);
}

final class SandboxSuccess extends SandboxResult {
  const SandboxSuccess(this.value);

  @override
  final Object? value;

  @override
  bool get isOk => true;

  @override
  SandboxError? get error => null;

  @override
  String toString() => 'SandboxSuccess($value)';
}

final class SandboxFailure extends SandboxResult {
  const SandboxFailure(this.kind, this.message);

  SandboxFailure.fromJson(Object? json) : this._fromError(SandboxError.fromJson(json));

  SandboxFailure._fromError(SandboxError error)
      : kind = error.kind,
        message = error.message;

  final SandboxErrorKind kind;
  final String message;

  @override
  bool get isOk => false;

  @override
  Object? get value => null;

  @override
  SandboxError get error => SandboxError(kind, message);

  @override
  String toString() => 'SandboxFailure($kind: $message)';
}
