import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/search/search_settings.dart';
import 'package:lume_box/features/video/playback_quality_preference.dart';

void main() {
  VideoQuality quality(String label) => VideoQuality(
    label: label,
    url: Uri.parse('https://example.com/$label.mp4'),
  );
  final choices = ['高清', '超清', '4K', '原画', '480p'].map(quality).toList();
  test('续播保留会话画质，不依赖跨会话记忆开关', () {
    final next = [quality('720p'), quality('960p'), quality('1080p')];
    expect(
      PlaybackQualityPreference.select(
        next,
        const PlayerSettings(defaultQuality: DefaultQuality.hd),
        currentQuality: quality('1080p'),
      )?.label,
      '1080p',
    );
    expect(
      PlaybackQualityPreference.select(
        next,
        const PlayerSettings(),
        currentQuality: quality('超清'),
      )?.label,
      '1080p',
    );
    expect(
      PlaybackQualityPreference.select(
        [quality('720p')],
        const PlayerSettings(),
        currentQuality: quality('1080p'),
      )?.label,
      '720p',
    );
  });
  test('记忆优先，其次全局预设，最后最高；关闭记忆不读取旧值', () {
    expect(
      PlaybackQualityPreference.select(
        choices,
        const PlayerSettings(
          rememberManualQuality: true,
          manualQualityLabel: '高清',
          defaultQuality: DefaultQuality.uhd,
        ),
      )?.label,
      '高清',
    );
    expect(
      PlaybackQualityPreference.select(
        choices,
        const PlayerSettings(
          rememberManualQuality: true,
          manualQualityLabel: '不存在',
          defaultQuality: DefaultQuality.uhd,
        ),
      )?.label,
      '4K',
    );
    expect(
      PlaybackQualityPreference.select(
        choices,
        const PlayerSettings(
          manualQualityLabel: '高清',
          defaultQuality: DefaultQuality.fullHd,
        ),
      )?.label,
      '超清',
    );
    expect(
      PlaybackQualityPreference.select([
        quality('高清'),
        quality('4K'),
      ], const PlayerSettings(defaultQuality: DefaultQuality.original))?.label,
      '4K',
    );
    expect(
      PlaybackQualityPreference.select(choices, const PlayerSettings())?.label,
      '原画',
    );
  });
  test('中文及繁体标签映射、缺项回退与空列表', () {
    for (final label in ['超清', '蓝光', '藍光']) {
      expect(quality(label).resolutionRank, 1080);
    }
    expect(quality('高清').resolutionRank, 720);
    expect(quality('標清').resolutionRank, 480);
    expect(
      PlaybackQualityPreference.select([
        quality('1080p'),
        quality('480p'),
      ], const PlayerSettings(defaultQuality: DefaultQuality.uhd))?.label,
      '1080p',
    );
    expect(
      PlaybackQualityPreference.select([
        quality('默认线路'),
      ], const PlayerSettings())?.label,
      '默认线路',
    );
    expect(
      PlaybackQualityPreference.select([], const PlayerSettings()),
      isNull,
    );
  });
  test('默认清晰度与毛玻璃默认值、复制和相等性', () {
    const original = PlayerSettings();
    expect(original.defaultQuality, DefaultQuality.automatic);
    expect(original.playbackGlass, isFalse);
    expect(
      original.copyWith(defaultQuality: DefaultQuality.sd),
      isNot(original),
    );
    expect(original.copyWith(playbackGlass: false), original);
    expect(DefaultQuality.parse('bad'), DefaultQuality.automatic);
  });
  test('搜索繁转简按词匹配，非中文保留，精确搜索可关闭', () {
    expect(
      SearchSettings.toSimplified('龍馬與電視劇，臺灣頭髮 1080P'),
      '龙马与电视剧，台湾头发 1080P',
    );
    final prefs = SearchSettings.instance;
    prefs.simplify = true;
    prefs.exact = true;
    expect(prefs.prepare('  電視劇  '), '电视剧');
    expect(prefs.accepts('電視劇', '电视剧'), isTrue);
    expect(prefs.accepts('电视剧第二部', '电视剧'), isFalse);
    prefs.exact = false;
    expect(prefs.accepts('其他结果', '关键词'), isTrue);
    prefs.simplify = false;
    expect(prefs.prepare('電視劇'), '電視劇');
    prefs.simplify = true;
  });
}
