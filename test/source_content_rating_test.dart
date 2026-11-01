import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source_content_rating.dart';

void main() {
  test('仓库明确分级的新增源和带命名空间的 ID 均识别为 18+', () {
    for (final id in [
      'jcomic_comic',
      'long91_comic',
      'xtube_video',
      'xchina_audiobook',
      'kaotic_video',
      'nnhanman_comic',
      'smtt6_comic',
      'relamanhua_comic',
      'xvideos_video',
      'p5mh_comic',
      'fxcomic_comic',
      'zhilian-duanju',
      'cg1_photo',
      'cg1_video',
      'betareel_video',
      'gamebus_comic',
      'gamebus_video',
      'tanhua_video',
      'f016_video',
      'resao_video',
      'yuxiu_video',
      'tianlula_video',
      'tianlula_photo',
      'haijiaoqing_video',
      'aiboaibo_video',
      'jizeyy_video',
      'hsex_video',
      'reddxxx_video',
      'theavporn_video',
      's618_video',
      'kkav_video',
      'twitthub_video',
      'd9y1w_video',
      'pornbest_video',
      'porn91plus_video',
      'pornlulu_video',
      'porn9188_video',
      'mtav_video',
      'heroero_video',
      'qinav_video',
    'laosiji_video',
    'fplayer_video',
    'forcedcinema_video',
    'avbebe_video',
    'cartoonporn_video',
    'pmvtube_video',
    'sexbjcam_video',
    'xxxfollow_video',
    'gifscroll_video',
    'xiaohuangniao_video',
    'ogfap_video',
    'hstream_video',
    'p91pinse_video',
    'ho5ho_comic',
    'rule34video_video',
    'oreno3d_video',
    'xcamtube_video',
    'madoutv_video',
    ]) {
      expect(SourceContentRating.isAdult(id, ''), isTrue);
      expect(SourceContentRating.isAdult('subscription:$id', ''), isTrue);
      expect(SourceContentRating.isAdult('subscription|$id', ''), isTrue);
    }
  });
  test('未知源不凭版本号或普通名字误标', () {
    expect(SourceContentRating.isAdult('unknown', '普通影视'), isFalse);
    expect(SourceContentRating.isAdult('version_18', '普通站点'), isFalse);
    expect(SourceContentRating.isAdult('SUB:FXCOMIC_COMIC', ''), isTrue);
    expect(SourceContentRating.isAdult('imported_custom_id', 'P5韩漫'), isTrue);
    expect(SourceContentRating.isAdult('imported_custom_id', 'SpankBang'), isTrue);
    expect(SourceContentRating.isAdult('unknown', '普通站点评论'), isFalse);
    for (final name in ['18＋', '18 +', 'R-18', 'r 18']) {
      expect(SourceContentRating.isAdult('new_source', name), isTrue);
    }
  });
}
