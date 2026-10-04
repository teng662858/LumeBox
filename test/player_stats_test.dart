import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_stats.dart';

/// HUD 参数模型的验证：格式化、缺项省略、单位换算后的展示口径。
void main() {
  test('空参数：不产出任何片段（HUD 整块不渲染）', () {
    expect(PlayerStats.empty.chips, isEmpty);
    expect(PlayerStats.empty.isEmpty, isTrue);
    expect(PlayerStats.empty.hasParameters, isFalse);
  });

  test('分辨率：只有宽高都拿到且为正才显示', () {
    expect(const PlayerStats(width: 1920, height: 1080).resolutionText, '1920×1080');
    expect(const PlayerStats(width: 1920).resolutionText, isNull);
    expect(const PlayerStats(width: 0, height: 1080).resolutionText, isNull);
  });

  test('码率：视频优先，kbps 与 Mbps 两种口径', () {
    expect(
      const PlayerStats(videoBitrateKbps: 1800).bitrateText,
      '1.8Mbps',
    );
    expect(
      const PlayerStats(audioBitrateKbps: 320).bitrateText,
      '320kbps',
    );
    expect(
      const PlayerStats(videoBitrateKbps: 2200, audioBitrateKbps: 128).bitrateText,
      '2.2Mbps',
      reason: '视频码率优先于音频',
    );
    expect(const PlayerStats(videoBitrateKbps: 0).bitrateText, isNull);
  });

  test('帧率：整数不带小数，非整数保留两位', () {
    expect(const PlayerStats(fps: 30).fpsText, '30FPS');
    expect(const PlayerStats(fps: 29.97).fpsText, '29.97FPS');
    expect(const PlayerStats(fps: 0).fpsText, isNull);
  });

  test('编码：视频编码优先，只有音频时给音频编码；统一大写', () {
    expect(
      const PlayerStats(videoCodec: 'hevc', audioCodec: 'aac').codecText,
      'HEVC',
    );
    expect(const PlayerStats(audioCodec: 'aac').codecText, 'AAC');
    expect(const PlayerStats(videoCodec: '  ').codecText, isNull);
  });

  test('缓冲：缓冲中优先，其后是前方已缓冲时长', () {
    expect(const PlayerStats(buffering: true).bufferText, '缓冲中');
    expect(
      const PlayerStats(buffered: Duration(seconds: 12)).bufferText,
      '缓冲 12s',
    );
    expect(
      const PlayerStats(buffered: Duration(minutes: 1, seconds: 30)).bufferText,
      '缓冲 1m30s',
    );
    expect(const PlayerStats(buffered: Duration.zero).bufferText, isNull);
  });

  test('chips：固定顺序「内核 / 编码 / 分辨率 / 帧率 / 码率 / 缓冲」，缺项省略', () {
    const full = PlayerStats(
      engineLabel: 'MPV',
      videoCodec: 'hevc',
      audioCodec: 'aac',
      videoBitrateKbps: 1800,
      fps: 30,
      width: 1920,
      height: 1080,
      buffered: Duration(seconds: 8),
    );
    expect(full.chips, <String>[
      'MPV',
      'HEVC',
      '1920×1080',
      '30FPS',
      '1.8Mbps',
      '缓冲 8s',
    ]);
    expect(full.hasParameters, isTrue);

    // AVPlayer 内核拿不到编码 / 帧率 / 码率：只剩内核名与它真有的两项。
    const avplayer = PlayerStats(
      engineLabel: 'AVPlayer',
      width: 1280,
      height: 720,
      buffered: Duration(seconds: 3),
    );
    expect(avplayer.chips, <String>['AVPlayer', '1280×720', '缓冲 3s']);

    // 只有内核名时不产出参数片段。
    expect(const PlayerStats(engineLabel: 'MPV').hasParameters, isFalse);
  });
}
