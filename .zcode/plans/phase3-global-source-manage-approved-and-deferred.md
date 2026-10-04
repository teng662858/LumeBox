# Lume Box · Phase3 全局图源总管理页面：已批准基线 + 延后待办

> 任务书说明：本轮任务书正文在消息中为截断状态（只到标题「Phase3 任务：全局图源
> 总管理页面开发」+「……」）。基线按标题与宪法口径实现并获批准；若正文另有条目
> （图源详情 / 导出 / 文件导入等），下一轮按条补齐后另行记录。

## 一、已批准基线

| 验收项 | 落点 | 验证 |
|---|---|---|
| 全局入口 | 首页 AppBar 动作（图标 tune，tooltip「图源总管理」）→ `GlobalSourcePage` | `test/widget_test.dart`「首页可进入全局图源总管理页」 |
| 四板块汇总：分组 + 计数（启用 / 总数） | `lib/features/source/global_source_page.dart`：`_buildSectionChildren`、`_buildFilterBar` | `test/global_source_test.dart`「汇总：四板块分组展示，计数与状态标记正确」 |
| 板块筛选：全部 / 小说 / 漫画 / 自定义视频 / 猫源 | `_buildFilterBar`（ChoiceChip，带各板块计数） | 「筛选：只显示所选板块的分组」 |
| 导入：显式选择目标板块 + 粘贴脚本 | `_import` + `_ImportDialog`（目标板块 chips、脚本框、载入内置示例） | 「导入：只写入所选板块，列表随即刷新」「导入：对话框里可改目标板块」「导入：空脚本被拦下，不写任何板块」「导入失败：提示原因，列表不变」 |
| 启停图源 | `_toggle` → 所属板块端口 `setEnabled`（停用即释放该图源运行时） | 「启停：只写入所属板块，停用后浏览入口禁用」 |
| 删除图源（二次确认） | `_delete` | 「删除：二次确认后只移除所属板块的记录」 |
| 浏览图源 | `_browse` → 所属板块端口 `open` → `BrowsePage` | 「浏览：经所属板块端口打开数据源」 |
| **板块隔离（宪法第 3 条）** | 页面持有四个 `SourceManager`（一板块一端口），所有操作显式按板块分发；导入必须先选目标板块 | 上述各用例同时断言：其他板块的 `imported / toggled / removed / openedIds` 均为空 |
| 单板块故障不牵连 | `_reloadSection` 逐板块 try/catch，失败板块显示「该板块图源存储不可用」 | 「单板块存储故障：只影响该板块，其他板块照常」 |
| 非 iOS 仅骨架（宪法第 1 条） | `_runtimeAvailable` 为假 → `SkeletonNotice`，不开库、不建沙箱 | 「运行时不可用：只显示骨架，无导入入口」+ `widget_test.dart` |
| 退出释放资源（宪法第 7 条） | `dispose` 逐个 `close()` 四个板块的管理器（JSContext / HTTP / 数据库连接） | 「页面退出：四个板块的管理器一起释放」 |
| 窄屏可用 | 条目控件固定宽 + 名称省略号 | 「窄屏：条目控件不溢出，超长名称省略」（390×844） |

本轮文件清单：

| 文件 | 类型 | 说明 |
|---|---|---|
| `lib/features/source/global_source_page.dart` | 新增 | 全局图源总管理页：筛选行、分组列表、导入对话框、条目（启停 / 浏览 / 删除） |
| `lib/features/shell/home_page.dart` | 修改 | AppBar 增加「图源总管理」入口；四个板块卡片不变 |
| `test/global_source_test.dart` | 新增 | 14 个用例 |
| `test/support/fake_source_manager.dart` | 修改 | 增加 `listFailure`（仅测试替身；生产代码零改动） |
| `test/widget_test.dart` | 修改 | 增加首页入口用例（非 iOS） |

## 二、延后待办

### 待办 1 · 「设为当前图源」（全局总管理页）

- **原提案**：在总管理页每条图源上提供「设为当前图源」动作（复用端口既有
  `current()` / `select()` 能力），并显示各板块当前源标记。
- **决定（本轮确认）**：不实现。第一版实现已连同 UI（当前标记 + 单选按钮）一并
  撤下，页面只保留列表 / 导入 / 启停 / 删除 / 浏览。
- **原因**：当前源切换在板块业务页已有入口（板块内切换面板），本轮总管理页先收
  在「管理图源本身」的范围里；是否把当前源切换上收到总管理页，需要单独确认交互
  口径（见待办 2 的关系）。
- **再次实现的落点**：`global_source_page.dart` 的 `_SourceTile` 增加当前标记与
  动作、`_reloadSection` 增加 `manager.current()` 读取；测试补 `selectedIds`
  断言。代价约 40 行 + 1 个用例。

### 待办 2 · 任务书正文补齐后的条目

任务书正文未到达。若正文包含总管理页的其它要求（例如图源详情 / 脚本预览 /
导出 / 从文件或剪贴板导入 / 排序搜索），按条补齐并更新本文件。

## 三、验证状态

`flutter analyze` 零问题；全量 191 个测试通过（基线 176 + 本轮 15）。
本轮无新增依赖、无 WebView、Phase1 一行未改。
