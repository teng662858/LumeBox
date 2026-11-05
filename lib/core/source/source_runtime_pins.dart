import '../session/section.dart';

/// Media can keep using a script-owned proxy after the source call returns.
class SourceRuntimePins {
  SourceRuntimePins._();
  static final _counts = <(Section, String), int>{};
  static bool contains(Section section, String id) =>
      (_counts[(section, id)] ?? 0) > 0;
  static void Function() retain(Section section, String id) {
    final key = (section, id);
    _counts[key] = (_counts[key] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = _counts[key] ?? 0;
      if (count <= 1) {
        _counts.remove(key);
      } else {
        _counts[key] = count - 1;
      }
    };
  }
}
