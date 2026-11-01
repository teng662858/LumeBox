import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A deliberate short tap opens reader chrome; drags, holds and scroll stops do not.
class ReaderInteractionSurface extends StatefulWidget {
  const ReaderInteractionSurface({
    super.key,
    required this.child,
    required this.onTapUp,
    this.onCancelTap,
  });
  final Widget child;
  final GestureTapUpCallback onTapUp;
  final VoidCallback? onCancelTap;
  @override
  State<ReaderInteractionSurface> createState() =>
      _ReaderInteractionSurfaceState();
}

class _ReaderInteractionSurfaceState extends State<ReaderInteractionSurface> {
  final _pointers = <int>{};
  Offset _origin = Offset.zero;
  bool _allowed = false, _cooling = false, _dragScrolling = false;
  Timer? _hold, _cooldown;

  void _down(PointerDownEvent event) {
    widget.onCancelTap?.call();
    _pointers.add(event.pointer);
    _hold?.cancel();
    _allowed = _pointers.length == 1 && !_cooling;
    _origin = event.position;
    _hold = Timer(const Duration(milliseconds: 250), _reject);
  }

  void _reject() {
    _allowed = false;
    widget.onCancelTap?.call();
  }

  bool _scroll(ScrollNotification event) {
    if ((event is ScrollStartNotification && event.dragDetails != null) ||
        (event is ScrollUpdateNotification && event.dragDetails != null)) {
      _dragScrolling = true;
      _reject();
    }
    if (event is ScrollEndNotification && _dragScrolling) {
      _dragScrolling = false;
      _cooling = true;
      _cooldown?.cancel();
      _cooldown = Timer(
        const Duration(milliseconds: 250),
        () => _cooling = false,
      );
    }
    return false;
  }

  @override
  void dispose() {
    _hold?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }

  void _semanticTap() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final center = box.size.center(Offset.zero);
    widget.onTapUp(
      TapUpDetails(
        kind: PointerDeviceKind.touch,
        localPosition: center,
        globalPosition: box.localToGlobal(center),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scroll,
        child: Semantics(
          onTap: _semanticTap,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: (event) {
              if ((event.position - _origin).distance > 8) _reject();
            },
            onPointerUp: (event) {
              _pointers.remove(event.pointer);
              _hold?.cancel();
            },
            onPointerCancel: (event) {
              _pointers.remove(event.pointer);
              _reject();
              _hold?.cancel();
            },
            child: GestureDetector(
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) {
                if (_allowed && !_cooling) widget.onTapUp(event);
              },
              child: widget.child,
            ),
          ),
        ),
      );
}

class ReaderLongPressRegion extends StatelessWidget {
  const ReaderLongPressRegion({
    super.key,
    required this.child,
    required this.onLongPress,
    required this.duration,
  });
  final Widget child;
  final VoidCallback onLongPress;
  final Duration duration;
  @override
  Widget build(BuildContext context) => RawGestureDetector(
    key: ValueKey(duration),
    behavior: HitTestBehavior.opaque,
    gestures: {
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: duration,
              postAcceptSlopTolerance: 8,
            ),
            (recognizer) => recognizer
              ..gestureSettings = const DeviceGestureSettings(touchSlop: 8)
              ..onLongPress = onLongPress,
          ),
    },
    child: child,
  );
}
