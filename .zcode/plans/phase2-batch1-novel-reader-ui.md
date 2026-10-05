# Lume Box · Phase2 第一批：自研小说分页阅读器（UI）

立项口径（本次确认）：Phase2 第一批**只做**「自研小说分页阅读器 UI」——小说阅读页本身。

- 漫画追踪同步、Bangumi 对接属**预留扩展**（已记入 `deferred-todo.md`「预留扩展（暂不开发）」，
  Phase2 本期不实现）；
- 小说书签分组 UI 留在 Phase2 待办（后续批次）；**追踪同步功能延后**；
- 本文件是本批的范围、落点、边界与延后项记录。范围之外一律不做（禁止超前开发），
  Phase1 沙箱 / 图源 / 网络层一行不改。

## 一、批次范围 → 落点 → 证据

| 能力（本批口径） | 落点 | 证据 |
|---|---|---|
| 分页引擎：按视口 + 排版参数自动分页；页页相接、完整覆盖整章；字符偏移 ↔ 页码双向映射 | `lib/features/novel/novel_pagination.dart`：`NovelChapterText.parse` :30、`ChapterPagination.pageIndexForChar` :148、`NovelPaginator` :198、`NovelLayoutCache` :365（文本 + 分页两层 LRU、预取相邻章） | `test/novel_pagination_test.dart` 10 例（含「页与页首尾相接，且完整覆盖整章」「每页起始字符都能反查回同一页（进度可精确还原）」） |
| 页渲染：自研 `CustomPainter` 画背景 / 正文 / 页眉页脚，不用 WebView | `lib/features/novel/novel_page_painter.dart`（`NovelPagePainter` :73）；`novel_reader_page.dart` `_buildContent` :1125、`_buildScroll` :1176 | `test/novel_reader_test.dart`「分页结果能画出可见正文（CustomPainter + TextPainter）」 |
| 四种翻页：仿真 Curl / 平移 Slide / 覆盖 Cover / 上下连续滚动 | `lib/features/novel/novel_turn_view.dart`（手势与动画）；`novel_page_painter.dart`（`NovelTurnMode` :202、`NovelCurlPainter` :240）；阅读器翻页面板 :1744 | 「翻页模式可切换：上下滚动不再走翻页视图」（含模式落库断言） |
| 排版：字号 / 行间距 / 段间距 / 页边距（实时重排、落库） | `lib/features/novel/novel_typesetting.dart`（`NovelTypesetting` :11，范围夹紧 + `signature`）；阅读器排版面板 :1566 | 「排版参数可调：字号变化落库并触发重排」；分页用例「换排版参数或视口会得到新的分页键」 |
| 主题独立于 App 主题：羊皮纸 / 夜间深灰 / 护眼绿 / 纯白 + 自定义 | `novel_typesetting.dart`（`NovelReaderTheme` :137、`presets` :173）；阅读器主题面板 :1647 | 「阅读主题独立于 App 主题：切到夜间深灰后整页换背景」 |
| 进度：章节索引 + 章节内字符偏移（打开续读 / 翻页即记 / 退出兜底） | `novel_reader_page.dart`：`_onPageChanged` :957、`dispose` :178；落小说板块独占库 `sections/novel/reading.db` | 阅读器 3 例（打开即分页 / 翻页推进 / 续读还原） |
| 目录：章节列表 + 当前章高亮 + 本章进度 | `novel_reader_page.dart` `_buildCatalog` :1354 | 目录跳章用例；入口经 `novel_detail_page.dart` :177、`novel_catalog_page.dart` :51 |
| 工具条：顶部（返回 / 标题 / 书签 / 上下章）+ 底部六页签（目录 / 书签 / 听书 / 排版 / 主题 / 翻页） | `novel_reader_page.dart`：`_buildTopBar` :1204、`_buildBottomPanel` :1303、`_PanelTab` :1770 | 各面板用例 |

页内**既有能力**（不在本批新增范围，随此前增量交付、已在内）：

- 书签（按字符偏移）/ 章节内查找 / 自动翻页——见 `.zcode/plans/phase1-finish-and-phase2-reader.md`
  第五节与 `test/novel_bookmarks_test.dart` 11 例；
- 听书面板（TTS 后端为独立批次交付，`e0b491a`、`5692411`）——`test/novel_speech_test.dart` 16 例。

本批涉及文件（阅读器目录 `lib/features/novel/`）：

| 文件 | 行数 | 作用 |
|---|---|---|
| `novel_reader_page.dart` | 1861 | 阅读器主体：模式分流、六面板、进度落库、资源释放 |
| `novel_pagination.dart` | 437 | 分页引擎：逐段断行 → 按行切页 → 字符偏移映射 + 两层缓存 |
| `novel_page_painter.dart` | 351 | 页画笔（背景 / 正文 / 页眉页脚）与仿真 Curl 绘制 |
| `novel_turn_view.dart` | 255 | 翻页手势与动画（平移 / 覆盖 / Curl 共用一套几何） |
| `novel_typesetting.dart` | 248 | 排版参数与阅读主题（4 预设 + 自定义背景色） |
| `novel_bookmarks.dart` | 157 | 书签模型与读写（页内既有能力） |
| `novel_speech_panel.dart` | 343 | 听书面板（页内既有能力） |

## 二、交付状态

核心实现已在 Phase2 基线交付并获验收（`.zcode/plans/phase2-novel-board-approved.md`
增量二「自研小说分页阅读器引擎」，7 条要求全项落点，0 行代码改动验收）。

本批按上表**核验收口**：存量实现即为本批交付物，**0 行代码改动**、不新增依赖、
不新增业务逻辑；范围之外不开发（禁止超前开发）。

## 三、明确不做与去向

| 项 | 去向 |
|---|---|
| 漫画：追踪同步 | `deferred-todo.md`「预留扩展（暂不开发）」；Phase2 本期不实现 |
| Bangumi 账号对接 | 同上（预留扩展，不在本批） |
| 小说：书签分组 UI | Phase2 待办（后续批次；本批不做） |
| 追踪同步功能（任何形式） | 延后，本期不实现 |

## 四、批内既有延后项（继续延后，待明确批准）

1. **阅读器自身平台守卫**（约 6 行，双保险）：非 iOS 现由板块入口拦截
   （`novel_page.dart` `_runtimeAvailable` :47 → `SkeletonNotice` :91），阅读器只有
   详情页与目录页两个入口、非 iOS 不可达；再加一层页内守卫与漫画侧同一口径，
   待明确批准后处理。
2. **严格「按请求取消」语义**：要让章节请求可被取消，需在 Phase1 的
   `DataSource` / `LumeHttp` 上开取消句柄，涉及 Phase1 改动、需单独授权；
   现口径为「退出即屏蔽（`mounted` 检查）+ 宿主超时收敛」。

## 五、验证

- `flutter analyze` 零问题；
- 全量回归 **829 例通过 + 1 例预期跳过**（QuickJS 纯 CPU 死循环，见 `deferred-todo.md`「已知底座缺陷」）；
- 小说专项 44 例：阅读器 7 + 分页 10 + 书签 11 + 听书 16。
