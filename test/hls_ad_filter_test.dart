import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/hls_ad_filter.dart';

const vod =
    '#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:8,\nmain.ts\n#EXT-X-CUE-OUT:8\n#EXTINF:8,\nad.ts\n#EXT-X-CUE-IN\n#EXTINF:8,\nnext.ts\n#EXT-X-ENDLIST\n';
void main() {
  test('只移除完整广告区间及 EXTINF，保留正片和衔接标记', () {
    final result = HlsAdFilter.filter(vod);
    expect(result, isNot(contains('\nad.ts')));
    expect(result, contains('main.ts'));
    expect(result, contains('next.ts'));
    expect(result, contains('#EXT-X-DISCONTINUITY'));
    expect(RegExp('#EXTINF:').allMatches(result).length, 2);
  });
  test('直播、加密、映射、字节范围和未闭合广告保持原样', () {
    for (final text in [
      vod.replaceAll('#EXT-X-ENDLIST', ''),
      vod.replaceAll('#EXT-X-CUE-IN', ''),
      vod.replaceAll('#EXT-X-CUE-OUT:8', ''),
      '#EXT-X-KEY:METHOD=AES-128\n$vod',
      '#EXT-X-MAP:URI="init.mp4"\n$vod',
      '#EXT-X-BYTERANGE:3\n$vod',
    ]) {
      expect(HlsAdFilter.filter(text), text);
    }
  });
  test('正常转场和跨域分片没有广告标记时不删除', () {
    const text =
        '#EXTM3U\n#EXTINF:8,\nhttps://a.test/1.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:8,\nhttps://b.test/ad.ts\n#EXT-X-ENDLIST';
    expect(HlsAdFilter.filter(text), text);
  });
}
