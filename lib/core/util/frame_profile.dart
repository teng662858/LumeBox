import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

class FrameProfile {
  static final instance = FrameProfile();
  final _build = <double>[], _raster = <double>[];
  String scene = '';
  final marks = <String, int>{};
  void mark(String name) {
    final begin = started;
    if (begin != null) {
      marks[name] = DateTime.now().difference(begin).inMilliseconds;
    }
  }

  DateTime? started;
  double budgetMs = 1000 / 60;
  int slow = 0, droppedSamples = 0;
  int? _memoryStart;
  int? _rss() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? lastReport;
  bool get recording => started != null;
  void start(String scene, {double refreshRate = 60}) {
    if (recording) SchedulerBinding.instance.removeTimingsCallback(_timings);
    this.scene = scene;
    budgetMs = 1000 / (refreshRate > 0 ? refreshRate : 60);
    marks.clear();
    _build.clear();
    _raster.clear();
    slow = 0;
    droppedSamples = 0;
    _memoryStart = _rss();
    started = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }

  void _timings(List<FrameTiming> timings) {
    for (final frame in timings) {
      add(
        frame.buildDuration.inMicroseconds / 1000,
        frame.rasterDuration.inMicroseconds / 1000,
      );
    }
  }

  void add(double build, double raster) {
    if (!recording) return;
    if (_build.length >= 20000) {
      droppedSamples++;
      return;
    }
    _build.add(build);
    _raster.add(raster);
    if (build > budgetMs || raster > budgetMs) slow++;
  }

  Map<String, Object?> stop() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    final begin = started;
    started = null;
    double percentile(List<double> values, double p) {
      final sorted = [...values]..sort();
      return sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];
    }

    return lastReport = {
      'scene': scene,
      'elapsedMs': begin == null
          ? 0
          : DateTime.now().difference(begin).inMilliseconds,
      'marksMs': Map<String, int>.of(marks),
      'os': Platform.operatingSystem,
      'mode': const bool.fromEnvironment('dart.vm.product')
          ? 'release'
          : const bool.fromEnvironment('dart.vm.profile')
          ? 'profile'
          : 'debug',
      'started': begin?.toIso8601String(),
      'ended': DateTime.now().toIso8601String(),
      'frames': _build.length,
      'budgetMs': budgetMs,
      'slowFrames': slow,
      'slowRatio': _build.isEmpty ? 0 : slow / _build.length,
      'buildP95Ms': percentile(_build, .95),
      'rasterP95Ms': percentile(_raster, .95),
      'buildP99Ms': percentile(_build, .99),
      'rasterP99Ms': percentile(_raster, .99),
      'droppedSamples': droppedSamples,
      'processRssStartBytes': _memoryStart,
      'processRssEndBytes': _rss(),
    };
  }

  Future<void> save() async {
    if (lastReport == null) return;
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/performance_last.json');
    await file.writeAsString(jsonEncode(lastReport), flush: true);
  }

  Future<void> load() async {
    if (lastReport != null || recording) return;
    try {
      final file = File(
        '${(await getApplicationSupportDirectory()).path}/performance_last.json',
      );
      if (await file.exists() && await file.length() < 65536) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic> && value['frames'] is int) {
          lastReport = value;
        }
      }
    } catch (_) {
      /* A missing or damaged old report does not affect recording. */
    }
  }
}
