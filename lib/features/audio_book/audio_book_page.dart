import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/module_glass_scope.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/audio_book/audio_book_player.dart';
import '../../core/audio_book/audio_book_track.dart';
import '../../core/media/media_library.dart';

/// Pure audio surface. There is deliberately no video widget or TTS backend.
class AudioBookPage extends StatefulWidget {
  const AudioBookPage({
    super.key,
    required this.resource,
    required this.tracks,
    this.initialIndex,
  });
  final MediaResource resource;
  final List<AudioBookTrack> tracks;
  final int? initialIndex;
  @override
  State<AudioBookPage> createState() => _AudioBookPageState();
}

class _AudioBookPageState extends State<AudioBookPage> {
  final session = AudioBookSession.instance;
  double? _drag;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    if (session.resource?.id != widget.resource.id) {
      await session.load(
        widget.resource,
        widget.tracks,
        index: widget.initialIndex,
      );
      if (session.error == null && session.resource?.id == widget.resource.id) {
        unawaited(session.play());
      }
    } else if (widget.initialIndex != null) {
      await session.load(
        widget.resource,
        widget.tracks,
        index: widget.initialIndex,
      );
      unawaited(session.play());
    }
  }

  String _time(Duration time) =>
      '${time.inMinutes}:${(time.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => ModuleGlassScope(
    module: GlassModule.audioBook,
    child: _legacyBuild(context),
  );
  Widget _legacyBuild(BuildContext context) => Scaffold(
    appBar: AppBar(
      flexibleSpace: const SizedBox.expand(),
      title: const Text('有声小说'),
      actions: [
        IconButton(
          tooltip: '音频播放器设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const AudioBookSettingsPage(),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final duration = session.duration.inMilliseconds.toDouble();
          final current = session.current.clamp(
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
                      ? const Icon(Icons.headphones_rounded, size: 88)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Image.network(
                            widget.resource.cover!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, error, stack) =>
                                const Icon(Icons.headphones_rounded, size: 88),
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
              if (session.loading) const LinearProgressIndicator(),
              if (session.error != null)
                Text(
                  session.error!,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              Slider(
                key: const Key('audio-book-seek'),
                min: 0,
                max: duration > 0 ? duration : 1,
                value: (_drag ?? session.position.inMilliseconds.toDouble())
                    .clamp(0, duration > 0 ? duration : 1),
                onChangeStart: duration > 0
                    ? (value) => setState(() => _drag = value)
                    : null,
                onChanged: duration > 0
                    ? (value) => setState(() => _drag = value)
                    : null,
                onChangeEnd: duration > 0
                    ? (value) async {
                        await session.seek(
                          Duration(milliseconds: value.round()),
                        );
                        if (mounted) setState(() => _drag = null);
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
                                    session.position.inMilliseconds.toDouble())
                                .round(),
                      ),
                    ),
                  ),
                  Text(_time(session.duration)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一集',
                    onPressed: session.current > 0 ? session.previous : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                    iconSize: 38,
                  ),
                  const SizedBox(width: 20),
                  IconButton.filled(
                    tooltip: session.playing ? '暂停' : '播放',
                    onPressed: session.loading
                        ? null
                        : () => session.playing
                              ? session.pause()
                              : session.play(),
                    icon: Icon(
                      session.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    iconSize: 48,
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    tooltip: '下一集',
                    onPressed:
                        session.current + 1 < widget.resource.episodes.length
                        ? session.next
                        : null,
                    icon: const Icon(Icons.skip_next_rounded),
                    iconSize: 38,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  PopupMenuButton<double>(
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
                    icon: const Icon(Icons.queue_music),
                    label: const Text('选集'),
                    onPressed: () => _episodes(context),
                  ),
                ],
              ),
              TextButton(onPressed: session.stop, child: const Text('停止播放')),
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
              await session.seek(Duration.zero, index: index);
              unawaited(session.play());
            },
          ),
        ),
      ),
    ),
  );
}

class AudioBookSettingsPage extends StatefulWidget {
  const AudioBookSettingsPage({super.key});
  @override
  State<AudioBookSettingsPage> createState() => _AudioBookSettingsPageState();
}

class _AudioBookSettingsPageState extends State<AudioBookSettingsPage> {
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
  Widget build(BuildContext context) => ModuleGlassScope(
    module: GlassModule.audioBook,
    child: _legacyBuild(context),
  );
  Widget _legacyBuild(BuildContext context) => Scaffold(
    appBar: AppBar(
      flexibleSpace: const SizedBox.expand(),
      title: const Text('有声小说播放器'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
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
        const Text('成品音频直接播放原始内容。文字小说的朗读模式在阅读器听书设置中选择。'),
      ],
    ),
  );
}
