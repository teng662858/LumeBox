import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source_display_names.dart';

/// 图源**展示名**（用户口径：下拉框里显示中文名，例如 NN韩漫 → 鸟鸟韩漫）。
///
/// 这一层只改界面文字：脚本里的 id / 变量 / 解析逻辑、数据库里的 name 字段都不动
/// ——收藏、阅读记录、阅读进度、WAF 会话全都按 **id** 存，改名字不会碰它们。
void main() {
  test('已知图源给中文展示名（用户点名的两个在内）', () {
    expect(SourceDisplayNames.of('nnhanman_comic', 'NN韩漫'), '鸟鸟韩漫');
    expect(SourceDisplayNames.of('xchina_novel', 'xChina 小说'), '小黄书小说');
    expect(SourceDisplayNames.of('mh92_comic', '92漫画'), '92漫画');
    expect(SourceDisplayNames.of('gztv5_video', '瓜子影视'), '瓜子影视');
  });

  test('表里没有的 id 原样用脚本自报的名字（新源导入即有名）', () {
    expect(SourceDisplayNames.of('brand_new_source', '新图源'), '新图源');
    expect(SourceDisplayNames.of('', ''), '');
  });

  test('映射的键就是图源 id：id 本身不变（收藏与记录都按它存）', () {
    for (final entry in SourceDisplayNames.table.entries) {
      expect(
        entry.key,
        isNot(contains(' ')),
        reason: 'id 里不会有空格——展示名才带空格（例：xChina 小说 → 小黄书小说）',
      );
      expect(entry.value, entry.value.trim());
      expect(entry.value, isNotEmpty, reason: '别把展示名映射成空串（会退化成无名）');
    }
  });
}
