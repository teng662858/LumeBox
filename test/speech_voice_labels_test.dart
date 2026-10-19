import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_voice_labels.dart';

void main() {
  test('系统音色名称、质量和语言显示中文，未知名称保持可辨认', () {
    expect(
      SpeechVoiceLabels.label({'name': 'Tingting', 'language': 'zh-CN'}),
      '婷婷 · 普通话',
    );
    expect(
      SpeechVoiceLabels.label({'name': 'Grandma', 'language': 'zh_CN'}),
      '奶奶 · 普通话',
    );
    expect(
      SpeechVoiceLabels.label({
        'name': 'Sin-ji (Enhanced)',
        'language': 'zh-HK',
      }),
      '善怡（增强） · 粤语',
    );
    expect(
      SpeechVoiceLabels.label({'name': 'Mei-Jia', 'language': 'zh-TW'}),
      '美嘉 · 普通话（台湾）',
    );
    expect(
      SpeechVoiceLabels.label({'name': 'Unknown Voice', 'language': 'en-US'}),
      'Unknown Voice · 英语',
    );
    expect(SpeechVoiceLabels.label({'id': 'private-id'}), '系统音色');
    expect(SpeechVoiceLabels.name('Eddy'), '埃迪');
    expect(SpeechVoiceLabels.name('Flo'), '弗洛');
    expect(SpeechVoiceLabels.name('Reed'), '里德');
    expect(SpeechVoiceLabels.name('Rocko'), '洛克');
    expect(SpeechVoiceLabels.name('Sandy'), '桑迪');
  });
}
