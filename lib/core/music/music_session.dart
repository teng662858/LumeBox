import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio_book/audio_book_player.dart';
import '../audio_book/audio_book_track.dart';
import '../media/media_library.dart';
import '../session/section.dart';
import 'music_library.dart';
import 'music_models.dart';
import 'music_service.dart';

/// Share the existing audio owner: just_audio_background supports one player.
class MusicSession extends ChangeNotifier {
  MusicSession({
    AudioBookSession? audio,
    MusicService? service,
    MusicLibrary? library,
  }) : audio = audio ?? AudioBookSession.instance,
       service = service ?? MusicService.instance,
       library = library ?? MusicLibrary.instance {
    this.audio.addListener(_changed);
  }
  static final instance = MusicSession();
  static final visible = ValueNotifier<bool>(false);
  static const resourceId = 'lumebox:music:queue';
  final AudioBookSession audio;
  final MusicService service;
  final MusicLibrary library;
  List<MusicTrack> _queue = [];
  List<MusicTrack> get queue => List.unmodifiable(_queue);
  bool get active => audio.resource?.id == resourceId;
  MusicTrack? get current =>
      active && audio.current < _queue.length && audio.current >= 0
      ? _queue[audio.current]
      : null;
  String? _last;
  String? error;
  bool opening = false;
  int _request = 0;
  void _changed() {
    final track = current;
    visible.value = track != null;
    if (track != null &&
        track.key != _last &&
        !audio.loading &&
        audio.error == null) {
      _last = track.key;
      unawaited(library.remember(track).catchError((Object _) {}));
    }
    notifyListeners();
  }

  Future<void> play(List<MusicTrack> tracks, {int index = 0}) async {
    if (tracks.isEmpty) return;
    final snapshot = List<MusicTrack>.of(tracks);
    final request = ++_request;
    error = null;
    opening = true;
    notifyListeners();
    try {
      await library.load();
      if (request != _request) return;
      library.queue
        ..clear()
        ..addAll(snapshot);
      await library.save();
      if (request != _request) return;
      _queue = snapshot;
      final episodes = [
        for (final t in _queue) ResourceEpisode(id: t.key, title: t.title),
      ];
      // Music always starts at normal speed. Book speed remains a book setting.
      await audio.open(
        MediaResource(
          id: resourceId,
          title: '音乐',
          kind: ResourceKind.audioBook,
          destination: Section.video,
          episodes: episodes,
        ),
        [
          for (var i = 0; i < _queue.length; i++)
            AudioBookTrack(
              id: 'music:${_queue[i].key}',
              episode: episodes[i],
              album: _queue[i].album.isEmpty ? '音乐' : _queue[i].album,
              artist: _queue[i].artist,
              cover: _queue[i].cover,
              music: true,
              resolve: () => service.resolve(snapshot[i]),
            ),
        ],
        index: index.clamp(0, _queue.length - 1),
        restart: true,
      );
    } catch (e) {
      if (request == _request) error = '$e';
    }
    if (request == _request) opening = false;
    notifyListeners();
  }

  Future<void> toggle() => audio.playing ? audio.pause() : audio.play();
  Future<void> select(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await audio.playChapter(index);
  }

  Future<void> next() => select(audio.current + 1);
  Future<void> previous() => select(audio.current - 1);
  @override
  void dispose() {
    audio.removeListener(_changed);
    super.dispose();
  }
}
