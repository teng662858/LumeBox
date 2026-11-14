import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../security/local_cipher.dart';
import '../player/text_subtitles.dart';

class SubtitleAccount {
  const SubtitleAccount(this.apiKey, this.token);
  final String apiKey, token;
  static Future<SubtitleAccount> load() async {
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/subtitles.private',
    );
    if (!await file.exists()) return const SubtitleAccount('', '');
    final data = jsonDecode(
      (await LocalCipher.open()).reveal(
        await file.readAsString(),
        context: 'subtitles',
      ),
    ) as Map;
    return SubtitleAccount('${data['apiKey'] ?? ''}', '${data['token'] ?? ''}');
  }

  Future<void> save() async {
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/subtitles.private',
    );
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      (await LocalCipher.open()).seal(
        jsonEncode({'apiKey': apiKey, 'token': token}),
        context: 'subtitles',
      ),
      flush: true,
    );
    await temp.rename(file.path);
  }
}

class SubtitleResult {
  const SubtitleResult(this.id, this.name, this.language);
  final int id;
  final String name, language;
}

class SubtitleService {
  SubtitleService(this.account, {http.Client? client})
    : client = client ?? http.Client();
  final SubtitleAccount account;
  final http.Client client;
  static final base = Uri.parse('https://api.opensubtitles.com/api/v1/');
  Map<String, String> get headers => {
    'Api-Key': account.apiKey,
    'Authorization': 'Bearer ${account.token}',
    'User-Agent': 'LumeBox v1.0',
    'Content-Type': 'application/json',
  };
  void close() => client.close();
  Future<Map> request(
    String path, {
    Map<String, String>? query,
    Map? body,
  }) async {
    if (account.apiKey.isEmpty) throw StateError('请先配置 OpenSubtitles API Key');
    final req = http.Request(
      body == null ? 'GET' : 'POST',
      base.resolve(path).replace(queryParameters: query),
    )..followRedirects = false;
    req.headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final response = await client
        .send(req)
        .timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(part);
      if (bytes.length > 2 * 1024 * 1024) throw const FormatException('服务返回过大');
    }
    if (response.statusCode != 200) {
      throw HttpException('字幕服务 HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(bytes)) as Map;
  }

  Future<List<SubtitleResult>> search(String title, String language) async {
    final result = await request(
      'subtitles',
      query: {'query': title, 'languages': language},
    );
    return [
      for (final row in result['data'] as List? ?? [])
        if (row is Map && row['attributes'] is Map)
          for (final file in row['attributes']['files'] as List? ?? [])
            if (file is Map && file['file_id'] is num)
              SubtitleResult(
                (file['file_id'] as num).toInt(),
                '${file['file_name'] ?? row['attributes']['release'] ?? '字幕'}',
                '${row['attributes']['language'] ?? ''}',
              ),
    ];
  }

  Future<File> download(int id) async {
    if (account.token.isEmpty) throw StateError('下载需要 OpenSubtitles 用户令牌');
    final result = await this.request('download', body: {'file_id': id});
    final uri = Uri.parse('${result['link']}');
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const FormatException('无效字幕下载地址');
    }
    // Download CDN must never receive account headers.
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('下载字幕失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(part);
      if (bytes.length > TextSubtitles.maxBytes) {
        throw const FormatException('字幕文件过大');
      }
    }
    final text = TextSubtitles.decode(bytes);
    if (TextSubtitles.parse(text).cues.isEmpty) {
      throw const FormatException('不是有效 SRT/VTT 字幕');
    }
    final extension = RegExp(r'^WEBVTT(?:\s|$)').hasMatch(text) ? 'vtt' : 'srt';
    final file = File(
      '${(await getTemporaryDirectory()).path}/subtitle-$id.$extension',
    );
    await file.writeAsString(text, flush: true);
    return file;
  }

  /// Align both streams by boundaries, preserving overlapping dialogue and gaps.
  static String bilingual(TextSubtitles first, TextSubtitles second) {
    final boundaries = {
      for (final cue in [...first.cues, ...second.cues]) ...[
        cue.start.inMilliseconds,
        cue.end.inMilliseconds,
      ],
    }.toList()..sort();
    if (boundaries.length > 50000) throw const FormatException('双语字幕条目过多');
    String timestamp(int ms) =>
        '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
    final out = StringBuffer('WEBVTT\n\n');
    for (var i = 0; i + 1 < boundaries.length; i++) {
      final at = Duration(milliseconds: boundaries[i]);
      final text = {first.at(at), second.at(at)}..remove('');
      if (text.isEmpty) continue;
      final escaped = text.join('\n')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      out.writeln(
        '${timestamp(boundaries[i])} --> ${timestamp(boundaries[i + 1])}\n$escaped\n',
      );
    }
    return out.toString();
  }
}
