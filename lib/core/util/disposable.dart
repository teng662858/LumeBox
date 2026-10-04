import 'lume_log.dart';

typedef DisposeCallback = void Function();

/// 统一资源释放，避免泄漏。按注册顺序逆序释放，重复释放安全。
class Disposable {
  final List<DisposeCallback> _callbacks = [];
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void add(DisposeCallback callback) {
    if (_disposed) {
      _run(callback);
      return;
    }
    _callbacks.add(callback);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final callback in _callbacks.reversed) {
      _run(callback);
    }
    _callbacks.clear();
  }

  static void _run(DisposeCallback callback) {
    try {
      callback();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }
}
