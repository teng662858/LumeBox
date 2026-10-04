/// 阅读体系底座（Phase2）。
///
/// 分层：
/// - [ReadingStore]：板块独占的 `reading.db`（书架 / 进度 / 阅读设置）与
///   `reading_cache/` 目录，隔离规则与图源库一致（目录 + 归属标记 + 写入拦截）；
/// - [ReadingLibrary]：书架与进度的领域门面，四个阅读页面共用；
/// - [ReadingProgress] / [LibraryItem]：阅读数据模型，含未读角标与两套进度口径；
/// - [SectionImagePipeline]：图片管线（网络 → 磁盘 → 解码 → 内存 LRU），
///   带请求取消、预加载窗口与位图释放。
library;

export 'image_pipeline.dart';
export 'reading_library.dart';
export 'reading_models.dart';
export 'reading_store.dart';
