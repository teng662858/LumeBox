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
    if (_release[name] != release) return;
    _release.remove(name);
    _playing.remove(name);
  }

  static Future<void> acquire(
    String name, {
    Future<void> Function()? onRelease,
    bool Function()? stillWanted,
  }) {
    final next = (_pending ?? Future<void>.value()).then((_) async {
      if (stillWanted?.call() == false) return;
      final previous = _release[_owner];
      if (previous != null &&
          (_owner != name || (onRelease != null && previous != onRelease))) {
        await previous();
      }
      if (stillWanted?.call() == false) return;
      if (_owner != name) {
        try {
          await const MethodChannel('lumebox/mediaTracks')
              .invokeMethod<void>('owner', name);
        } on MissingPluginException {
          /* Platform skeletons have no native owner. */
        }
        _owner = name;
      }
      if (onRelease != null) register(name, onRelease);
    });
    final settled = next.catchError((_) {});
    _pending = settled;
    settled.whenComplete(() {
      if (identical(_pending, settled)) _pending = null;
    });
    return next;
  }
}
