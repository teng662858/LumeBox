import 'dart:async';

import '../../core/bangumi/bangumi_sync.dart';
import '../../core/media/playback_focus.dart';
import '../../core/net/ios_verified_webview.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/native_video_bridge.dart';
import '../../core/player/playback_diagnostics.dart';
import '../../core/player/player_settings.dart';
import '../../core/player/video_disk_cache.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/session/section_module_settings.dart';
import '../../core/session/app_preferences.dart';
import '../../core/source/source.dart';
import '../../core/source/source_runtime_pins.dart';
import 'source_playback.dart';
import 'playback_quality_preference.dart';
import 'source_playback_profiles.dart';
import 'video_episode_catalog.dart';
import 'video_download_center.dart';
import 'video_play_target.dart';
import 'video_player_settings.dart';
import 'danmaku/danmaku_models.dart';

/// Resolves source payloads and stores progress. Contains no decoder, frame
/// ticker, gesture state, seek watchdog, PiP or automatic kernel recovery.
class NativeVideoSourceSession {
  NativeVideoSourceSession({
    required PlayerMedia media,
    required this.library,
    this.target,
    this.initialPosition,
    this.source,
    this.manager,
    this.qualities = const [],
    NativeVideoBridge? bridge,
    this.prepareMedia,
    VideoDownloadCenter? downloads,
    // Public parameter name is part of the route API.
    // ignore: prefer_initializing_formals
  }) : _media = media,
       _downloads = downloads ?? VideoDownloadCenter.instance,
       _bridge = bridge ?? NativeVideoBridge.shared;

  final ReadingLibrary library;
  final Duration? initialPosition;
  final DataSource? source;
  final SourceManager? manager;
  final Future<PlayerMedia> Function(PlayerMedia, bool)? prepareMedia;
  final NativeVideoBridge _bridge;
  final VideoDownloadCenter _downloads;
  DownloadedVideoPlayback? _localPlayback;
  PlayerMedia _media;
  VideoPlayTarget? target;
  List<VideoQuality> qualities;
  VideoQuality? _manualQuality;
  NativeVideoConnection? _connection;
  DataSource? _openedSource;
  List<SourceChapter>? _chapters;
  final _targets = <String, VideoPlayTarget>{};
  final _saved = <String, double>{};
  bool _closed = false;
  Future<void>? _closing;
  int _resolution = 0;
  void Function()? _releasePin;
  late PlayerSettings _settings;

  Future<void> get finished => _connection?.finished ?? Future.value();
  String? get connectionId => _connection?.id;
  late final String _directIdentity = _media.uri.toString();
  String get _identity => target == null
      ? _directIdentity
      : '${target!.identity}:${target!.chapterId}';

  Future<void> open() async {
    if (_closed) return;
    _settings = SourcePlaybackProfiles(library).load(
      target?.sourceId ?? source?.id,
      VideoPlayerSettingsStore(library).load(),
    );
    if (_settings.kernel != PlayerKernel.avplayer &&
        _settings.kernel != PlayerKernel.mpv) {
      _settings = _settings.copyWith(kernel: PlayerKernel.mpv);
    }
    if (RegExp(
      r'\.(mkv|webm|avi|flv|wmv|mpd)$',
      caseSensitive: false,
    ).hasMatch(_media.uri.path)) {
      _settings = _settings.copyWith(kernel: PlayerKernel.mpv);
    }
    await PlaybackFocus.acquire(
      'video',
      onRelease: close,
      stillWanted: () => !_closed,
    );
    if (_closed) {
      PlaybackFocus.unregister('video', close);
      return;
    }
    if (target != null) {
      _releasePin = SourceRuntimePins.retain(
        source?.section ?? library.section,
        target!.sourceId,
      );
    }
    final current = target;
    var position = (initialPosition?.inMilliseconds ?? 0) / 1000;
    if (initialPosition == null && current != null) {
      final saved = library.videoEpisodeProgress(
        current.itemId,
        current.chapterId,
        sourceId: current.sourceId,
      );
      if (saved != null && !saved.isFinished) {
        position = saved.position.inMilliseconds / 1000;
      }
    }
    late Map<String, Object?> payload;
    try {
      payload = await _payload(_media, position: position);
    } on UnsupportedError {
      if (_settings.kernel != PlayerKernel.avplayer) rethrow;
      // Signed script URLs can hide an MKV/DASH container until cache inspection.
      _settings = _settings.copyWith(kernel: PlayerKernel.mpv);
      payload = await _payload(_media, position: position);
    }
    if (_closed) return;
    if (current != null) _targets[_identity] = current;
    _saved[_identity] = position;
    _connection = _bridge.connect(request: _request, event: _event);
    await _connection!.open(payload, {
      'kernel': _settings.kernel.name,
      'speed': _settings.speed,
      'hardwareDecoding': _settings.hardwareDecoding,
      'autoNext': _settings.autoNext,
      'forwardBufferSeconds': SourcePlaybackProfiles(library).bufferSeconds(
        target?.sourceId ?? source?.id,
        SectionModuleSettings.load(library).bufferSeconds,
      ),
      'maxBufferBytes':
          SectionModuleSettings.load(library).bufferMiB * 1024 * 1024,
      'backgroundPlayback': AppPreferences.instance.backgroundPlayback,
      'subtitlesEnabled': _settings.subtitlesEnabled,
      'fill': _settings.zoom == ZoomMode.fill,
    });
  }

  Future<Map<String, Object?>> _payload(
    PlayerMedia media, {
    double position = 0,
    String? resumeIdentity,
    VideoPlayTarget? targetOverride,
    PlayerKernel? kernelOverride,
  }) async {
    final current = targetOverride ?? target;
    final identity = current == null
        ? _directIdentity
        : '${current.identity}:${current.chapterId}';
    final apple = (kernelOverride ?? _settings.kernel) == PlayerKernel.avplayer;
    final PlayerMedia prepared;
    if (prepareMedia != null) {
      prepared = await prepareMedia!(media, apple);
    } else {
      final headers = await IosVerifiedWebView.resourceHeaders(
        media.uri.toString(),
        media.headers ?? const {},
      );
      await VideoDiskCache.instance.boot();
      prepared = await VideoDiskCache.instance.wrap(
        PlayerMedia(uri: media.uri, headers: headers, title: media.title),
        appleHls: apple,
        inspect: true,
      );
    }
    // Preparation may involve redirects and container probing while the old
    // player is still advancing or accepting seeks.
    final playhead = _saved[resumeIdentity] ?? position;
    return {
      'url': prepared.uri.toString(),
      'sourceUrl': media.uri.toString(),
      'headers': prepared.headers ?? const <String, String>{},
      'title': current?.mediaTitle ?? media.title ?? '播放',
      'identity': identity,
      'position': playhead.isFinite ? playhead.clamp(0.0, 365.0 * 86400) : 0.0,
    };
  }

  Future<DataSource?> _source() async {
    if (source != null || target == null) return source;
    return _openedSource ??= await manager?.open(target!.sourceId);
  }

  Future<({List<SourceChapter> chapters, Map<String, int> indices})>
  _catalog() async {
    final current = target;
    const noIndices = <String, int>{};
    if (current == null) {
      return (chapters: const <SourceChapter>[], indices: noIndices);
    }
    if (_chapters != null) return (chapters: _chapters!, indices: noIndices);
    Object? failure;
    try {
      final chapters = await _source()
          .then<List<SourceChapter>>(
            (dataSource) => dataSource == null
                ? const <SourceChapter>[]
                : VideoEpisodeCatalog.load(dataSource, current.itemId),
          )
          .timeout(const Duration(seconds: 15));
      if (chapters.isNotEmpty) {
        _chapters = chapters;
        return (chapters: chapters, indices: noIndices);
      }
    } catch (error) {
      failure = error;
    }
    if ((source?.section ?? library.section) != Section.video) {
      if (failure != null) throw failure;
      return (chapters: const <SourceChapter>[], indices: noIndices);
    }
    await _downloads.boot();
    final local = [
      for (final task in _downloads.tasks.toList())
        if (task.sourceId == current.sourceId &&
            task.itemId == current.itemId &&
            task.canPlayOffline &&
            await _downloads.localFile(task).exists())
          task,
    ]..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    if (local.isEmpty && failure != null) throw failure;
    return (
      chapters: [
        for (final t in local)
          SourceChapter(id: t.chapterId, title: t.chapterTitle, line: t.line),
      ],
      indices: {for (final t in local) t.chapterId: t.chapterIndex},
    );
  }

  Future<Map<String, Object?>> _request(
    String action,
    Map<String, Object?> arguments,
  ) async {
    if (_closed) return {'error': '播放会话已经关闭'};
    final changesMedia = const {
      'quality',
      'episode',
      'retry',
      'next',
      'previous',
      'line',
      'kernel',
    }.contains(action);
    final revision = changesMedia ? ++_resolution : _resolution;
    return _resolve(action, arguments, revision).timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        if (changesMedia && revision == _resolution) _resolution++;
        return {'error': '播放请求超时，请重试'};
      },
    );
  }

  Future<Map<String, Object?>> _resolve(
    String action,
    Map<String, Object?> arguments,
    int revision,
  ) async {
    if (action == 'kernel') {
      final kernel = arguments['id'] == 'mpv'
          ? PlayerKernel.mpv
          : PlayerKernel.avplayer;
      final payload = await _payload(
        _media,
        resumeIdentity: _identity,
        kernelOverride: kernel,
      );
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      return {'media': payload};
    }
    if (action == 'danmaku') return _danmaku();
    if (action == 'qualities') {
      return {
        'items': [
          for (var i = 0; i < qualities.length; i++)
            {
              'id': i,
              'title': qualities[i].label,
              'selected': qualities[i].url == _media.uri,
            },
        ],
      };
    }
    if (action == 'quality') {
      final index = arguments['id'];
      if (index is! int || index < 0 || index >= qualities.length) {
        return {'error': '画质已失效，请重新打开'};
      }
      final choice = qualities[index];
      final media = PlayerMedia(
        uri: choice.url,
        headers: choice.headers,
        title: _media.title,
      );
      final payload = await _payload(media, resumeIdentity: _identity);
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      _media = media;
      _manualQuality = choice;
      if (_settings.rememberManualQuality) {
        _settings = _settings.copyWith(manualQualityLabel: choice.label);
        library.setSetting(
          VideoPlayerSettingsStore.keyManualQualityLabel,
          choice.label,
        );
      }
      return {'media': payload};
    }
    // A retry already has the chapter ID. An unavailable catalog must not
    // prevent refreshing an expired media URL for the current episode.
    final catalog = action == 'retry'
        ? (chapters: const <SourceChapter>[], indices: const <String, int>{})
        : await _catalog();
    final chapters = catalog.chapters;
    if (_closed) return {'error': '播放会话已经关闭'};
    final current = target;
    if (action == 'episodes') {
      final line = current == null
          ? chapters
          : VideoEpisodeCatalog.forChapter(chapters, current.chapterId);
      return {
        'items': [
          for (var i = 0; i < line.length; i++)
            {
              'id': line[i].id,
              'title': VideoEpisodeCatalog.displayLabel(
                line[i],
                catalog.indices[line[i].id] ?? i,
              ),
              'line': VideoEpisodeCatalog.lineOf(line[i]),
              'selected': line[i].id == current?.chapterId,
            },
        ],
      };
    }
    if (action == 'lines') {
      final selected = chapters
          .where((c) => c.id == current?.chapterId)
          .firstOrNull;
      return {
        'items': [
          for (final line in VideoEpisodeCatalog.group(chapters).keys)
            {
              'id': line,
              'title': line,
              'selected':
                  selected != null &&
                  VideoEpisodeCatalog.lineOf(selected) == line,
            },
        ],
      };
    }
    if (revision != _resolution) return {'error': '此次取址已经取消'};
    if (current == null || (action == 'retry' && _media.isDownloaded)) {
      if (action != 'retry') return {'message': '此资源没有选集'};
      final payload = await _payload(_media, resumeIdentity: _identity);
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      return {'media': payload};
    }
    SourceChapter? chosen;
    final selected = chapters
        .where((c) => c.id == current.chapterId)
        .firstOrNull;
    if (action == 'episode') {
      chosen = chapters.where((c) => c.id == arguments['id']).firstOrNull;
    }
    if (action == 'retry') {
      chosen =
          selected ??
          SourceChapter(id: current.chapterId, title: current.chapterTitle);
    }
    if (action == 'next' || action == 'previous') {
      final line = VideoEpisodeCatalog.forChapter(chapters, current.chapterId);
      final index = line.indexWhere((c) => c.id == current.chapterId);
      final next = index + (action == 'next' ? 1 : -1);
      if (catalog.indices.isNotEmpty && selected != null) {
        final desired = current.chapterIndex + (action == 'next' ? 1 : -1);
        chosen = line
            .where((c) => catalog.indices[c.id] == desired)
            .singleOrNull;
      } else if (index >= 0 && next >= 0 && next < line.length) {
        chosen = line[next];
      }
    }
    if (action == 'line' && selected != null) {
      final line = chapters
          .where((c) => VideoEpisodeCatalog.lineOf(c) == arguments['id'])
          .toList();
      final index = VideoEpisodeCatalog.matchingIndex(selected, line);
      if (index >= 0) chosen = line[index];
      if (chosen == null) return {'error': '这条线路没有匹配的当前集，请手动选集'};
    }
    if (chosen == null) return {'message': '没有可播放的下一项'};
    final same = chosen.id == current.chapterId || action == 'line';
    final line = VideoEpisodeCatalog.forChapter(chapters, chosen.id);
    final nextTarget = chosen.id == current.chapterId
        ? current
        : VideoPlayTarget(
            sourceId: current.sourceId,
            itemId: current.itemId,
            title: current.title,
            chapterIndex:
                catalog.indices[chosen.id] ??
                line.indexWhere((c) => c.id == chosen!.id),
            chapterId: chosen.id,
            chapterTitle: VideoEpisodeCatalog.labelOf(chosen),
            cover: current.cover,
          );
    DownloadedVideoPlayback? local;
    try {
      try {
        if ((source?.section ?? library.section) == Section.video) {
          local = await _downloads.completedPlayback(
            current.sourceId,
            current.itemId,
            chosen.id,
          );
        }
      } catch (_) {
        PlaybackDiagnostics.record(
          'offline-lookup-failed',
          source: current.sourceId,
        );
      }
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      List<VideoQuality> nextQualities = const [];
      final PlayerMedia nextMedia;
      if (local != null) {
        nextMedia = local.media(nextTarget.mediaTitle);
      } else {
        final dataSource = await _source();
        if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
        if (dataSource == null) return {'error': '源不可用，请返回更新订阅后重试'};
        final content = await dataSource
            .content(itemId: current.itemId, chapterId: chosen.id)
            .timeout(const Duration(seconds: 15));
        if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
        if (content is! VideoContent) return {'error': '源没有返回可播放的媒体地址'};
        nextQualities = SourcePlayback.contentQualities(
          content,
          source: dataSource,
        );
        final choice = PlaybackQualityPreference.select(
          nextQualities,
          _settings,
          currentQuality: _manualQuality,
        );
        nextMedia = PlayerMedia(
          uri: choice?.url ?? SourcePlayback.contentAddress(content)!,
          headers:
              choice?.headers ??
              SourcePlayback.contentHeaders(content, source: dataSource),
          title: nextTarget.mediaTitle,
        );
      }
      final payload = await _payload(
        nextMedia,
        targetOverride: nextTarget,
        resumeIdentity: same ? _identity : null,
      );
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      target = nextTarget;
      _targets[_identity] = nextTarget;
      if (nextTarget.chapterId != current.chapterId) {
        _saved[_identity] = payload['position'] as double;
      }
      qualities = nextQualities;
      _media = nextMedia;
      final previous = _localPlayback;
      _localPlayback = local;
      local = null;
      if (previous != null) unawaited(previous.close());
      return {'media': payload};
    } finally {
      await local?.close();
    }
  }

  Future<Map<String, Object?>> _danmaku() async {
    final dataSource = await _source(), current = target;
    if (dataSource is! DanmakuCapable || current == null) {
      return {'items': <Object?>[]};
    }
    final result = await (dataSource as DanmakuCapable).danmaku(
      itemId: current.itemId,
      chapterId: current.chapterId,
    );
    final track = DanmakuTrack.parse(result);
    return {
      'items': [
        for (final entry in track.items)
          {'time': entry.time.inMilliseconds / 1000, 'text': entry.text},
      ],
    };
  }

  void _event(Map<String, Object?> data) {
    final type = data['type'];
    // The native screen emits its final progress while handling close.
    if (_closed && type != 'progress') return;
    final identity = data['identity'] as String? ?? '';
    final active = identity == _identity;
    if (type == 'settings' && (active || identity.isEmpty)) {
      final kernel = data['kernel'] == 'mpv'
          ? PlayerKernel.mpv
          : PlayerKernel.avplayer;
      final speed = data['speed'];
      _settings = _settings.copyWith(
        kernel: kernel,
        speed: speed is num && speed.isFinite
            ? speed.toDouble().clamp(0.25, 4)
            : _settings.speed,
        hardwareDecoding:
            data['hardwareDecoding'] as bool? ?? _settings.hardwareDecoding,
        autoNext: data['autoNext'] as bool? ?? _settings.autoNext,
      );
      final id = target?.sourceId ?? source?.id;
      final profiles = SourcePlaybackProfiles(library);
      if (id != null && profiles.contains(id)) {
        profiles.save(id, _settings, profiles.bufferSeconds(id, 0));
      } else {
        VideoPlayerSettingsStore(library).save(_settings);
      }
    }
    final sessionEvent = active || identity.isEmpty;
    if (!sessionEvent && !_targets.containsKey(identity)) return;
    if (sessionEvent && data['playing'] is bool) {
      PlaybackFocus.setPlaying('video', data['playing'] == true);
    }
    if (sessionEvent &&
        (type == 'load-start' ||
            type == 'ready' ||
            type == 'firstFrame' ||
            type == 'error')) {
      final elapsed = data['elapsedMs'];
      PlaybackDiagnostics.record(
        type == 'load-start' ? 'native-open' : 'native-$type',
        source: target?.sourceId,
        kernel: data['kernel'] as String?,
        uri: _media.uri,
        elapsedMs: elapsed is num && elapsed.isFinite && elapsed >= 0
            ? elapsed.toInt()
            : null,
        error: data['error'] as String?,
      );
    }
    final position = data['position'], duration = data['duration'];
    if (position is! num ||
        !position.isFinite ||
        position < 0 ||
        (position == 0 && type != 'seek') ||
        position > 365 * 86400 ||
        data['error'] != null) {
      return;
    }
    if (identity.isEmpty) return;
    _saved[identity] = position.toDouble();
    final current = _targets[identity];
    if (current == null || library.setting('history.incognito') == 'true') {
      return;
    }
    final progress = VideoProgress(
      sourceId: current.sourceId,
      section: library.section,
      itemId: current.itemId,
      chapterIndex: current.chapterIndex,
      chapterId: current.chapterId,
      chapterTitle: current.chapterTitle,
      updatedAt: DateTime.now(),
      position: Duration(milliseconds: (position * 1000).round()),
      duration:
          duration is num &&
              duration.isFinite &&
              duration > 0 &&
              duration <= 365 * 86400
          ? Duration(milliseconds: (duration * 1000).round())
          : library.videoEpisodeProgress(
                current.itemId,
                current.chapterId,
                sourceId: current.sourceId,
              )?.duration ??
              Duration.zero,
    );
    if (!active) {
      library.saveVideoEpisodeProgress(progress);
      return;
    }
    library.recordHistoryItem(
      sourceId: current.sourceId,
      itemId: current.itemId,
      title: current.title,
      cover: current.cover,
      chapterCount: 0,
    );
    library.saveProgress(progress);
    unawaited(BangumiSyncService.instance.afterProgress(library, progress));
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _resolution++;
    try {
      await _connection?.close();
    } finally {
      PlaybackFocus.unregister('video', close);
      _releasePin?.call();
      _releasePin = null;
      await _localPlayback?.close();
      _localPlayback = null;
    }
  }
}
