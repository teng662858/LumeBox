import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/music/lx_catalog.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_runtime.dart';
import 'package:lume_box/core/music/music_service.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/source_subscription.dart';

class _Runtime implements MusicRuntime {
  _Runtime(this.protocol, this.script, this.calls);
  final MusicProtocol protocol;
  final String script;
  final List<Map<String, dynamic>> calls;
  bool disposed = false;
  @override
  Future<Map<String, dynamic>> describe() async => {
    'name': script.contains('bad') ? 'Bad' : protocol.name,
    'version': '1.0',
    'capabilities': ['search', 'importMusicSheet'],
    'platforms': protocol == MusicProtocol.lx
        ? {
            'kw': ['128k', '320k'],
          }
        : <String, dynamic>{},
    'variables': [],
  };
  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add({'method': method, ...args});
    if (script.contains('bad')) throw StateError('broken');
    if (method == 'search') {
      return {
        'data': [
          {'id': '1', 'title': 'Song', 'artist': 'Singer'},
        ],
        'isEnd': true,
      };
    }
    if (method == 'media') {
      return {
        'url': script.contains('invalid')
            ? 'file:///x'
            : 'https://example.com/song.mp3',
        'headers': {'Referer': 'https://example.com/'},
      };
    }
    if (method == 'importSheet') {
      return [
        {'id': '2', 'title': 'Sheet song'},
      ];
    }
    return {'rawLrc': '[00:01]Hello'};
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MusicLibrary library;
  late MusicService service;
  late List<Map<String, dynamic>> calls;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lume-music-service-');
    library = MusicLibrary(directory: directory);
    calls = [];
    service = MusicService(
      library: library,
      factory: (id, script, protocol) async =>
          _Runtime(protocol, script, calls),
    );
    await library.load();
  });
  tearDown(() async {
    service.dispose();
    await library.save();
    library.dispose();
    await directory.delete(recursive: true);
  });
  test('MusicFree search, lazy resolve, user variables, lyrics and playlist import', () async {
    final plugin = await service.importScript('module.exports={}');
    await library.change(plugin.copyWith(values: {'token': 'secret'}));
    final result = await service.search('query');
    expect(result.tracks.single.title, 'Song');
    final media = await service.resolve(result.tracks.single);
    expect(media.url.toString(), 'https://example.com/song.mp3');
    expect(media.headers['Referer'], 'https://example.com/');
    expect(calls.last['quality'], 'standard');
    expect(calls.last['variables'], {'token': 'secret'});
    expect(
      (await service.lyrics(result.tracks.single)).original,
      '[00:01]Hello',
    );
    expect(
      (await service.importSheet(
        plugin.id,
        'https://example.com/sheet',
      )).single.id,
      '2',
    );
  });
  test('failed plugin does not hide successful results; disabled plugin is never searched', () async {
    final good = await service.importScript('module.exports={}');
    await service.importScript('bad');
    final result = await service.search('song');
    expect(result.tracks, hasLength(1));
    expect(result.failures, hasLength(1));
    await library.change(good.copyWith(enabled: false));
    calls.clear();
    expect((await service.search('song')).tracks, isEmpty);
    expect(calls, hasLength(1));
    await expectLater(service.resolve(result.tracks.single), throwsStateError);
  });
  test(
    'LX retains platform IDs and chooses a quality declared by the script',
    () async {
      final plugin = await service.importScript(
        'const {on}=lx; // bundled module.exports',
      );
      expect(plugin.protocol, MusicProtocol.lx);
      library.quality = 'super';
      final track = MusicTrack.parse(plugin.id, {
        'songmid': '42',
        'name': 'LX',
        'source': 'kw',
        'hash': 'kept',
      });
      await service.resolve(track);
      expect(calls.last['quality'], '320k');
      expect(calls.last['platform'], 'kw');
      expect((calls.last['track'] as Map)['hash'], 'kept');
    },
  );
  test('subscription resolves relative URLs, bounds recursion and reports partial failures', () async {
    final importer = MusicService(
      library: library,
      factory: service.factory,
      fetch: (url) async {
        if (url.endsWith('bad.js')) throw StateError('unavailable');
        final text = url.endsWith('list.json')
            ? jsonEncode({
                'plugins': [
                  {'url': 'ok.js'},
                  {'url': 'bad.js'},
                  {'url': 'list.json'},
                ],
              })
            : 'module.exports={}';
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );
    final result = await importer.importUrl('https://example.com/list.json');
    expect(result.imported, 1);
    expect(result.failures, hasLength(1));
    expect(library.plugins.single.origin, 'https://example.com/ok.js');
    await expectLater(importer.importUrl('file:///bad'), throwsFormatException);
    importer.dispose();
  });
  test('library roundtrip preserves favorites, queue, disabled state and variables', () async {
    final plugin = await service.importScript(
      'module.exports={}',
      origin: 'https://example.com/plugin.js',
    );
    await library.change(
      plugin.copyWith(enabled: false, values: {'token': 'saved'}),
    );
    final track = MusicTrack.parse(plugin.id, {
      'id': 'same',
      'title': 'Title',
      'source': 'kw',
      'custom': {'hash': 'value'},
    });
    await library.toggleFavorite(track);
    await library.remember(track);
    library.queue.add(track);
    library.quality = 'high';
    await library.save();
    final restored = MusicLibrary(directory: directory);
    await restored.load();
    expect(restored.plugins.single.enabled, false);
    expect(restored.plugins.single.values, {'token': 'saved'});
    expect(restored.favorites.single.key, track.key);
    expect(restored.queue.single.raw['custom'], {'hash': 'value'});
    expect(restored.quality, 'high');
    expect(await restored.script(plugin.id), 'module.exports={}');
    restored.dispose();
  });
  test('unsafe playback schemes are rejected; a deleted plugin cannot resolve old favorites', () async {
    final plugin = await service.importScript('invalid');
    final track = MusicTrack.parse(plugin.id, {'id': '1', 'title': 'Song'});
    await expectLater(service.resolve(track), throwsStateError);
    service.invalidate(plugin.id);
    await library.remove(plugin.id);
    await expectLater(service.resolve(track), throwsStateError);
    expect(await File('${directory.path}/${plugin.id}.js').exists(), false);
  });
  test(
    'LX KuGou normalization preserves quality hashes needed by resolvers',
    () {
      final track = LxCatalog.normalize('plugin', 'kg', {
        'Audioid': 123,
        'FileHash': 'normal',
        'HQFileHash': 'high',
        'OriSongName': 'Song',
        'Singers': [
          {'name': 'Singer'},
        ],
        'Duration': 125,
        'MixSongID': 456,
      });
      expect(track.id, '123');
      expect(track.artist, 'Singer');
      expect(
        track.raw['_types'],
        containsPair('320k', {'hash': 'high', 'size': null}),
      );
      expect(track.raw['albumAudioId'], 456);
      expect(track.raw['interval'], '2:05');
    },
  );
  test(
    'catalog applies page offsets and preserves platform-specific identifiers',
    () async {
      final requests = <Uri>[];
      final network = LumeHttp(
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'code': 200,
              'result': {
                'songs': [
                  {
                    'id': 123,
                    'name': 'Song',
                    'artists': [
                      {'name': 'Singer'},
                    ],
                    'duration': 125000,
                    'album': {
                      'id': 456,
                      'name': 'Album',
                      'picUrl': 'https://example.com/cover.jpg',
                    },
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      final catalog = LxCatalog(http: network);
      final result = await catalog.search('plugin', 'wy', 'test query', 2);
      expect(requests.single.queryParameters['offset'], '30');
      expect(requests.single.queryParameters['s'], 'test query');
      expect(result.tracks.single.duration, const Duration(seconds: 125));
      expect(result.tracks.single.raw['albumId'], 456);
      network.dispose();
    },
  );
  test(
    'LRC offsets, repeated timestamps and LX word markers remain synchronized',
    () {
      final lines = LyricLine.parse(
        '[offset:-100]\n[00:02.50][00:04.005]<0,30>Hello\n[00:01]First',
      );
      expect(lines.map((l) => l.time.inMilliseconds), [1100, 2600, 4105]);
      expect(lines.map((l) => l.text), ['First', 'Hello', 'Hello']);
    },
  );
}
