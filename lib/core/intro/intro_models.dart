import 'dart:convert';

enum SegmentKind { recap, opening, main, ending, preview }

enum RecognitionStage {
  community,
  manual,
  metadata,
  fingerprint,
  heuristic,
  ai,
}

extension RecognitionStageLabel on RecognitionStage {
  String get label =>
      const ['联网社区库', '本地手动标记', '视频内置元数据', '音视频指纹', '启发式组合', '本地 AI'][index];
}

/// No URL is used as the series identity: signed URLs change between sessions.
class EpisodeIdentity {
  const EpisodeIdentity({
    required this.series,
    required this.episode,
    this.season = 1,
    this.tmdb,
    this.imdb,
    this.movie = false,
  });
  final String series;
  final int season, episode;
  final int? tmdb;
  final String? imdb;
  final bool movie;
  String get seasonKey => jsonEncode([series, season, movie]);
  String get key => jsonEncode([series, season, episode, movie]);
}

class SkipSegment {
  const SkipSegment({
    required this.kind,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    required this.source,
    this.evidence = '',
  });
  final SegmentKind kind;
  final int startMs, endMs;
  final double confidence;
  final String source, evidence;
  String get id => '${kind.name}:$startMs:$endMs';
  bool validFor(int durationMs) =>
      kind != SegmentKind.main &&
      startMs >= 0 &&
      endMs > startMs &&
      endMs <= durationMs &&
      confidence.isFinite &&
      confidence >= 0 &&
      confidence <= 1;
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'start': startMs,
    'end': endMs,
    'confidence': confidence,
    'source': source,
    'evidence': evidence,
  };
  static SkipSegment? parse(Object? value) {
    if (value is! Map) return null;
    try {
      return SkipSegment(
        kind: SegmentKind.values.byName(value['kind'] as String),
        startMs: (value['start'] as num).toInt(),
        endMs: (value['end'] as num).toInt(),
        confidence: (value['confidence'] as num).toDouble(),
        source: value['source'] as String,
        evidence: '${value['evidence'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

class IntroOptions {
  IntroOptions([Map<String, Object?> values = const {}])
    : values = Map.unmodifiable(values);
  final Map<String, Object?> values;
  static const switches = {
    'theIntroDB': 'TheIntroDB（TMDB）',
    'introDB': 'IntroDB（IMDb）',
    'chapters': 'Chapter 章节标记',
    'mkvTags': 'MKV 标签',
    'subtitles': '内嵌字幕关键词',
    'filename': '文件名关键词',
    'black': '黑屏与亮度淡入淡出',
    'silence': '音频静默',
    'sceneCuts': '场景切换频率',
    'ocr': 'OCR 滚动演职员文字',
    'phash': '图像 pHash',
    'dhash': '图像 dHash',
    'mfcc': '音频 MFCC',
    'joint': '音视频联合指纹',
    'repeat': '学习同季重复片段',
    'videoAI': 'MobileCLIP 视频片段分类',
    'audioAI': 'YAMNet 对白／音乐分类',
    'manual': '手动四点标记',
  };
  bool enabled(String name) =>
      values[name] is bool ? values[name] as bool : true;
  bool get active => enabled('active');
  bool get autoSkip => enabled('autoSkip');
  bool get idleOnly => enabled('idleOnly');
  bool get wifiOnly => enabled('wifiOnly');
  bool get chargingOnly => values['chargingOnly'] == true;
  bool get logs => enabled('logs');
  int number(String key, int fallback, int min, int max) {
    final raw = values[key];
    return (raw is num && raw.isFinite ? raw.toInt() : fallback).clamp(
      min,
      max,
    );
  }

  int get countdown => number('countdown', 5, 0, 5);
  int get scanSeconds => number('scanSeconds', 45, 5, 120);
  int get sampleEverySeconds => number('sampleEverySeconds', 3, 1, 10);
  int get maxSamples => number('maxSamples', 100, 10, 240);
  double get threshold {
    final raw = values['threshold'];
    return (raw is num && raw.isFinite ? raw.toDouble() : .85).clamp(.5, 1);
  }

  List<RecognitionStage> get order {
    final result = <RecognitionStage>[];
    for (final name
        in (values['order'] is List ? values['order'] as List : const [])) {
      final stage = RecognitionStage.values
          .where((s) => s.name == name)
          .firstOrNull;
      if (stage != null && !result.contains(stage)) result.add(stage);
    }
    for (final stage in RecognitionStage.values) {
      if (!result.contains(stage)) result.add(stage);
    }
    return result;
  }

  IntroOptions patch(Map<String, Object?> patch) =>
      IntroOptions({...values, ...patch});
}

class IntroCancellation {
  bool cancelled = false;
  void check() {
    if (cancelled) throw const IntroCancelled();
  }
}

class IntroCancelled implements Exception {
  const IntroCancelled();
}

class RecognitionRecord {
  RecognitionRecord(
    this.episode,
    this.stage,
    this.status,
    this.elapsedMs,
    this.segments, {
    this.detail = '',
  });
  final String episode, status, detail;
  final RecognitionStage stage;
  final int elapsedMs;
  final List<SkipSegment> segments;
  Map<String, Object?> toJson() => {
    'at': DateTime.now().toUtc().toIso8601String(),
    'episode': episode,
    'stage': stage.name,
    'status': status,
    'elapsedMs': elapsedMs,
    'detail': detail,
    'segments': segments.map((s) => s.toJson()).toList(),
  };
}
