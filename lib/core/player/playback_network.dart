import 'dart:async';

import 'package:flutter/services.dart';

/// One inspection at a time; never wait for network inspection on a playback tick.
class PlaybackNetwork {
  static const _channel = MethodChannel('lumebox/experience');
  bool? wifi, cellular;
  DateTime? _checked;
  bool _busy = false;
  bool _disposed = false;
  Timer? _timeout;
  Completer<Map<String, dynamic>?>? _pending;
  bool allowsPreload(bool wifiOnly) => !wifiOnly || wifi == true;
  void refresh({bool force = false}) {
    if (_disposed ||
        _busy ||
        (!force &&
            _checked != null &&
            DateTime.now().difference(_checked!) <
                const Duration(seconds: 15))) {
      return;
    }
    _busy = true;
    _checked = DateTime.now();
    unawaited(_inspect());
  }

  Future<void> _inspect() async {
    final pending = _pending = Completer<Map<String, dynamic>?>();
    void finish(Map<String, dynamic>? facts) {
      if (!pending.isCompleted) pending.complete(facts);
    }

    _timeout = Timer(const Duration(seconds: 4), () => finish(null));
    try {
      unawaited(
        _channel
            .invokeMapMethod<String, dynamic>('networkAndStorage')
            .then(finish, onError: (Object _) => finish(null)),
      );
      final facts = await pending.future;
      if (!_disposed) {
        wifi = facts == null ? null : facts['wifi'] == true;
        cellular = facts == null ? null : facts['cellular'] == true;
      }
    } catch (_) {
      wifi = cellular = null;
    } finally {
      _timeout?.cancel();
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timeout?.cancel();
    if (_pending?.isCompleted == false) _pending!.complete(null);
  }
}
