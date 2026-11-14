import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/av_presentation_channel.dart';
import 'package:lume_box/core/player/highest_hls.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/text_subtitles.dart';
import 'package:lume_box/features/video/presentation_settings_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preferences survive JSON and kernel changes; corrupt fields fall back independently', () {
    const p = PlaybackPresentation(
      hdrEnabled: false,
      dolbyVision: false,
      dolbyAudio: false,
      enhancementEnabled: true,
      preset: EnhancementPreset.anime,
      sharpen: false,
      deband: false,
      upscale: false,
      originalSubtitleStyle: false,
      subtitleLanguage: 'zh-Hant',
      rememberSubtitle: false,
    );
    expect(PlaybackPresentation.fromJson(p.toJson()), p);
    final settings = const PlayerSettings().copyWith(presentation: p);
    expect(settings.copyWith(kernel: PlayerKernel.mpv).presentation, p);
    expect(settings, isNot(const PlayerSettings()));
    final corrupt = PlaybackPresentation.fromJson({
      'hdrPolicy': 'bad',
      'sharpen': 'no',
      'deband': false,
    });
    expect(corrupt.hdrPolicy, HdrPolicy.automatic);
    expect(corrupt.sharpen, true);
    expect(corrupt.deband, false);
  });
  test('enhancement off restores scaling and removes sharpening / debanding independently', () {
    const p = PlaybackPresentation(enhancementEnabled: true, sharpen: false);
    expect(p.mpvProperties['sharpen'], '0');
    expect(p.mpvProperties['deband'], 'yes');
    expect(p.mpvProperties['scale'], 'spline36');
    final off = p.copyWith(enhancementEnabled: false).mpvProperties;
    expect(off['sharpen'], '0');
    expect(off['deband'], 'no');
    expect(off['scale'], 'bilinear');
    expect(p.copyWith(preset: EnhancementPreset.original).enhances, false);
    expect(p.copyWith(deband: false).mpvProperties['deband'], 'no');
  });
  const master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",URI="zh.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="杜比",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=9000,RESOLUTION=3840x2160,VIDEO-RANGE=SDR,SUBTITLES="subs",AUDIO="audio"
sdr.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000,RESOLUTION=1920x1080,VIDEO-RANGE=PQ,CODECS="hvc1.2"
hdr.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=9500,RESOLUTION=3840x2160,VIDEO-RANGE=PQ,CODECS="dvh1.05"
dv.m3u8
''';
  final base = Uri.parse('https://example.com/movie/master.m3u8');
  test('HDR priority selects HDR; disabling Dolby avoids DV without losing media groups', () {
    final hdr = HighestHls.singleRendition(
      master,
      base,
      presentation: const PlaybackPresentation(
        hdrPolicy: HdrPolicy.prefer,
        dolbyVision: false,
      ),
    )!;
    expect(hdr, contains('/movie/hdr.m3u8'));
    expect(hdr, isNot(contains('/movie/dv.m3u8')));
    expect(hdr, contains('URI="https://example.com/movie/zh.m3u8"'));
    expect(hdr, contains('URI="https://example.com/movie/audio.m3u8"'));
    final sdr = HighestHls.singleRendition(
      master,
      base,
      presentation: const PlaybackPresentation(hdrEnabled: false),
    )!;
    expect(sdr, contains('/movie/sdr.m3u8'));
    expect(sdr, isNot(contains('/movie/hdr.m3u8')));
    final dv = HighestHls.singleRendition(
      master,
      base,
      presentation: const PlaybackPresentation(),
    )!;
    expect(dv, contains('/movie/dv.m3u8'));
  });
  test(
    'single-format HDR keeps a usable fallback rather than an empty playlist',
    () {
      final onlyHdr = master.replaceAll(
        RegExp(r'#EXT-X-STREAM-INF:[^\n]*SDR[^\n]*\nsdr.m3u8\n'),
        '',
      );
      final result = HighestHls.singleRendition(
        onlyHdr,
        base,
        presentation: const PlaybackPresentation(
          hdrEnabled: false,
          dolbyVision: false,
        ),
      )!;
      expect(result, contains('/movie/hdr.m3u8'));
      expect(RegExp('#EXT-X-STREAM-INF:').allMatches(result).length, 1);
    },
  );
  test('SRT and VTT timing, overlapping cues and backwards seek', () {
    final srt = TextSubtitles.parse(
      '1\n00:00:01,000 --> 00:00:03,000\n<b>你好</b>\n\n2\n00:00:02,000 --> 00:00:04,000\nWorld\n',
    );
    expect(srt.at(const Duration(milliseconds: 999)), '');
    expect(srt.at(const Duration(seconds: 2)), '你好\nWorld');
    expect(srt.at(const Duration(seconds: 3)), 'World');
    expect(srt.at(const Duration(seconds: 1)), '你好');
    expect(srt.at(const Duration(seconds: 4)), '');
    final vtt = TextSubtitles.parse(
      'WEBVTT\n\ncue\n01:02.000 --> 01:04.000 align:start\nA &amp; B\n',
    );
    expect(vtt.at(const Duration(seconds: 63)), 'A & B');
    final crOnly = TextSubtitles.parse(
      'WEBVTT\r\r00:01.000 --> 00:02.000\r第一行\r第二行\r',
    );
    expect(crOnly.at(const Duration(seconds: 1)), '第一行\n第二行');
    expect(TextSubtitles.parse('\ufeff00:01.000 --> 00:02.000\n带 BOM 的字幕\n')
        .at(const Duration(seconds: 1)), '带 BOM 的字幕');
    expect(TextSubtitles.parse('<html>Error</html>').cues, isEmpty);
  });
  test(
    'UTF16 text imports and non-subtitle files fail without replacing captions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lume-subtitle-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/test.srt');
      const text = '1\n00:00:01,000 --> 00:00:02,000\n你好\n';
      await file.writeAsBytes([
        255,
        254,
        for (final c in text.codeUnits) ...[c & 255, c >> 8],
      ]);
      expect(
        (await TextSubtitles.load(file.path))!.at(const Duration(seconds: 1)),
        '你好',
      );
      await file.writeAsString('not a subtitle');
      expect(await TextSubtitles.load(file.path), isNull);
    },
  );
  test('VTT comments and metadata never become visible dialogue', () {
    final subtitles = TextSubtitles.parse(
      'WEBVTT\n\nNOTE timing example\n00:01.000 --> 00:03.000\n不要播放这条注释\n\n'
      'STYLE\n00:01.000 --> 00:03.000\n不要播放样式\n\n'
      'REGION\n00:01.000 --> 00:03.000\n不要播放区域\n\n'
      'NOTEworthy\n00:01.000 --> 00:03.000\n真实对白\n',
    );
    expect(subtitles.at(const Duration(seconds: 2)), '真实对白');
    expect(TextSubtitles.parse('WEBVTT\n\nNOTE\n00:01.000 --> 00:02.000\n注释\n').cues, isEmpty);
  });
  test('invalid subtitle timestamps cannot poison the remaining cues', () {
    final huge = '9' * 400;
    final subtitles = TextSubtitles.parse(
      '1\n$huge:00:01.000 --> $huge:00:02.000\n溢出\n\n'
      '2\n-00:01.000 --> 00:03.000\n负数\n\n'
      '3\n00:61.000 --> 00:62.000\n越界\n\n'
      '4\n00:01.000 --> 00:03.000broken\n错误时间\n\n'
      '5\n00:01.000 --> 00:03.000\n正常字幕\n',
    );
    expect(subtitles.cues, hasLength(1));
    expect(subtitles.at(const Duration(seconds: 2)), '正常字幕');
  });
  test('native channel addresses one player and tolerates a missing platform implementation', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AvPresentationChannel.channel, (
      call,
    ) async {
      calls.add(call);
      return ['片源：HDR'];
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AvPresentationChannel.channel,
        null,
      ),
    );
    expect(await AvPresentationChannel.invoke<List<Object?>>(9, 'status'), [
      '片源：HDR',
    ]);
    expect(calls.single.arguments, {'playerId': 9});
    expect(await AvPresentationChannel.invoke<Object?>(null, 'status'), isNull);
    messenger.setMockMethodCallHandler(AvPresentationChannel.channel, null);
    expect(await AvPresentationChannel.invoke<Object?>(9, 'status'), isNull);
  });
  testWidgets('each independent switch preserves the remaining preferences', (
    tester,
  ) async {
    var settings = const PlayerSettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => SingleChildScrollView(
              child: PresentationSettingsCard(
                settings: settings,
                onChanged: (next) => update(() {
                  settings = next;
                }),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('HDR 与杜比'));
    await tester.pumpAndSettle();
    final hdr = find.ancestor(
      of: find.text('启用 HDR'),
      matching: find.byType(SwitchListTile),
    );
    tester.widget<SwitchListTile>(hdr).onChanged!(false);
    await tester.pump();
    expect(settings.presentation.hdrEnabled, false);
    expect(settings.presentation.dolbyVision, true);
    expect(settings.presentation.dolbyAudio, true);
    expect(settings.subtitlesEnabled, true);
    expect(settings.presentation.enhancementEnabled, false);
    final dolby = find.ancestor(
      of: find.text('优先杜比音频'),
      matching: find.byType(SwitchListTile),
    );
    tester.widget<SwitchListTile>(dolby).onChanged!(false);
    await tester.pump();
    expect(settings.presentation.hdrEnabled, false);
    expect(settings.presentation.dolbyVision, true);
    expect(settings.presentation.dolbyAudio, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
