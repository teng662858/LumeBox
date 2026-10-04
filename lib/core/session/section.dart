/// 四大板块。图源、数据库、缓存目录在板块间完全隔离，不可跨板块互通。
enum Section {
  novel('novel', '小说'),
  comic('comic', '漫画'),
  video('video', '视频'),
  cat('cat', '猫源');

  const Section(this.id, this.label);

  /// 稳定标识：用于数据库文件名、缓存目录名、图源归属。
  ///
  /// **底层标识符，任何展示改动都不许动它**——视频板块的库、缓存与图源记录
  /// 都落在 `sections/video/` 之下，改它就等于换了一套数据。
  final String id;

  /// 展示文案（界面上显示的名字）。视频板块的展示名为「视频」，
  /// 与内部标识 `video` 是两回事：文案可改，标识不可改。
  final String label;
}
