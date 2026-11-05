import '../../core/net/network_cancellation.dart';
import 'video_episode_catalog.dart';
import '../../core/cache/media_preload.dart';

import 'dart:io' show Platform;

import '../../core/net/ios_verified_webview.dart';

import 'dart:async';

import '../../core/player/abstract_player.dart';
import '../../core/player/buffering.dart';
import '../../core/player/player_settings.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import 'source_playback.dart';
import 'playback_quality_preference.dart';
import 'video_play_target.dart';

class PreparedEpisode {
  PreparedEpisode(
    this.chapter,
    this.index,
    this.content,
    this.player, {
    DateTime? at,
  }) : at = at ?? DateTime.now();
  final SourceChapter chapter;
  final int index;
  final ChapterContent content;
  final AbstractPlayer player;
  final DateTime at;
}

/// Holds at most one paused player; ownership transfers on a matching next-episode switch.
class NextEpisodeBuffer {
  NextEpisodeBuffer({DateTime Function()? now}) : _now = now ?? DateTime.now {
    _removeClearer = MediaPreload.instance.onClear(clear);
    MediaPreload.instance.addListener(discard);
  }
  final DateTime Function() _now;
  String? _attemptKey, _catalogKey;
  int _attempts = 0, _catalogAttempts = 0, _catalogRevision = 0;
  DateTime? _retryAfter, _catalogRetryAfter;
  NetworkCancellation? _catalogToken, _preparationToken;
  Future<({DataSource source, List<SourceChapter> chapters})?>? _catalog;

  Future<void> warmCatalog(
    VideoPlayTarget target,
    Future<DataSource?> Function() openSource,
  ) async {
    if (!MediaPreload.instance.video || MediaPreload.instance.clearing) return;
    await _loadCatalog(target, openSource);
  }

  Future<({DataSource source, List<SourceChapter> chapters})?> _loadCatalog(
    VideoPlayTarget target,
    Future<DataSource?> Function() openSource,
  ) {
    final key = '${target.sourceId}|${target.itemId}|${target.chapterId}';
    if (_catalogKey != key) {
      _catalogRevision++;
      _catalogToken?.cancel();
      _catalogKey = key;
      _catalog = null;
      _catalogAttempts = 0;
      _catalogRetryAfter = null;
    }
    if (_catalog != null) return _catalog!;
    if (_catalogAttempts >= 2 ||
        (_catalogRetryAfter?.isAfter(_now()) ?? false)) {
      return Future.value(null);
    }
    _catalogAttempts++;
    final revision = _catalogRevision;
    final token = _catalogToken = NetworkCancellation();
    final task = token
        .run(() async {
          final source = await token.guard(openSource());
          if (source == null) return null;
          final chapters = VideoEpisodeCatalog.forChapter(
            await token.guard(VideoEpisodeCatalog.load(source, target.itemId)),
            target.chapterId,
          );
          token.check();
          return (source: source, chapters: chapters);
        })
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            token.cancel();
            return null;
          },
        )
        .catchError((Object error) {
          if (error is! NetworkCancelled) {
            LumeLog.info('[player] 目录预热未完成：$error');
          }
          return null;
        })
        .then((value) {
          if (revision != _catalogRevision) return null;
          if (value == null) {
            _catalog = null;
            _catalogRetryAfter = _now().add(const Duration(seconds: 10));
          }
          return value;
        });
    _catalog = task;
    return task;
  }

  late final void Function() _removeClearer;
  int _revision = 0;
  String? _key;
  PreparedEpisode? _ready;
  AbstractPlayer? _loadingPlayer;
  final _releases = Expando<Future<void>>();
  bool _preparing = false;
  String status = '尚未预加载';
  Completer<void>? _finished;
  static const _maxAge = Duration(minutes: 5);
  static String _identity(VideoPlayTarget target, PlayerKernel kernel) =>
      '${target.sourceId}|${target.itemId}|${target.chapterId}|${kernel.id}';

  Future<void> prepare(
    VideoPlayTarget target,
    PlayerSettings settings,
    Future<DataSource?> Function() openSource,
    AbstractPlayer? Function(PlayerKernel) create, {
    bool refreshNearEnd = false,
  }) async {
    if (!MediaPreload.instance.video || MediaPreload.instance.clearing) return;
    final key = _identity(target, settings.kernel);
    if (_preparing) return;
    if (_key == key &&
        _ready != null &&
        _now().difference(_ready!.at) <= _maxAge) {
      return;
    }
    if (_attemptKey != key) {
      _attemptKey = key;
      _attempts = 0;
      _retryAfter = null;
    }
    if (_ready != null) _attempts = 0;
    if (_attempts >= 2 || (_retryAfter?.isAfter(_now()) ?? false)) return;
    _attempts++;
    _preparing = true;
    final finished = _finished = Completer<void>();
    final revision = ++_revision;
    final previous = _ready;
    _ready = null;
    _key = key;
    status = '正在解析下一集';
    final token = _preparationToken = NetworkCancellation();
    AbstractPlayer? player;
    bool stale() => revision != _revision;
    try {
      if (previous != null) await _dispose(previous.player);
      final catalog = await token.guard(_loadCatalog(target, openSource));
      if (catalog == null || stale()) return;
      final source = catalog.source;
      final chapters = catalog.chapters;
      final current = chapters.indexWhere(
        (chapter) => chapter.id == target.chapterId,
      );
      final index = (current < 0 ? target.chapterIndex : current) + 1;
      if (index >= chapters.length || stale()) return;
      final chapter = chapters[index];
      final content = await token
          .run(
            () => token.guard(
              source.content(itemId: target.itemId, chapterId: chapter.id),
            ),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              token.cancel();
              return null;
            },
          );
      final chosen = PlaybackQualityPreference.select(
        SourcePlayback.contentQualities(content, source: source),
        settings,
      );
      final uri = chosen?.url ?? SourcePlayback.contentAddress(content);
      if (content == null || uri == null || stale()) return;
      status = '地址已解析，正在准备播放器';
      player = _loadingPlayer = create(settings.kernel);
      if (player == null) return;
      final instance = player;
      await instance.setBuffering(
        BufferingConfig(
          forwardBuffer: Duration(seconds: MediaPreload.instance.bufferSeconds),
          readAhead: Duration(seconds: MediaPreload.instance.bufferSeconds),
          maxBufferBytes: MediaPreload.instance.mediaBudgetBytes,
          maxBackBufferBytes: 0,
        ),
      );
      await instance.applySettings(settings);
      await instance.setVolume(0);
      if (stale()) return;
      await instance
          .load(
            PlayerMedia(
              uri: uri,
              title: '${target.title} · ${chapter.title}',
              headers: Platform.isIOS
                  ? await IosVerifiedWebView.resourceHeaders(
                      uri.toString(),
                      (chosen?.headers ??
                          SourcePlayback.contentHeaders(
                            content,
                            source: source,
                          )),
                    )
                  : (chosen?.headers ??
                        SourcePlayback.contentHeaders(content, source: source)),
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (stale()) return;
      await instance.pause();
      if (stale() || instance.snapshot.value.error != null) return;
      status = '播放器已准备，实际缓冲量取决于内核';
      _ready = PreparedEpisode(chapter, index, content, instance, at: _now());
      _loadingPlayer = null;
      player = null; // owned by _ready
    } catch (error) {
      LumeLog.info('[player] 下一集预加载未完成，切集时正常重试：$error');
    } finally {
      if (identical(_loadingPlayer, player)) _loadingPlayer = null;
      if (player != null) await _dispose(player);
      if (_ready == null && _key == key) {
        status = '预加载未完成，切集时重试';
        _retryAfter = _now().add(const Duration(seconds: 10));
      }
      _preparing = false;
      if (identical(_finished, finished)) _finished = null;
      if (!finished.isCompleted) finished.complete();
    }
  }

  PreparedEpisode? take(
    VideoPlayTarget target,
    int index,
    PlayerKernel kernel,
  ) {
    final ready = _ready;
    if (_key != _identity(target, kernel) || ready?.index != index) return null;
    if (_now().difference(ready!.at) > _maxAge) {
      discard();
      return null;
    }
    _ready = null;
    _key = null;
    _revision++;
    return ready;
  }

  /// 若下一集正在准备，短暂等同一任务，避免并发重复解析。
  Future<PreparedEpisode?> takeWhenReady(
    VideoPlayTarget target,
    int index,
    PlayerKernel kernel, {
    Duration wait = const Duration(milliseconds: 350),
  }) async {
    if (_key == _identity(target, kernel) && index == target.chapterIndex + 1) {
      final pending = _finished;
      if (pending != null) {
        try {
          await pending.future.timeout(wait);
        } on TimeoutException {
          discard();
        }
      }
    }
    return take(target, index, kernel);
  }

  void discard() {
    unawaited(clear());
  }

  Future<void> clear() async {
    _revision++;
    _catalogRevision++;
    _catalogToken?.cancel();
    _preparationToken?.cancel();
    _catalog = null;
    _catalogKey = null;
    _attemptKey = null;
    _attempts = 0;
    _catalogAttempts = 0;
    _retryAfter = null;
    _catalogRetryAfter = null;
    _key = null;
    status = '尚未预加载';
    final ready = _ready;
    _ready = null;
    final loading = _loadingPlayer;
    _loadingPlayer = null;
    if (loading != null) await _dispose(loading);
    if (ready != null) await _dispose(ready.player);
  }

  void dispose() {
    _removeClearer();
    MediaPreload.instance.removeListener(discard);
    discard();
  }

  Future<void> _dispose(AbstractPlayer player) =>
      _releases[player] ??= () async {
        try {
          await player.dispose();
        } catch (error) {
          LumeLog.info('[player] 释放下一集预加载实例失败：$error');
        }
      }();
}
