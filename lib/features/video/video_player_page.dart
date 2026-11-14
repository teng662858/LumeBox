import 'classic_video_player_page.dart';
import '../../shared/widgets/player_appearance_scope.dart';

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/native_video_bridge.dart';
import '../../core/player/pip.dart';
import '../../core/player/playback_session.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import 'native_video_source_session.dart';
import 'playback_source_validator.dart';
import 'player_speed_meter.dart';
import 'video_play_target.dart';

/// Both player appearances share the complete classic page and media state.
/// An explicitly injected bridge retains the standalone native host test port;
/// production navigation uses the shared page for both material choices.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    this.media,
    this.initialPosition,
    this.title,
    this.target,
    this.sourceId,
    this.qualities = const [],
    this.sourceManager,
    this.source,
    this.library,
    this.prelaunch,
    this.bridge,
    this.fullscreenOnly = true,
    this.playerFactory,
    this.catalog,
    this.pipBackend,
    this.brightnessBackend,
    this.playbackBackend,
    this.speedMeter,
    this.healthClock,
    this.sourceValidator,
    this.prepareMedia,
  });

  final PlayerMedia? media;
  final Duration? initialPosition;
  final String? title, sourceId;
  final VideoPlayTarget? target;
  final List<VideoQuality> qualities;
  final SourceManager? sourceManager;
  final DataSource? source;
  final ReadingLibrary? library;
  final PlayerPrelaunch? prelaunch;
  final NativeVideoBridge? bridge;
  final bool fullscreenOnly;
  // Constructor compatibility for existing launchers. Native playback never
  // constructs any of the removed Flutter player implementations from these.
  final AbstractPlayer? Function(PlayerKernel)? playerFactory;
  final PlayerKernelCatalog? catalog;
  final PipBackend? pipBackend;
  final BrightnessBackend? brightnessBackend;
  final PlaybackSessionBackend? playbackBackend;
  final PlaybackSpeedMeter? speedMeter;
  final DateTime Function()? healthClock;
  final PlaybackSourceValidator? sourceValidator;
  final Future<PlayerMedia> Function(PlayerMedia, bool)? prepareMedia;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  NativeVideoSourceSession? _session;
  final _address = TextEditingController();
  String? _error;
  bool _opening = false, _disposed = false, _presented = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.bridge != null && widget.media != null) {
        unawaited(_open(widget.media!));
      }
    });
  }

  Future<void> _open(PlayerMedia media) async {
    if (_opening || _disposed) return;
    if (!Platform.isIOS && widget.bridge == null) {
      await widget.prelaunch?.discard();
      if (mounted) setState(() => _error = '原生视频播放仅支持 iOS');
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await widget.prelaunch?.discard();
      final library =
          widget.library ??
          ReadingLibrary.find(Section.video) ??
          await ReadingLibrary.open(Section.video);
      if (_disposed) return;
      final session = NativeVideoSourceSession(
        media: media,
        initialPosition: widget.initialPosition,
        library: library,
        target: widget.target,
        source: widget.source,
        manager: widget.sourceManager ?? LumeSources.manager(library.section),
        qualities: widget.qualities,
        bridge: widget.bridge,
        prepareMedia: widget.prepareMedia,
      );
      _session = session;
      await session.open();
      if (mounted) setState(() => _presented = true);
      await session.finished;
      await session.close();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      if (!mounted || _disposed) return;
      if (widget.media != null && ModalRoute.of(context)?.isCurrent == true) {
        await Navigator.of(context).maybePop();
      }
    } catch (error) {
      await _session?.close();
      if (mounted) setState(() => _error = '原生播放页未能打开：$error');
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _presented = false;
        });
      }
    }
  }

  void _openAddress() {
    final uri = Uri.tryParse(_address.text.trim());
    if (uri == null || !uri.hasScheme) {
      setState(() => _error = '请输入完整媒体地址');
      return;
    }
    unawaited(_open(PlayerMedia(uri: uri)));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_session?.close());
    // The shared player owns its prelaunch; only the standalone bridge discards here.
    if (widget.bridge != null) unawaited(widget.prelaunch?.discard());
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.bridge == null
      ? PlayerAppearanceScope(
          child: ClassicVideoPlayerPage(
            managePlaybackFocus: widget.playerFactory == null,
            media: widget.media,
            initialPosition: widget.initialPosition,
            title: widget.title,
            target: widget.target,
            sourceId: widget.sourceId,
            qualities: widget.qualities,
            sourceManager: widget.sourceManager,
            source: widget.source,
            library: widget.library,
            prelaunch: widget.prelaunch,
            fullscreenOnly: widget.fullscreenOnly,
            playerFactory: widget.playerFactory,
            catalog: widget.catalog,
            pipBackend: widget.pipBackend,
            brightnessBackend: widget.brightnessBackend,
            playbackBackend: widget.playbackBackend,
            speedMeter: widget.speedMeter,
            healthClock: widget.healthClock,
            sourceValidator: widget.sourceValidator,
          ),
        )
      : Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(widget.title ?? '播放'),
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_opening && !_presented)
                      const CircularProgressIndicator(),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _opening
                            ? null
                            : widget.media == null
                            ? _openAddress
                            : () => _open(widget.media!),
                        child: const Text('重试'),
                      ),
                    ],
                    if (!_opening && widget.media == null) ...[
                      TextField(
                        controller: _address,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(labelText: '媒体地址'),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _openAddress,
                        child: const Text('打开原生播放器'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
}
