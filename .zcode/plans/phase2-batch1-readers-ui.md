# Lume Box · Phase2 第一批：小说 + 漫画阅读器（UI）

立项口径（本次确认，含计划调整）：Phase2 第一批做**两个阅读器 UI**——小说分页阅读器与
漫画阅读器，均为纯本地阅读 UI 层。

- **明确不做**：Bangumi 追踪同步（属预留扩展，记在 `deferred-todo.md`「预留扩展（暂不开发）」，
  Phase2 本期不实现）；小说书签分组 UI（留后续批次）；漫画追踪同步；任何第三方账号同步；
- 漫画侧本批只做：**分页浏览、缩放、阅读设置（背景、点击翻页模式）、本地基础书签**；
- 本文件是这一批的范围、落点、边界与延后项记录。范围之外一律不做（禁止超前开发），
  Phase1 沙箱 / 图源 / 网络层一行不改。

## 一、小说分页阅读器（既有实现核验收口）

| 能力（本批口径） | 落点 | 证据 |
|---|---|---|
| 分页引擎：按视口 + 排版参数自动分页；页页相接、完整覆盖整章；字符偏移 ↔ 页码双向映射 | `lib/features/novel/novel_pagination.dart`：`NovelChapterText.parse` :30、`ChapterPagination.pageIndexForChar` :148、`NovelPaginator` :198、`NovelLayoutCache` :365（文本 + 分页两层 LRU、预取相邻章） | `test/novel_pagination_test.dart` 10 例（含「页与页首尾相接，且完整覆盖整章」） |
| 页渲染：自研 `CustomPainter` 画背景 / 正文 / 页眉页脚，不用 WebView | `lib/features/novel/novel_page_painter.dart`（`NovelPagePainter` :73）；`novel_reader_page.dart` `_buildContent` :1125、`_buildScroll` :1176 | `test/novel_reader_test.dart`「分页结果能画出可见正文（CustomPainter + TextPainter）」 |
| 四种翻页：仿真 Curl / 平移 Slide / 覆盖 Cover / 上下连续滚动 | `lib/features/novel/novel_turn_view.dart`；`novel_page_painter.dart`（`NovelTurnMode` :202、`NovelCurlPainter` :240）；阅读器翻页面板 :1744 | 「翻页模式可切换：上下滚动不再走翻页视图」（含模式落库断言） |
| 排版：字号 / 行间距 / 段间距 / 页边距（实时重排、落库） | `lib/features/novel/novel_typesetting.dart`（`NovelTypesetting` :11，范围夹紧 + `signature`）；阅读器排版面板 :1566 | 「排版参数可调：字号变化落库并触发重排」 |
| 主题独立于 App 主题：羊皮纸 / 夜间深灰 / 护眼绿 / 纯白 + 自定义 | `novel_typesetting.dart`（`NovelReaderTheme` :137、`presets` :173）；阅读器主题面板 :1647 | 「阅读主题独立于 App 主题：切到夜间深灰后整页换背景」 |
| 进度：章节索引 + 章节内字符偏移（打开续读 / 翻页即记 / 退出兜底） | `novel_reader_page.dart`：`_onPageChanged` :957、`dispose` :178；落小说板块独占库 `sections/novel/reading.db` | 阅读器 3 例（打开即分页 / 翻页推进 / 续读还原） |
| 目录：章节列表 + 当前章高亮 + 本章进度 | `novel_reader_page.dart` `_buildCatalog` :1354 | 目录跳章用例；入口经 `novel_detail_page.dart` :177、`novel_catalog_page.dart` :51 |
| 工具条：顶部（返回 / 标题 / 书签 / 上下章）+ 底部六页签（目录 / 书签 / 听书 / 排版 / 主题 / 翻页） | `novel_reader_page.dart`：`_buildTopBar` :1204、`_buildBottomPanel` :1303、`_PanelTab` :1770 | 各面板用例 |

页内**既有能力**（不在本批新增范围，随此前增量交付、已在内）：书签（按字符偏移）/
章节内查找 / 自动翻页——见 `.zcode/plans/phase1-finish-and-phase2-reader.md` 第五节与
`test/novel_bookmarks_test.dart` 11 例；听书面板（TTS 后端为独立批次交付，
`e0b491a`、`5692411`）——`test/novel_speech_test.dart` 16 例。

小说侧文件：`lib/features/novel/` 下 `novel_reader_page.dart`（1861）、`novel_pagination.dart`（437）、
`novel_page_painter.dart`（351）、`novel_turn_view.dart`（255）、`novel_typesetting.dart`（248）、
`novel_bookmarks.dart`（157）、`novel_speech_panel.dart`（343）。

## 二、漫画阅读器（本批新增三项）

| 能力（本批口径） | 落点 | 证据 |
|---|---|---|
| 分页浏览：条漫瀑布流 / 单页左右翻页 / 双页跨页（含翻页方向、跨页配对、页间距） | `comic_reader_page.dart` `_buildWaterfall` / `_buildPaged` / `_buildSpread`；`comic_settings.dart`（`spreadIndexOf` / `imagesOfSpread` / `spreadCount`） | `test/comic_reader_test.dart`「三种阅读模式可切换并落库」「单页模式翻页推进页序号」；`test/comic_settings_test.dart` 配对与屏序号用例 |
| 缩放：双击放大 + 双指缩放（1x–4x，随「双击放大」开关） | `comic_reader_page.dart` `_ComicImageTile`（`_toggleZoom`、`InteractiveViewer`） | 「调节控件：侧边距与双击放大都会落库」 |
| 阅读设置 · 背景：纯黑 / 深灰 / 护眼绿 / 纯白（落库、立即换底色） | `comic_settings.dart`（`ComicReaderBackground`）、阅读器面板「背景」行、`Scaffold(backgroundColor:)` | 「阅读背景：切到纯白后落库，页面底色立即跟着换」 |
| 阅读设置 · 点击行为：呼出工具栏 / 点击翻页（左 1/3 上一页、右 1/3 下一页、中间呼出工具栏；分区方向随阅读方向；瀑布流不适用） | `comic_settings.dart`（`ComicTapAction`）、`comic_reader_page.dart` `_onTapUp` / `_turnPage` | 「点击行为：分区点击翻页，中间仍是呼出工具栏」「点击翻页在瀑布流不生效」 |
| 本地书签：按（章节 + 页）存板块阅读库；顶栏加 / 移除，列表面板跳转与删除 | `lib/features/comic/comic_bookmarks.dart`（新增）、阅读器顶栏与 `_BookmarkSheet` | `test/comic_bookmarks_test.dart` 9 例（编解码 / 同位置覆盖 / 排序 / 坏数据 / 加删落库 / 跨章跳转 / 空态指引） |
| 小屏 / 横屏兜底：设置面板超限时内部滚动，不溢出 | `comic_reader_page.dart` 底栏 `ConstrainedBox + SingleChildScrollView` | 「小屏 / 横屏：设置面板超限时内部滚动，不溢出」 |

漫画侧**既有能力**（不在本批新增范围）：进度写入（章节 + 页，含瀑布流偏移）、
章节目录面板、图片管线资源纪律——见 `.zcode/plans/phase2-comic-reader-approved-and-deferred.md`。

## 三、交付状态

- **小说侧**：核心实现已在 Phase2 基线交付并获验收（`phase2-novel-board-approved.md` 增量二），
  本批按上表核验收口，0 行代码改动；
- **漫画侧**：在既有基线上本批新增三项（阅读背景 / 点击翻页 / 本地书签）与面板小屏兜底；
  改动文件：`comic_settings.dart`（设置模型 +2 字段）、`comic_bookmarks.dart`（新增）、
  `comic_reader_page.dart`（阅读器接入）；**不新增依赖、不引入 WebView、不接任何账号同步**；
- 漫画底栏行数变多后按 62% 屏高约束、超限内部滚动（含用例钉住），避免小屏 / 横屏溢出。

## 四、明确不做与去向

| 项 | 去向 |
|---|---|
| Bangumi 账号对接 / 漫画：追踪同步 | `deferred-todo.md`「预留扩展（暂不开发）」；Phase2 本期不实现 |
| 小说：书签分组 UI | Phase2 待办（后续批次；本批不做） |
| 第三方账号同步（任何形式） | 不实现 |
| 漫画侧既有延后三项（保存到系统相册 / 旋屏锚点 / 阅读器平台守卫） | 仍按 `phase2-comic-reader-approved-and-deferred.md` 延后，不在本批 |

## 五、批内既有延后项（继续延后，待明确批准）

1. **阅读器自身平台守卫**（小说、漫画各约 6 行，双保险）：非 iOS 现由板块入口拦截
   （`novel_page.dart` `_runtimeAvailable` :47、`comic_page.dart` 平台门），阅读器入口
   只有详情 / 目录页，非 iOS 不可达；再加一层页内守卫待明确批准后处理。
2. **严格「按请求取消」语义**：要让章节请求可被取消，需在 Phase1 的
   `DataSource` / `LumeHttp` 上开取消句柄，涉及 Phase1 改动、需单独授权；
   现口径为「退出即屏蔽（`mounted` 检查）+ 宿主超时收敛」。

## 六、验证

- `flutter analyze` 零问题；
- 全量回归 **844 例通过 + 1 例预期跳过**（QuickJS 纯 CPU 死循环，见 `deferred-todo.md`「已知底座缺陷」）；
- 小说专项 44 例：阅读器 7 + 分页 10 + 书签 11 + 听书 16；
- 漫画专项 38 例：阅读器 11 + 设置 18 + 书签 9（本批新增 15 例）。
