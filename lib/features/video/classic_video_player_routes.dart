part of 'classic_video_player_page.dart';

extension _RouteTools on _ClassicVideoPlayerPageState {
  LinePerformance? _performance(VideoPlayTarget target) => _library == null
      ? null
      : _linePerformanceCache.putIfAbsent(
          target.identity,
          () => LinePerformance(_library!, target.identity),
        );

  Future<List<PlayerSourceLine>> _rankedLines(VideoPlayTarget target) async {
    final source = await _openSource();
    if (source == null) throw StateError('图源不可用');
    final all = await VideoEpisodeCatalog.load(source, target.itemId);
    final current = all.where((c) => c.id == target.chapterId).firstOrNull;
    final groups = VideoEpisodeCatalog.group(all);
    final performance = _performance(target);
    final original = groups.keys.toList();
    final names = [...original]
      ..sort((a, b) {
        final score = performance?.compare(a, b) ?? 0;
        return score != 0
            ? score
            : original.indexOf(a).compareTo(original.indexOf(b));
      });
    return [
      for (final name in names)
        PlayerSourceLine(
          name,
          current:
              current != null && name == VideoEpisodeCatalog.lineOf(current),
          available:
              current != null &&
              VideoEpisodeCatalog.matchingIndex(current, groups[name]!) >= 0,
          detail: performance?.describe(name),
        ),
    ];
  }

  Future<void> _benchmarkLines(VideoPlayTarget target) async {
    if (_benchmarkMeter != null) return;
    final meter = _benchmarkMeter = PlaybackSpeedMeter();
    try {
      final source = await _openSource();
      if (source == null) throw StateError('图源不可用');
      final all = await VideoEpisodeCatalog.load(source, target.itemId);
      final current = all.where((c) => c.id == target.chapterId).firstOrNull;
      if (current == null) return;
      final groups = VideoEpisodeCatalog.group(all);
      // Probe serially; never allocate extra native players/decoders.
      for (final entry in groups.entries) {
        if (!mounted ||
            _target?.isSameEpisode(target) != true ||
            !identical(_benchmarkMeter, meter)) {
          return;
        }
        final index = VideoEpisodeCatalog.matchingIndex(current, entry.value);
        if (index < 0) continue;
        try {
          final content = await source
              .content(itemId: target.itemId, chapterId: entry.value[index].id)
              .timeout(const Duration(seconds: 12));
          if (!mounted ||
              _target?.isSameEpisode(target) != true ||
              !identical(_benchmarkMeter, meter)) {
            return;
          }
          final qualities = SourcePlayback.contentQualities(
            content,
            source: source,
          );
          final selected = PlaybackQualityPreference.select(
            qualities,
            _settings,
          );
          final uri = selected?.url ?? SourcePlayback.contentAddress(content);
          if (uri == null || !['http', 'https'].contains(uri.scheme)) continue;
          await meter.measure(
            uri,
            force: true,
            headers:
                selected?.headers ??
                SourcePlayback.contentHeaders(content, source: source),
          );
          if (!mounted ||
              _target?.isSameEpisode(target) != true ||
              !identical(_benchmarkMeter, meter)) {
            return;
          }
          _performance(target)?.record(
            entry.key,
            kbps: meter.kbps.value,
            failed: meter.failed.value,
          );
        } catch (_) {
          if (mounted &&
              _target?.isSameEpisode(target) == true &&
              identical(_benchmarkMeter, meter)) {
            _performance(target)?.record(entry.key, failed: true);
          }
        }
      }
    } finally {
      if (identical(_benchmarkMeter, meter)) {
        _benchmarkMeter = null;
        meter.dispose();
      }
    }
  }

  Future<void> _recordLineStartup(
    VideoPlayTarget target,
    int milliseconds,
  ) async {
    try {
      final source = await _openSource();
      if (source == null || !mounted) return;
      final all = await VideoEpisodeCatalog.load(source, target.itemId);
      final current = all.where((c) => c.id == target.chapterId).firstOrNull;
      if (current != null &&
          mounted &&
          _target?.isSameEpisode(target) == true) {
        _performance(
          target,
        )?.record(VideoEpisodeCatalog.lineOf(current), startupMs: milliseconds);
      }
    } catch (_) {
      /* Telemetry never blocks playback. */
    }
  }

  Future<void> _recoverAlternative({bool stalled = false}) async {
    if (_autoRecovering ||
        _kernelFallbackInFlight ||
        (!stalled && _player?.snapshot.value.error == null) ||
        _switchingQuality ||
        _advancing ||
        _recoveringPlayback ||
        !ContentCenter.instance.enabled('autoRecover', fallback: true)) {
      return;
    }
    final target = _target;
    if (target == null) return;
    final error = _player?.snapshot.value.error?.toLowerCase() ?? '';
    if ([
          PlaybackFailureKind.login,
          PlaybackFailureKind.membership,
          PlaybackFailureKind.forbidden,
        ].contains(PlaybackFailure.from(error).kind) ||
        ([
              PlayerKernel.avplayer,
              PlayerKernel.aether,
            ].contains(_settings.kernel) &&
            !_rangeFallbackAttempted &&
            _catalog.isAvailable(PlayerKernel.mpv) &&
            PlayerErrorText.needsAlternativeKernel(error))) {
      return;
    }
    _autoRecovering = true;
    var attempted = false;
    try {
      final source = await _openSource();
      if (source == null || !mounted) return;
      final all = await VideoEpisodeCatalog.load(source, target.itemId);
      if (!mounted || _target?.isSameEpisode(target) != true) return;
      final current = all.where((c) => c.id == target.chapterId).firstOrNull;
      if (current == null) return;
      final episode =
          '${target.identity}:${VideoEpisodeCatalog.episodeKey(current) ?? VideoEpisodeCatalog.labelOf(current)}:';
      final currentLine = VideoEpisodeCatalog.lineOf(current);
      _performance(target)?.record(currentLine, failed: true);
      _recoveryLines.add('$episode$currentLine');
      if (_recoveryLines.where((key) => key.startsWith(episode)).length > 3) {
        return;
      }
      final candidates = (await _rankedLines(target))
          .where(
            (line) =>
                line.available &&
                !line.current &&
                !_recoveryLines.contains('$episode${line.name}'),
          )
          .toList();
      if (!mounted ||
          _target?.isSameEpisode(target) != true ||
          candidates.isEmpty) {
        return;
      }
      final line = candidates.first.name;
      _recoveryLines.add('$episode$line');
      _showToast('${stalled ? '播放持续卡住' : '播放失败'}，正在换到 $line');
      attempted = true;
      await _offerAlternativeLines(selectedLine: line);
    } catch (_) {
      if (mounted) _showToast('自动换线未成功，可手动换线或重试');
    } finally {
      _autoRecovering = false;
      if (mounted && attempted && _player?.snapshot.value.error != null) {
        scheduleMicrotask(() => _recoverAlternative());
      }
    }
  }

  void _switchAvPlayerToMpv(String message) {
    _rangeFallbackAttempted = true;
    _kernelFallbackInFlight = true;
    final player = _player;
    final media = _media;
    scheduleMicrotask(() async {
      try {
        if (!mounted ||
            !identical(player, _player) ||
            !identical(media, _media) ||
            ![
              PlayerKernel.avplayer,
              PlayerKernel.aether,
            ].contains(_settings.kernel)) {
          return;
        }
        _showToast(message);
        await _applySettings(
          _settings.copyWith(kernel: PlayerKernel.mpv),
          autoPlayAfterKernelSwitch: true,
        );
      } finally {
        _kernelFallbackInFlight = false;
        if (mounted && _player?.snapshot.value.error != null) {
          unawaited(_recoverAlternative());
        }
      }
    });
  }

  void _checkPlaybackStall(PlayerSnapshot snapshot) {
    final target = _target;
    final eligible =
        target != null &&
        _loaded &&
        (snapshot.playing || snapshot.buffering) &&
        snapshot.error == null &&
        _lifecycle == AppLifecycleState.resumed &&
        !_switchingQuality &&
        !_advancing &&
        !_recoveringPlayback &&
        !_autoRecovering &&
        _operation == null &&
        _committedSeekTarget == null &&
        !_scrubSeekInFlight &&
        (snapshot.duration <= Duration.zero ||
            snapshot.position < snapshot.duration - const Duration(seconds: 3));
    final now = widget.healthClock?.call() ?? DateTime.now();
    final stats = _player?.stats.value;
    if (eligible &&
        snapshot.playing &&
        !snapshot.buffering &&
        _settings.kernel == PlayerKernel.avplayer &&
        stats?.firstFrameReady == false &&
        (stats?.width ?? 0) > 0 &&
        _session?.state != PipState.active &&
        _session?.state != PipState.entering &&
        !_rangeFallbackAttempted &&
        _catalog.isAvailable(PlayerKernel.mpv) &&
        ContentCenter.instance.enabled('autoRecover', fallback: true)) {
      final previous = _missingFramePosition;
      if (previous == null || snapshot.position <= previous) {
        _missingFrameSince = now;
      }
      _missingFramePosition = snapshot.position;
      if (_missingFrameSince != null &&
          now.difference(_missingFrameSince!) >= const Duration(seconds: 15)) {
        PlaybackDiagnostics.record(
          'visible-first-frame-timeout',
          source: target.sourceId,
          kernel: _settings.kernel.name,
          uri: _media?.uri,
        );
        _switchAvPlayerToMpv('AVPlayer 播放进度在走，但没有输出画面，正在切换 MPV');
        return;
      }
    } else {
      _missingFrameSince = null;
      _missingFramePosition = null;
    }
    if (_stallGuard.observe(
      '${target?.identity}:${target?.chapterId}',
      snapshot,
      now,
      eligible: eligible,
    )) {
      if (snapshot.position < const Duration(seconds: 1) &&
          (stats?.buffered ?? Duration.zero) >= const Duration(seconds: 5) &&
          [
            PlayerKernel.avplayer,
            PlayerKernel.aether,
          ].contains(_settings.kernel) &&
          !_rangeFallbackAttempted &&
          _catalog.isAvailable(PlayerKernel.mpv) &&
          ContentCenter.instance.enabled('autoRecover', fallback: true)) {
        PlaybackDiagnostics.record(
          'buffered-startup-stalled',
          source: target?.sourceId,
          kernel: _settings.kernel.name,
          uri: _media?.uri,
        );
        _switchAvPlayerToMpv('已有缓冲但未开始播放，正在尝试 MPV');
        return;
      }
      unawaited(_recoverAlternative(stalled: true));
    }
  }
}
