# Lume Box · Phase2 漫画阅读器：已批准基线 + 延后待办

本文件记录两件事：本轮交付并获批准的漫画阅读器基线，以及经确认**延后处理**的三项优化。
延后项本轮不实现，也不写任何预留扩展钩子（宪法第 6 条）。

## 一、已批准基线（漫画阅读器）

| 需求 | 落点 | 验证 |
|---|---|---|
| 三种阅读模式：条漫瀑布流 / 单页左右翻页 / 双页跨页 | `lib/features/comic/comic_reader_page.dart`：`_buildContent` 分流，`_buildWaterfall`、`_buildPaged(doublePage:)` | `test/comic_reader_test.dart`：三模式切换并落库、单页翻页推进页序号 |
| 控制面板：侧边距 0–50% 滑块、双击放大开关、长按保存图片 | 同上：`_buildBottomPanel`（SegmentedButton / Slider / Switch / 保存）、`_saveImage`、`_ComicImageTile`（双击缩放 + 长按） | 侧边距与双击放大落库断言 |
| 进度写入独立漫画数据表：章节序号 + 当前页面位置 | `lib/core/reading/reading_store.dart` 的 `reading_progress` 表（`sections/comic/reading.db`，与图源库分文件）；`ComicProgress{chapterIndex, page, pageFraction}` | 进章即记、翻页推进、目录跳章三处断言 |
| dispose 生命周期：取消图片请求、释放图像内存 | `comic_reader_page.dart` `dispose`（先落进度后释放）+ `lib/core/reading/image_pipeline.dart` `dispose`（关客户端取消在飞请求 + 逐张 `ui.Image.dispose`） | 内存淘汰 / 钉住 / 引用保护 / 清空计数用例 |
| Android / Windows 仅骨架 | `lib/features/comic/comic_page.dart` 平台门（不进阅读业务、不落阅读数据） | `test/reading_shelf_test.dart` 骨架断言 |

状态：`flutter analyze` 零问题；全量 175 个测试通过（其中阅读器专项 7 个）。获批准后未再改动代码。

## 二、延后待办（已确认延后，本轮不实现）

### 待办 1 · 长按保存图片的目标落点

- **现状**：写入本板块 `sections/comic/reading_cache/exports/`（零新增依赖、本机可验证、同名自动加序号、不参与缓存清理）。
- **目标口径**：改为写入**系统相册**（用户对「保存图片」的常规预期）。
- **代价**：新增原生插件依赖（如 `gal` / `image_gallery_saver`），iOS 需照片库权限文案（`NSPhotoLibraryAddUsageDescription`），且必须在 iOS 上验证构建与授权流程；当前开发机为 Windows，无法验证 iOS 侧。
- **决策点**：是否接受新增原生依赖。不接受则保持现状（应用目录内，提示里给出完整路径）。

### 待办 2 · 旋屏后的位置锚点

- **现状**：`didChangeDependencies` 只更新视口尺寸与解码宽度；滚动/翻页控制器仍按旧尺寸建立，旋屏后偏移按像素保留，可能偏约半页。
- **建议**：检测视口变化后重建控制器并把位置锚回当前页（`_rebuildControllers` 已具备按模式重建的能力，预计约 10 行）。
- **影响面**：仅漫画阅读器。小说阅读器的分页键已含视口尺寸，旋屏会自动重排，无需改动。

### 待办 3 · 阅读器自身的平台骨架守卫

- **现状**：非 iOS 平台由板块入口（`lib/features/comic/comic_page.dart`）拦住，阅读器不可达。
- **建议**：在 `ComicReaderPage` 内再加一层守卫，非 iOS 直接渲染骨架（双保险，约 6 行）。
- **性质**：防御性，与宪法第 1 条一致，不新增业务逻辑。

## 三、执行方式

以上三项在下一轮明确批准后按顺序处理；每项改动仍走「分模块输出 → 变更预览 → 等待批准」的流程。
