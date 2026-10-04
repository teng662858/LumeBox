/// 四大板块。图源、数据库、缓存目录在板块间完全隔离，不可跨板块互通。
enum Section {
  novel('novel', '小说'),
  comic('comic', '漫画'),
  video('video', '自定义视频'),
  cat('cat', '猫源');

  const Section(this.id, this.label);

  /// 稳定标识：用于数据库文件名、缓存目录名、图源归属。
  final String id;

  final String label;
}
