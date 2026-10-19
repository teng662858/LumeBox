part of 'reference_player_page.dart';

extension _ReferenceChrome on _ReferencePlayerPageState {
  void _saveReferenceSettings(PlayerSettings settings) =>
      _store?.save(settings, preferredKernel: _preferredReferenceKernel);
  void _referenceRecoverKernel(PlayerSnapshot snapshot) {
    if (!_experience.autoKernelSwitch ||
        _switchingAfterError ||
        !_failedPlaybackKernels.add(_settings.kernel)) {
      return;
    }
    final failedPlayer = _player;
    final next = PlayerKernel.values
        .where(
          (kernel) =>
              !_failedPlaybackKernels.contains(kernel) &&
              _catalog.isAvailable(kernel),
        )
        .firstOrNull;
    if (next == null) return;
    _switchingAfterError = true;
    scheduleMicrotask(() async {
      try {
        if (!mounted || !identical(_player, failedPlayer)) return;
        _showToast('当前内核报错，正在尝试 ${next.label}');
        await _applySettings(_settings.copyWith(kernel: next));
        if (mounted && _player?.snapshot.value.error == null) {
          await _player?.play();
        }
      } finally {
        _switchingAfterError = false;
        final snapshot = _player?.snapshot.value;
        if (mounted && snapshot?.error != null) {
          _referenceRecoverKernel(snapshot!);
        }
      }
    });
  }

  void _onReferenceIntroChanged() => _refresh(() {});

  void _syncReferenceIntro(PlayerSnapshot snapshot) {
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
          ..addListener(_onReferenceIntroChanged);

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
            if (current != null) _syncReferenceIntro(current);
          }
        }
      }
    }();
  }

  Future<void> _openReferenceIntro() async {
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
            if (snapshot != null) _syncReferenceIntro(snapshot);
          },
        ),
      ),
    );
    if (mounted) _scheduleAutoHide();
  }

  Widget _referenceSkipPrompt() {
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
                    slot: 'reference_player_chrome.1',
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

  void _referenceSkipNow() {
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

  void _restoreReferenceBrightness(VideoPlayTarget? target) {
    final saved = target == null
        ? null
        : _experienceStore?.brightnessFor(target.sourceId, target.itemId);
    _restoredReferenceBrightness =
        saved != null && _experience.rememberBrightness;
    if (_restoredReferenceBrightness) {
      _brightness = saved!;
      if (_systemBrightness) unawaited(_brightnessBackend.setBrightness(saved));
    }
  }

  Future<void> _loadReferenceDetails(VideoPlayTarget? target) async {
    if (target == null) return;
    try {
      final source = await _openSource();
      if (source == null) return;
      final results = await Future.wait<Object?>([
        source.detail(target.itemId),
        source.chapters(target.itemId),
      ]);
      if (!mounted || !(_target?.isSameEpisode(target) ?? false)) return;
      _refresh(() {
        _referenceDetail = results[0] as SourceDetail?;
        _referenceChapters = results[1] as List<SourceChapter>;
      });
    } catch (_) {
      /* playback and its source-selection recovery remain available */
    }
  }

  Future<void> _startReferenceLog(PlayerMedia media) async {
    final sequence = ++_logSequence;
    _playLog?.close();
    _playLog = null;
    if (!_experience.logging(_settings.kernel.id)) return;
    try {
      final logs = await PlaybackLogs.open();
      if (mounted && sequence == _logSequence && identical(_media, media)) {
        _playLog = logs.start(_settings.kernel.id, media.uri);
      }
    } catch (_) {
      _showToast('播放日志无法写入，播放继续');
    }
  }

  Future<DandanplayCredentials> _referenceDanmakuCredentials() async {
    try {
      final data = await DanmakuSourcesStore.read();
      return DandanplayCredentials(
        data['appId'] ?? '',
        data['appSecret'] ?? '',
        baseUrl: data['baseUrl'] ?? DandanplayCredentials.defaultBase,
      );
    } catch (_) {
      return const DandanplayCredentials('', '');
    }
  }

  Widget _buildImmersiveTopBar() => _experience.flag('referenceChrome', true)
      ? _referenceTopBar()
      : _buildLegacyImmersiveTopBar();
  Widget _buildFloatingControls() => _experience.flag('referenceChrome', true)
      ? _referenceBottomBar()
      : _buildLegacyFloatingControls();
  Widget _referenceAction(String id) {
    final (label, icon, action) = switch (id) {
      'kernel' => (_settings.kernel.label, Icons.memory, _openKernelPicker),
      'decode' => (
        _settings.hardwareDecoding ? '硬解' : '软解',
        Icons.developer_board,
        () => _applySettings(
          _settings.copyWith(hardwareDecoding: !_settings.hardwareDecoding),
        ),
      ),
      'intro' => ('片头', Icons.first_page, _openReferenceIntro),
      'outro' => ('片尾', Icons.last_page, _openReferenceIntro),
      'skip' => ('跳过', Icons.skip_next, _referenceSkipNow),
      'pip' => ('画中画', Icons.picture_in_picture_alt, _togglePip),
      'fullscreen' => (
        '全屏',
        Icons.fullscreen,
        () => _setFullscreen(!_fullscreen),
      ),
      'speed' => ('倍速', Icons.speed, _showSpeedPicker),
      'subtitle' => ('字幕', Icons.subtitles_outlined, _pickSubtitleTrack),
      'audio' => ('音轨', Icons.audiotrack, _pickAudioTrack),
      'danmaku' => ('弹幕', Icons.comment_outlined, _openDanmakuSettings),
      'quality' => ('画质', Icons.high_quality_outlined, _openQualityMenu),
      'ratio' => ('比例', Icons.aspect_ratio, _openSettings),
      'picture' => ('画面', Icons.tune, _openSettings),
      'info' => ('信息', Icons.info_outline, _openSettings),
      'episodes' => ('选集', Icons.playlist_play, _openSourceSheet),
      'comment' => (
        '评论',
        Icons.forum_outlined,
        () => _showToast('参考播放器的评论服务尚未接入'),
      ),
      'cast' => ('投屏', Icons.cast, () => _showToast('参考播放器的 DLNA 设备发现尚未接入')),
      'airplay' => (
        'AirPlay',
        Icons.airplay,
        () => _showToast('参考播放器的系统 AirPlay 路由入口尚未接入'),
      ),
      _ => (
        PlayerButtonLayout.labels[id] ?? id,
        Icons.more_horiz,
        _openSettings,
      ),
    };
    return TextButton(
      onPressed: () {
        action();
        _scheduleAutoHide();
      },
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(44, 44),
      ),
      child: _settings.controlStyle == PlayerControlStyle.text
          ? Text(
              label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            )
          : Tooltip(
              message: label,
              child: LumeIcon(
                icon,
                slot: 'reference_player_chrome.2',
                variant: true,
                size: 22,
              ),
            ),
    );
  }

  Widget _referenceTopBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(
      children: [
        IconButton(
          tooltip: '关闭播放器',
          color: Colors.white,
          icon: const LumeIcon(Icons.close, slot: 'reference_player_chrome.3'),
          onPressed: () => Navigator.maybePop(context),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _target?.mediaTitle ?? widget.title ?? '播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                ),
              ),
              if (_player != null)
                ValueListenableBuilder<PlayerStats>(
                  valueListenable: _player!.stats,
                  builder: (_, stats, _) => Text(
                    '${stats.width ?? "—"}×${stats.height ?? "—"}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _experience.layout.top.map(_referenceAction).toList(),
            ),
          ),
        ),
        IconButton(
          tooltip: '播放设置',
          color: Colors.white,
          icon: const LumeIcon(
            Icons.more_horiz,
            slot: 'reference_player_chrome.4',
          ),
          onPressed: _openSettings,
        ),
      ],
    ),
  );
  Widget _referenceBottomBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: ValueListenableBuilder<PlayerSnapshot>(
      valueListenable: _player?.snapshot ?? _idleSnapshot,
      builder: (context, snapshot, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _referenceProgress(snapshot),
          Row(
            children: [
              for (final action in <(IconData, String, VoidCallback)>[
                (
                  Icons.replay_10,
                  '后退 10 秒',
                  () => _seekBy(const Duration(seconds: -10)),
                ),
                (
                  snapshot.playing ? Icons.pause : Icons.play_arrow,
                  snapshot.playing ? '暂停' : '播放',
                  () => unawaited(
                    snapshot.playing ? _player?.pause() : _player?.play(),
                  ),
                ),
                (
                  Icons.forward_10,
                  '前进 10 秒',
                  () => _seekBy(const Duration(seconds: 10)),
                ),
                (
                  Icons.skip_previous,
                  '上一集',
                  () => _playEpisodeAt((_target?.chapterIndex ?? 0) - 1),
                ),
                (
                  Icons.skip_next,
                  '下一集',
                  () => _playEpisodeAt((_target?.chapterIndex ?? 0) + 1),
                ),
              ])
                IconButton(
                  tooltip: action.$2,
                  color: Colors.white,
                  icon: LumeIcon(
                    action.$1,
                    slot: 'reference_player_chrome.5',
                    variant: true,
                  ),
                  onPressed: _player == null ? null : action.$3,
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _experience.layout.bottom
                        .map(_referenceAction)
                        .toList(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _referenceProgress(PlayerSnapshot snapshot) {
    final total = snapshot.duration.inMilliseconds;
    final position = (_previewTarget ?? snapshot.position).inMilliseconds
        .clamp(0, math.max(0, total))
        .toInt();
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            _format(Duration(milliseconds: position)),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Colors.white,
              thumbColor: Colors.white,
              inactiveTrackColor: Colors.white30,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: total <= 0 ? 0 : position / total,
              onChangeStart: (_) => _cancelAutoHide(),
              onChanged: total <= 0
                  ? null
                  : (value) => _refresh(
                      () => _previewTarget = Duration(
                        milliseconds: (value * total).round(),
                      ),
                    ),
              onChangeEnd: total <= 0
                  ? null
                  : (value) async {
                      try {
                        await _player?.seek(
                          Duration(milliseconds: (value * total).round()),
                        );
                      } finally {
                        _refresh(() => _previewTarget = null);
                        _scheduleAutoHide();
                      }
                    },
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            _format(snapshot.duration),
            textAlign: TextAlign.end,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _referencePortrait() => Scaffold(
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    body: SafeArea(
      child: Column(
        children: [
          Container(
            color: Colors.black,
            height: MediaQuery.sizeOf(context).height * .31,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildStage(_player),
                if (!_locked)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _referenceTopBar(),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: _locked ? '解除锁定' : '锁定',
                    color: Colors.white,
                    icon: LumeIcon(
                      _locked ? Icons.lock : Icons.lock_open,
                      slot: 'reference_player_chrome.6',
                      variant: true,
                    ),
                    onPressed: () => _refresh(() => _locked = !_locked),
                  ),
                ),
                if (!_locked)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 0,
                    child: ValueListenableBuilder<PlayerSnapshot>(
                      valueListenable: _player?.snapshot ?? _idleSnapshot,
                      builder: (context, snapshot, _) => Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            tooltip: '播放／暂停',
                            icon: LumeIcon(
                              snapshot.playing ? Icons.pause : Icons.play_arrow,
                              slot: 'reference_player_chrome.7',
                              variant: true,
                            ),
                            onPressed: () => unawaited(
                              snapshot.playing
                                  ? _player?.pause()
                                  : _player?.play(),
                            ),
                          ),
                          Expanded(child: _referenceProgress(snapshot)),
                          IconButton(
                            color: Colors.white,
                            tooltip: '全屏',
                            icon: const LumeIcon(
                              Icons.fullscreen,
                              slot: 'reference_player_chrome.8',
                            ),
                            onPressed: () => _setFullscreen(true),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((_referenceDetail?.cover ?? _target?.cover) != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.network(
                          _referenceDetail?.cover ?? _target!.cover!,
                          width: 96,
                          height: 136,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const SizedBox(width: 96, height: 136),
                        ),
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _referenceDetail?.title ??
                                _target?.title ??
                                widget.title ??
                                '视频',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (_referenceDetail?.subtitle != null)
                            Text(_referenceDetail!.subtitle!),
                          if (_referenceDetail?.description != null)
                            Text(
                              _referenceDetail!.description!,
                              maxLines: _referenceDetailsCollapsed ? 3 : 8,
                              overflow: TextOverflow.ellipsis,
                            ),
                          TextButton(
                            onPressed: () => _refresh(
                              () => _referenceDetailsCollapsed =
                                  !_referenceDetailsCollapsed,
                            ),
                            child: Text(
                              _referenceDetailsCollapsed ? '展开简介' : '收起简介',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton.icon(
                      onPressed: _openReferenceIntro,
                      icon: const LumeIcon(
                        Icons.skip_next,
                        slot: 'reference_player_chrome.9',
                      ),
                      label: const Text('片头片尾'),
                    ),
                    TextButton.icon(
                      onPressed: _openSettings,
                      icon: const LumeIcon(
                        Icons.tune,
                        slot: 'reference_player_chrome.10',
                      ),
                      label: const Text('播放设置'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text('选集', style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    TextButton(
                      onPressed: _openQualityMenu,
                      child: const Text('画质'),
                    ),
                    TextButton(
                      onPressed: _openSourceSheet,
                      child: const Text('线路／选集'),
                    ),
                  ],
                ),
                if (_referenceChapters.isNotEmpty)
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _referenceChapters.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.8,
                        ),
                    itemBuilder: (context, i) => FilledButton.tonal(
                      onPressed: () => _playEpisodeAt(i),
                      style: FilledButton.styleFrom(
                        backgroundColor: i == _target?.chapterIndex
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      child: Text(
                        _referenceChapters[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
