# Lume Box · 猫源 QuickJS‑NG Node 垫片扩展（真实脚本驱动）

本轮任务书口径：**QuickJS‑NG Node Polyfill 垫片开发（给猫源 JS 脚本提供模拟
process、Buffer 等环境）**，随后重新打包 IPA。范围仍是垫片层与测试，
沙箱策略、预算、污染重建、宿主桥协议与数据源契约一行未改。

## 一、先探测再补：真实引擎自带了什么

对着真机同一套原生桥（Windows 用构建产物 DLL、iOS 走 `DynamicLibrary.process()`）
逐个探测 QuickJS‑NG 的全局能力：

| 引擎自带（不需要垫片） | 引擎缺失（本轮补齐） |
|---|---|
| `atob` / `btoa`、`queueMicrotask`、`performance`、`BigInt`、`Proxy`、`Reflect`、`Symbol`、`WeakMap` / `WeakRef` / `FinalizationRegistry`、`Uint8Array` / `DataView` 等 | `URL` / `URLSearchParams`、`TextEncoder` / `TextDecoder`、`crypto`、`structuredClone`、`localStorage` / `sessionStorage`、Node 的 `require` 内建模块 |

先探测再动手，避免垫片覆盖引擎原生实现（那会让行为与真机不一致）。

## 二、新增垫片（三层，只对猫源注入）

| 层 | 文件 | 内容 |
|---|---|---|
| 平台全局 | `lib/core/js/cat_web_polyfills.dart` | `TextEncoder` / `TextDecoder`（utf‑8 / utf‑16le / latin1、BOM 语义）、`URL` / `URLSearchParams`（解析、相对解析、参数读写、form‑urlencoded 序列化、与 `search` / `href` 联动）、`structuredClone`（环引用与常见内建类型，不可克隆值报 `DataCloneError`）、`localStorage` / `sessionStorage`（**进程内**、不落盘、上下文销毁即清空） |
| Node 模块 | `lib/core/js/cat_node_modules.dart` | `crypto`（md5 / sha1 / sha256、HMAC、randomBytes / randomUUID / `globalThis.crypto` 的 `getRandomValues` / `subtle.digest`，纯 JS）、`events`（EventEmitter）、`path`（posix 语义）、`util`（format / inspect / inherits / promisify / types / isDeepStrictEqual）、`assert`、`stream`（Readable / Writable / Duplex / Transform / PassThrough / pipeline / finished / `Readable.from` / `for await`）、`http` + `https`（**经 `fetch` 桥接到宿主网络层**，响应按 `IncomingMessage` 形状投递）、`fs`（**内存虚拟盘**：不落盘、不跨上下文、无宿主权限）、`os`、`timers/promises` |
| 补充模块 | `lib/core/js/cat_node_extras.dart` | `zlib`（**纯 JS DEFLATE 解压**：stored / fixed / dynamic、gzip / zlib / raw 三种容器；压缩侧给可读错误）、`tty`（`isatty` 恒 false + `process.stdout/stderr` 形状）、`async_hooks`（AsyncLocalStorage / AsyncResource 最小实现）、`diagnostics_channel`（无人订阅的观测通道）、`perf_hooks`、`module`（createRequire / builtinModules） |
| Buffer 扩展 | `lib/core/js/cat_polyfills.dart` | 编码加 `utf16le`；二进制读写 `readUInt8/16LE/16BE/32LE/32BE`、`readInt*`、`readBigUInt64LE/BE` 与对应 `write*`；`indexOf` / `lastIndexOf` / `includes` / `copy` / `fill` / `reverse` / `compare` / `subarray` / `entries` / `keys` / `values` / `forEach` / `isEncoding`；`Buffer.from(ArrayBuffer)` 与 `DataView` 输入 |

## 三、边界（明确不做，且都给出可读错误）

- **真实 socket / 进程 / 线程能力**：`net` / `tls` / `dns` / `child_process` /
  `worker_threads` / `cluster` / `vm` / `http2` 一律拒绝（网络只能走 `fetch` →
  宿主桥；`http.createServer` 也明确拒绝——沙箱不监听端口）。
- **`zlib` 只解压不压缩**：沙箱里压缩没有实际用途，压缩侧抛
  `LUME_UNSUPPORTED`。
- **`fs` 是内存盘**：不落盘、不跨上下文；需要持久化的脚本必须走宿主桥接层。
- **随机数是沙箱内 PRNG**（无系统熵源）：够 nonce / 占位，**不是密码学安全的
  随机源**，注释与测试里都写明，不给脚本造成「有 OS 熵」的错觉。
- 已知边界：沙箱结果通道是 C 字符串，**返回文本里不能含 NUL**（零填充字节
  这类内容要用 hex/base64 传），已在用例里注明。

## 四、真实脚本实测（用户提供的猫源）

脚本：`https://9280.kstore.vip/cat/index.js.md5`（`.md5` 里是校验值
`6c7379bc24a23ec5b923ecf6f9c9d331`，脚本实体在同名 `index.js`，6.48 MB，哈希核对一致）。

| 实测项 | 结果 |
|---|---|
| 沙箱载入 | 1.18 s 完成求值（在 4 s 预算内），在 `require("node:dns")` 处被**可读拒绝**：`猫源沙箱不支持「dns」：沙箱不提供进程、线程与底层网络：网络请求走 fetch（宿主桥接层）` |
| 临时补 dns 存根后再试 | 继续执行到别的缺失点，报 `TypeError: not a function`（同类 Node 深层能力） |
| 脚本形态 | `createServer` ×5、`.listen(` ×4、`127.0.0.1` ×37、`module.exports = { start, stop }` —— 这是**服务型猫源**（自带 HTTP 服务、导出一对 start/stop） |
| 结论 | 架构文档硬性约束写明：iOS 猫源运行栈**只支持纯 JS 爬虫脚本**，「自带服务 / 原生扩展 / WASI」属不兼容范围。本脚本按设计应被**友好拒绝**，而不是崩溃或静默失败——当前行为正是如此：导入侧提示可读失败口径，引擎侧把具体原因写进运行日志（设置 → 运行日志） |
| 若将来要支持 | 需要独立立项：要么适配「服务型猫源」的调用契约（沙箱内起服务不可能，只能改成把它的路由映射到宿主请求），要么在导入时识别这类脚本并直接标记「不兼容类型」 |

## 五、验证

- `flutter analyze` 零问题。
- 全量 **357 个测试通过**（基线 334 + 本轮 23），其中：
  - `test/cat_polyfills_ext_test.dart`（22 例，真实引擎）：平台全局、Buffer 扩展、
    crypto 标准向量（md5 / sha1 / sha256 / HMAC 逐个对照已知向量）、zlib 解压
    （数据由 Dart 侧 `gzip` / `zlib` / raw deflate 现场压缩）、Node 模块、
    `http`/`https` 经宿主桥（含 POST 请求头 / 正文、`pipe`、错误事件、`createServer` 拒绝）；
  - `test/cat_node_bundle_test.dart`（1 例，真实引擎）：把真实脚本的**用法模式**
    串成一条链路（require 一串内建 → Buffer 二进制读写 → TextEncoder → URL →
    crypto md5 → 内存 fs → EventEmitter → stream → 结构化克隆 → `http.get`
    经宿主 → `zlib.gunzipSync` → 按契约返回条目），端到端跑通；
  - 既有垫片用例同步更新：`utf16le` 从「拒绝」改为「支持」、`fs`/`http` 从
    「拒绝」改为「可用」，越界清单改为 `net` / `tls` / `child_process` /
    `worker_threads` / `http2`。
- 未新增任何依赖；无 WebView；沙箱策略 / 预算 / 污染重建零改动。
