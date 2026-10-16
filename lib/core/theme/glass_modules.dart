enum GlassModule {
  all('全 App 通用'),
  novel('小说'),
  comic('漫画 / 美图'),
  video('视频 / 影视'),
  cat('猫源'),
  audioBook('有声小说'),
  sources('源管理 / 订阅'),
  settings('全局设置'),
  search('搜索');

  const GlassModule(this.label);
  final String label;
  static GlassModule fromId(String id) => GlassModule.values.firstWhere(
    (value) => value.name == id,
    orElse: () => GlassModule.all,
  );
}

enum GlassPart {
  navigation('顶部导航'),
  home('首页功能 / 分类筛选'),
  dock('底部导航'),
  cards('卡片 / 列表表面'),
  panels('抽屉 / 弹窗面板'),
  buttons('小型操作按钮'),
  badges('小型标签 / 数字徽标'),
  toasts('小型提示'),
  progress('进度条 / 进度提示');

  const GlassPart(this.label);
  final String label;
}
