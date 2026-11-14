import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;

import '../../core/bangumi/bangumi_sync.dart';
import '../../core/cat/cat_web_parse.dart';
import '../../core/media/playback_focus.dart';
import '../../core/net/ios_verified_webview.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/native_video_bridge.dart';
import '../../core/player/playback_diagnostics.dart';
import '../../core/player/player_settings.dart';
import '../../core/player/video_disk_cache.dart';
import '../../core/reading/reading.dart';
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
import 'danmaku/dandanplay_client.dart';

typedef _EpisodeCatalog = ({
  List<SourceChapter> chapters,
  Map<String, int> indices,
});
typedef _PreparedVideo = ({Map<String, Object?> media, PlayerKernel kernel});

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
    this.danmakuClient,
    VideoDownloadCenter? downloads,
    // Public parameter name is part of the route API.
    // ignore: prefer_initializing_formals
  }) : _media = media,
       _downloads = downloads ?? VideoDownloadCenter.instance,
       _bridge = bridge ?? NativeVideoBridge.shared;

  final Future<DandanplayClient> Function()? danmakuClient;
  Future<DandanplayClient> _commentClient() async => danmakuClient != null
      ? await danmakuClient!()
      : DandanplayClient(credentials: await DandanplayCredentials.load());
  String get _danmakuKey =>
      "video.native.danmaku.${Uri.encodeComponent(_identity)}";
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
  VideoQuality? _activeQuality;
  NativeVideoConnection? _connection;
  DataSource? _openedSource;
  List<SourceChapter>? _chapters;
  Future<List<SourceChapter>>? _loadingChapters;
  final _targets = <String, VideoPlayTarget>{};
  final _saved = <String, double>{};
  bool _closed = false;
  Future<void>? _closing;
  int _resolution = 0;
  void Function()? _releasePin;
  late PlayerSettings _settings;
  PlayerKernel? _preferredBeforeFallback;

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
    final sameUrl = qualities.where((q) => q.url == _media.uri);
    Map<String, String> headerNamesToLower(Map<String, String> headers) => {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final headers = headerNamesToLower(_media.headers ?? const {});
    final sameRequest = [
      for (final quality in sameUrl)
        if (mapEquals(headerNamesToLower(quality.headers), headers)) quality,
    ];
    _activeQuality =
        PlaybackQualityPreference.select(sameRequest, _settings) ??
        sameUrl.singleOrNull;
    if (_settings.kernel != PlayerKernel.avplayer &&
        _settings.kernel != PlayerKernel.mpv) {
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
    final requestedPosition = initialPosition ?? current?.resumePosition;
    var position = (requestedPosition?.inMilliseconds ?? 0) / 1000;
    if (requestedPosition == null && current != null) {
      final saved = library.videoEpisodeProgress(
        current.itemId,
        current.chapterId,
        sourceId: current.sourceId,
      );
      if (saved != null && !saved.isFinished) {
        position = saved.position.inMilliseconds / 1000;
      }
    }
    final prepared = await _prepareVideo(_media, position: position);
    if (_closed) return;
    _acceptVideo(prepared);
    if (current != null) _targets[_identity] = current;
    _saved[_identity] = position;
    _connection = _bridge.connect(request: _request, event: _event);
    await _connection!.open(prepared.media, {
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

  Future<_PreparedVideo> _prepareVideo(
    PlayerMedia media, {
    double position = 0,
    String? resumeIdentity,
    VideoPlayTarget? targetOverride,
  }) async {
    Future<Map<String, Object?>> prepare(PlayerKernel kernel) => _payload(
      media,
      position: position,
      resumeIdentity: resumeIdentity,
      targetOverride: targetOverride,
      kernelOverride: kernel,
    );
    // A fallback belongs to the media that required it. A replacement URL
    // can have a different container even on the same episode or quality.
    final kernel = _preferredBeforeFallback ?? _settings.kernel;
    try {
      return (media: await prepare(kernel), kernel: kernel);
    } on UnsupportedError {
      if (kernel != PlayerKernel.avplayer) rethrow;
      return (media: await prepare(PlayerKernel.mpv), kernel: PlayerKernel.mpv);
    }
  }

  // Commit a compatibility switch only after the caller accepts this request.
  Map<String, Object?> _acceptVideo(_PreparedVideo prepared) {
    if (prepared.kernel == _settings.kernel) return {'media': prepared.media};
    _preferredBeforeFallback = prepared.kernel == _preferredBeforeFallback
        ? null
        : _settings.kernel;
    _settings = _settings.copyWith(kernel: prepared.kernel);
    return {
      'media': prepared.media,
      'kernel': prepared.kernel.name,
      'speed': _settings.speed,
    };
  }

  Future<bool> _requiresMpv(PlayerMedia media) async {
    if (VideoDiskCache.mpvFormats.any(media.uri.path.toLowerCase().endsWith)) {
      return true;
    }
    // Older downloads used media.mp4 for extensionless URLs.
    if (!media.isDownloaded ||
        media.uri.scheme != 'file' ||
        !media.uri.path.endsWith('/media.mp4')) {
      return false;
    }
    try {
      return VideoDiskCache.mpvFormats.contains(
        await VideoDiskCache.detectFileFormat(File.fromUri(media.uri)),
      );
    } on FileSystemException {
      return false;
    }
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
    if (apple && await _requiresMpv(media)) {
      throw UnsupportedError('当前媒体格式需要 MPV 内核');
    }
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

  Future<List<SourceChapter>> _remoteChapters(VideoPlayTarget current) async {
    try {
      final chapters = await _source()
          .then<List<SourceChapter>>(
            (dataSource) => dataSource == null
                ? const <SourceChapter>[]
                : VideoEpisodeCatalog.load(dataSource, current.itemId),
          )
          .timeout(const Duration(seconds: 15));
      if (chapters.isNotEmpty && !_closed) _chapters = chapters;
      return chapters;
    } finally {
      _loadingChapters = null;
    }
  }

  Future<List<VideoDownloadTask>> _downloadedChapters(
    VideoPlayTarget current,
  ) async {
    await _downloads.boot();
    return [
      for (final task in _downloads.tasks.toList())
        if (task.section == library.section &&
            task.sourceId == current.sourceId &&
            task.itemId == current.itemId &&
            task.canPlayOffline &&
            await _downloads.checkedLocalFile(task) != null)
          task,
    ]..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
  }

  Future<_EpisodeCatalog> _catalog(String action, Object? id) async {
    final current = target;
    if (current == null) {
      return (
        chapters: const <SourceChapter>[],
        indices: const <String, int>{},
      );
    }
    List<VideoDownloadTask> local = [];
    try {
      local = await _downloadedChapters(current);
    } on Exception {
      PlaybackDiagnostics.record(
        'offline-lookup-failed',
        source: current.sourceId,
      );
    }
    final here = local
        .where((t) => t.chapterId == current.chapterId)
        .firstOrNull;
    final offline = (
      chapters: [
        for (final t in local)
          SourceChapter(id: t.chapterId, title: t.chapterTitle, line: t.line),
      ],
      indices: {for (final t in local) t.chapterId: t.chapterIndex},
    );
    final remote = _chapters;
    final online = remote != null
        ? Future.value(remote)
        : _loadingChapters ??= _remoteChapters(current);
    var available = online;
    if (remote == null && _media.isDownloaded && here != null) {
      final line = VideoEpisodeCatalog.forChapter(
        offline.chapters,
        here.chapterId,
      );
      final adjacent = here.chapterIndex + (action == 'next' ? 1 : -1);
      final localAction = switch (action) {
        'episode' => offline.indices.containsKey(id),
        'next' || 'previous' =>
          line.where((c) => offline.indices[c.id] == adjacent).length == 1,
        'line' =>
          VideoEpisodeCatalog.matchingIndex(
                line.firstWhere((c) => c.id == here.chapterId),
                offline.chapters
                    .where((c) => VideoEpisodeCatalog.lineOf(c) == id)
                    .toList(),
              ) >=
              0,
        _ => false,
      };
      if (localAction) {
        online.ignore();
        return offline;
      }
      if (action == 'episodes' || action == 'lines') {
        // Include online choices when ready, without holding a local menu
        // until the source's full network timeout.
        available = online.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () => [],
        );
      }
    }
    final List<SourceChapter> chapters;
    try {
      chapters = await available;
    } catch (_) {
      if (local.isEmpty) rethrow;
      return offline;
    }
    if (chapters.isEmpty) return offline;
    final ids = chapters.map((c) => c.id).toSet();
    final missing = offline.chapters.where((c) => !ids.contains(c.id)).toList();
    if (missing.isEmpty) {
      return (chapters: chapters, indices: const <String, int>{});
    }
    final lines = VideoEpisodeCatalog.group(chapters);
    final indices = {
      for (final line in lines.values)
        for (var i = 0; i < line.length; i++) line[i].id: i,
      for (final c in missing) c.id: offline.indices[c.id]!,
    };
    for (final c in missing) {
      (lines[VideoEpisodeCatalog.lineOf(c)] ??= []).add(c);
    }
    for (final line in lines.values) {
      line.sort((a, b) {
        final byIndex = indices[a.id]!.compareTo(indices[b.id]!);
        if (byIndex != 0) return byIndex;
        if (ids.contains(a.id) != ids.contains(b.id)) {
          return ids.contains(a.id) ? -1 : 1;
        }
        return a.id.compareTo(b.id);
      });
    }
    return (
      chapters: lines.values.expand((line) => line).toList(),
      indices: indices,
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
      return {
        'media': payload,
        'speed': _settings.copyWith(kernel: kernel).speed,
      };
    }
    if (action == 'danmaku-search') {
      final client = await _commentClient();
      try {
        final entries = await client.search(
          '${arguments['title'] ?? target?.title ?? _media.title ?? ''}',
          episode:
              (arguments['episode'] as num?)?.toInt() ??
              (target?.chapterIndex ?? 0) + 1,
        );
        return {
          'items': [
            for (final entry in entries)
              {
                'id': entry.id,
                'title': '${entry.title} · ${entry.episode}',
                'line': entry.details,
              },
          ],
        };
      } finally {
        client.close();
      }
    }
    if (action == 'danmaku-select') {
      final identity = _identity, key = _danmakuKey;
      final client = await _commentClient();
      try {
        final id = '${arguments['id'] ?? ''}';
        final track = await client.comments(id);
        if (_closed || identity != _identity) return {'error': '播放内容已改变，请重新匹配'};
        if (track.items.isNotEmpty) library.setSetting(key, id);
        return _commentPayload(track);
      } finally {
        client.close();
      }
    }
    if (action == 'danmaku') return _danmaku();
    if (action == 'qualities') {
      final selected = qualities.indexWhere(
        (quality) => identical(quality, _activeQuality),
      );
      return {
        'items': [
          for (var i = 0; i < qualities.length; i++)
            {'id': i, 'title': qualities[i].label, 'selected': i == selected},
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
      final prepared = await _prepareVideo(media, resumeIdentity: _identity);
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      _media = media;
      _manualQuality = choice;
      _activeQuality = choice;
      if (_settings.rememberManualQuality) {
        _settings = _settings.copyWith(manualQualityLabel: choice.label);
        library.setSetting(
          VideoPlayerSettingsStore.keyManualQualityLabel,
          choice.label,
        );
      }
      return _acceptVideo(prepared);
    }
    // A retry already has the chapter ID. An unavailable catalog must not
    // prevent refreshing an expired media URL for the current episode.
    final catalog = action == 'retry'
        ? (chapters: const <SourceChapter>[], indices: const <String, int>{})
        : await _catalog(action, arguments['id']);
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
    if (current == null) {
      if (action != 'retry') return {'message': '此资源没有选集'};
      return _retryCurrentMedia(revision);
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
        final desired =
            catalog.indices[selected.id]! + (action == 'next' ? 1 : -1);
        final adjacent = line
            .where((c) => catalog.indices[c.id] == desired)
            .toList();
        chosen = adjacent.singleOrNull;
        if (chosen == null && adjacent.isNotEmpty) {
          final remoteIds = _chapters?.map((c) => c.id).toSet();
          chosen = adjacent
              .where((c) => remoteIds?.contains(c.id) == true)
              .singleOrNull;
        }
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
      local = await _downloads.playbackIfAvailable(
        current.sourceId,
        current.itemId,
        chosen.id,
        section: library.section,
      );
      final server = local?.server;
      if (action == 'retry' &&
          server != null &&
          !await server.hasCompletePlaylist(local!.uri)) {
        await local.close();
        local = null;
      }
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      List<VideoQuality> nextQualities = const [];
      VideoQuality? choice;
      final PlayerMedia nextMedia;
      if (local != null) {
        nextMedia = local.media(nextTarget.mediaTitle);
      } else {
        // Detail pages can start a single direct item without a resolver.
        // Retry still prefers a fresh signed URL when the source supplies one.
        final direct = action == 'retry' && current.chapterId == current.itemId
            ? SourcePlayback.itemAddress(current.itemId)
            : null;
        final directRetry =
            direct != null && (direct == _media.uri || _media.isDownloaded);
        DataSource? dataSource;
        ChapterContent? content;
        try {
          dataSource = await _source();
          if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
          if (dataSource == null && !directRetry) {
            return {'error': '源不可用，请返回更新订阅后重试'};
          }
          content = await dataSource
              ?.content(itemId: current.itemId, chapterId: chosen.id)
              .timeout(const Duration(seconds: 15));
        } on CatWebParseRequired {
          rethrow;
        } catch (_) {
          if (!directRetry) rethrow;
        }
        if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
        if (content == null && directRetry) {
          if (!_media.isDownloaded) return await _retryCurrentMedia(revision);
          content = VideoContent(url: direct);
        }
        if (content is! VideoContent) return {'error': '源没有返回可播放的媒体地址'};
        nextQualities = SourcePlayback.contentQualities(
          content,
          source: dataSource,
        );
        choice = PlaybackQualityPreference.select(
          nextQualities,
          _settings,
          currentQuality: action == 'retry'
              ? _activeQuality ?? _manualQuality
              : _manualQuality,
        );
        nextMedia = PlayerMedia(
          uri: choice?.url ?? SourcePlayback.contentAddress(content)!,
          headers:
              choice?.headers ??
              SourcePlayback.contentHeaders(content, source: dataSource),
          title: nextTarget.mediaTitle,
        );
      }
      final prepared = await _prepareVideo(
        nextMedia,
        targetOverride: nextTarget,
        resumeIdentity: same ? _identity : null,
      );
      if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
      target = nextTarget;
      _targets[_identity] = nextTarget;
      if (nextTarget.chapterId != current.chapterId) {
        _saved[_identity] = prepared.media['position'] as double;
      }
      qualities = nextQualities;
      _activeQuality = choice;
      _media = nextMedia;
      final previous = _localPlayback;
      _localPlayback = local;
      local = null;
      if (previous != null) unawaited(previous.close());
      return _acceptVideo(prepared);
    } finally {
      await local?.close();
    }
  }

  Future<Map<String, Object?>> _retryCurrentMedia(int revision) async {
    if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
    final prepared = await _prepareVideo(_media, resumeIdentity: _identity);
    if (_closed || revision != _resolution) return {'error': '此次取址已经取消'};
    return _acceptVideo(prepared);
  }

  Map<String, Object?> _commentPayload(DanmakuTrack track) => {
    'items': [
      for (final entry in track.items)
        {'time': entry.time.inMilliseconds / 1000, 'text': entry.text},
    ],
  };
  Future<Map<String, Object?>> _danmaku() async {
    final matched = library.setting(_danmakuKey);
    if (matched != null && matched.isNotEmpty) {
      final client = await _commentClient();
      try {
        return _commentPayload(await client.comments(matched));
      } finally {
        client.close();
      }
    }
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
      // Reloading an engine echoes its current rate, which older screens may
      // carry across engines. A speed selection sends a separate rate event.
      final loadSnapshot =
          data.containsKey('hardwareDecoding') && data.containsKey('autoNext');
      final changedAutoNext =
          data['autoNext'] is bool && data['autoNext'] != _settings.autoNext;
      if (kernel != _settings.kernel) _preferredBeforeFallback = null;
      _settings = _settings.copyWith(
        kernel: kernel,
        speed: !loadSnapshot && speed is num && speed.isFinite
            ? speed.toDouble().clamp(0.25, 4)
            : null,
        hardwareDecoding:
            data['hardwareDecoding'] as bool? ?? _settings.hardwareDecoding,
        autoNext: data['autoNext'] as bool? ?? _settings.autoNext,
      );
      final id = target?.sourceId ?? source?.id;
      final profiles = SourcePlaybackProfiles(library);
      // File compatibility chooses the engine for this session only. Save
      // speed edits in its own slot while keeping the user's default engine.
      final saved = _settings.copyWith(kernel: _preferredBeforeFallback);
      if (id != null && profiles.contains(id)) {
        profiles.save(id, saved, profiles.bufferSeconds(id, 0));
        // Auto-next is shared by all sources, including those with custom
        // kernel settings. Native also echoes it when opening an engine.
        if (changedAutoNext) {
          library.setSetting(
            VideoPlayerSettingsStore.keyAutoNext,
            _settings.autoNext.toString(),
          );
        }
      } else {
        VideoPlayerSettingsStore(library).save(saved);
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
          : library
                    .videoEpisodeProgress(
                      current.itemId,
                      current.chapterId,
                      sourceId: current.sourceId,
                    )
                    ?.duration ??
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
