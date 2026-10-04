import 'lume_log.dart';

/// 捕获异步异常，避免未处理异常导致闪退。失败返回 null。
Future<T?> guard<T>(Future<T> Function() run) async {
  try {
    return await run();
  } catch (error, stackTrace) {
    LumeLog.error(error, stackTrace);
    return null;
  }
}

/// 捕获同步异常，失败返回 null。
T? guardSync<T>(T Function() run) {
  try {
    return run();
  } catch (error, stackTrace) {
    LumeLog.error(error, stackTrace);
    return null;
  }
}
