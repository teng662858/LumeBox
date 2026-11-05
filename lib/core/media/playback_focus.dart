import 'package:flutter/services.dart';

/// Sound sources yield before another one starts. This has no UI dependency.
class PlaybackFocus {
  static final Map<String, Future<void> Function()> _release = {};
  static Future<void>? _pending;
  static String? _owner;
  static String? get owner => _owner;
  static final _playing = <String>{};
  static bool get isPlaying => _playing.contains(_owner);
  static void setPlaying(String name, bool value) {
    if (value) {
      _playing.add(name);
    } else {
      _playing.remove(name);
    }
  }

  static void register(String name, Future<void> Function() release) =>
      _release[name] = release;
  static void unregister(String name, Future<void> Function() release) {
    if (_release[name] == release) _release.remove(name);
  }

  static Future<void> acquire(String name) {
    final next = (_pending ?? Future<void>.value()).then((_) async {
      if (_owner == name) return;
      for (final entry in [..._release.entries]) {
        if (entry.key != name && entry.key == _owner) await entry.value();
      }
      try {
        await const MethodChannel('lumebox/mediaTracks')
            .invokeMethod<void>('owner', name);
      } on MissingPluginException {
        /* Platform skeletons have no native owner. */
      }
      _owner = name;
    });
    final settled = next.catchError((_) {});
    _pending = settled;
    settled.whenComplete(() {
      if (identical(_pending, settled)) _pending = null;
    });
    return next;
  }
}
