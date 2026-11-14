import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_download_center.dart';

import 'video_download_merge_test.dart' show waitFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var available = false;
  try {
    available = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {}
  test('an audio-only MP4 from a remux cannot replace the original offline video', () async {
    final root = await Directory.systemTemp.createTemp('lume-audio-only-remux-');
    try {
      final audio = File('${root.path}/audio.mp4');
      final result = await Process.run('ffmpeg', [
        '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.5',
        '-c:a', 'aac', '-movflags', '+faststart', audio.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final probe = await Process.run('ffprobe', [
        '-v', 'error', '-show_streams', '-of', 'json', audio.path,
      ]);
      expect(probe.exitCode, 0);
      expect((jsonDecode('${probe.stdout}')['streams'] as List).map((s) => s['codec_type']), ['audio']);
      final center = VideoDownloadCenter(
        directory: () async => root,
        merge: (_, output, _) async { await audio.copy(output.path); },
      );
      await center.boot();
      final task = VideoDownloadTask(
        id: VideoDownloadCenter.identity('source', 'movie', 'one'),
        sourceId: 'source', itemId: 'movie', chapterId: 'one',
        title: 'Movie', chapterTitle: 'One', state: 'paused', fileName: 'index.m3u8',
      );
      center.tasks.add(task);
      final directory = await Directory(center.folder(task)).create(recursive: true);
      final generated = await Process.run('ffmpeg', [
        '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=10:duration=0.5',
        '-c:v', 'libx264', '-f', 'hls', '-hls_playlist_type', 'vod',
        '${directory.path}/index.m3u8',
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      await center.resume(task);
      await waitFor(() => ['done', 'merge_failed'].contains(task.state));
      await center.flush();
      expect(task.state, 'merge_failed');
      expect(await center.localFile(task).exists(), isTrue);
      final decode = await Process.run('ffmpeg', [
        '-v', 'error', '-i', center.localFile(task).path, '-map', '0:v', '-f', 'null', '-',
      ]);
      expect(decode.exitCode, 0, reason: '${decode.stderr}');
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: available ? false : 'Requires FFmpeg on desktop');

  test(
    'real FFmpeg preserves video frames, separate audio and duration in a single MP4',
    () async {
      final root = await Directory.systemTemp.createTemp('lume-real-remux-');
      try {
        final center = VideoDownloadCenter(directory: () async => root);
        await center.boot();
        final task = VideoDownloadTask(
          id: VideoDownloadCenter.identity('source', 'movie', 'one'),
          sourceId: 'source',
          itemId: 'movie',
          chapterId: 'one',
          title: 'Movie',
          chapterTitle: 'One',
          state: 'done',
          fileName: 'index.m3u8',
        );
        center.tasks.add(task);
        final directory = Directory(center.folder(task));
        await Directory('${directory.path}/video').create(recursive: true);
        Future<String> ffmpeg(List<String> args) async {
          final result = await Process.run('ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            '-y',
            ...args,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          return '${result.stdout}';
        }

        Future<void> audioFixture(String folder, int frequency) async {
          await Directory('${directory.path}/$folder').create(recursive: true);
          await ffmpeg([
            '-f', 'lavfi', '-i', 'sine=frequency=$frequency:sample_rate=48000',
            '-t', '2', '-c:a', 'aac', '-f', 'hls', '-hls_time', '1',
            '-hls_playlist_type', 'vod', '${directory.path}/$folder/index.m3u8',
          ]);
        }
        await ffmpeg([
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=96x64:rate=10',
          '-t',
          '2',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-g',
          '10',
          '-f',
          'hls',
          '-hls_time',
          '1',
          '-hls_playlist_type',
          'vod',
          '${directory.path}/video/index.m3u8',
        ]);
        await audioFixture('audio', 440);
        await audioFixture('dub', 880);
        await File('${directory.path}/index.m3u8').writeAsString(
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English: director\'s cut",LANGUAGE="en",DEFAULT=NO,URI="audio/index.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Mandarin",LANGUAGE="zh-Hans",DEFAULT=YES,URI="dub/index.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="audio"\nvideo/index.m3u8\n',
        );
        await Directory('${directory.path}/side').create();
        await ffmpeg([
          '-i', '${directory.path}/video/index.m3u8', '-vf', 'negate',
          '-c:v', 'libx264', '-g', '10', '-f', 'hls', '-hls_time', '1',
          '-hls_playlist_type', 'vod', '${directory.path}/side/index.m3u8',
        ]);
        Future<List<String>> frameHashes(String path, [int index = 0]) async {
          final data = await ffmpeg([
            '-i',
            path,
            '-map',
            '0:v:$index',
            '-f',
            'framemd5',
            '-',
          ]);
          return const LineSplitter()
              .convert(data)
              .where((line) => line.isNotEmpty && !line.startsWith('#'))
              .map((line) => line.split(',').last.trim())
              .toList();
        }

        final original = await frameHashes('${directory.path}/index.m3u8');
        final side = await frameHashes('${directory.path}/side/index.m3u8');
        expect(side, isNot(original));
        // Exercise the download path before the local merge cleans these inputs.
        // The chosen stream points to audio, with its picture in a VIDEO group.
        HttpOverrides.global = null;
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        origin.listen((r) async {
          requests.add(r.uri.path);
          if (r.uri.path == '/master.m3u8') {
            r.response.write('#EXTM3U\n'
                '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="hd",NAME="Original",DEFAULT=YES,URI="video/index.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=950000,RESOLUTION=48x32\nlow.m3u8\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=96x64,VIDEO="hd"\naudio/index.m3u8\n');
          } else if (r.uri.path == '/angles.m3u8') {
            r.response.write('#EXTM3U\n'
                '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="views",NAME="Side",DEFAULT=NO,URI="side/index.m3u8"\n'
                '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="views",NAME="Main",DEFAULT=YES,URI="video/index.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=96x64,VIDEO="views"\naudio/index.m3u8\n');
          } else if (r.uri.path == '/unlabelled.m3u8') {
            r.response.write('#EXTM3U\n'
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="Original",DEFAULT=YES,URI="audio/index.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=950000,CODECS="mp4a.40.2"\naudio/index.m3u8\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="sound"\nvideo/index.m3u8\n');
          } else if (r.uri.path == '/nested.m3u8') {
            r.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nindex.m3u8\n');
          } else if (r.uri.path == '/nested-audio.m3u8') {
            r.response.write('#EXTM3U\n'
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="outer",NAME="Original",DEFAULT=YES,URI="master.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="outer"\nvideo/index.m3u8\n');
          } else {
            final file = File.fromUri(directory.uri.resolve(r.uri.path.substring(1)));
            if (await file.exists()) {
              await r.response.addStream(file.openRead());
            } else {
              r.response.statusCode = 404;
            }
          }
          await r.response.close();
        });
        final remote = VideoDownloadCenter(
          directory: () async => Directory('${root.path}/remote'),
          resolve: (task) async => VideoContent(url: Uri.parse('http://127.0.0.1:${origin.port}/${task.chapterId}.m3u8')),
        );
        try {
          await remote.enqueue(sourceId: 'source', itemId: 'movie', title: 'Movie',
              chapters: const [
                SourceChapter(id: 'master', title: 'Separate video'),
                SourceChapter(id: 'angles', title: 'Two camera angles'),
                SourceChapter(id: 'unlabelled', title: 'Unlabelled video'),
                SourceChapter(id: 'nested', title: 'Nested master'),
                SourceChapter(id: 'nested-audio', title: 'Nested audio rendition'),
              ]);
          await waitFor(() => remote.tasks.every((t) => ['done', 'failed', 'merge_failed', 'paused'].contains(t.state)));
          await remote.flush();
          for (final task in remote.tasks) {
            expect(task.state, 'done', reason: '${task.chapterId}: ${task.error}');
          }
        } finally {
          await origin.close(force: true);
        }
        expect(requests, containsAll(['/video/index.m3u8', '/audio/index.m3u8']));
        expect(requests, isNot(contains('/low.m3u8')));
        Future<String> audioHash(String path, [int index = 0]) => ffmpeg([
          '-i', path, '-map', '0:a:$index', '-c:a', 'pcm_s16le', '-f', 'hash', '-',
        ]);
        final originalAudio = await audioHash('${directory.path}/audio/index.m3u8');
        final dubbedAudio = await audioHash('${directory.path}/dub/index.m3u8');
        expect(dubbedAudio, isNot(originalAudio));
        for (final task in remote.tasks) {
          final downloaded = remote.localFile(task);
          if (task.chapterId == 'angles') {
            final probe = await Process.run('ffprobe', [
              '-v', 'error', '-select_streams', 'v', '-show_streams', '-of', 'json', downloaded.path,
            ]);
            expect(probe.exitCode, 0);
            final videos = jsonDecode('${probe.stdout}')['streams'] as List;
            expect(videos, hasLength(2));
            expect(videos.map((v) => v['disposition']['default']), unorderedEquals([0, 1]));
            for (var i = 0; i < videos.length; i++) {
              expect(await frameHashes(downloaded.path, i), videos[i]['disposition']['default'] == 1 ? original : side);
            }
          } else {
            expect(await frameHashes(downloaded.path), original);
          }
          expect(await audioHash(downloaded.path), originalAudio);
        }
        // Earlier downloads can also contain an already-written nested master.
        await File('${directory.path}/index.m3u8').rename('${directory.path}/inner.m3u8');
        await File('${directory.path}/index.m3u8').writeAsString(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=220000\ninner.m3u8\n',
        );
        await center.resume(task);
        await waitFor(
          () => task.state == 'done' || task.state == 'merge_failed',
        );
        expect(task.state, 'done', reason: task.error);
        await center.flush();
        await waitFor(() => !File('${directory.path}/index.m3u8').existsSync());
        final output = center.localFile(task);
        expect(await frameHashes(output.path), original);
        final probe = await Process.run('ffprobe', [
          '-v',
          'error',
          '-show_streams',
          '-show_format',
          '-of',
          'json',
          output.path,
        ]);
        expect(probe.exitCode, 0);
        final metadata = jsonDecode('${probe.stdout}') as Map;
        final tracks = (metadata['streams'] as List).where((s) => s['codec_type'] == 'audio');
        expect(tracks.map((s) => [s['tags']['language'], s['tags']['handler_name'], s['disposition']['default']]),
            [['eng', "English: director's cut", 0], ['zho', 'Mandarin', 1]]);
        expect(await audioHash(output.path, 0), originalAudio);
        expect(await audioHash(output.path, 1), dubbedAudio);
        expect(
          (metadata['streams'] as List).map((s) => s['codec_type']),
          containsAll(['video', 'audio']),
        );
        expect(double.parse(metadata['format']['duration']), closeTo(2, 0.25));
        expect((await directory.list().toList()).length, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: available
        ? false
        : 'Requires an installed FFmpeg and ffprobe on desktop',
  );
}
