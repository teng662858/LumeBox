/// 图源的**展示名**（只影响界面文字，不动脚本、不动数据）。
///
/// 用户口径：下拉框等处的名字要中文、要好认（例：`NN韩漫` → **鸟鸟韩漫**）。
/// **脚本内部的 id / 变量 / 解析逻辑一个都不改**——收藏、阅读记录、阅读进度、
/// 分页记忆、WAF 会话全部按图源 id 存，改展示名不会碰它们。
///
/// 落地方式：只在**界面拿到的展示模型**（`SourceDescriptor.name`）与验证窗标题上
/// 过一道映射；脚本自报的名字（`LumeSource.name`、数据库里的 name 字段）保持原样，
/// 「更新订阅源」时也不会被这里覆盖——它只是显示层的一层别名字典。
///
/// 表里没有的 id 原样透传：新源导入后立刻就有名字，不需要先来登记。
class SourceDisplayNames {
  SourceDisplayNames._();

  /// id → 中文展示名。新增一条即生效（不用改任何脚本）。
  static const Map<String, String> _names = <String, String>{
    // 漫画
    'mh92_comic': '92漫画',
    'daniao5_comic': '大鸟禁漫',
    'p5mh_comic': 'P5韩漫',
    'seyoumanhua_comic': '色友漫画',
    'nnhanman_comic': '鸟鸟韩漫',
    // 小说
    '99xs_novel': 'CA小说',
    'xchina_novel': '小黄书小说',
    'xxiaoshuo_novel': 'X小说',
    // 视频
    'gztv5_video': '瓜子影视',
    'dage_video': '大哥视频',
    'luttt_video': '北觅影视',
    'vv3nwjk_video': '金牌影院',
  };

  /// 这个图源在界面上该显示什么名字。[fallback] 是脚本自报的名字。
  static String of(String sourceId, [String fallback = '']) {
    final mapped = _names[sourceId.trim()];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    return fallback;
  }

  /// 仅测试用：表里有哪些 id（钉住「映射不改 id」这条口径）。
  static Map<String, String> get table => Map<String, String>.unmodifiable(_names);
}
