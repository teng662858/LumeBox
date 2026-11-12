/// Mobile preview and native smoke check. Does not change the shipping entry.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/direct_video_source.dart';
import 'package:lume_box/features/video/video_play_target.dart';
import 'package:lume_box/core/intro/intro_backend.dart';
import 'package:lume_box/core/intro/intro_models.dart';
import 'package:lume_box/core/intro/intro_signals.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/intro_settings_page.dart';
import 'package:lume_box/features/video/player_settings_host.dart';
import 'package:lume_box/features/video/video_player_page.dart';

const fixtureURL = String.fromEnvironment(
  'PREVIEW_MEDIA',
  defaultValue: 'http://127.0.0.1:8765/player-fixture.mp4',
);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPreferences.instance.boot();
  await FloatingModules.instance.boot();
  await FrostedSettings.instance.boot();
  await ReadingLibrary.open(Section.video);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: const AndroidPlayerPreview(),
    ),
  );
}

class AndroidPlayerPreview extends StatefulWidget {
  const AndroidPlayerPreview({super.key});
  @override
  State<AndroidPlayerPreview> createState() => AndroidPlayerPreviewState();
}

class AndroidPlayerPreviewState extends State<AndroidPlayerPreview> {
  String _result = '测试媒体：原创测试画面／音调，含 OP、正片、ED 章节标记。';
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open({bool portrait = false}) async {
    final uri = portrait
        ? Uri.parse(fixtureURL).resolve('player-portrait-fixture.mp4')
        : Uri.parse(fixtureURL);
    final qualities = [
      VideoQuality(label: '原画', url: uri),
      VideoQuality(label: '兼容线路', url: uri),
    ];
    final episodes = [
      for (final line in ['直连线路', '备用线路'])
        for (var i = 0; i < 120; i++)
          SourceChapter(id: '$line-$i', title: '第${i + 1}集', line: line),
    ];
    final source = DirectVideoSource(
      id: 'player-layout-preview',
      name: '本地测试媒体',
      title: '山海之间 · 播放器预览',
      uri: uri,
      episodes: episodes,
      resolveEpisode: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        return VideoContent(url: uri, qualities: qualities);
      },
    );
    final media = PlayerMedia(uri: uri, title: '山海之间 · 第1集');
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          catalog: const _AndroidPreviewCatalog(),
          media: media,
          title: '山海之间 · 播放器预览',
          source: source,
          qualities: qualities,
          target: VideoPlayTarget(
            sourceId: source.id,
            itemId: portrait ? 'portrait-preview' : 'landscape-preview',
            title: source.title,
            chapterId: episodes.first.id,
            chapterIndex: 0,
            chapterTitle: '第1集',
          ),
        ),
      ),
    );
  }

  Future<void> _smoke() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = '原生取帧、音频、OCR 与 YAMNet 推理中…';
    });
    final backend = NativeIntroBackend();
    try {
      final options = IntroOptions({'videoAI': false, 'audioAI': true});
      final resources = await backend.resources();
      final sample = await backend.sample(
        Uri.parse(fixtureURL),
        {},
        7000,
        options,
        IntroCancellation(),
      );
      if (sample == null) throw StateError('No native sample');
      final inference = await backend.infer(sample, options);
      final result = const JsonEncoder.withIndent('  ').convert({
        'resources': resources,
        'grayPixels': sample.gray.length,
        'pcmSamples': sample.pcm.length,
        'audioRMS': IntroSignals.rms(sample.pcm),
        'ocr': sample.text,
        'yamnet': inference.ai,
      });
      debugPrint('INTRO_NATIVE_SMOKE $result');
      if (mounted) setState(() => _result = result);
    } catch (error, stack) {
      debugPrint('INTRO_NATIVE_SMOKE_FAILURE $error\n$stack');
      if (mounted) setState(() => _result = '$error');
    } finally {
      await backend.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放器移动端预览')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton(onPressed: () => _open(), child: const Text('横屏播放器与选集')),
        OutlinedButton(
          onPressed: () => _open(portrait: true),
          child: const Text('竖屏短剧播放器'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const IntroSettingsPage()),
          ),
          child: const Text('片头片尾全部识别设置'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const PlayerSettingsHost()),
          ),
          child: const Text('播放器设置'),
        ),
        const SizedBox(height: 20),
        FilledButton.tonal(
          onPressed: _busy ? null : _smoke,
          child: const Text('运行原生采样与 YAMNet 检查'),
        ),
        const SizedBox(height: 16),
        SelectableText(_result),
      ],
    ),
  );
}

/// Only the preview opts into Android's video_player backend. Shipping platform
/// availability and the three iOS kernels remain governed by PlayerFactory.
class _AndroidPreviewCatalog implements PlayerKernelCatalog {
  const _AndroidPreviewCatalog();
  @override
  bool isAvailable(PlayerKernel kernel) => kernel == PlayerKernel.avplayer;
  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '此移动预览使用 Android 系统解码，内核效果请在 iPhone 验收';
}
