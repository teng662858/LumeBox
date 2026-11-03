import 'package:flutter/foundation.dart';

import '../util/sensitive_data.dart';

class WaitingNetworkRequest {
  WaitingNetworkRequest({
    required this.label,
    required this.host,
    required this.method,
    required this.cancel,
  });
  final String label, host, method;
  final VoidCallback cancel;
  DateTime? waitingSince;
}

class NetworkActivity {
  static final waiting = ValueNotifier<Set<String>>(const {});
  static final _requests = <String, WaitingNetworkRequest>{};
  static WaitingNetworkRequest? request(String id) => _requests[id];
  static String displayLabel(String label) {
    final safe = SensitiveData.redact(label).replaceAllMapped(
      RegExp(r'https?://\S+'),
      (m) => Uri.tryParse(m[0]!)?.host ?? '[地址]',
    );
    return safe.length > 120 ? '${safe.substring(0, 120)}…' : safe;
  }

  static void register(String id, WaitingNetworkRequest request) =>
      _requests[id] = request;
  static void finish(String id) {
    setWaiting(id, false);
    _requests.remove(id);
  }

  static void cancel(String id) {
    _requests[id]?.cancel();
    setWaiting(id, false);
  }

  static void setWaiting(String id, bool value) {
    final request = _requests[id];
    if (request != null) {
      request.waitingSince = value
          ? (request.waitingSince ?? DateTime.now())
          : null;
    }
    final next = Set<String>.of(waiting.value);
    if (value ? next.add(id) : next.remove(id)) {
      waiting.value = Set.unmodifiable(next);
    }
  }
}
