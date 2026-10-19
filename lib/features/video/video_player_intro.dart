part of 'video_player_page.dart';

extension _OriginalIntro on _VideoPlayerPageState {
  void _onOriginalIntroChanged() => _refresh(() {});

  void _syncOriginalIntro(PlayerSnapshot snapshot) {
    if (identical(_introMedia, _media)) {
      _intro?.update(
        snapshot,
        foreground: _lifecycle == AppLifecycleState.resumed,
        pictureInPicture: _session?.state == PipState.active,
      );
    }
    final media = _media;
    if (media == null ||
        snapshot.duration <= Duration.zero ||
        identical(_introMedia, media) ||
        _introOpening) {
      return;
    }
    _introOpening = true;
    final generation = ++_introGeneration;
    () async {
      try {
        final store = await IntroStore.open();
        final player = _player;
        if (!mounted ||
            generation != _introGeneration ||
            !identical(_media, media)) {
          return;
        }
        final target = _target;
        final series = target == null
            ? PlaybackLogs.safeUri(media.uri)
            : '${target.sourceId}:${target.itemId}';
        final identity = store.identity(series);
        if (target != null &&
            !_skipMarks.isEmpty &&
            store
                .seriesMemory(
                  EpisodeIdentity(
                    series: series,
                    episode: target.chapterIndex + 1,
                    season: (identity['season'] as num?)?.toInt() ?? 1,
                    movie: identity['movie'] == true,
                  ),
                  snapshot.duration.inMilliseconds,
                )
                .isEmpty &&
            !store.hasSeriesMemory(
              EpisodeIdentity(
                series: series,
                episode: target.chapterIndex + 1,
                season: (identity['season'] as num?)?.toInt() ?? 1,
                movie: identity['movie'] == true,
              ),
            )) {
          await rememberPlayerSkip(target, _skipMarks, snapshot.duration);
          if (!mounted ||
              generation != _introGeneration ||
              !identical(_media, media)) {
            return;
          }
        }
        final controller = _intro ??= IntroController(store)
          ..addListener(_onOriginalIntroChanged);

        _introMedia = media;
        controller.bind(
          IntroRequest(
            episode: EpisodeIdentity(
              series: series,
              episode: (target?.chapterIndex ?? 0) + 1,
              season: (identity['season'] as num?)?.toInt() ?? 1,
              tmdb: (identity['tmdb'] as num?)?.toInt(),
              imdb: identity['imdb'] as String?,
              movie: identity['movie'] == true,
            ),
            uri: media.uri,
            durationMs: snapshot.duration.inMilliseconds,
            headers: _playbackRequestHeaders,
            playbackMetadata: player is IntroPlaybackMetadata
                ? (player as IntroPlaybackMetadata).introMetadata
                : null,
          ),
          (position) async {
            final active = _player;
            if (!mounted || !identical(_media, media) || active == null) {
              throw StateError('Playback changed before skip');
            }
            await active.seek(position);
          },
          deferQueries: true,
        );
        controller.update(
          _player?.snapshot.value ?? snapshot,
          foreground: _lifecycle == AppLifecycleState.resumed,
          pictureInPicture: _session?.state == PipState.active,
        );
        _refresh(() {});
      } catch (error) {
        LumeLog.warn('片头片尾初始化失败：${error.runtimeType}');
        if (mounted) _showToast('片头片尾识别暂不可用，仍可手动跳过');
      } finally {
        if (generation == _introGeneration) {
          _introOpening = false;
          // A media switch during initialization must not leave recognition bound
          // to the previous episode or permanently suppress the next bind.
          if (mounted && !identical(_media, media)) {
            final current = _player?.snapshot.value;
            if (current != null) _syncOriginalIntro(current);
          }
        }
      }
    }();
  }

  Future<void> _openOriginalIntro() async {
    final controller = _intro;
    if (controller == null) {
      _showToast('先打开视频并等待总时长可用');
      return;
    }
    _cancelAutoHide();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => IntroEpisodeSheet(
          controller: controller,
          position: () => _player?.snapshot.value.position ?? Duration.zero,
          onRebind: () {
            _introMedia = null;
            final snapshot = _player?.snapshot.value;
            if (snapshot != null) _syncOriginalIntro(snapshot);
          },
        ),
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  Widget _originalSkipPrompt() {
    final controller = _intro;
    if (controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final segment = controller.prompt;
        if (segment == null) return const SizedBox.shrink();
        final label = switch (segment.kind) {
          SegmentKind.opening => '片头',
          SegmentKind.ending => '片尾',
          SegmentKind.recap => '前情回顾',
          SegmentKind.preview => '下集预告',
          SegmentKind.main => '片段',
        };
        return Material(
          color: const Color(0xe6202022),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: controller.skipNow,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: Text(
                    '跳过$label${controller.store.value.autoSkip ? ' · ${controller.secondsLeft}s' : ''}',
                  ),
                ),
                IconButton(
                  tooltip: '取消本段跳过',
                  onPressed: controller.dismiss,
                  color: Colors.white,
                  icon: const LumeIcon(
                    Icons.close,
                    slot: 'video_player_intro.1',
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _originalSkipNow() {
    final controller = _intro;
    if (controller?.prompt != null) {
      unawaited(controller!.skipNow());
      return;
    }
    final snapshot = _player?.snapshot.value;
    if (snapshot == null) return;
    final position = snapshot.position.inMilliseconds;
    final segment = controller?.segments
        .where((s) => position >= s.startMs && position < s.endMs)
        .firstOrNull;
    if (segment != null) {
      unawaited(controller!.skipSegment(segment));
      return;
    }
    if (controller == null && !_skipMarks.isEmpty) {
      _maybeSkip(_skipMarks, snapshot.position, snapshot.duration);
      return;
    }
    _markSkipFromQuick(snapshot);
  }
}
