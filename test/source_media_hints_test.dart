import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source_media_hints.dart';

void main() {
  test('美图元数据和旧photo标识不会退回漫画分类', () {
    expect(
      SourceMediaHints.fromScript(
        '// LumeSource: {"mediaType":"photo","category":"comic"}',
      ),
      'photo',
    );
    expect(
      SourceMediaHints.fromScript(
        '// LumeSource: {"id":"sample_photo","category":"comic"}',
      ),
      'photo',
    );
    expect(
      SourceMediaHints.fromScript(
        '// LumeSource: {"id":"sample_comic","category":"comic"}',
      ),
      'comic',
    );
  });
  test('识别元数据与旧纯音频脚本，混合影视源不会误判为纯音频', () {
    expect(
      SourceMediaHints.fromScript('// LumeSource: {"mediaType":"audio"}'),
      'audio',
    );
    expect(
      SourceMediaHints.fromScript("return {kind:'audio', url:u};"),
      'audio',
    );
    expect(
      SourceMediaHints.fromScript(
        "return a ? {kind:'audio'} : {kind:'video'};",
      ),
      '',
    );
    expect(SourceMediaHints.audioLabel('小黄书听书'), isTrue);
    expect(SourceMediaHints.audioLabel('xchina_audiobook'), isTrue);
    expect(SourceMediaHints.audioLabel('普通影视小说改编'), isFalse);
  });
}
