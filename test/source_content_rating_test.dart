import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source_content_rating.dart';

void main() {
  test('Stripchat 直播源按 18+ 隔离', () {
    expect(SourceContentRating.isAdult('stripchat_live_video', '直播源'), isTrue);
  });
  test('PY合集成人源全部登记', () {
    for (final id in <String>[
      'pypack_02c9b149e1a6c17c',
      'pypack_035ad44c7cfa4911',
      'pypack_039fc633d5411ce5',
      'pypack_044068473e0303be',
      'pypack_080362d6222f8d32',
      'pypack_0cab865ff159c1fd',
      'pypack_0fa95981ae4f3015',
      'pypack_13192b0f19124210',
      'pypack_14c974b7e43130e0',
      'pypack_1545f23820617dc8',
      'pypack_169f40b6923802fe',
      'pypack_188d3d5770e9c9dc',
      'pypack_1ca85e9f09038929',
      'pypack_1fd0a1be766d7b05',
      'pypack_212b74af09e423b2',
      'pypack_2629ee05b2ac3eaf',
      'pypack_2802226610d4e6c2',
      'pypack_28f71b72956965f4',
      'pypack_3042d332a8ee89e5',
      'pypack_347be6b91aa06257',
      'pypack_352c21db33be3427',
      'pypack_373136a3ed1617f1',
      'pypack_3d7dffbaeec81d24',
      'pypack_40321f7e9e507396',
      'pypack_404e583d4c7b09a0',
      'pypack_491ad8064be66652',
      'pypack_4c860756bba96c00',
      'pypack_4cdfb404f7da5cca',
      'pypack_52a1686b1efed9a8',
      'pypack_549496d6e862b0db',
      'pypack_55b2e6841964471b',
      'pypack_5ae710262db60781',
      'pypack_5e60e725a825e9e1',
      'pypack_66515b5817a196f0',
      'pypack_67127010003a8ec7',
      'pypack_6801804eecf1b0ce',
      'pypack_6b049c4e0b2b3ff6',
      'pypack_6c2cc842049cd28d',
      'pypack_6ff24041e6c8c703',
      'pypack_71f0984fc2a49e62',
      'pypack_723fd810eaeae521',
      'pypack_78875f382dd4a609',
      'pypack_794ea446a150d735',
      'pypack_7a615a369fb3f055',
      'pypack_8150f4dc8fbe64db',
      'pypack_848d31242beb0ab9',
      'pypack_8535d5c4a40c0174',
      'pypack_87e83502384a0eba',
      'pypack_8834e2ad23fa3ad9',
      'pypack_8d2f80865c942d19',
      'pypack_8d4d40be57ae814e',
      'pypack_8d8b8d926b7d858a',
      'pypack_8f4699005dff15c2',
      'pypack_974c88bd7ff4e50e',
      'pypack_9932d9ac3e3680fd',
      'pypack_a0e18a45cf84fc00',
      'pypack_a75ceff6963d4930',
      'pypack_a8990556ad2e6277',
      'pypack_ac18f1ead1d18b21',
      'pypack_b11f4ecce820a17c',
      'pypack_b6ab593a7e33e63d',
      'pypack_b7bf8b0f1eb0e1da',
      'pypack_bbbc0c3df2696c99',
      'pypack_c20d21a3b2666142',
      'pypack_c8c7380efd79eaa4',
      'pypack_ccbbb52aea68400b',
      'pypack_daf13bb5f32259b4',
      'pypack_df3dd9f97a066d9f',
      'pypack_e3c62fdc39efc998',
      'pypack_eb5d0c9439edad02',
      'pypack_ee97103063bb832a',
      'pypack_f02cdca2ef3b69ca',
      'pypack_f103a317c218faad',
      'pypack_f837697be39f3e55',
    ]) {
      expect(SourceContentRating.isAdult(id, 'PY合集'), isTrue);
    }
  });

  test('新发布源按已安装脚本声明分级，无需重新编译 ID 表', () {
    const id = 'remote_python_rating_fixture';
    expect(SourceContentRating.isAdult(id, '新发布源'), false);
    SourceContentRating.registerDeclaration(id, 'adult');
    expect(SourceContentRating.isAdult(id, '新发布源'), true);
    SourceContentRating.registerDeclaration(id, 'movie');
    expect(SourceContentRating.isAdult(id, '新发布源'), false);
    SourceContentRating.registerDeclaration('jm18_comic', 'movie');
    expect(SourceContentRating.isAdult('jm18_comic', '已知源'), true);
  });
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
      'itsacg_comic',
      'yeshezy_video',
      'hsckzy_video',
      'lao4j_video',
      'uaa_video',
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
      'mitaow_video',
      'mitaovideo_video',
      'chengshe_video',
      'akmh_video',
      'insav_video',
      'livebox_video',
      'akmh_comic',
      'kpdz_video',
      'alicesw_comic',
      '91dasj_video',
      'xiguashuwu_comic',
      '8csk_comic',
      'mycall_video',
      'yueliang_comic',
      'liz_video',
      'lcm_video',
      'jmcomic_video',
      'jmcomic_novel',
      'shuba_novel',
      'ciyuanji_novel',
      'cool18_comic',
      'diyibanzhu_novel',
      'miaobo_video',
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
    expect(
      SourceContentRating.isAdult('imported_custom_id', 'SpankBang'),
      isTrue,
    );
    expect(SourceContentRating.isAdult('unknown', '普通站点评论'), isFalse);
    for (final name in ['18＋', '18 +', 'R-18', 'r 18']) {
      expect(SourceContentRating.isAdult('new_source', name), isTrue);
    }
  });
  test('2026-11-09 三个新源按 18+ 归档', () {
    for (final id in <String>[
      'jifangge_video',
      'xyunsou_video',
      'book18_novel',
    ]) {
      expect(SourceContentRating.isAdult(id, ''), isTrue);
    }
    // 显示名也要认（导入的自定义 id 靠名字兜底）
    expect(SourceContentRating.isAdult('custom', '集芳阁云搜'), isTrue);
    expect(SourceContentRating.isAdult('custom', 'X云搜'), isTrue);
    expect(SourceContentRating.isAdult('custom', '色文網'), isTrue);
  });
}
