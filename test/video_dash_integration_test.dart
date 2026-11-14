import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var available = false;
  try {
    available = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } on ProcessException {
    // The HTTP regression tests also run on hosts without FFmpeg.
  }
  test('decode a signed DASH stream through the player cache after a manifest redirect', () async {
    HttpOverrides.global = null;
    final root = await Directory.systemTemp.createTemp('lume-dash-play-');
    final cache = VideoDiskCache();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      await cache.boot(directory: root);
      final made = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=96x64:rate=10',
        '-frames:v',
        '20',
        '-c:v',
        'libx264',
        '-bf',
        '0',
        '-g',
        '10',
        '-f',
        'dash',
        '-seg_duration',
        '1',
        '-use_timeline',
        '0',
        '${root.path}/movie.mpd',
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final paths = <String>[];
      final cdnPaths = <String>[];
      cdn.listen((request) async {
        cdnPaths.add(request.uri.path);
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('referer'), 'https://player.example/watch');
        final file = File('${root.path}/${request.uri.pathSegments.last}');
        if (request.uri.path.startsWith('/final/') && await file.exists()) {
          final bytes = await file.readAsBytes();
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      server.listen((request) async {
        final path = request.uri.path;
        paths.add(path);
        if (request.headers.value('authorization') != 'Bearer fixture') {
          request.response.statusCode = 403;
        } else if (path == '/entry') {
          request.response.statusCode = 302;
          request.response.headers.set('Location', '/final/movie.mpd${request.uri.hasQuery ? '?${request.uri.query}' : ''}');
        } else if (path.startsWith('/final/')) {
          final file = File('${root.path}/${request.uri.pathSegments.last}');
          if (await file.exists()) {
            var bytes = await file.readAsBytes();
            if (path.endsWith('.mpd') && request.uri.queryParameters.containsKey('cdn')) {
              final document = XmlDocument.parse(utf8.decode(bytes));
              final template = document.findAllElements('SegmentTemplate').single;
              for (final name in ['media', 'initialization']) {
                template.setAttribute(name, '/final/${template.getAttribute(name)!}');
              }
              template.parent!.children.remove(template);
              final representation = document.findAllElements('Representation').single;
              representation.parent!.children.insert(0, template);
              representation.children.insert(0, XmlElement(XmlName.parts('BaseURL'), [], [
                XmlText('http://127.0.0.1:${cdn.port}/unused/deep/'),
              ]));
              bytes = utf8.encode(document.toXmlString());
            }
            if (path.endsWith('.mpd') && request.uri.queryParameters.containsKey('ranges')) {
              final range = request.headers.value('range');
              if (range == null) {
                request.response.statusCode = 403;
              } else {
                final start = int.parse(range.substring(6).split('-').first);
                final end = (start + 128).clamp(0, bytes.length);
                request.response.statusCode = 206;
                request.response.headers.set('Content-Range', 'bytes $start-${end - 1}/${bytes.length}');
                request.response.add(bytes.sublist(start, end));
              }
              await request.response.close();
              return;
            }
            request.response.headers.set(
              'Content-Type',
              path.endsWith('.mpd') ? 'application/dash+xml' : 'video/mp4',
            );
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          } else {
            request.response.statusCode = 404;
          }
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final input = await cache.wrap(
        PlayerMedia(
          uri: Uri.parse('http://127.0.0.1:${server.port}/entry?sig=signed'),
          headers: const {'Authorization': 'Bearer fixture'},
        ),
        inspect: true,
      );
      expect(input.headers, isNull);
      Future<List<String>> frames(String input) async {
        final decoded = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-rw_timeout',
          '5000000',
          '-i',
          input,
          '-map',
          '0:v:0',
          '-fps_mode',
          'passthrough',
          '-f',
          'framemd5',
          '-',
        ]);
        expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
        return LineSplitter.split('${decoded.stdout}')
            .where((line) => line.startsWith('0,'))
            .toList();
      }

      final original = await frames('${root.path}/movie.mpd');
      expect(original, hasLength(20));
      expect(
        await frames(input.uri.toString()),
        original,
        reason: paths.join(', '),
      );
      final ranged = await cache.wrap(
        PlayerMedia(
          uri: Uri.parse('http://127.0.0.1:${server.port}/entry?sig=signed&ranges=1'),
          headers: const {'Authorization': 'Bearer fixture'},
        ),
        inspect: true,
      );
      expect(ranged.uri.path, endsWith('.mpd'));
      expect(await frames(ranged.uri.toString()), original);
      final inherited = await cache.wrap(PlayerMedia(
        uri: Uri.parse('http://127.0.0.1:${server.port}/entry?cdn=1'),
        headers: const {
          'Authorization': 'Bearer fixture', 'Referer': 'https://player.example/watch',
        },
      ), inspect: true);
      expect(await frames(inherited.uri.toString()), original);
      expect(cdnPaths, containsAll([
        '/final/init-stream0.m4s', '/final/chunk-stream0-00001.m4s',
        '/final/chunk-stream0-00002.m4s',
      ]));
      expect(
        paths,
        containsAll([
          '/final/init-stream0.m4s',
          '/final/chunk-stream0-00001.m4s',
          '/final/chunk-stream0-00002.m4s',
        ]),
      );
    } finally {
      await cdn.close(force: true);
      await server.close(force: true);
      await cache.close();
      await root.delete(recursive: true);
    }
  }, skip: !available);
}
