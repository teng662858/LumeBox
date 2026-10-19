/// Display names only. The original voice identifier is always sent to TTS.
abstract final class SpeechVoiceLabels {
  static const _names = {
    'tingting': '婷婷',
    'eddy': '埃迪',
    'flo': '弗洛',
    'grandma': '奶奶',
    'grandpa': '爷爷',
    'reed': '里德',
    'rocko': '洛克',
    'sandy': '桑迪',
    'shelley': '雪莉',
    'sinji': '善怡',
    'meijia': '美嘉',
    'yushu': '语舒',
    'hanhan': '涵涵',
    'honghong': '宏宏',
    'lili': '丽丽',
    'limu': '李沐',
    'albert': '阿尔伯特',
    'alice': '爱丽丝',
    'anna': '安娜',
    'daniel': '丹尼尔',
    'david': '大卫',
    'karen': '凯伦',
    'kathy': '凯西',
    'samantha': '萨曼莎',
    'susan': '苏珊',
    'thomas': '托马斯',
    'victoria': '维多利亚',
    'alex': '亚历克斯',
    'junior': '少年',
    'whisper': '低语',
    'badnews': '坏消息',
    'goodnews': '好消息',
    'bells': '铃声',
    'boing': '弹簧',
    'bubbles': '气泡',
    'cellos': '大提琴',
    'jester': '小丑',
    'organ': '管风琴',
    'superstar': '超级明星',
    'bahh': '绵羊',
    'trinoids': '三重音',
    'zarvox': '扎沃克斯',
  };

  static String name(String raw) {
    final name = raw.trim();
    final match = RegExp(
      r'^(.*?)\s*\((Enhanced|Premium|Compact)\)$',
      caseSensitive: false,
    ).firstMatch(name);
    final base = match?.group(1) ?? name;
    final key = base.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
    final translated = _names[key] ?? base;
    final quality = switch (match?.group(2)?.toLowerCase()) {
      'enhanced' => '增强',
      'premium' => '高品质',
      'compact' => '精简',
      _ => null,
    };
    return quality == null ? translated : '$translated（$quality）';
  }

  static String language(String raw) {
    final tag = raw.replaceAll('_', '-').toLowerCase();
    if (tag.startsWith('yue') || tag == 'zh-hk') return '粤语';
    if (tag == 'zh-tw' || tag.startsWith('zh-hant')) return '普通话（台湾）';
    if (tag == 'zh-sg') return '普通话（新加坡）';
    final base = tag.split('-').first;
    return const {
          'zh': '普通话',
          'en': '英语',
          'ja': '日语',
          'ko': '韩语',
          'fr': '法语',
          'de': '德语',
          'es': '西班牙语',
          'it': '意大利语',
          'pt': '葡萄牙语',
          'ru': '俄语',
          'ar': '阿拉伯语',
          'hi': '印地语',
          'th': '泰语',
          'vi': '越南语',
          'id': '印度尼西亚语',
          'nl': '荷兰语',
          'tr': '土耳其语',
          'pl': '波兰语',
          'sv': '瑞典语',
          'fi': '芬兰语',
          'da': '丹麦语',
          'no': '挪威语',
          'nb': '挪威语',
          'cs': '捷克语',
          'el': '希腊语',
          'he': '希伯来语',
          'uk': '乌克兰语',
          'ro': '罗马尼亚语',
          'hu': '匈牙利语',
          'sk': '斯洛伐克语',
          'ms': '马来语',
        }[base] ??
        (raw.isEmpty ? '' : raw);
  }

  static String label(Map<dynamic, dynamic> voice) {
    final raw = voice['name'] is String ? voice['name'] as String : '';
    final displayName = raw.trim().isEmpty ? '系统音色' : name(raw);
    final locale = language('${voice['language'] ?? ''}');
    return locale.isEmpty ? displayName : '$displayName · $locale';
  }
}
