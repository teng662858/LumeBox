import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/audio_book/audio_book_proxy.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';

void main() {
  var available = false;
  try {
    available = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } on ProcessException {
    // Protocol tests run separately on hosts without FFmpeg.
  }
  test(
    'decode an extensionless signed audio playlist to the original PCM',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lumebox-hls-audio-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = AudioBookProxy();
      try {
        final playlist = File.fromUri(directory.uri.resolve('tone.m3u8'));
        final generated = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=2.5',
          '-c:a',
          'aac',
          '-f',
          'hls',
          '-hls_time',
          '1',
          '-hls_list_size',
          '0',
          playlist.path,
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        origin.listen((request) async {
          final name = request.uri.pathSegments.last;
          final file = name == 'listen'
              ? playlist
              : File.fromUri(directory.uri.resolve(name));
          if (request.headers.value('authorization') != 'Bearer fixture') {
            request.response.statusCode = 403;
          } else if (!await file.exists()) {
            request.response.statusCode = 404;
          } else {
            request.response.headers.contentType = ContentType.binary;
            request.response.contentLength = await file.length();
            if (request.method == 'GET') {
              await request.response.addStream(file.openRead());
            }
          }
          await request.response.close();
        });
        final local = (await proxy.prepare([
          AudioBookTrack(
            id: 'chapter',
            album: 'Tone',
            episode: ResourceEpisode(
              id: 'chapter',
              title: 'Tone',
              headers: const {'Authorization': 'Bearer fixture'},
              url: Uri.parse(
                'http://127.0.0.1:${origin.port}/book/listen?ticket=1',
              ),
            ),
          ),
        ])).single;
        Future<String> pcmHash(String input) async {
          final decoded = await Process.run('ffmpeg', [
            '-v',
            'error',
            '-rw_timeout',
            '5000000',
            '-i',
            input,
            '-map',
            '0:a:0',
            '-c:a',
            'pcm_s16le',
            '-f',
            'hash',
            '-',
          ]);
          expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
          return decoded.stdout.toString().trim();
        }

        final original = await pcmHash(playlist.path);
        expect(original, startsWith('SHA256='));
        expect(await pcmHash(local.toString()), original);
      } finally {
        await proxy.close();
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: !available,
  );
}
