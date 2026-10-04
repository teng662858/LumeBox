# Lume Box · Phase2 小说板块：已批准基线（底座 + 四页面 + 分页阅读器）+ 延后待办

两次验收分别对应任务书「Phase2 小说板块底座开发任务」（5 条要求）与
「Phase2 自研小说分页阅读器开发任务」（7 条要求）。本文档记录两个已批准基线与小说侧的延后待办。

## 一、已批准基线（小说板块底座与基础 UI）

| 验收项（任务书口径） | 落点 | 验证 |
|---|---|---|
| 1. 独立数据库表 + 独立缓存目录，与另外三大板块物理隔离 | `sections/novel/reading.db`（与 Phase1 图源库 `novel.db` **分文件**）+ `sections/novel/reading_cache/{images,exports}`；表 `library_item` / `reading_progress` / `reading_setting`；隔离三重：路径经 `SectionScope.resolve` 校验、库内自证 `owner_section`、写入拦截 `_requireOwn` | `test/reading_store_test.dart`：阅读库与图源库分文件 / 漫画与小说各存各的 / 库内自证归属：标记不符拒绝打开 / 跨板块写入被拒绝 |
| 2. 小说专属独立 JSContext，复用现有沙箱桥接 | 复用 Phase1 `SourceRegistry`：`LumeSources.manager(Section.novel)` → 本板块注册表（自带引擎表 + 库 + HTTP 客户端），一图源一个 `LumeJsEngine`（= 一个 `LumeSandbox` = 一个 JSRuntime + JSContext）；脚本只从本板块库读出（`_belongs` 归属校验），网络只经 `LumeSourceHost` → `LumeHttp`，JS 侧无 socket / 文件权限 | Phase1 既有 `test/section_database_test.dart`、`test/source_manager_test.dart` + 本轮隔离用例 |
| 3. UI：小说书架 / 探索页 / 详情页 / 章节目录页 | `lib/features/novel/novel_page.dart`（外壳 + 书架/探索页签）、`novel_shelf_page.dart`、`novel_explore_page.dart`（共享 `ExploreView`：图源下拉 + 筛选抽屉 + 列表）、`novel_detail_page.dart`、`novel_catalog_page.dart`（正序/倒序、当前章高亮、点章即读） | `test/reading_shelf_test.dart`「小说书架：展示阅读进度与续读入口」；`test/reading_detail_test.dart`「小说详情：元信息 + 完整目录入口」「小说目录页：倒序切换与点章进阅读器」 |
| 4. 独立阅读进度：章节索引 + 文本字符偏移量 | `NovelProgress{chapterIndex, charOffset, chapterLength}`；落 `reading_progress.chapter_index` + `position`（= 字符偏移）+ `chapter_length`；`chapterRatio` 供书架/详情展示百分比；保存进度同时推进书架「最远读到」标记 | `test/reading_store_test.dart`「小说进度记录字符偏移，比例由章节长度算出」「书架按最近阅读排序」 |
| 5. Android / Windows 仅骨架 | `lib/features/novel/novel_page.dart` 平台门：`runtimeAvailable` 为假时不打开阅读库、不构建页签，直接 `SkeletonNotice` | `test/widget_test.dart`「非 iOS 平台进入板块只显示空页面骨架」 |

状态：`flutter analyze` 零问题；全量 175 个测试通过（本轮批准后未再改动代码）。

## 二、已批准基线（增量二：自研小说分页阅读器引擎）

验收口径来自任务书「Phase2 自研小说分页阅读器开发任务」的 7 条要求；本轮 0 行代码改动（存量实现直接验收）。

| 验收项（任务书口径） | 落点 | 验证 |
|---|---|---|
| 1. 4 种翻页模式：仿真 Curl / 平移 Slide / 覆盖 / 上下连续滚动 | `novel_turn_view.dart`（`_buildStage` :191、手势与动画 :53）、`novel_page_painter.dart`（`NovelTurnMode` :202、`NovelCurlPainter` :240）、`novel_reader_page.dart` :664（连续滚动） | `test/novel_reader_test.dart`「翻页模式可切换：上下滚动不再走翻页视图」（含模式落库断言） |
| 2. 可调排版：字号 / 行间距 / 段间距 / 页边距 | `novel_typesetting.dart` :11（`NovelTypesetting`，范围夹紧 + `signature`）、`novel_reader_page.dart` :852（四根滑杆）、:555（落库并触发重排） | 「排版参数可调：字号变化落库并触发重排」；`test/novel_pagination_test.dart`「换排版参数或视口会得到新的分页键」 |
| 3. 主题独立于 App 主题：羊皮纸 / 夜间深灰 / 护眼绿 / 纯白 | `novel_typesetting.dart` :134（`NovelReaderTheme`，四预设 :142–:170、自定义 :190）；阅读页背景、正文、页眉页脚、工具栏全部按主题取色 | 「阅读主题独立于 App 主题：切到夜间深灰后整页换背景」；`test/reading_store_test.dart`「排版参数与主题按板块各存各的」 |
| 4. 按屏幕尺寸 + 排版参数自动分页 | `novel_pagination.dart`：`NovelChapterText.parse` :30、`NovelPaginator.paginate` :193（逐段 TextPainter → LineMetrics → 按行切页）、`ChapterPagination.pageIndexForChar` :134、`NovelLayoutCache` :351（文本 + 分页两层 LRU、预取相邻章） | 「页与页首尾相接，且完整覆盖整章」「每页起始字符都能反查回同一页（进度可精确还原）」「字号变大页数变多，视口变高页数变少」 |
| 5. 独立阅读进度读写：章节索引 + 文本字符偏移量 | `NovelProgress{chapterIndex, charOffset, chapterLength}`；写点：翻页去抖 700ms / 切章前 / `dispose` 兜底（`novel_reader_page.dart` :452）；落小说板块独占库的 `reading_progress.chapter_index` + `position` + `chapter_length` | 「打开即分页，并按章节 + 字符偏移落下进度」「翻页推进字符偏移，进度按新位置落库」「续读：按保存的字符偏移回到当时那一页」；`reading_store_test`「小说进度记录字符偏移，比例由章节长度算出」 |
| 6. dispose 释放资源、取消未完成网络请求 | `novel_reader_page.dart` :120：停去抖 → 落进度 → 释放滚动控制器 → 释放页画布（推迟一帧）→ 清空 `NovelLayoutCache`。**取消口径（本轮确认沿用现状）**：小说侧没有可取消的 HTTP——章节文本经宿主数据源取得，Phase1 接口未暴露取消句柄；语义为「退出即屏蔽」（`await` 回来先查 `mounted`，未挂载即丢弃、不写缓存、不 setState），在飞请求由宿主超时收敛（沙箱单次调用 3–5s / `LumeHttp` 20s） | 阅读器用例 + `test/comic_reader_test.dart` 内存策略组（漫画侧真正取消请求的路径） |
| 7. Android / Windows 仅骨架 | `lib/features/novel/novel_page.dart` :40 平台门（不打开阅读库、不构建页签 → `SkeletonNotice`）；阅读器只有详情页一个入口，非 iOS 不可达 | `test/widget_test.dart`「非 iOS 平台进入板块只显示空页面骨架」 |

本增量文件清单：

| 文件 | 行数 | 作用 |
|---|---|---|
| `lib/features/novel/novel_reader_page.dart` | 1145 | 阅读器主体：模式切换、排版/主题/目录面板、进度落库、资源释放 |
| `lib/features/novel/novel_pagination.dart` | 420 | 分页引擎：TextPainter 逐段断行 → 按行切页 → 字符偏移映射 + 两层缓存 |
| `lib/features/novel/novel_page_painter.dart` | 351 | 页画笔（背景/正文/页眉页脚）与仿真 Curl 绘制 |
| `lib/features/novel/novel_turn_view.dart` | 251 | 翻页手势与动画（平移 / 覆盖 / Curl 共用一套几何） |
| `lib/features/novel/novel_typesetting.dart` | 245 | 排版参数与阅读主题（4 预设 + 自定义背景色） |
| `test/novel_pagination_test.dart`、`test/novel_reader_test.dart` | — | 17 个用例：分页覆盖面与字符映射、缓存、四种模式与主题独立、像素级渲染断言 |

验证状态：`flutter analyze` 零问题；全量 175 个测试通过（本增量 17 个）；全仓库无 WebView 依赖（唯一出现处是阅读器注释里写明「不用 WebView」）。Phase1 一行未改。

## 三、延后待办（小说侧）

1. **阅读器自身平台守卫**：非 iOS 现在由板块入口拦住、阅读器不可达；若要再加一层守卫（约 6 行，双保险）随下一轮处理。与漫画侧同一口径。
2. **严格「按请求取消」语义**：要让章节请求可被取消，需要在 Phase1 的 `DataSource` / `LumeHttp` 上开取消句柄。本轮经确认不改 Phase1，保持「退出即屏蔽 + 宿主超时收敛」；该改动需单独授权。

漫画侧三项延后待办（长按保存图片落点 / 旋屏锚点 / 阅读器平台守卫）记录在
`.zcode/plans/phase2-comic-reader-approved-and-deferred.md`，本轮未动。
