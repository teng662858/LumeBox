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
  PreparedEpisode(this.chapter, this.index, this.content, this.player);
  final SourceChapter chapter;
  final int index;
  final ChapterContent content;
  final AbstractPlayer player;
  final at = DateTime.now();
}

/// Holds at most one paused player; ownership transfers on a matching next-episode switch.
class NextEpisodeBuffer {
  NextEpisodeBuffer() {
    _removeClearer = MediaPreload.instance.onClear(clear);
    MediaPreload.instance.addListener(discard);
  }
  late final void Function() _removeClearer;
  int _revision = 0;
  String? _key;
  PreparedEpisode? _ready;
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
    if (_key == key &&
        _ready != null &&
        DateTime.now().difference(_ready!.at) >
            (refreshNearEnd ? const Duration(seconds: 30) : _maxAge)) {
      discard();
    }
    if (_key == key || _preparing) return;
    _preparing = true;
    final finished = _finished = Completer<void>();
    discard();
    _key = key;
    status = '正在解析下一集';
    final revision = _revision;
    AbstractPlayer? player;
    bool stale() => revision != _revision;
    try {
      final source = await openSource();
      if (source == null || stale()) return;
      final chapters = VideoEpisodeCatalog.forChapter(
        await VideoEpisodeCatalog.load(source, target.itemId),
        target.chapterId,
      );
      final index = target.chapterIndex + 1;
      if (index >= chapters.length || stale()) return;
      final chapter = chapters[index];
      final content = await source.content(
        itemId: target.itemId,
        chapterId: chapter.id,
      );
      final chosen = PlaybackQualityPreference.select(
        SourcePlayback.contentQualities(content, source: source),
        settings,
      );
      final uri = chosen?.url ?? SourcePlayback.contentAddress(content);
      if (content == null || uri == null || stale()) return;
      status = '地址已解析，正在准备播放器';
      player = create(settings.kernel);
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
      await instance.pause();
      if (stale() || instance.snapshot.value.error != null) return;
      status = '播放器已准备，实际缓冲量取决于内核';
      _ready = PreparedEpisode(chapter, index, content, instance);
      player = null; // owned by _ready
    } catch (error) {
      LumeLog.info('[player] 下一集预加载未完成，切集时正常重试：$error');
    } finally {
      if (player != null) await _dispose(player);
      if (_ready == null && _key == key) status = '预加载未完成，切集时重试';
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
    if (DateTime.now().difference(ready!.at) > _maxAge) {
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
    PlayerKernel kernel,
  ) async {
    if (_key == _identity(target, kernel) && index == target.chapterIndex + 1) {
      final pending = _finished;
      if (pending != null) {
        try {
          await pending.future.timeout(const Duration(seconds: 3));
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
    _key = null;
    status = '尚未预加载';
    final ready = _ready;
    _ready = null;
    if (ready != null) await _dispose(ready.player);
  }

  void dispose() {
    _removeClearer();
    MediaPreload.instance.removeListener(discard);
    discard();
  }

  static Future<void> _dispose(AbstractPlayer player) async {
    try {
      await player.dispose();
    } catch (error) {
      LumeLog.info('[player] 释放下一集预加载实例失败：$error');
    }
  }
}
