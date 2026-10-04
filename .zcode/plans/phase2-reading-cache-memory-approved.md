# Lume Box · Phase2 图文缓存与内存优化：已批准基线 + 延后待办

验收口径来自任务书「Phase2 图文缓存与内存优化任务」的 4 条要求。
本文件是共享阅读底座（`lib/core/reading/**`）与两个阅读器资源纪律的收口记录。

## 一、已批准基线

| 验收项（任务书口径） | 落点 | 验证 |
|---|---|---|
| 1. 漫画滑动预加载前后若干张 + 图片内存淘汰/释放策略 | `lib/core/reading/image_pipeline.dart`：窗口 ±2 钉住（`retain`）、窗口外预加载（`preload`，半径 2）、按字节预算 64MB 的 LRU；引用中与钉住的不回收；淘汰时 `ui.Image.dispose()` 归还位图 | `test/comic_reader_test.dart`「预加载与淘汰走真实链路：磁盘缓存 → 解码 → 内存 LRU」「按预算淘汰最久未使用，引用中与钉住的都不回收」 |
| 2. 小说大章节文本缓存优化 | `lib/features/novel/novel_pagination.dart` 的 `NovelLayoutCache`：文本 LRU（60 万字符 / 4 章）+ 分页 LRU（3 份，键含章节 / 视口 / 排版）+ 相邻章预取；渲染只排当前页可见段 | 「文本缓存按条目上限淘汰，字符计数同步」「分页缓存按章节 + 几何参数分别命中」「页与页首尾相接，且完整覆盖整章」 |
| 3. 统一加固阅读页面 dispose：终止未完成网络请求、释放内存 | 见「二、本轮改动」 | `test/reading_store_test.dart`「板块库生命周期：关闭后可重开，旧引用的读写静默降级」+ 各阅读页面用例 |
| 4. Android / Windows 仅骨架 | 漫画 / 小说外壳页平台门（不打开阅读库、不构建页签 → `SkeletonNotice`） | `test/widget_test.dart` 骨架用例 + `test/reading_shelf_test.dart` 骨架断言 |

## 二、本轮改动（第 3 条：统一加固）

修复的四个真实缺陷：

1. **交付即引用（引用契约）**：`image()` 返回的图自带一次引用，调用方 `release` 归还；`preload` 不持有引用。此前存在「刚交付就被并发淘汰回收」的窗口，调用方可能拿到已释放的位图。
2. **刚插入的图不被自己触发的那次淘汰回收**：`put` → `_trim(protect: key)`。长条漫单张超预算、其余条目全部受保护时，旧逻辑会当场 dispose 刚解码好的图。
3. **换图时的引用泄漏**：`SectionImage` / `_ComicImageTile` 在 `didUpdateWidget` 里 `_release()` 用的是**新图** URL，旧引用被漏掉（钉在管线上直到销毁）；改为按实际持有的键（`_heldUrl` / `_heldWidth`）归还，并补上「未挂载即归还引用」分支。
4. **退出时的资源收口**：新增 `ReadingLibrary.close(Section)`——板块退出释放 sqlite 句柄与内存，重进自动重开同一库文件，旧引用静默降级；小说阅读器 `dispose` 立即排空待释放页画布（`_flushPendingDisposal`，退出后不会再有下一帧）。

另有一处解码语义调整：`allowUpscaling: false`——原图小于目标宽度时按原尺寸解码，长图不再被放大后白占内存。

### 已确认语义（本轮批准，后续不必再讨论）

- **预算是软上限**：所有条目都处于「引用中」或「钉住」时，允许临时超出字节预算；保护优先于预算。
- **解码不放大**：原图比目标宽度小则按原尺寸解码。

### 网络请求终止矩阵

| 请求来源 | 终止方式 |
|---|---|
| 漫画页图、所有封面缩略图 | **真取消**：页面退出 `http.Client.close()` 取消在飞请求 |
| 图源脚本调用（章节内容 / 详情 / 列表） | 退出即屏蔽（`await` 回来先查 `mounted`，丢弃结果不写缓存）+ 宿主超时收敛（沙箱 3–5s / `LumeHttp` 20s）；**不改 Phase1**（已确认） |
| 小说章节预取 | 同上 |
| 板块退出 | `ExploreView.dispose → manager.close()` 释放注册表（JSContext + HTTP 客户端）；本轮新增阅读库关闭 |

## 三、延后待办（与本轮相关，均为延后处理）

| # | 待办 | 与本轮的关系 |
|---|---|---|
| 1 | 小说侧严格「按请求取消」：需 Phase1 `DataSource` / `LumeHttp` 开取消句柄（待单独授权） | 第 3 条「终止未完成网络请求」的直接延伸 |
| 2 | 漫画旋屏后重建滚动/翻页控制器，并把位置锚回当前页（约 10 行） | 阅读器生命周期加固 |
| 3 | 漫画阅读器平台骨架守卫（约 6 行，双保险） | 第 4 条的非 iOS 兜底 |
| 4 | 小说阅读器平台骨架守卫（约 6 行，双保险） | 同上 |

漫画长按保存图片落点（系统相册）一项归属漫画阅读器，见
`.zcode/plans/phase2-comic-reader-approved-and-deferred.md`；
小说板块两个基线见 `.zcode/plans/phase2-novel-board-approved.md`。

## 四、验证状态

`flutter analyze` 零问题；全量 176 个测试通过。本轮无新增依赖、无 WebView、Phase1 一行未改。
