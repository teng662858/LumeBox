# Lume Box · Phase3 本轮：图源导入体验优化（已批准基线 + 延后待办）

> 任务口径：本轮 Phase3 先梳理待办清单，优先做【图源导入体验优化】。
> 三条硬约束（用户给定，优先级高于本文件的一切设计倾向）：
> 1. **禁止超前开发第三方账号同步**（Bangumi / AniList 等）——全部留在 `deferred-todo.md`；
> 2. **不开启 AVPlayer API 开发**——继续留延后；
> 3. **只做体验层改进，不新增爬虫业务逻辑**。
>
> 状态：**已批准并落地**。含一处批准后的追加任务（全量文案统一，见第四节，
> 单独提交为 `文案统一：全部板块「图源」展示文案改为「源」`）。

---

## 一、待办清单梳理：本轮做 / 继续延后

`deferred-todo.md` 现存开放项全部过了一遍，结论：**导入链路上真正缺的是「输入
通道」与「结果反馈」两件事**——通道少（本地单文件 + 粘贴，剪贴板与多文件没有）
且两个页面口径不一致（总管理页连本地文件都没有）；反馈弱（拼一行的 SnackBar +
同 id 静默覆盖）。本轮就补这两件。

### 1.1 本轮纳入（全部落在导入这条链路上）

| # | 来源 | 待办 | 为什么本轮做 |
|---|---|---|---|
| 1 | `phase3-global-source-manage-approved-and-deferred.md` 待办 2 | 图源总管理页的**文件 / 剪贴板导入** | 总管理页的导入弹窗至今只有粘贴框，同一条导入需求在两个页面口径不一致 |
| 2 | 宪法「图源导入/导出模块规范」 | 「支持**剪贴板一键导入**」 | 规范里写了，代码里没有 |
| 3 | 宪法「方式 A：本地导入 `.js` / `.js.md5`」 | 本地 **`.js.md5`** | 现状自相矛盾：文件选择器把 `md5` 列为可选项，选中后必然报「缺少元信息」 |
| 4 | 代码事实 | 批量导入的**逐条结果** | 失败原因混在几秒即逝的 SnackBar 里，看不完也带不走 |
| 5 | 代码事实 | **覆盖确认** | 同 id 导入是静默 upsert：用户以为「加了个新源」，实际旧源连脚本一起被换了 |
| 6 | 代码事实 | 本地**多文件**导入 | 一次只能挑一个文件，导入一套源要重复 N 次往返 |

### 1.2 本轮明确不做（继续延后，理由逐条）

| 待办 | 结论 | 理由 |
|---|---|---|
| Bangumi / AniList / MyAnimeList 追踪同步、iCloud 同步 | **延后** | 约束 1；宪法「预留未来扩展需求」也明确 Phase1~3 均不开发 |
| AVPlayer 内核的 AVPlayer API 适配 | **延后** | 约束 2；且必须先有 Mac + 真机（本机 Windows 无法验证） |
| 纯 CPU 死循环无法中断回收 | **延后** | 需原生侧放开 `JS_SetInterruptHandler` 导出符号（或换进程隔离），非体验层 |
| Node-Mobile（Android 猫源引擎原生侧）、`dns` 垫片、自建聚合服务类「猫源」薄壳脚本 | **延后** | 三者都是**给沙箱加运行时能力**，属约束 3 排除的「新增爬虫业务逻辑」 |
| 沙盒文件 IO 持久化 | **延后** | 存储层，与导入体验无关 |
| 小说书签分组 UI | **延后** | Phase2 遗留，与导入无关；交互口径需单独确认 |
| 漫画追踪同步、WebDAV、备份恢复扩展 | **延后** | 宪法预留清单 |
| 批量图源校验工具 | **已完成** | 「批量测试连通性」已落地（含总管理页跨板块） |
| 导入后自动跑连通性检测 | **下轮候选** | 与既有「批量测试连通性」重叠；批量导入时每条 3–5s，会让导入明显变慢 |
| Mihon / Venera 扩展仓库批量安装 | **本轮未动** | 那是另一条导入链路（`comic_repo_service.dart`）；避免一轮改两条链路 |
| 恢复备份的逐条预览（dry-run） | **下轮候选** | 与「写入前预览」同类，但涉及备份格式与跨板块写入，单独一轮做 |

---

## 二、已批准基线（本轮验收项）

| 验收项 | 落点 | 验证 |
|---|---|---|
| **P1 统一导入弹窗**：本地 / 订阅 / 剪贴板三通道，板块页与总管理页共用一份实现 | 新增 `lib/features/source/source_import_dialog.dart`（`SourceImportDialog` + `SourceImportRequest` + `runSourceImport`）；`add_source_button.dart` 瘦身成「按钮 + 接弹窗」；`global_source_page.dart` 的 `_ImportDialog` 删除换共用件 | `add_source_button_test`（三通道各组）、`global_source_test`「本地文件通道可用」「订阅链接通道可用」「剪贴板里的脚本一键填入」 |
| 剪贴板**只在用户点按钮时读** | 同上（不在弹窗打开时自动读：iOS 16+ 静默读会弹系统授权条，平白吓用户一跳） | 「剪贴板没有文本：给一句人话」 |
| **P2 本地多文件**：`openFile` → `openFiles`（一次选多个，逐个导入） | 同上 + `SourceImportDialog.maxLocalFiles = 50` | 「本地多文件：一次选多个文件逐个导入，结果弹窗逐条列」 |
| **P2 本地内容识别**：脚本 / 地址清单 / 裸 MD5 / 备份 / 认不出 五态 | 新增 `lib/core/net/source_import_input.dart`（纯 Dart，无 Flutter 依赖） | 新增 `source_import_input_test`（11 例） |
| 本地**清单文件**（`.txt` / `.js.md5`）走既有订阅解析，并记下来源地址 | `source_import_dialog.dart` 分类后交给 `SourceSubscription` | 「本地清单文件：一行一个地址 → 走订阅解析并记下来源」 |
| 本地**裸 `.js.md5`**：认得出、当时标红，并给下一步动作（改用订阅链接填该 `.md5` 网址） | `SourceImportInput.describeFailure` | 「本地 .js.md5 文件：认得出、当场标红，且给下一步动作」 |
| 本地**备份文本**：直说去「恢复源」，绝不当作脚本导入 | 同上（备份判定排在脚本判定**之前**：备份里带着脚本原文） | 「本地备份文本：直说去『恢复源』，不当作脚本导入」 + 分类器用例 |
| **P3 导入结果弹窗**：条数 ≥ 2 或含失败时逐条列出（名称 / 新增 / 覆盖 / 失败原因），可复制明细；单条成功仍是一句 Toast | 新增 `lib/features/source/source_import_flow.dart`（`importSources` + `_ImportResultDialog`） | 「本地多文件…结果弹窗逐条列」「导入失败：透出管理器的失败原因」 |
| 结果里的板块名用**前缀**（`猫源 · 已导入：X（订阅）`）而不是后缀括号 | `source_import_flow.dart` `_report` | `global_source_test` 三条新用例 |
| **P4 覆盖确认**：同 id 已存在时先确认（含新旧版本箭头），取消即**整批零写入** | `source_import_flow.dart` `confirmOverwrite` + `existingSources`，用 `SourceMetadata.parseHeader`（**纯文本，不调沙箱**）静态读 id | 「同 id 已存在：先确认，取消则零写入」「确认后覆盖，结论写成『已覆盖』」「新 id 不弹确认」 |
| 覆盖确认同样接进**可视化编辑器**的导入 | `source_editor_page.dart` `_import` | 编辑器用例（`source_manager_test` / `board_source_entry_test` 回归） |
| **P5 订阅拉取进度**（「正在拉取第 N 个地址…」）与**截断提示**（清单超过 20 条时说明只处理前 N 条） | `source_import_dialog.dart` `_resolve`（在注入口包一层计数，**不动** `SourceSubscription`） | 「拉取过程中显示进度」「清单超过上限时说明只处理前 N 条」 |
| **P6 空态直达导入**：管理页空态从纯文字改成「暂无源 + 导入源按钮」 | `source_section_page.dart` `_buildSources` + `_import` | 「空板块：显示空态与导入入口（含空态里的导入按钮）」 |
| 板块隔离与平台边界不变 | 弹窗只产出「要导入什么」，写库仍走目标板块端口；非 iOS 仍 `SkeletonNotice` + 无入口 | `global_source_test` 各用例断言「其他板块 imported 为空」；「运行时不可用：只显示不显示添加入口」 |

**如实的边界（不假装覆盖全部情况）**：
覆盖确认只在**头部注释里声明了 id、且 id 合法**的脚本上生效。只在运行时
`LumeSource` 上声明元信息的脚本，导入前无法知道 id（要起引擎跑一遍才能拿到，
代价与风险都不划算）；id 非法（如带点）的脚本头部也读不出来——这类脚本本来就
会在导入阶段被拒绝，所以不会漏掉真实问题。上述情况仍按原样导入，结果里如实
标成「已覆盖」而不是「已导入」。

本轮文件清单：

| 文件 | 类型 | 说明 |
|---|---|---|
| `lib/core/net/source_import_input.dart` | 新增 | 导入输入分类器（纯 Dart，五态判定 + 失败时的下一步动作） |
| `lib/features/source/source_import_dialog.dart` | 新增 | 共用导入弹窗（三通道 / 板块选择 / 进度 / 截断说明）+ `runSourceImport` |
| `lib/features/source/source_import_flow.dart` | 新增 | 导入编排 + 覆盖确认 + 结果弹窗 |
| `lib/features/source/add_source_button.dart` | 重写 | 只留按钮与公开参数；`readLocalScript` → `readLocalScripts` |
| `lib/features/source/global_source_page.dart` | 修改 | 删除 `_ImportDialog` / `_ImportRequest`，改用共用弹窗与编排；新增两个测试注入口 |
| `lib/features/source/source_section_page.dart` | 修改 | 空态加「导入源」按钮 + `_import`；透传注入口 |
| `lib/features/source/source_editor_page.dart` | 修改 | 导入前覆盖确认（结论写成「已覆盖 / 已导入」） |
| `test/source_import_input_test.dart` | 新增 | 11 个用例 |
| `test/add_source_button_test.dart` | 重写 | 26 个用例（三通道 / 多文件 / 清单 / 校验值 / 备份 / 覆盖确认 / 结果弹窗 / 进度 / 截断） |
| `test/global_source_test.dart` | 修改 | 新增 3 个用例（三通道 × 只写所选板块） |
| `test/source_manager_test.dart` | 修改 | 空态用例改断言并覆盖空态导入按钮 |
| `test/support/fake_source_manager.dart` | 修改 | 导入描述符可配置（覆盖确认用例需要不含点的 id） |

---

## 三、验证状态

- `flutter analyze`：零问题；
- `flutter test`：**870 通过 + 1 跳过**（基线 844 通过 + 1 跳过；跳过项是既有的
  CPU 死循环缺陷留档，与本轮无关）；
- 无新增依赖（`file_selector` 已支持多选；剪贴板走 Flutter 自带 `Clipboard`）；
- 未触碰 `lib/core/js/**`（沙箱 / 引擎 / 注册表 / 桥接 / 垫片）、`lib/core/db/**`
  （无 schema 变更）、播放器、缓存与阅读器。
- **真机限制（如实说明）**：iOS 端到端（系统文件选择器多选、剪贴板授权条）本机
  （Windows）无法验证；本机覆盖的是纯 Dart 分类器、Widget 层（替身端口）与既有
  引擎用例，iOS 侧需真机确认。

---

## 四、批准后的追加任务：全量文案统一（已单独提交）

用户在批准本轮计划的同时追加了一项**纯 UI 文案**任务（业务逻辑零改动）：

| 口径 | 旧 → 新 |
|---|---|
| 弹窗标题 | 添加图源 · X → **添加源 · X** |
| 空态 | 暂无图源 → **暂无源**；进入图源管理导入并启用图源 → **进入源管理导入并启用源** |
| 页面标题 | X · 图源编辑器 → **X · 源编辑器**；图源总管理 → **源总管理** |
| 其余用户可见串 | 图源管理 → 源管理、图源脚本 → 源脚本、图源名称 → 源名称…（含引擎错误文案与日志文案） |

实现方式：只替换**引号字符串内部**的「图源」（整行注释、代码标识符一律不动，
脚本内联垫片文本不动）；测试同步更新受影响断言，用例名与夹具数据名保持原样。
共 34 个 lib 文件 153 处、27 个测试文件 111 处；`test` 里仍有「图源」的只剩
用例名与夹具名（有意保留）。

一处需要确认的叫法：**「图源总管理」按统一口径变成「源总管理」**——如果你更
倾向别的叫法（例如「总源管理」），改一处字符串即可。
