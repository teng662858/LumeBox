/// 数据源抽象接口层。
///
/// 分层：
/// - [DataSource]：四个板块（小说 / 漫画 / 自定义视频 / 猫源）共用的统一接口，
///   UI 只依赖它；
/// - [SourceCategory] / [SourceItem] / [SourceDetail] / [SourceChapter] /
///   [ChapterContent]：共享数据模型与契约解析；
/// - [MockDataSource]：简单模拟实现，全平台可跑，供测试与样例；
/// - [JsDataSource] / [JsSourceRuntime]：把 QuickJS-NG 沙箱图源适配到统一接口；
/// - [LumeSources]：门面与组合根（图源管理与打开数据源）；
/// - [SourceManager] / [SourceImportResult]：图源管理界面依赖的端口与结果模型；
/// - [SourceStateKind] / [stateForError]：页面状态的统一分类，展示层据此选视图。
library;

export 'data_source.dart';
export 'js_data_source.dart';
export 'lume_sources.dart';
export 'mock_data_source.dart';
export 'source_backup.dart';
export 'source_manager.dart';
export 'source_models.dart';
export 'source_state.dart';
