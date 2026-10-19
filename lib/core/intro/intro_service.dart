import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dart:math' as math;

import 'intro_backend.dart';
import 'intro_detectors.dart';
import 'intro_models.dart';
import 'intro_signals.dart';
import 'intro_store.dart';
import 'community_sources.dart';
import 'mkv_metadata.dart';

class IntroRequest {
  const IntroRequest({
    required this.episode,
    required this.uri,
    required this.durationMs,
    this.headers = const {},
    this.metadata = const {},
    this.playbackMetadata,
  });
  final EpisodeIdentity episode;
  final Uri uri;
  final int durationMs;
  final Map<String, String> headers;
  final Map<String, Object?> metadata;
  final Future<Map<String, Object?>> Function()? playbackMetadata;
}

class IntroRecognitionService {
  IntroRecognitionService({
    required this.store,
    required this.backend,
    CommunitySegments? community,
  }) : community = community ?? CommunitySegments();
  final IntroStore store;
  final IntroScanBackend backend;
  final CommunitySegments community;
  final Map<String, List<SkipSegment>> _networkCache = {};
  bool deferred = false;
  Future<void> close() async {
    community.close();
    await backend.close();
  }

  Future<List<SkipSegment>> recognize(
    IntroRequest request,
    IntroCancellation token, {
    required bool allowHeavy,
    List<SkipSegment>? confirmedSegments,
    void Function(String)? onStatus,
  }) async {
    final options = store.value;
    if (!options.active || request.durationMs <= 0) return [];
    List<IntroSample>? samples;
    List<Map<String, Object?>>? frames;
    final heavyWatch = Stopwatch();
    Future<void> checkResources() async {
      final gate = await backend.resources();
      token.check();
      if (gate['allowed'] != true) {
        deferred = true;
        throw StateError('预扫描暂缓：${gate['reason'] ?? "设备资源不足"}');
      }
      if (options.wifiOnly &&
          request.uri.scheme != 'file' &&
          gate['wifi'] != true) {
        deferred = true;
        throw StateError('预扫描等待 Wi-Fi');
      }
      if (options.chargingOnly && gate['charging'] != true) {
        deferred = true;
        throw StateError('预扫描等待充电');
      }
    }

    Future<List<IntroSample>> scan() async {
      if (samples != null) return samples!;
      await checkResources();
      heavyWatch.start();
      final result = <IntroSample>[];
      final positions = scanPositions(request.durationMs, options);
      for (final at in positions) {
        token.check();
        final scanBudget =
            options.enabled('videoAI') || options.enabled('audioAI')
            ? options.scanSeconds * .6
            : options.scanSeconds;
        if (heavyWatch.elapsed.inSeconds >= scanBudget) break;
        await checkResources();
        onStatus?.call('空闲预扫描 ${result.length + 1}/${positions.length}');
        final sample = await backend.sample(
          request.uri,
          request.headers,
          at,
          options,
          token,
        );
        if (sample != null) result.add(sample);
        if (sample != null && sample.warnings.isNotEmpty) {
          store.record(
            RecognitionRecord(
              request.episode.key,
              RecognitionStage.heuristic,
              'sample-warning',
              heavyWatch.elapsedMilliseconds,
              [],
              detail: '${sample.atMs}ms ${sample.warnings}',
            ),
          );
        }
        token.check();
        // Serial native decode + a duty-cycle gap, no parallel decoders.
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
      result.sort((a, b) => a.atMs.compareTo(b.atMs));
      samples = result;
      return result;
    }

    Future<List<Map<String, Object?>>> fingerprints() async {
      if (frames != null) return frames!;
      final data = await scan();
      token.check();
      final computed = await compute(_fingerprintBatch, (data, options.values));
      frames = computed;
      return computed;
    }

    Future<void> learn(List<SkipSegment> segments) async {
      if (segments.isEmpty ||
          !allowHeavy ||
          !(options.enabled('phash') ||
              options.enabled('dhash') ||
              options.enabled('mfcc') ||
              options.enabled('joint'))) {
        return;
      }
      try {
        final data = await fingerprints();
        token.check();
        store.saveFingerprint(request.episode, request.durationMs, {
          'frames': data,
          'segments': segments.map((s) => s.toJson()).toList(),
        });
      } on IntroCancelled {
        rethrow;
      } catch (error) {
        store.record(
          RecognitionRecord(
            request.episode.key,
            RecognitionStage.fingerprint,
            'teaching-error',
            heavyWatch.elapsedMilliseconds,
            [],
            detail: _safeError(error),
          ),
        );
      }
    }

    if (confirmedSegments != null && confirmedSegments.isNotEmpty) {
      token.check();
      await learn(confirmedSegments);
      return confirmedSegments;
    }

    for (final stage in options.order) {
      token.check();
      onStatus?.call('识别：${stage.label}');
      final timer = Stopwatch()..start();
      try {
        List<SkipSegment> result = [];
        final cached = store
            .readSegments(request.episode, request.durationMs)
            .where(
              (segment) => switch (stage) {
                RecognitionStage.community =>
                  ['theIntroDB', 'introDB'].contains(segment.source) &&
                      options.enabled(segment.source),
                RecognitionStage.metadata =>
                  [
                        'chapters',
                        'mkvTags',
                        'subtitles',
                        'filename',
                      ].contains(segment.source) &&
                      options.enabled(segment.source),
                RecognitionStage.fingerprint => segment.source.startsWith(
                  'fingerprint',
                ),
                RecognitionStage.heuristic => segment.source.startsWith(
                  'heuristic',
                ),
                RecognitionStage.ai => segment.source.startsWith('ai'),
                RecognitionStage.manual => false,
              },
            )
            .toList();
        if (cached.isNotEmpty) {
          store.record(
            RecognitionRecord(
              request.episode.key,
              stage,
              'cache-hit',
              timer.elapsedMilliseconds,
              cached,
            ),
          );
          if (stage == RecognitionStage.community ||
              stage == RecognitionStage.metadata) {
            await learn(cached);
          }
          return cached;
        }
        switch (stage) {
          case RecognitionStage.community:
            for (final provider in ['theIntroDB', 'introDB']) {
              if (!options.enabled(provider)) continue;
              if ((provider == 'theIntroDB' && request.episode.tmdb == null) ||
                  (provider == 'introDB' && request.episode.imdb == null)) {
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'identity-missing',
                    0,
                    [],
                    detail: provider,
                  ),
                );
                continue;
              }
              final key =
                  '$provider:${request.episode.key}:${request.durationMs}';
              try {
                final data = _networkCache[key] ??= await community.lookup(
                  provider,
                  request.episode,
                  request.durationMs,
                  token,
                );
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'provider-result',
                    timer.elapsedMilliseconds,
                    data,
                    detail: provider,
                  ),
                );
                result = data
                    .where((s) => s.confidence >= options.threshold)
                    .toList();
                if (result.isNotEmpty) break;
              } on IntroCancelled {
                rethrow;
              } catch (error) {
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'provider-error',
                    timer.elapsedMilliseconds,
                    [],
                    detail: '$provider: ${_safeError(error)}',
                  ),
                );
              }
            }
          case RecognitionStage.manual:
            if (options.enabled('manual')) {
              result = store.manual(request.episode, request.durationMs);
              if (result.isEmpty) {
                result = store.seriesMemory(
                  request.episode,
                  request.durationMs,
                );
              }
              if (result.isEmpty) {
                result = store.manual(
                  request.episode,
                  request.durationMs,
                  reuseSeason: options.enabled('reuseManualSeason'),
                );
              }
            }
          case RecognitionStage.metadata:
            if (![
              'chapters',
              'mkvTags',
              'subtitles',
              'filename',
            ].any(options.enabled)) {
              continue;
            }
            final metadata = <String, Object?>{...request.metadata};
            if (request.playbackMetadata != null) {
              try {
                metadata.addAll(await request.playbackMetadata!());
              } catch (_) {
                /* native asset/EBML remain available */
              }
            }
            try {
              final native = await backend.metadata(
                request.uri,
                request.headers,
              );
              for (final entry in native.entries) {
                if (entry.value is List && (entry.value as List).isNotEmpty) {
                  metadata[entry.key] = entry.value;
                }
              }
            } catch (error) {
              store.record(
                RecognitionRecord(
                  request.episode.key,
                  stage,
                  'native-unavailable',
                  timer.elapsedMilliseconds,
                  [],
                  detail: _safeError(error),
                ),
              );
            }
            if (request.uri.path.toLowerCase().endsWith('.mkv') &&
                (options.enabled('chapters') || options.enabled('mkvTags'))) {
              try {
                final embedded = await MkvMetadataProbe().inspect(
                  request.uri,
                  request.headers,
                  token,
                );
                for (final entry in embedded.entries) {
                  if (entry.value is List && (entry.value as List).isNotEmpty) {
                    metadata[entry.key] = entry.value;
                  }
                }
              } on IntroCancelled {
                rethrow;
              } catch (error) {
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'mkv-unavailable',
                    timer.elapsedMilliseconds,
                    [],
                    detail: _safeError(error),
                  ),
                );
              }
            }
            metadata['filename'] = MetadataSegments.timedFilename(
              request.uri.pathSegments.lastOrNull ?? '',
            );
            if (options.enabled('filename')) {
              final hint = MetadataSegments.kind(
                request.uri.pathSegments.lastOrNull ?? '',
              );
              if (hint != null) {
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'filename-hint',
                    timer.elapsedMilliseconds,
                    [],
                    detail: '${hint.name}: no invented timestamp',
                  ),
                );
              }
            }
            result = MetadataSegments.detect(
              metadata,
              request.durationMs,
              options,
            );
          case RecognitionStage.fingerprint:
            if (!allowHeavy) {
              store.record(
                RecognitionRecord(
                  request.episode.key,
                  stage,
                  'deferred-idle',
                  timer.elapsedMilliseconds,
                  [],
                ),
              );
              continue;
            }
            if (options.enabled('phash') ||
                options.enabled('dhash') ||
                options.enabled('mfcc') ||
                options.enabled('joint')) {
              final histories = store.fingerprints(request.episode);
              if (histories.isNotEmpty) {
                final data = await fingerprints();
                result = await compute(_matchFingerprintBatch, (
                  data,
                  histories,
                  request.durationMs,
                  options.values,
                ));
              }
            }
          case RecognitionStage.heuristic:
            if (!allowHeavy) {
              store.record(
                RecognitionRecord(
                  request.episode.key,
                  stage,
                  'deferred-idle',
                  timer.elapsedMilliseconds,
                  [],
                ),
              );
              continue;
            }
            if (['black', 'silence', 'sceneCuts', 'ocr'].any(options.enabled)) {
              final data = await scan();
              result = await compute(_heuristicBatch, (
                data,
                request.durationMs,
                options.values,
              ));
            }
          case RecognitionStage.ai:
            if (!allowHeavy) {
              store.record(
                RecognitionRecord(
                  request.episode.key,
                  stage,
                  'deferred-idle',
                  timer.elapsedMilliseconds,
                  [],
                ),
              );
              continue;
            }
            if (options.enabled('videoAI') || options.enabled('audioAI')) {
              final classified = <IntroSample>[];
              final data = await scan();
              heavyWatch.start();
              for (final sample in data) {
                token.check();
                if (heavyWatch.elapsed.inSeconds > options.scanSeconds) break;
                await checkResources();
                onStatus?.call('本地 AI ${classified.length + 1}/${data.length}');
                classified.add(await backend.infer(sample, options));
                store.record(
                  RecognitionRecord(
                    request.episode.key,
                    stage,
                    'window-scores',
                    heavyWatch.elapsedMilliseconds,
                    [],
                    detail:
                        '${sample.atMs}ms ${classified.last.ai} ${classified.last.warnings}',
                  ),
                );
                token.check();
                await Future<void>.delayed(const Duration(milliseconds: 250));
              }
              result = AiSegments.classify(
                classified,
                request.durationMs,
                options,
              );
            }
        }
        token.check();
        final candidates = result
            .where((s) => s.validFor(request.durationMs))
            .toList();
        result = candidates
            .where((s) => s.confidence >= options.threshold)
            .toList();
        store.record(
          RecognitionRecord(
            request.episode.key,
            stage,
            result.isEmpty
                ? (candidates.isEmpty ? 'no-match' : 'below-threshold')
                : 'matched',
            timer.elapsedMilliseconds,
            candidates,
          ),
        );
        if (result.isNotEmpty) {
          // Keep per-method proposals in logs, but seek only one overlapping
          // interval. A joint match has stronger evidence than a single stream.
          result.sort((a, b) {
            final joint = (b.source == 'fingerprint.joint' ? 1 : 0).compareTo(
              a.source == 'fingerprint.joint' ? 1 : 0,
            );
            return joint != 0 ? joint : b.confidence.compareTo(a.confidence);
          });
          final chosen = <SkipSegment>[];
          for (final segment in result) {
            if (!chosen.any(
              (other) =>
                  other.kind == segment.kind &&
                  segment.startMs < other.endMs &&
                  other.startMs < segment.endMs,
            )) {
              chosen.add(segment);
            }
          }
          result = chosen..sort((a, b) => a.startMs.compareTo(b.startMs));
          if (stage != RecognitionStage.manual) {
            store.saveSegments(request.episode, request.durationMs, result);
          }
          // Learning copies trusted timestamps; it does not run lower-priority detectors.
          if (stage == RecognitionStage.community ||
              stage == RecognitionStage.manual ||
              stage == RecognitionStage.metadata) {
            await learn(result);
          }
          return result;
        }
      } on IntroCancelled {
        rethrow;
      } catch (error) {
        store.record(
          RecognitionRecord(
            request.episode.key,
            stage,
            'error',
            timer.elapsedMilliseconds,
            [],
            detail: _safeError(error),
          ),
        );
      }
    }
    return [];
  }

  static String _safeError(Object error) => error
      .toString()
      .replaceAll(RegExp(r'https?://[^\s)]+'), '[media URL omitted]')
      .replaceAll(
        RegExp(
          r'(authorization|cookie|token|secret)[=:][^\s,]+',
          caseSensitive: false,
        ),
        '[credential omitted]',
      )
      .substring(
        0,
        math.min(
          400,
          error
              .toString()
              .replaceAll(RegExp(r'https?://[^\s)]+'), '[media URL omitted]')
              .replaceAll(
                RegExp(
                  r'(authorization|cookie|token|secret)[=:][^\s,]+',
                  caseSensitive: false,
                ),
                '[credential omitted]',
              )
              .length,
        ),
      );
  static List<int> scanPositions(int duration, IntroOptions options) {
    final edge = math.min(240000, duration ~/ 3);
    final step = options.sampleEverySeconds * 1000;
    final starts = <int>[], ends = <int>[];
    for (var at = 0; at < edge; at += step) {
      starts.add(at);
    }
    for (
      var at = math.max(edge, duration - edge);
      at < duration - 1000;
      at += step
    ) {
      ends.add(at);
    }
    // Cover both edges before refining either; a wall-time limit cannot starve ED.
    final selected = <int>[];
    final stride = math.max(
      1,
      ((starts.length + ends.length) / options.maxSamples).ceil(),
    );
    for (var i = 0; i < math.max(starts.length, ends.length); i += stride) {
      if (i < starts.length) selected.add(starts[i]);
      if (i < ends.length) selected.add(ends[i]);
    }
    return selected.take(options.maxSamples).toList();
  }
}

// Top-level entry points prevent closures from retaining the SQLite store,
// HTTP client or native method channel in isolate messages.
List<Map<String, Object?>> _fingerprintBatch(
  (List<IntroSample>, Map<String, Object?>) data,
) => data.$1
    .map((sample) => IntroSignals.fingerprint(sample, IntroOptions(data.$2)))
    .toList();
List<SkipSegment> _matchFingerprintBatch(
  (
    List<Map<String, Object?>>,
    List<Map<String, Object?>>,
    int,
    Map<String, Object?>,
  )
  data,
) =>
    FingerprintSegments.match(data.$1, data.$2, data.$3, IntroOptions(data.$4));
List<SkipSegment> _heuristicBatch(
  (List<IntroSample>, int, Map<String, Object?>) data,
) => HeuristicSegments.detect(data.$1, data.$2, IntroOptions(data.$3));
