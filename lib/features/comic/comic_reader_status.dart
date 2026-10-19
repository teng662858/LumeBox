import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'comic_reader_glyphs.dart';

/// Reader-owned status capsules. The existing iOS channel supplies real battery
/// levels; unsupported devices show an unknown value rather than a fake level.
class ComicReaderStatus extends StatefulWidget {
  const ComicReaderStatus({super.key, this.now = DateTime.now});
  final DateTime Function() now;

  @override
  State<ComicReaderStatus> createState() => _ComicReaderStatusState();
}

class _ComicReaderStatusState extends State<ComicReaderStatus>
    with WidgetsBindingObserver {
  static const _battery = MethodChannel('lumebox/battery');
  late DateTime _now = widget.now();
  int? _level;
  Timer? _timer;
  Timer? _requestTimeout;
  Completer<int?>? _request;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _update());
  }

  Future<void> _update() async {
    final generation = ++_generation;
    setState(() => _now = widget.now());
    _cancelRequest();
    final request = _request = Completer<int?>();
    void complete(int? value) {
      if (!request.isCompleted) request.complete(value);
    }

    _requestTimeout = Timer(const Duration(seconds: 3), () => complete(null));
    unawaited(
      _battery
          .invokeMethod<int>('level')
          .then(complete, onError: (Object _) => complete(null)),
    );
    final level = await request.future;
    if (!mounted || generation != _generation) return;
    _cancelRequest();
    setState(
      () => _level = level != null && level >= 0 && level <= 100 ? level : null,
    );
  }

  void _cancelRequest() {
    _requestTimeout?.cancel();
    final request = _request;
    _request = null;
    if (request != null && !request.isCompleted) request.complete(null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _generation++;
      _timer?.cancel();
      _cancelRequest();
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _cancelRequest();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _capsule(Widget child, String label, Key key) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .76),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x22000000), width: .6),
          boxShadow: const [
            BoxShadow(color: Color(0x08000000), blurRadius: 12),
          ],
        ),
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(_now),
      alwaysUse24HourFormat: true,
    );
    final battery = _level == null ? '—' : '$_level%';
    return IgnorePointer(
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          color: Color(0xFF16171B),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _capsule(Text(time), '当前时间 $time', const Key('comic.status.time')),
            _capsule(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(battery),
                  const SizedBox(width: 4),
                  LumeIcon(
                    _level == null
                        ? Icons.battery_unknown_outlined
                        : _level! <= 20
                        ? Icons.battery_alert_outlined
                        : Icons.battery_full,
                    slot: 'comic_reader_status.1',
                    variant: true,
                    size: 22,
                    fallback: ComicReaderBatteryGlyph(
                      key: const Key('comic.status.batteryGlyph'),
                      level: _level,
                      color: _level != null && _level! <= 20
                          ? const Color(0xFFD82D47)
                          : const Color(0xFF16171B),
                    ),
                    color: _level != null && _level! <= 20
                        ? const Color(0xFFD82D47)
                        : const Color(0xFF16171B),
                  ),
                ],
              ),
              _level == null ? '电量暂不可用' : '剩余电量 $battery',
              const Key('comic.status.battery'),
            ),
          ],
        ),
      ),
    );
  }
}
