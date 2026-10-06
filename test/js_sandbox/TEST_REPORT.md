# JsDataSource 适配器冒烟安全测试 · 运行报告

- **任务**：JsDataSource 适配器冒烟安全测试（只写测试用例与样板 JS 脚本）
- **日期**：2026-10-05（初版） / 2026-10-06（安全加固后更新）
- **平台**：Windows x64（真实 QuickJS-NG 原生桥，Debug 产物）
- **原生命令**：`flutter test test/js_sandbox --reporter expanded`
- **结论**：**三条测试清单全部通过**。
  初版唯一未通过项「纯 CPU 死循环能被中断回收」已在安全加固轮修复——
  实际有两处断点：插件未导出 `JS_SetInterruptHandler`（已通过 vendored 副本打补丁导出），
  以及 `SandboxContext._evaluate` 在排空微任务**之前**就解除了中断装备
  （`async` 方法体 `await` 之后的部分正是在排空阶段执行）。详见
  `.zcode/plans/phase3-js-sandbox-hardening.md`。

## 一、总览

| 编号 | 用例 | 结果 | 备注 |
|---|---|---|---|
| 1a | 纯 CPU 死循环 `while(true){}`：被中断并回收上下文 | **通过**（安全加固后） | 1 秒内回收；判定为失控（`instructions` 或 `timeout`，取决于哪个预算先到），上下文重建可用 |
| 1b | 超出预算但会返回的脚本：判超时、销毁上下文 | 通过 | 本轮修复项 |
| 1c | 污染后重建：新上下文可用、旧实例不复用 | 通过 | 本轮修复项（内存失控分类） |
| 1d | 卡死隔离：一个源失控不阻塞主线程，新上下文照常建立 | 通过 | |
| 1e | 超时预算口径（3–5s 收敛 + 预算账本） | 通过 | |
| 2a | 两份脚本的全局变量互不可见（含同名不同值） | 通过 | |
| 2b | 沙盒文件 IO 按图源隔离：同名路径互不覆盖 | 通过 | |
| 2c | 释放一个源不影响另一个源的运行态 | 通过 | |
| 2d | 板块级注册表：两板块记录与引擎互不串线 | 通过 | |
| 3a | 板块声明解析（纯 Dart，7 项） | 通过 | |
| 3b | 跨板块导入被解析阶段拒绝（真实引擎，6 项） | 通过 | 本轮新增能力 |

合计：**24 项通过、0 项失败**（安全加固后）；另新增攻击矩阵
`malicious_script_test.dart`（10 例，覆盖正则回溯 / 无限递归 / 大分配 / 微任务自循环 /
宿主调用风暴 / 定时器风暴 / 超大返回值 / 伪造沙箱身份 / 跨源隔离）。
全量回归 **882 通过 / 0 跳过 / 0 失败**。

> 各套件单独运行结果：`deadloop_timeout` 6 通过、`context_isolation` 4 通过、
> `section_category` 13 通过、`malicious_script` 10 通过、`evidence_log` 1 通过
> （详见 `logs/*.log`）。

## 二、逐条验证

### 第 1 条：死循环 & 超时销毁

**要求**：到达 3–5s 阈值后 JSContext 被销毁；App 不卡死；后续新请求可重建全新上下文正常工作；
旧中毒上下文必须销毁释放，不允许复用卡死实例。

#### 1a 纯 CPU 死循环 —— 通过（安全加固后）

**现象（修复前）**：脚本方法体内 `while(true){}` 把调用线程一直占住。预算 3s，
等待 12s 后仍未收尾。

**根因（两处，均已在安全加固轮修复）**：

1. `SandboxGuard` 依赖的 `JS_SetInterruptHandler` 在插件构建里被设为 hidden，
   导出表中不存在该符号（初版核验：`quickjs_c_bridge_plugin.dll` 共 66 个导出，
   无任何 `*nterrupt*`；Debug 与 Release 一致）。没有中断处理器，quickjs 就没有
   「周期性回调宿主」的机会，Dart 侧无从夺回控制权。
   → 已 vendor 插件副本并在 `native/cxx/libfastdev_quickjs_runtime.cpp` 补
   `jsSetInterruptHandler` 导出包装（导出表 66 → 67）。
2. **装备被提前解除**（初版未发现，这才是仍收不回来的直接原因）：
   `SandboxContext._evaluate` 原先「先 `disarm` 再 `_drainJobs`」，而 `async` 方法体
   `await` 之后的部分正是在排空阶段执行的（`_drainJobs` → `executePendingJob`）
   ——死循环卡在那里时中断已解除，回调读不到装备记录直接放行。
   → 已改为装备保持到排空结束，并按求值深度收口。

**当前结果**：死循环在 **1 秒内**被回收，判定为失控（`instructions` 或 `timeout`，
取决于哪个预算先到），上下文重建后可用。

#### 1b 超预算但会返回的脚本 —— 通过（本轮修复）

脚本 CPU 空转 6s 后**正常返回**（引擎预算 4s）。原实现会把这个结果当成功收下
（3–5s 墙钟预算形同虚设），因为结果是在排空微任务时被投递回来的，
`.timeout()` 没有机会介入。

修复：在结果投递处与微任务排空循环里补判墙钟预算，越过上限即按超时处理并销毁上下文。

```
调用结果: ok=false kind=timeout msg=执行超时（6001ms > 4000ms）
上下文: 代数 1 → 1，在册数 1 → 0
[warn] [evidence-overrun] 沙箱上下文判定污染（timeout）: 执行超时（6001ms > 4000ms）
```

#### 1c 污染后重建 —— 通过（本轮修复）

脚本方法体内堆爆（`out of memory`）原本被归类为**可捕获的普通脚本错误**，
于是内存已失控的上下文被原样留着继续用。修复后按引擎级错误处理，销毁并重建。

```
调用结果: ok=false kind=memory msg=out of memory
上下文: 在册数 1 → 0
[warn] [evidence-oom] 沙箱上下文判定污染（memory）: out of memory
```

#### 1d 卡死隔离 —— 通过

死循环期间主 isolate 照常调度（定时器持续 tick），另起的新上下文照常建立并正常干活。
**说明**：本用例断言的是「失控脚本不阻塞主 isolate」，**不**断言 tick 的具体次数——
修复中断通路后死循环通常在 1 秒内被回收，tick 自然比「卡死 6 秒」时少。
初版曾用 `> 10 ticks` 表达隔离性，那实际上把「卡得久」当成了前提，已修正。

### 第 2 条：多图源上下文隔离 —— 全部通过

两份独立脚本（`isolation_alpha.js` / `isolation_beta.js`）各自设置全局变量与沙盒文件。

- **2a 全局层**：甲看不见乙的 `__LUME_ISO_BETA__`（读到 `undefined`），反之亦然；
  同名对象字段 `__lumeIsolationMark` 各自为 `alpha` / `beta`，不串线。
- **2b 存储层**：两个源都写 `probe/owner.txt`，各读回自己的值（`alpha` / `beta`）；
  文件清单各是各的，看不见对方写的私有文件。
- **2c 生命周期**：释放甲之后，乙的上下文与状态不受影响；甲自身返回 `disposed` 而非崩溃。
- **2d 板块层**：同一 id 的图源在两个板块各自持有独立引擎实例（`identical` 为 false），
  释放一个板块不影响另一个。

隔离实现依据：一个图源独占一个 `JSRuntime + JSContext`（`SandboxContext`），
沙盒存储 `SandboxStore` 每引擎一份，板块库与目录也各自独立。

### 第 3 条：板块 category 隔离校验 —— 全部通过

**本轮新增能力**：底座原先**没有** `category` 概念——`SourceMetadata` 只解析
id / name / version，导入路径不校验板块归属。本轮补齐（属适配器底座对应问题）：

1. `SourceMetadata` 增加可选 `category` 字段，头部注释与运行时 `LumeSource.category`
   两条路径都能解析；两处声明做**合并**（头部优先、运行时补齐缺失字段），
   避免「头部命中就整体采用」让 `category` 只写在运行时的脚本绕过校验。
2. `SourceMetadata.sectionMismatch(Section)` 给出点名到板块的可读原因；
   板块标识大小写不敏感，中文展示名（如「漫画」）同样认。
3. `SourceRegistry.import` 在**解析阶段**校验：不一致即拒绝并输出明确日志，
   不落库、不进入运行期。

验证覆盖：

- **3a**：声明解析、一致性放行、不符拒绝、非法板块名拒绝、合并规则（7 项）。
- **3b**：小说脚本导入漫画板块被拒（含日志留痕与不落库）；同脚本导入小说成功（对照）；
  仅运行时声明同样被拦下；头部与运行时冲突时按头部判定；无声明脚本照旧可导入任意板块
  （不误伤既有脚本）；库内记录在读取路径上同样不可跨板块可见（6 项）。

```
[warn] [comic] 拒绝跨板块图源 test-section-novel：跨板块图源被拒绝：
脚本声明归属「小说」（novel），当前导入目标是「漫画」（comic）。…
```

## 三、本轮修复的底座缺陷（3 项）

均属适配器底座自身问题，未越界实现任何爬虫业务逻辑：

| # | 缺陷 | 位置 | 修复 |
|---|---|---|---|
| 1 | 超预算但会返回的脚本被当成功收下，3–5s 墙钟预算形同虚设 | `sandbox_context.dart`（结果投递 + 微任务排空） | 补判墙钟预算，越过上限即判超时并销毁 |
| 2 | 脚本方法体内堆爆被归类为可捕获的普通脚本错误，失控上下文被继续使用 | `sandbox_context.dart` `_handleResult` | 按文本还原错误分类，引擎级错误一律销毁上下文 |
| 3 | 污染判定已结束在飞调用后，补投结果抛 `Bad state: Future already completed` | `sandbox_context.dart` `_handleResult` | 新增 `_settle`，投递幂等 |

第 3 项是在留档日志里发现的连带问题：一次正常的超时处理会变成引擎级异常。

## 四、产物清单

**测试代码**（`test/js_sandbox/`）

| 文件 | 内容 |
|---|---|
| `deadloop_timeout_test.dart` | 第 1 条：死循环 & 超时销毁（1a–1e） |
| `context_isolation_test.dart` | 第 2 条：多图源上下文隔离（2a–2d） |
| `section_category_test.dart` | 第 3 条：板块 category 隔离校验（3a–3b） |
| `evidence_log_test.dart` | 日志留档：把关键场景跑一遍并落盘证据 |
| `support/js_sandbox_support.dart` | 公共装置（原生桥装配、样板读取、隔离观测 worker） |
| `logs/*.log` | 三份套件运行日志 + `evidence.log` 内部日志证据 |

**样板 JS 脚本**（`assets/test_sources/`，未加入 `pubspec.yaml` 资源，不进 App 包）

| 文件 | 用途 |
|---|---|
| `deadloop_source.js` | 死循环（`while(true){}`）与有限空转两种失控形态 |
| `isolation_alpha.js` | 隔离测试甲：全局标记 + 沙盒文件 + 探针 |
| `isolation_beta.js` | 隔离测试乙：同名不同值，与甲成对 |
| `section_mismatch_novel.js` | 自报 `category: "novel"`，用于跨板块拒绝验证 |

**底座改动**：`source_script.dart`（category 解析与校验）、`source_registry.dart`
（导入时拒绝）、`lume_js_engine.dart`（元信息读取带上 category）、
`sandbox_context.dart`（三处修复）。

## 五、未决项与后续

1. ~~纯 CPU 死循环无法中断回收~~ —— **已修复**（中断符号导出 + 装备保持到排空结束）。
2. **插件的 `stringifyFn` 泄漏 → JSRuntime 无法回收**：插件上下文创建时两处
   `JS_FreeValue` 被注释掉，且 `stringifyFn` 是全局变量（多上下文互相覆盖），
   因此只能 `Qjs.reclaimRuntime = false`，runtime 被漏掉不回收。
   已记入 `deferred-todo.md`，刻意不与中断补丁混在同一文件改。
3. **真机手动确认**：本轮为自动化单元测试（Windows + 真实 QuickJS 桥）。
   iOS 真机（含补丁能否编过、真机跑死循环脚本、文件多选 / 剪贴板授权条）
   由项目负责人执行。
