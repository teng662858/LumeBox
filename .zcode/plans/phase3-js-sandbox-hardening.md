# Lume Box · Phase3 本轮：JS 沙箱安全防护（已批准基线 + 延后待办）

> 主线口径：图源导入体验优化已完成并推送，本轮转回主线 **JS 沙箱安全防护**，
> 三个目标：**死循环指令计数超时销毁 / 上下文隔离 / 板块隔离校验**。
>
> 状态：**已落地**。Windows 本地自测通过（analyze 零问题、全量 882 通过）。
> iOS 侧等 Actions 出包后真机复测。

---

## 一、结论：三个目标的现状

| 目标 | 修复前 | 本轮 |
|---|---|---|
| **死循环指令计数超时销毁** | 机制早已写好且算术正确，但**两处断点**导致纯 CPU 死循环永远收不回来 | **已修复**（P1） |
| **上下文隔离** | 已实现且有测试；另外核实了插件 C 桥的全局 channel 表**不存在**跨上下文错算（`CChannelFunction` 传的是调用方 ctx，表里存的 `.ctx` 只出现在被注释掉的旧代码里） | 补护栏用例（P4） |
| **板块隔离校验** | 四层已有（导入期 `sectionMismatch` / 读取期 `_belongs` / 库归属自证 / 路径作用域），但**宿主代理层从不校验身份**——`SandboxHostRequest.sandboxId` 自存在以来只被赋值、从未被读 | **已补**（P2） |

---

## 二、P1 · 死循环中断回收（安全测试第 1 条）

原判断是「插件不导出 `JS_SetInterruptHandler`，所以纯 CPU 死循环无法回收」。
本轮实测发现**根因有两个**，只修符号并不够：

### 断点 1：符号没导出（原判断，成立）

插件用 `C_VISIBILITY_PRESET hidden` 编译 quickjs，`JS_EXTERN` 在 Windows 上需要
`BUILDING_QJS_SHARED` 才展开（插件从未定义），因此 `JS_SetInterruptHandler` 不在
动态符号表里。quickjs 本体是支持的：解释器热路径每 10000 条指令轮询
（`js_poll_interrupts` → `__js_poll_interrupts` → `rt->interrupt_handler`），
灾难性正则回溯走同一条通路（`lre_check_timeout` 直接调 `rt->interrupt_handler`）。

**修法**：vendor 插件到 `third_party/quickjs_engine`（≈3.3MB / 99 文件），
在 `native/cxx/libfastdev_quickjs_runtime.cpp` 加一个导出包装：

```c
DLLEXPORT void jsSetInterruptHandler(JSRuntime *rt, JSInterruptHandler *cb, void *opaque)
{ JS_SetInterruptHandler(rt, cb, opaque); }
```

Dart 侧只改符号查表名（先找 `jsSetInterruptHandler`，回退 `JS_SetInterruptHandler`）；
`SandboxGuard` 的接线一行未动（它本来就是按「符号将来会出现」写的）。

**验证**：PE 导出表 66 → **67** 个符号，`jsSetInterruptHandler` 在表内；
干净重建（删掉 `build/windows/x64/quickjs_engine_native`）后依然在。

### 断点 2：装备被提前解除（原先没发现，**这才是纯 CPU 死循环仍收不回来的直接原因**）

`SandboxContext._evaluate` 的收尾是「先 `SandboxGuard.disarm` 再 `_drainJobs`」。
而 `async` 方法体 `await` 之后的部分正是在**排空阶段**执行的
（`_drainJobs` → `executePendingJob`）——`while(true){}` 就卡在那里，此时中断已解除，
回调读不到装备记录直接放行。

实测证据（修复前）：预算 3s、等 12s，栈顶仍是
`_drainJobs` → `executePendingJob`。

**修法**：装备保持到排空结束，且按求值深度收口（嵌套求值不得提前解除外层的装备）。

### 结果

`test/js_sandbox/deadloop_timeout_test.dart` 用例 **1a 由「期望失败（skip）」转为通过**：
死循环在 **1 秒内**被回收，判定为失控（`instructions` 或 `timeout`，取决于哪个预算先到），
上下文重建后可用。1b/1c/1d 同步修正了因修复而失效的旧前提。

### 顺带修掉的两个真问题（都是安全属性，不是测试写法）

1. **栈上限过高会让进程当场死亡**：`defaultStackLimitBytes` 原为 **1MB**。实测无限递归
   会撞穿宿主线程栈、**进程无异常直接消失**（连测试结果都发不回来）。
   逐个值实测：768KB / 900KB / 960KB 正常抛 `RangeError: Maximum call stack size exceeded`，
   **1024KB 崩**。已下调为 **512KB**（2 倍安全余量）。
   → 修复前，一个 `function f(n){return f(n+1);} f(0);` 就能让 App 直接死掉。
2. **无限微任务链被当成成功**：排空阶段判废后，求值结果仍被原样交出
   （实测 `isOk=true`，而上下文已被销毁重建）。现已在排空后复核污染标记，
   与「跑得完但跑太久」同一口径：以预算账本为准。

### 用例口径的一处修正（负载相关的不稳定）

`1b`（空转 6s 后返回的脚本）原先只接受 `timeout`，但它在整套测试并行跑时偶发失败：
单条指令被机器负载拖慢后，20000 tick 的**指令预算**会先于 4 秒墙钟耗尽，判定为
`instructions`。两者都是「失控被兜住」的正当结论，先到哪个取决于机器负载、
不是被测行为。已改为同时接受两种分类，并要求失败原因点名是哪条预算
（`超时` / `指令计数`）。改后全量连跑 3 次稳定通过。

---

## 三、P2 · 宿主层隔离校验（板块隔离的最后一层）

**修法**：

1. 沙箱身份改为**板块限定**：`'<板块 id>:<来源 id>'`
   （`LumeSourceHost.sandboxIdFor`，`LumeSandbox.create` 与宿主共用同一口径）；
2. `LumeSourceHost` 持有自己的 `section` / `sourceId`，在 `invoke` 入口校验
   `request.sandboxId` 与自身身份一致，不符即抛 `SandboxHostException` 并记日志
   （点名「声明方」与「宿主方」）；
3. **身份先于能力**：校验失败不触达 http 与 store。

为什么值得补：这条隔离此前完全依赖「每个板块的注册表各自建宿主」这个**约定**，
而 `sandboxId` 的文档写着「便于宿主做隔离（例如按板块拒绝跨区访问）」却从未被读过。
把约定变成机器校验的不变式，将来任何重构（共用 HTTP 池、一个宿主多板块）都不会
悄悄把隔离打开一个口子。

---

## 四、P3 · `maxSteps` 口径写实

`maxSteps` 原注释写的是「单次操作内允许的引擎步数（求值 + 微任务排空 + 宿主回调往返）」，
但 `spendStep()` 全仓库只有一个调用点（`_handleTimeout`）——它实际只数
`setTimeout` 注册次数（那件事 `maxTimers = 32` 已经在管）。**注释承诺了一个不存在的保护**。

**修法**：实现成真正的单次操作交互预算，四处记账：
求值前、每轮微任务排空、每次宿主往返、每次定时器注册。注释同步写实，
并明确标注**它看不见纯 CPU 空转**（那只能靠原生中断）。

---

## 五、P4 · 恶意脚本矩阵用例（`test/js_sandbox/malicious_script_test.dart`，10 例）

每类都断言**三件事**：失败分类正确、上下文被销毁重建、App 侧仍可继续工作。

| 用例 | 实测结论 |
|---|---|
| 4a 灾难性正则回溯 `/(a+)+$/` | 3s 内判定失控（修复前：**进程挂死 15 分钟**，后续用例全部 `did not complete`） |
| 4b 无限递归 | `script`（RangeError），上下文可继续用；修复前直接**进程死亡** |
| 4c 大分配 | 命中 64MB 内存上限，销毁重建 |
| 4d 无限微任务链 | `instructions`（微任务排空超出预算）；修复前**被当成成功** |
| 4e 宿主调用风暴 | `instructions`；**真实请求数 16 == `maxHostCalls` 16**，记账与放行一致 |
| 4f 定时器风暴 | 超限注册被忽略并留日志 |
| 4g 超大返回值 | `protocol`，销毁重建 |
| 4h 伪造沙箱身份（4 种） | 入口拒绝、网络与存储零副作用、日志点名 |
| 4i 身份校验不误伤 | 本板块本来源正常读写 |
| 4j 跨源隔离 | 一个源失控，旁观者实例全程可用 |

**用例写法上的两个坑（已在用例里注明）**：
- 4d 不能用「预先排 10 万个 `.then`」——那是**有限**链条，只会撑爆栈（RangeError），
  测不到预算本身；要用「自己排自己」的无限链；
- 4e 必须走 `load` + `call`，不能走 `eval`——`eval` 只把顶层求值完就返回（拿到的是
  Promise 对象本身），异步风暴会在操作结束后继续跑，测不到预算。

---

## 六、本轮文件清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `third_party/quickjs_engine/**` | 新增 | vendored 插件副本（上游 0.1.6，≈3.3MB/99 文件），含 1 处安全补丁 |
| `third_party/quickjs_engine/PATCHES.md` | 新增 | 补丁说明、与上游的差异、升级上游时的做法 |
| `lib/core/js/qjs_bindings.dart` | 修改 | 中断符号先找补丁包装、回退本体符号；注释写实 |
| `lib/core/js/sandbox/sandbox_context.dart` | 修改 | 装备保持到排空结束（按求值深度收口）；排空判废后收回结果；求值/微任务/宿主往返三处记账；抽出 `_settleAfterDrain` / `_releaseAndDrain` / `_releaseNative` |
| `lib/core/js/sandbox/sandbox_policy.dart` | 修改 | 栈上限 1MB → 512KB（附实测依据）；`maxSteps` 注释与语义写实 |
| `lib/core/js/sandbox/sandbox_guard.dart` | 修改 | 注释写实（中断通路现已可用） |
| `lib/core/js/lume_js_engine.dart` | 修改 | `LumeSourceHost` 增加板块/来源身份与入口校验；`sandboxIdFor`；沙箱 id 带板块前缀 |
| `lib/features/source/add_source_button.dart` 等 4 个 UI 文件 | 修改 | 上一轮导入体验优化（本轮一并提交前已落地，见另一份计划文档） |
| `test/js_sandbox/malicious_script_test.dart` | 新增 | 10 例攻击矩阵 |
| `test/js_sandbox/deadloop_timeout_test.dart` | 修改 | 1a 转正向断言；1d 去掉「卡得久」这个失效前提 |
| `test/js_sandbox/support/js_sandbox_support.dart` | 修改 | worker 报告 `generationAfter` 改在重建探针之后读 |
| `test/source_bridge_native_test.dart` 等 3 个 | 修改 | 宿主构造补 `section` / `sourceId`；沙箱 id 对齐宿主身份 |
| `analysis_options.yaml` | 修改 | 排除 `third_party/**`（vendored 代码不参与本项目 lint） |
| `pubspec.yaml` | 修改 | `quickjs_engine` 改为路径依赖 `third_party/quickjs_engine` |

---

## 七、验证状态

- `flutter analyze`：零问题（vendored 目录已排除）；
- `flutter test`：**882 通过 + 0 跳过**（本轮开工基线 871 通过 + 1 跳过；
  那个跳过项就是纯 CPU 死循环，现已转为通过）；**连跑 3 次稳定**；
- `flutter build windows`（干净重建）：通过，补丁符号在导出表内；
- **未触碰**：爬虫业务逻辑、播放器、缓存、阅读器、数据库 schema、四大板块隔离口径。

### 真机待复测（iOS）

本机为 Windows，以下只能等 Actions 出包后真机确认：

1. iOS 构建能编过（补丁走 `ios/quickjs_engine.podspec` → 共享 `native/cxx`，
   已确认 iOS 侧是转发 TU，不重复源码）；
2. 真机跑一次 `while(true){}` 图源脚本：页面不卡、秒级报超时、再次调用正常；
3. 顺带补上一轮遗留：系统文件选择器**多选**、剪贴板授权条。

---

## 八、延后待办（本轮明确不做）

| 待办 | 理由 |
|---|---|
| 插件的 `stringifyFn` 泄漏 → JSRuntime 无法回收 | 已定位（两处 `JS_FreeValue` 被注释掉，且 `stringifyFn` 是全局变量，直接打开注释是错的），但刻意不与中断补丁混在同一文件改：出问题难定位。详见 `deferred-todo.md` |
| 进程 / isolate 级隔离（外部 kill 兜底） | 已实测：卡在原生调用里的 isolate **无法**被 `Isolate.kill` 回收；iOS 也不允许 fork/exec。中断修好后更没必要 |
| 打开插件的 GC 阈值（`JS_SetGCThreshold(rt, -1)`） | 影响全部运行的性能/内存曲线，属全局调优，与本轮安全目标不同源 |
| 扩大 Node 垫片 / dns 垫片 / 沙盒文件 IO 持久化 | 老延后项，不变 |
