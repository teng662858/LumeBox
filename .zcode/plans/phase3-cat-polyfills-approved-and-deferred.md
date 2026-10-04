# Lume Box · Phase3 猫源 QuickJS‑NG 垫片补全：已批准基线 + 延后待办

验收口径来自任务书「Phase3 任务：猫源 QuickJS‑NG Polyfill 垫片补全」的 5 条要求。
本文档记录已批准基线、已确认口径与延后待办（含真机联调，本轮不执行）。

## 一、已确认口径（批准时按下列取值定稿）

| 口径 | 取值 | 理由 |
|---|---|---|
| `process.platform` | `'darwin'` | iOS 上的 Node 语义平台名 |
| `process.version` | `'v0.0.0-lume'`，`versions` 为空对象 | **不假装 Node 版本**：脚本走兼容分支，而不是误用未实现的能力 |
| `require` 白名单 | `buffer` / `process` / `console` / `timers`（含 `node:` 前缀） | 其余一律友好错误，不擅自扩面 |
| IO 通路 | 网络只能 `fetch` → `LumeBridge` → `LumeSourceHost`（Dart）；沙箱无文件 IO | 任务书第 2 条（硬约束） |
| `Buffer` 编码 | `utf8` / `base64`（兼容 base64url）/ `hex` / `latin1`，纯 JS 实现 | 其余编码（如 `utf16le`）抛友好错误 |

## 二、已批准基线（5 条要求 → 落点 → 证据）

| 验收项（任务书口径） | 落点 | 证据 |
|---|---|---|
| 1. 只针对猫源的垫片：process / Buffer / 基础 require / console / 定时器 | `lib/core/js/cat_polyfills.dart`：`CatProcessPolyfill` / `CatBufferPolyfill` / `CatRequirePolyfill` / `CatConsolePolyfill`（info·debug·trace·dir·assert）/ `CatTimersPolyfill`（setInterval·clearInterval·setImmediate·clearImmediate + setTimeout 附加参数） | 真引擎用例「全量注入」「process：…」「Buffer：utf8 / base64 / hex 编解码与常用方法」「require：四个内建可用」「定时器：…」 |
| 2. 不引入 Node 运行时；不暴露 node fs/http；网络与文件 IO 全部走 Dart 桥接 | 垫片是纯 JS，无原生依赖；`require` 对 `fs` / `http` / `net` 等抛出可读错误并指向宿主桥接层；猫源表仍含通用 fetch 垫片（`LumeBridge` → `LumeSourceHost` → `LumeHttp`） | 用例「网络仍走宿主桥接层：fetch 由 Dart 侧发出」（断言宿主收到请求并回填响应）+ `cat_polyfills_test.dart`「猫源垫片是纯 JS：不直接碰宿主桥」 |
| 3. WASM / `.node` 直接友好报错，不做兼容 | `CatUnsupportedGuardPolyfill`：统一 `__lumeUnsupportedModule`（稳定 `code = 'LUME_UNSUPPORTED'`）+ `WebAssembly` 抛错存根（compile/instantiate/Module/…） | 用例「WebAssembly：存根一用就报友好错误」「require：… .node / WASM 友好拒绝」 |
| 4. 一猫源一独立上下文；超时销毁重建保护 | 沿用既有：一图源一 `LumeSandbox`（一 JSRuntime + JSContext）；污染即弃、重建后垫片随新上下文再次注入 | 用例「超时销毁重建：上下文与垫片状态都是全新的」（重建后 `Buffer.__dirty` / `process.__dirty` / 全局痕迹全部消失且编码仍可用）「两个猫源实例互不共享垫片状态」 |
| 5. Android / Windows 仅骨架占位 | 猫源板块在非 iOS 不打开（`LumeSources.runtimeAvailable` 门）；引擎本身 `LumeJsEngine.isSupported` 仅 iOS | 既有 `widget_test.dart` 骨架用例（本轮零改动） |

**只对猫源注入**（第 1、4 条的隔离落点）：`LumeSourcePolyfills.catRegistry` +
`forSection(section)`；`LumeJsEngine.create` 新增 `section` 参数，
`source_registry.dart` 的载入引擎与导入探针两处都传板块（导入校验与运行时同环境）。
证据：`cat_polyfills_test.dart`「按板块选表：只有猫源拿到垫片补全」（逐个板块断言
没有 `lume.cat.*`）「依赖顺序：require 在它引用的内建之后注入」。

本轮文件清单：新增 `lib/core/js/cat_polyfills.dart`（691 行，六个垫片）；
修改 `lib/core/js/lume_js_engine.dart`（+21：catRegistry / forSection / create 参数）、
`lib/core/js/source_registry.dart`（+7：两处传板块）；测试新增 2 文件 14 例
（真引擎 10 + 登记表 4）。

## 三、明确不做（未经要求，不得再提）

- 不引入真实 Node 运行时、不新增任何原生依赖。
- 不做 node `fs` / `http` / `https` / `net` 垫片（IO 一律走桥接层）。
- 不做 WASM / `.node` 的兼容或降级加载。
- 不实现白名单之外的 Node 内建（`crypto` / `os` / `path` / `util` 等）；
  `crypto`（md5/sha）若真实脚本需要，属独立立项。

## 四、延后待办

### 待办 1 · 真实脚本真机联调（本轮确认不做）

| # | 验证项 | 为什么必须真机 | 落点 |
|---|---|---|---|
| 1 | 真机加载**真实猫源脚本**（用户导入的实际脚本）跑通：脚本需要的垫片能力是否齐备、缺失能力是否给出可读错误而不是崩溃 | 本机只用手写脚本对着 DLL 验证垫片语义；真实脚本的用法面只有真机能试 | `cat_polyfills.dart` |
| 2 | `Buffer` 编码在真实数据上的表现（真实 base64 密钥 / 图片数据、hex 摘要） | 真实数据的长度与边界（缺失填充、URL 安全变体）在真机上过一遍 | `CatBufferPolyfill` |
| 3 | 超时 / 死循环在真机上确实销毁重建且不闪退（结合真实脚本的耗时行为） | 真机性能与预算触发点与桌面不同 | 沙箱既有机制 + 垫片重注入 |
| 4 | 与真实猫源仓库脚本的端到端联调（导入 → 加载 → 出内容） | 端到端只在真机成立 | 猫源板块链路 |
| 5 | iOS 构建通过（本轮新增 Dart 代码编译链接） | 本机无 Xcode，只过了 `flutter analyze` | 本轮全部改动 |

### 待办 2 · 与既有真机待办的关系

Phase1 真实沙箱图源、Phase2 系统相册与旋屏、Phase3 播放器 PiP / 扩展仓库 /
杂项设置的真机项记录在各自板块文档里；本清单只覆盖猫源垫片，互不替代。

## 五、验证状态

`flutter analyze` 零问题；全量 **291 个测试通过**（基线 277 + 本轮 14）。
真实引擎用例与 `sandbox_native_test` 同一套原生桥（Windows 用构建产物 DLL、
iOS 走 `DynamicLibrary.process()`），垫片行为是对着真引擎验证的。
无新增依赖、无 WebView；Phase1 沙箱策略 / 预算 / 污染重建一行未改。
