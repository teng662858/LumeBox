import 'package:lume_box/features/video/player_source_sheet.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_match_sheet.dart';
import 'package:lume_box/features/video/danmaku/danmaku_models.dart';
import 'package:lume_box/features/video/danmaku/danmaku_overlay.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  runApp(
    MaterialApp(
      theme: LumeTheme.build(),
      debugShowCheckedModeBanner: false,
      home: const DanmakuRedesignPreview(),
    ),
  );
}

/// Isolated interaction demo: fixture results, no saved credentials or progress.
class DanmakuRedesignPreview extends StatefulWidget {
  const DanmakuRedesignPreview({super.key});
  @override
  State<DanmakuRedesignPreview> createState() => _PreviewState();
}

class _PreviewState extends State<DanmakuRedesignPreview> {
  final revision = ValueNotifier(0);
  DanmakuSettings settings = const DanmakuSettings();
  DanmakuTrack track = DanmakuTrack.empty;
  String? match;
  late final Timer timer;
  final clock = Stopwatch()..start();
  late final client = DandanplayClient(
    credentials: const DandanplayCredentials(
      '',
      '',
      baseUrl: 'https://preview.example',
    ),
    client: MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.path.contains('/comment/')
              ? {
                  'comments': [
                    for (var i = 0; i < 240; i++)
                      {
                        'p': '${i / 3},1,16777215,preview',
                        'm':
                            '${['连续跟随效果', '弹幕交互预览', '这一集选对了', '保持文字间距', '字体和密度可调整'][i % 5]} $i',
                      },
                  ],
                }
              : {
                  'animes': [
                    {
                      'animeId': 8334076,
                      'animeTitle': '熔城(2026)【电视剧】from tencent',
                      'typeDescription': '电视剧',
                      'episodes': [
                        for (var i = 1; i <= 3; i++)
                          {
                            'episodeId': 1557960 + i,
                            'episodeTitle': '【qq】 熔城_0$i',
                          },
                      ],
                    },
                    {
                      'animeId': 13014,
                      'animeTitle': '活火熔城(1997)【电影】from 360',
                      'typeDescription': '电影',
                      'episodes': [
                        {'episodeId': 99, 'episodeTitle': '正片'},
                      ],
                    },
                  ],
                },
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => open());
  }

  @override
  void dispose() {
    timer.cancel();
    client.close();
    revision.dispose();
    super.dispose();
  }

  Future<void> open() => showDanmakuPanel<void>(
    context: context,
    builder: (_) => ValueListenableBuilder(
      valueListenable: revision,
      builder: (_, value, child) => DanmakuSettingsSheet(
        settings: settings,
        videoTitle: '熔城',
        episodeTitle: '01 · 交互预览',
        serviceLabel: '模拟数据 · 不修改你的服务配置',
        sourceCount: 0,
        publicCount: track.length,
        danmakuCount: track.length,
        matchLabel: match,
        status: track.isEmpty ? '尚未匹配，请选择当前作品与集数' : '已加载 ${track.length} 条预览弹幕',
        onChanged: (next) {
          setState(() => settings = next);
          revision.value++;
        },
        onReload: () {
          clock.reset();
          revision.value++;
        },
        onMatch: () async {
          final result = await showDanmakuPanel<DanmakuMatchSelection>(
            context: context,
            builder: (_) => DanmakuMatchSheet(
              client: client,
              title: '熔城',
              episode: 1,
              serviceLabel: '模拟接口结果 · 可核对作品和集数',
            ),
          );
          if (result != null && mounted) {
            setState(() {
              track = result.track;
              match = '${result.episode.workTitle} · ${result.episode.episode}';
              clock.reset();
            });
            revision.value++;
          }
        },
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff102932),
    body: Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xff163e4c), Color(0xff081218)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        const Center(
          child: Text(
            '播放区域 · 弹幕交互预览',
            style: TextStyle(color: Colors.white30, fontSize: 24),
          ),
        ),
        Positioned.fill(
          child: DanmakuOverlay(
            position: clock.elapsed,
            playing: true,
            track: track,
            settings: settings,
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                const Text(
                  '熔城  01',
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '剧集线路',
                  icon: const Icon(Icons.alt_route, color: Colors.white),
                  onPressed: () => showDanmakuPanel<void>(
                    context: context,
                    builder: (_) => PlayerSourceSheet(
                      address: 'https://preview.invalid/video.m3u8',
                      fullBleed: true,
                      initialTab: PlayerSourceTab.lines,
                      loadLines: () async => const [
                        PlayerSourceLine('默认线路', current: true),
                        PlayerSourceLine('备用线路'),
                        PlayerSourceLine('暂无本集的线路', available: false),
                      ],
                      onSelectLine: (_) async => true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '弹幕',
                  onPressed: open,
                  icon: const Icon(Icons.comment_outlined, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
        const Positioned(
          left: 30,
          right: 30,
          bottom: 32,
          child: LinearProgressIndicator(
            value: .36,
            color: Colors.white70,
            backgroundColor: Colors.white24,
          ),
        ),
      ],
    ),
  );
}
