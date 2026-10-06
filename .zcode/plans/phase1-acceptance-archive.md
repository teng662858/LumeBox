# Lume Box · Phase1 验收归档（正式闭环记录）

- **归档日期**：2026-10-06
- **归档依据**：用户确认「两项测试全部完成，沙箱-Phase3 验收通过」+ 真机补充测试通过
- **当前状态**：`flutter analyze` 零问题；`flutter test` **892 通过 + 0 跳过**
- **iOS 产物**：Actions run `37437046071`（commit `2ac872d`）→ `LumeBox-unsigned.ipa`
  （18.4MB，arm64，未签名，SHA256 `ac67c837…0d8025`）

本文档是 Phase1 的**收尾确认**：把三条收尾任务逐条钉到代码位置与验证用例上，
并记录真机验收结果，作为阶段闭环的正式凭据。

---

## 一、三条收尾任务：逐条核对结果

三条任务在**提出时即已完成**（属早期轮次交付物），本轮为**核对归档、零代码改动**。
核对方式：读实现 + 跑对应用例（不凭记忆下结论）。

### 1.1 主导航改造 ✅

| 子要求 | 落点 | 验证用例 |
|---|---|---|
| 底部 5 Tab，顺序「小说｜漫画｜视频｜猫源｜设置」 | `lib/features/shell/app_shell.dart:60-91`（`_tabs`，文案取 `Section.label`，设置页为字面量 `'设置'`） | `test/app_shell_test.dart`「移动端：底部 Dock 五页签，顺序为 小说 / 漫画 / 视频 / 猫源 / 设置」 |
| 桌面端左侧 NavigationRail | `app_shell.dart:160`（`NavigationRail`，按平台自动切换，页签内容同一套） | 「桌面端：自动切换为左侧 NavigationRail，页签一致」 |
| 阅读器 / 播放器全屏时自动隐藏底部 Tab | `lib/features/shell/shell_dock.dart`（`ShellDockController` + 令牌机制）+ `ShellDockObserver`（全屏路由压栈即隐藏、出栈恢复；多个来源可同时要求隐藏） | 「全屏页压栈隐藏 Dock，出栈恢复」「播放中隐藏 Dock：令牌释放后恢复（视频页联动）」「弹窗（非全屏路由）不影响 Dock 显隐」 |

**展示口径说明**：视频板块展示名为「视频」，底层标识仍是 `Section.video`
（库 / 缓存 / 图源归属不受文案影响）——这是既定口径，代码注释已写明。

### 1.2 四大板块「+」图源添加按钮 ✅

| 板块 | 入口 | 说明 |
|---|---|---|
| 小说 | `novel_page.dart:123` `AddSourceButton` | 各自 AppBar |
| 漫画 | `comic_page.dart:184` `AddSourceButton` | 各自 AppBar |
| 视频 | `video_page.dart:1296` `AddSourceButton` | 各自 AppBar |
| 猫源 | `source_section_page.dart:449` | 猫源页本身就是 `SourceSectionPage`（`cat_page.dart` 12 行纯委托），因此「+」来自同一页面 |

导入方式：**本地 JS 文件** + **远程订阅链接**（另有本轮新增的**剪贴板**通道）。
验证：`test/app_shell_test.dart`「板块页右上角有统一的「+」添加图源入口」、
`test/board_source_entry_test.dart` 各板块入口用例。

### 1.3 JS 脚本 UTF-8 BOM 预处理 ✅

| 项 | 落点 |
|---|---|
| 剥离实现 | `lib/core/js/source_script.dart:10` `stripScriptBom`（循环剥离开头 `\uFEFF`） |
| 解析前调用 | 同文件 `parseHeader`（先 `stripScriptBom` 再正则匹配）、`headerIdOf`、`describeImportFailure` |
| 导入链路 | `source_import_dialog.dart` / `source_registry.import` 落库前统一剥离 |

验证（`test/source_script_import_test.dart` 组 2）：
- 「`stripScriptBom` 正确移除开头的 `\uFEFF`，正文一字不动」；
- 「**元信息同样解析成功（BOM 不再让正则失配）**」——即本次任务书点名的场景；
- 「剥离顺序：先 `stripScriptBom` 再匹配（对多字节正文也成立）」——中文 + emoji 正文。

另有端到端用例：`test/add_source_button_test.dart`「本地文件导入：读出的脚本剥掉 BOM 后写入本板块」。

---

## 二、真机验收结果（用户执行）

| 测试项 | 结果 |
|---|---|
| `simple_test.js` 导入并运行 | ✅ 正常运行，**列表条目成功渲染** |
| 点击播放 | ⚠️ 出现 404 —— **属示例脚本的假 URL，预期现象**，非缺陷 |
| 沙箱 · Phase3 验收 | ✅ **通过** |

真机侧同时确认了本机（Windows）无法验证的 iOS 交互路径（系统文件选择器多选、
剪贴板授权条、触摸路径下的死循环恢复观感）——详见
`.zcode/plans/phase3-device-acceptance-report.md`。

---

## 三、Phase1 交付范围总览

| 领域 | 状态 | 归档文档 |
|---|---|---|
| 主导航壳（5 Tab / 侧边栏 / 全屏隐藏） | ✅ | 本文档 §1.1 |
| 四板块图源管理（导入 / 启停 / 删除 / 测试 / 更新订阅 / 备份恢复） | ✅ | `phase3-global-source-manage-approved-and-deferred.md` |
| 图源导入体验（三通道 / 覆盖确认 / 结果弹窗 / 本地清单与 .js.md5） | ✅ | `phase3-source-import-ux.md` |
| QuickJS-NG 沙箱安全（死循环中断回收 / 上下文隔离 / 板块隔离校验） | ✅ | `phase3-js-sandbox-hardening.md` |
| MPV 播放器 + AbstractPlayer 抽象层 + HUD | ✅ | `phase1-mpv-kernel-and-hud.md` |
| 网络层（双层并发 / 退避重试 / 图源级 UA·Cookie·代理） | ✅ | `network-layer-concurrency.md` |
| 缓存与数据库物理隔离（四板块独立库 / 独立缓存目录） | ✅ | `phase2-reading-cache-memory-approved.md` |
| 视频播放进度记忆 / 历史页 / 跨集连播 | ✅ | `video-playback-progress.md` |
| iOS 原生 PiP + 帧转发管道 | ✅ | `phase3-player-pip-approved-and-deferred.md` |
| 真机复测（沙箱 + 导入冒烟） | ✅ | `phase3-device-acceptance-report.md` |

### 宪法验收项抽查（Phase1 口径）

| 宪法要求 | 结果 |
|---|---|
| iOS 编译包无任何 Node / libuv / node_start 符号（第 9 条） | ✅ 三个二进制命中数均为 **0** |
| 恶意死循环脚本测试，APP 永不卡死（第 9 条） | ✅ 死循环 1 秒内回收（原为永不回收） |
| 多图源并发搜索单域名受控（第 6 条） | ✅ 双层并发限制 + 429/503 退避 |
| 异常脚本友好降级无崩溃（第 8 条） | ✅ 攻击矩阵 10 例全通过 |
| 三板块缓存独立清理互不干扰（第 9 条） | ✅ 按板块清理用例 |

---

## 四、延后项（不阻塞 Phase1 闭环）

以下均已记入 `deferred-todo.md`，按指示继续延后：

| 项 | 说明 |
|---|---|
| **`stringifyFn` 泄漏 → JSRuntime 无法回收** | 上游插件两处 `JS_FreeValue` 被注释掉；实测泄漏 **1.00 个/次销毁、≈0.2MB/轮**（基线数字已留档供修复对照） |
| **AVPlayer 内核的 AVPlayer API 适配** | 需 Mac + 真机验证；与 PiP / 字幕样式同源 |
| **Android Node-Mobile 猫源引擎** | 需 NDK + libnode，独立立项 |
| **小说：书签分组 UI** | Phase2 遗留（同步功能延后） |
| **恢复备份的逐条预览（dry-run）** | 涉及备份格式与跨板块写入 |
| **导入后自动连通性检测** | 与既有批量测试重叠，待真实反馈 |

---

## 五、Phase1 结论

**Phase1 收尾任务全部完成、真机验收通过，阶段正式闭环。**

- 三条收尾任务：核对确认已完成（零代码改动），证据见 §1；
- 真机验收：沙箱与导入冒烟均通过，唯一 404 属示例假 URL（预期）；
- 全量测试：892 通过 + 0 跳过（含本轮之前把「死循环」从期望失败转为通过）；
- iOS 产物：可复现构建（Actions），关键安全补丁经二进制级核实确实编入。

下一阶段：Phase2（漫画阅读器全套功能 / 小说自研分页排版与翻页引擎 / 图文缓存预加载优化）。
小说侧阅读器底座已在 Phase2 早期交付（见 `phase2-novel-board-approved.md`），
Phase2 剩余项按任务书逐轮推进。
