import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/video_download_center.dart';

import 'video_download_merge_test.dart' show waitFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var available = false;
  try {
    available = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {}
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
        await Directory('${directory.path}/audio').create();
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
        await ffmpeg([
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000',
          '-t',
          '2',
          '-c:a',
          'aac',
          '-f',
          'hls',
          '-hls_time',
          '1',
          '-hls_playlist_type',
          'vod',
          '${directory.path}/audio/index.m3u8',
        ]);
        await File('${directory.path}/index.m3u8').writeAsString(
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Original",DEFAULT=YES,URI="audio/index.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="audio"\nvideo/index.m3u8\n',
        );
        Future<List<String>> frameHashes(String path) async {
          final data = await ffmpeg([
            '-i',
            path,
            '-map',
            '0:v:0',
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
