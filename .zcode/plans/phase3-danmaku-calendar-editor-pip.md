# Lume Box · Phase3 一批：弹幕 / 追剧日历 / 图源编辑器 / PiP 帧转发 / 历史页 / 后台修剪

来源：一次批量交付，覆盖用户点名的六项——画中画帧转发、播放历史页、图源可视化
编辑器、弹幕、追剧日历、缓存策略后台定时修剪。

## 一、画中画帧转发（`ios/Runner/PipFramePump.swift` + `lib/core/player/pip_frame_source.dart`）

Dart 与 Swift 两端都补齐了：

```
MPV 解码帧（原生） → Dart 帧源（节流） → 方法通道 lumebox/pip/frames → Swift 帧泵 → AVSampleBufferDisplayLayer
```

- **Dart 帧源**（`PipFrameSource`）：帧率上限（默认 30fps，画中画窗口不需要满帧）、
  单帧体积上限（默认 8MB）、送帧/丢弃计数（诊断）。`submitFrame` 传 `Uint8List`
  而不是 `List<int>`——方法通道对它走二进制编码，不必逐元素序列化成 JSON 数字数组；
- **Swift 帧泵**（`PipFramePump`）：BGRA 字节 → CVPixelBuffer → CMSampleBuffer →
  `enqueue` 到显示层。**复用 CVPixelBufferPool**（按首帧尺寸建，尺寸变化时重建）：
  30fps 下每帧新建 buffer 的分配压力在移动端很贵，池化把这块开销降到接近零；
- 首帧到达时才建层并绑定内容源（`attach(frameLayer:)`）——没有帧就没有内容源，
  避免「系统说支持但窗口全黑」；
- 逐行拷贝（`memcpy` per row）：CVPixelBuffer 的行距有对齐要求，不能假设
  `bytesPerRow == width * 4`。

**仍需内核侧配合**：MPV 的帧回调尚未接（需要动 MPV 原生），因此真机上画中画
按钮会如实报「内容源未就绪」。通道、节流、缓冲池、错误口径都已就位，接上回调即生效。

## 二、弹幕系统（`lib/features/video/danmaku/`）

四层：

| 层 | 文件 | 职责 |
|---|---|---|
| 模型 | `danmaku_models.dart` | `DanmakuItem` / `DanmakuTrack`：宽容解析（时间三种写法、颜色两种、字号倍数与像素两种口径、位置三种 + 数字写法），按时间排序，`window(from,to)` 二分取窗口 |
| 设置 | `danmaku_settings.dart` | 开关 / 透明度 / 字号 / 显示区域 / 速度 / 描边 / 同屏上限；越界值收敛；按板块存；`DanmakuCache` 按「作品/剧集」缓存 |
| 渲染 | `danmaku_overlay.dart` | 吃播放位置（不是自走时钟，因此 seek 后立即对齐）、分层轨道（滚动按占用分配、顶/底各独立）、同屏上限、暂停静止、固定弹幕末段淡出 |
| UI | `danmaku_settings_sheet.dart` | 设置面板（与播放器设置分开，文档要求）+ 发弹幕弹窗（文本 + 位置） |

图源契约：`DataSource` 之外新增**可选端口** `DanmakuCapable`——弹幕不是每个图源
都有，做成必选会逼所有实现（含测试替身）写空方法。能力缺失是**正常情况**，
播放页静默降级为「这集没有弹幕」，绝不影响播放。

## 三、追剧日历（`lib/features/video/watch_calendar*.dart`）

关键设计：**日历是既有数据的视图，不引入新存储**——因此「日历与进度不一致」这类
问题从根上不存在。

- 数据来源：播放记录（视频进度的 `updatedAt`）+ 图源章节时间（`SourceChapter.publishedAt`，
  可选能力，认 `publishedAt`/`published`/`updatedAt`/`date` 四种写法与秒级时间戳）；
- 页面：月历（周一起算、补白格子留空）、当天更新 / 当天看过分区展示、点条目续看；
- 修复了一个真实缺陷：补白格子原本会带上相邻月份的数据（9 月 30 日的记录会同时
  出现在 10 月网格的首格里），测试当场抓出，现在补白一律留空。

## 四、图源可视化编辑器（`lib/features/source/source_form.dart` + `source_editor_page.dart`）

定位说清楚：它是「**新建图源的脚手架**」，不是任意脚本的解析器。

- **表单模式**：填 id / 名称 / 站点地址 / 列表与详情路径 / 搜索与页码参数名 /
  列表字段路径 / 附加请求头 → 生成一份**函数式图源脚本**（顶层 `getList` 等，
  头部带元信息与 `@lume-form` 标记）；
- **高级模式**：直接编辑脚本（脚本被手改过就禁止切回表单——不假装能还原）；
- **反解**只认带标记的脚本（自己生成的），别的写法返回 null；
- 生成的脚本交给 `importScript`，走的是与「+ 添加图源」完全相同的校验路径。

## 五、视频播放历史页（`lib/features/video/video_history_page.dart`）

首页「继续观看」只到最近 10 条，这里是完整列表（上限 500）：按最近播放倒序、
显示剧集 / 时间点 / 相对时间（刚刚 / N 分钟前 / …）、进度条、单条删除、一键清空。
首页「继续观看」标题行加了「全部」入口。

## 六、缓存策略后台执行（`lib/features/settings/cache_pruner.dart`）

策略此前只在保存策略 / 进缓存页时执行——用户设了上限却从不打开缓存页，缓存就会
一直涨。`CachePruner` 挂在应用入口：启动延迟 20 秒首跑（避开启动高峰），之后每
6 小时复查；**只在有策略时才干活**（四板块都不限制就整个跳过，不做磁盘遍历）；
失败只记日志，绝不影响使用。

## 七、测试

| 文件 | 例数 | 覆盖 |
|---|---|---|
| `test/danmaku_test.dart`（新） | 18 | 解析（时间/颜色/字号/位置各写法）、坏数据跳过、整体载荷无法识别 → 空轨、排序、时间窗口左闭右开与边界、设置收敛与 JSON 往返、样式换算、缓存按剧集隔离与 FIFO |
| `test/watch_calendar_test.dart`（新） | 10 | 同日归组、更新与播放分开归类与角标优先级、跨零点不串天、网格形状（周一起算补白数）、**补白格子不含数据**、activeDays 只数本月、跨月不串、dayOf 归一 |
| `test/source_form_test.dart`（新） | 17 | 校验（id 白名单含长破折号、地址协议、HTML 模式不需字段）、生成（元信息与标记、五个入口、路径规范化、点路径、非法标识符方括号、请求头解析、引号与反斜杠转义、HTML 正则）、反解（往返、非自己生成的返回 null、坏 JSON 不抛）、形态 id 往返 |
| `test/pip_frame_source_test.dart`（新） | 7 | 未接原生不抛错、送帧内容、帧率节流、体积上限、detach、resetStats、诊断文案 |
| `test/cache_pruner_test.dart`（新） | 5 | 无策略不遍历、按策略修剪且板块独立、策略读取失败不误删、start/dispose 生命周期、dispose 后不动磁盘 |

验证：`flutter analyze` 零告警；全量 **633 例**通过。

## 八、仍未做（如实记录）

- **MPV 帧回调**：画中画链路的最后一环，需要动 MPV 原生（libmpv 的
  `MPV_EVENT_VIDEO_RECONFIG` + 帧导出），属原生开发；
- 弹幕**发送到图源**：当前只进本地（内存 + 缓存），没有上报接口——图源契约里
  没有「发弹幕」这一项，加了也只能发到支持它的站；
- 日历的「更新」依赖图源提供章节时间，多数图源不提供，因此通常只显示播放记录。
