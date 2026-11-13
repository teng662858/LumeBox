import '../experience/clip_editor.dart';
import '../../core/experience/content_center.dart';
import '../../shared/widgets/native_glass_controls.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/glass_card.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/audio_book/audio_book_player.dart';
import '../../core/audio_book/audio_book_track.dart';
import '../../core/media/media_library.dart';

/// Pure audio surface. There is deliberately no video widget or TTS backend.
class AudioPlayerPage extends StatefulWidget {
  const AudioPlayerPage({
    super.key,
    required this.resource,
    required this.tracks,
    this.initialIndex,
    this.initialPosition,
    this.restart = false,
  });
  final MediaResource resource;
  final List<AudioBookTrack> tracks;
  final int? initialIndex;
  final Duration? initialPosition;
  final bool restart;
  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<AudioPlayerPage> {
  final session = AudioBookSession.instance;
  double? _drag;
  bool _starting = true;
  @override
  void initState() {
    super.initState();
    // Let the route paint before preparing a large chapter catalog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    try {
      await session.open(
        widget.resource,
        widget.tracks,
        index: widget.initialIndex,
        initialPosition: widget.initialPosition,
        restart: widget.restart,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  String _time(Duration time) =>
      '${time.inMinutes}:${(time.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => SettingsSurfaceScope(
    enabled: true,
    child: ModuleGlassScope(
      module: GlassModule.video,
      child: _legacyBuild(context),
    ),
  );
  Widget _legacyBuild(BuildContext context) => Scaffold(
    appBar: AppBar(
      flexibleSpace: const SizedBox.expand(),
      title: const Text('音频播放'),
      actions: [
        IconButton(
          tooltip: '保存听书书签',
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: () => saveContentClip(
            context,
            ContentRef(
              widget.resource.destination,
              '@audio-library',
              widget.resource.id,
              widget.resource.title,
            ),
            chapter: session.current,
            seconds: session.position.inSeconds,
          ),
        ),

        IconButton(
          tooltip: '音频播放器设置',
          icon: const LumeIcon(
            Icons.settings_outlined,
            slot: 'audio_book_page.1',
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const AudioPlaybackSettingsPage(),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final ownsSession = session.resource?.id == widget.resource.id;
          final busy = _starting || !ownsSession || session.loading;
          final failure = ownsSession ? session.error : null;
          final playing = !busy && session.playing;
          final current =
              (ownsSession ? session.current : widget.initialIndex ?? 0).clamp(
                0,
                widget.resource.episodes.isEmpty
                    ? 0
                    : widget.resource.episodes.length - 1,
              );
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            children: [
              Center(
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: widget.resource.cover == null
                      ? const LumeIcon(
                          Icons.headphones_rounded,
                          slot: 'audio_book_page.2',
                          size: 88,
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Image.network(
                            widget.resource.cover!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, error, stack) => const LumeIcon(
                              Icons.headphones_rounded,
                              slot: 'audio_book_page.3',
                              size: 88,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                widget.resource.title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (widget.resource.episodes.isNotEmpty)
                Text(
                  widget.resource.episodes[current].title,
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 20),
              if (busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  ownsSession ? session.loadingMessage : '正在准备播放器…',
                  textAlign: TextAlign.center,
                ),
              ],
              if (failure != null)
                Text(
                  failure,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              if (failure != null && !busy)
                TextButton.icon(
                  onPressed: session.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新加载'),
                ),
              ValueListenableBuilder<(Duration, Duration)>(
                valueListenable: session.progress,
                builder: (context, progress, _) {
                  final position = ownsSession ? progress.$1 : Duration.zero;
                  final total = ownsSession ? progress.$2 : Duration.zero;
                  final duration = busy ? 0.0 : total.inMilliseconds.toDouble();
                  return StatefulBuilder(
                    builder: (context, updateProgress) => Column(
                      children: [
                        NativeGlassSlider(
                          key: const Key('audio-book-seek'),
                          min: 0,
                          max: duration > 0 ? duration : 1,
                          value: (_drag ?? position.inMilliseconds.toDouble())
                              .clamp(0, duration > 0 ? duration : 1),
                          onChangeStart: duration > 0
                              ? (value) => updateProgress(() => _drag = value)
                              : null,
                          onChanged: duration > 0
                              ? (value) => updateProgress(() => _drag = value)
                              : null,
                          onChangeEnd: duration > 0
                              ? (value) async {
                                  await session.seek(
                                    Duration(milliseconds: value.round()),
                                  );
                                  if (mounted) {
                                    updateProgress(() => _drag = null);
                                  }
                                }
                              : null,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _time(
                                Duration(
                                  milliseconds:
                                      (_drag ??
                                              position.inMilliseconds
                                                  .toDouble())
                                          .round(),
                                ),
                              ),
                            ),
                            Text(_time(total)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一集',
                    onPressed: !busy && current > 0 ? session.previous : null,
                    icon: const LumeIcon(
                      Icons.skip_previous_rounded,
                      slot: 'audio_book_page.4',
                    ),
                    iconSize: 38,
                  ),
                  const SizedBox(width: 20),
                  IconButton.filled(
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: busy
                        ? null
                        : () => session.playing
                              ? session.pause()
                              : session.play(),
                    icon: LumeIcon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      slot: 'audio_book_page.5',
                      variant: true,
                    ),
                    iconSize: 48,
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    tooltip: '下一集',
                    onPressed:
                        !busy && current + 1 < widget.resource.episodes.length
                        ? session.next
                        : null,
                    icon: const LumeIcon(
                      Icons.skip_next_rounded,
                      slot: 'audio_book_page.6',
                    ),
                    iconSize: 38,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  PopupMenuButton<double>(
                    enabled: !busy,
                    tooltip: '播放倍速',
                    initialValue: AudioBookSettings.instance.speed,
                    onSelected: session.setSpeed,
                    itemBuilder: (_) => [
                      for (final rate in [
                        .5,
                        .75,
                        1.0,
                        1.25,
                        1.5,
                        1.75,
                        2.0,
                        2.5,
                        3.0,
                      ])
                        PopupMenuItem(value: rate, child: Text('$rate×')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('${AudioBookSettings.instance.speed}×'),
                    ),
                  ),
                  PopupMenuButton<int>(
                    enabled: !busy,
                    tooltip: '睡眠定时',
                    onSelected: (minutes) async {
                      session.setSleep(minutes);
                      AudioBookSettings.instance.sleepMinutes = minutes;
                      await AudioBookSettings.instance.save();
                    },
                    itemBuilder: (_) => [
                      for (final minutes in [0, 15, 30, 45, 60, 90])
                        PopupMenuItem(
                          value: minutes,
                          child: Text(minutes == 0 ? '关闭定时' : '$minutes 分钟后停止'),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        session.sleepAt == null
                            ? '睡眠定时'
                            : '${session.sleepAt!.hour.toString().padLeft(2, '0')}:${session.sleepAt!.minute.toString().padLeft(2, '0')} 停止',
                      ),
                    ),
                  ),
                  TextButton.icon(
                    icon: const LumeIcon(
                      Icons.queue_music,
                      slot: 'audio_book_page.7',
                    ),
                    label: const Text('选集'),
                    onPressed: busy ? null : () => _episodes(context),
                  ),
                ],
              ),
              TextButton(
                onPressed: busy ? null : session.stop,
                child: const Text('停止播放'),
              ),
            ],
          );
        },
      ),
    ),
  );
  Future<void> _episodes(BuildContext context) => showLumeBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: DrawerGeometry.height(context),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: widget.resource.episodes.length,
          itemBuilder: (context, index) => ListTile(
            selected: index == session.current,
            title: Text(widget.resource.episodes[index].title),
            onTap: () async {
              Navigator.pop(context);
              if (session.resource?.id == widget.resource.id) {
                await session.playChapter(index);
              }
            },
          ),
        ),
      ),
    ),
  );
}

class AudioPlaybackSettingsPage extends StatefulWidget {
  const AudioPlaybackSettingsPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<AudioPlaybackSettingsPage> createState() =>
      _AudioPlaybackSettingsPageState();
}

class _AudioPlaybackSettingsPageState extends State<AudioPlaybackSettingsPage> {
  final settings = AudioBookSettings.instance;
  @override
  void initState() {
    super.initState();
    unawaited(
      settings.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ModuleGlassScope(module: GlassModule.video, child: _legacyBuild(context));
  Widget _legacyBuild(BuildContext context) => Scaffold(
    appBar: widget.embedded
        ? null
        : AppBar(
            flexibleSpace: const SizedBox.expand(),
            title: const Text('音频播放器'),
          ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<AudioBookEngine>(
                initialValue: AudioBookEngine.justAudio,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '音频播放器'),
                items: const [
                  DropdownMenuItem(
                    value: AudioBookEngine.justAudio,
                    child: Text('just_audio（默认推荐）'),
                  ),
                  DropdownMenuItem(
                    value: AudioBookEngine.audioPlayers,
                    enabled: false,
                    child: Text('audioplayers（预留，暂不可用）'),
                  ),
                ],
                onChanged: (value) async {
                  if (value != AudioBookEngine.justAudio) return;
                  settings.engine = value!;
                  await settings.save();
                },
              ),
              const SizedBox(height: 20),
              const Text('用于音频文件和播放列表，支持倍速、定时关闭、后台与锁屏控制。'),
            ],
          ),
        ),
      ],
    ),
  );
}
