import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'tvbox_config.dart';

class TvBoxLiveChannel {
  TvBoxLiveChannel(this.name, this.group, this.logo)
    : id = sha256
          .convert(utf8.encode('$group\n$name'))
          .toString()
          .substring(0, 24);
  final String name, group, logo;
  final String id;
  final List<({String url, Map<String, String> headers})> routes = [];
}

class TvBoxLivePlaylist {
  TvBoxLivePlaylist(this.channels, this.skipped);
  final List<TvBoxLiveChannel> channels;
  final int skipped;

  static TvBoxLivePlaylist parse(
    String text, {
    required String origin,
    Map<String, String> headers = const {},
  }) {
    final channels = <TvBoxLiveChannel>[];
    final grouped = <String, TvBoxLiveChannel>{};
    var skipped = 0;
    void add(
      String name,
      String group,
      String logo,
      String raw,
      Map<String, String> extra,
    ) {
      if (RegExp(r'[<>\r\n]').hasMatch(raw)) {
        skipped++;
        return;
      }
      final separator = raw.indexOf('|');
      var url = separator < 0 ? raw : raw.substring(0, separator);
      url = url.split(r'$').first.trim();
      final parsed = Uri.tryParse(url);
      if (parsed != null &&
          parsed.hasScheme &&
          !['http', 'https'].contains(parsed.scheme)) {
        skipped++;
        return;
      }
      url = TvBoxConfig.resolve(url, origin);
      if (url.isEmpty) {
        skipped++;
        return;
      }
      final resultHeaders = {...headers, ...extra};
      if (separator >= 0) {
        try {
          resultHeaders.addAll(
            Uri.splitQueryString(raw.substring(separator + 1)),
          );
        } catch (_) {
          skipped++;
          return;
        }
      }
      final key = '$group\n$name';
      final channel = grouped.putIfAbsent(key, () {
        final item = TvBoxLiveChannel(
          name.isEmpty ? '未命名频道' : name,
          group.isEmpty ? '全部频道' : group,
          TvBoxConfig.resolve(logo, origin),
        );
        channels.add(item);
        return item;
      });
      if (!channel.routes.any(
        (r) =>
            r.url == url && jsonEncode(r.headers) == jsonEncode(resultHeaders),
      )) {
        channel.routes.add((url: url, headers: resultHeaders));
      }
      if (channels.length > 20000) {
        throw const FormatException('直播频道超过 20000 项');
      }
    }

    final clean = text.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
    if (clean.startsWith('<')) {
      throw const FormatException('直播地址返回网页，请提供 M3U/TXT 频道列表');
    }
    if (clean.startsWith('{') || clean.startsWith('[')) {
      final decoded = jsonDecode(clean);
      final groups = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['lives']
          : null;
      if (groups is! List) throw const FormatException('直播 JSON 缺少 lives/频道分组');
      for (final group in groups.whereType<Map>()) {
        for (final row in (group['channels'] as List? ?? []).whereType<Map>()) {
          final urls = row['urls'] is List ? row['urls'] as List : [row['url']];
          for (final url in urls.whereType<String>()) {
            add(
              '${row['name'] ?? ''}',
              '${group['name'] ?? ''}',
              '${row['logo'] ?? ''}',
              url,
              const {},
            );
          }
        }
      }
    } else if (clean.startsWith('#EXTM3U')) {
      // A media HLS manifest is one live route, not an IPTV channel directory.
      if (RegExp(
        r'^#EXT-X-(TARGETDURATION|STREAM-INF|MEDIA-SEQUENCE)',
        multiLine: true,
      ).hasMatch(clean)) {
        add('直播', '全部频道', '', origin, const {});
      } else {
        var name = '', group = '', logo = '';
        var extra = <String, String>{};
        for (final raw in const LineSplitter().convert(clean)) {
          final line = raw.trim();
          if (line.startsWith('#EXTINF:')) {
            final comma = line.lastIndexOf(',');
            name = comma >= 0 ? line.substring(comma + 1).trim() : '';
            String attr(String key) =>
                RegExp('$key="([^"]*)"').firstMatch(line)?[1] ?? '';
            group = attr('group-title');
            logo = attr('tvg-logo');
            extra = {
              if (attr('http-user-agent').isNotEmpty)
                'User-Agent': attr('http-user-agent'),
              if (attr('http-referrer').isNotEmpty)
                'Referer': attr('http-referrer'),
              if (attr('http-referer').isNotEmpty)
                'Referer': attr('http-referer'),
            };
          } else if (line.startsWith('#EXTGRP:')) {
            group = line.substring(8).trim();
          } else if (line.startsWith('#EXTVLCOPT:http-user-agent=')) {
            extra['User-Agent'] = line.substring(
              '#EXTVLCOPT:http-user-agent='.length,
            );
          } else if (line.startsWith('#EXTVLCOPT:http-referrer=')) {
            extra['Referer'] = line.substring(
              '#EXTVLCOPT:http-referrer='.length,
            );
          } else if (line.isNotEmpty && !line.startsWith('#')) {
            add(name, group, logo, line, extra);
            name = '';
            extra = {};
          }
        }
      }
    } else {
      var group = '全部频道';
      for (final raw in const LineSplitter().convert(clean)) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final comma = line.indexOf(',');
        if (comma <= 0) {
          skipped++;
          continue;
        }
        final name = line.substring(0, comma).trim();
        final value = line.substring(comma + 1).trim();
        if (value == '#genre#') {
          group = name;
          continue;
        }
        for (final url in value.split(RegExp(r'#(?=https?://)'))) {
          add(name, group, '', url, const {});
        }
      }
    }
    if (channels.isEmpty) {
      throw FormatException(
        '未找到可播放的 HTTP(S) 频道${skipped > 0 ? '，已跳过 $skipped 条无效或不支持的协议' : ''}',
      );
    }
    return TvBoxLivePlaylist(channels, skipped);
  }
}
