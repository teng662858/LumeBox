import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_service.dart';
import 'package:lume_box/core/music/music_session.dart';
import 'package:lume_box/core/session/section.dart';

class _Audio extends AudioBookSession {
  final entered = Completer<void>(), ready = Completer<void>();
  List<AudioBookTrack> tracks = [];
  @override
  Future<void> open(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
    Duration? initialPosition,
    bool restart = false,
  }) async {
    tracks = sources;
    resource = entry;
    current = index ?? 0;
    notifyListeners();
    entered.complete();
    await ready.future;
  }

  @override
  Future<void> playChapter(int index) async {
    current = index;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('music queue uses the existing audio owner, keeps IDs, loads URLs lazily and yields to books', () async {
    final root = await Directory.systemTemp.createTemp('lume-music-session-');
    final library = MusicLibrary(directory: root), audio = _Audio();
    final service = MusicService(library: library);
    final music = MusicSession(
      audio: audio,
      service: service,
      library: library,
    );
    const tracks = [
      MusicTrack(pluginId: 'one', id: 'same', title: 'One', artist: 'Artist'),
      MusicTrack(pluginId: 'two', id: 'same', title: 'Two'),
    ];
    try {
      final pending = music.play(tracks, index: 1);
      await audio.entered.future;
      expect(music.opening, true);
      expect(music.current?.title, 'Two');
      expect(audio.tracks.every((track) => track.music), true);
      expect(audio.tracks.first.artist, 'Artist');
      expect(audio.tracks.map((track) => track.id).toSet(), hasLength(2));
      expect(
        audio.tracks.every(
          (track) => track.initialMedia == null && track.resolve != null,
        ),
        true,
      );
      audio.ready.complete();
      await pending;
      expect(music.opening, false);
      await music.previous();
      expect(music.current?.title, 'One');
      await music.next();
      expect(music.current?.title, 'Two');
      final restored = MusicLibrary(directory: root);
      await restored.load();
      expect(
        restored.queue.map((track) => track.key),
        tracks.map((track) => track.key),
      );
      restored.dispose();
      audio.resource = const MediaResource(
        id: 'book',
        title: 'Book',
        kind: ResourceKind.audioBook,
        destination: Section.video,
        episodes: [],
      );
      audio.notifyListeners();
      expect(music.current, isNull);
      expect(MusicSession.visible.value, false);
    } finally {
      music.dispose();
      audio.dispose();
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      await library.save();
      library.dispose();
      MusicSession.visible.value = false;
      await root.delete(recursive: true);
    }
  });
}
