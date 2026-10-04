# Lume Box · 报错可读性：导入失败要说清原因 / 播放失败不贴原始异常

来源：用户两张截图 + 一份猫源订阅地址（`https://9280.kstore.vip/cat/index.js.md5`）

1. 视频板块「播放」页签里显示的是内核原始异常
   （`PlatformException(VideoError, … CoreMediaErrorDomain error -12938 - HTTP 404 …)`）；
2. 猫源导入失败，Toast 只有一句笼统的「脚本载入失败：语法错误、运行异常，或用到了
   沙箱不支持的能力（如 dns / child_process / 自带 HTTP 服务的猫源脚本）」，
   真实原因（`猫源沙箱不支持「dns」`）只有翻运行日志才看得到。

## 一、对那份猫源的诊断（结论先说）

`…/cat/index.js` **不是图源脚本，是自建影视聚合服务端程序**：

| 证据 | 说明 |
|---|---|
| `listen({port, host})`、`createServer`、fastify ×80 / express ×25 / light-my-request | 这是要跑起来的 HTTP 服务 |
| `require` 了 `dns` / `net` / `tls` / `http2` / `worker_threads` / `stream/web` | socket、端口、进程、线程——沙箱按设计（宪法：脚本只能 fetch）不提供 |
| 6.4 MB 打包产物，含 axios / got / node-fetch / ajv / emby / redis / danmu_api 引用 | 服务端全家桶，常见于「自建聚合服务」 |

本地用真实 QuickJS 引擎实测：该包 **1.1 秒**解析执行到 `require('dns')` 被拒；
给它挂上「用到才抛」的 socket 存根后继续跑，随即倒在 `net/tls/http2` 这类无法在
沙箱里实现的能力上。**结论：这类服务端程序在 App 里跑不了**（iOS 更不可能跑 node
服务），正确用法是把它跑在电脑 / NAS 上，App 侧用一份薄壳图源脚本经
`LumeSource.http` 转发；或者改用真正的单文件图源脚本。

## 二、修复

### 1. 导入失败：把引擎的真实原因带出来

| 层 | 改动 |
|---|---|
| `SandboxContext`/`LumeSandbox`（既有） | 失败分类与原因本来就在 `SandboxError` 里 |
| `LumeJsEngine` | 新增 `lastLoadFailure`：`loadScript` 不再只返回 bool，失败原因留档 |
| `SourceEngine` 端口 | 新增 `loadFailure`（可读文本）；QuickJS 直通，Node-Mobile 在启动失败 / 超时 / 原生报错时记原因 |
| `SourceRegistry` | `describeLoadFailure(reason)`：有原因就原样带上（「脚本载入失败：猫源沙箱不支持「dns」…」），没有才回落到笼统提示；原因命中 socket / 进程 / 端口特征时**追加一句定向说明**：「若这是需要 node 运行的自建服务端程序，它不是图源脚本，App 不能直接运行它；图源脚本只需提供 getList / getDetail 这类函数，用 fetch 取数据」 |
| 运行时载入失败（`engineFor`） | 日志同样带上原因，排查「图源为什么打不开」不用猜 |

顺带加了 `LumeJsEngine.debugSupportedOverride`（与 `CatEngines.debugPlatformOverride`
同一套做法）：测试在原生桥可用的机器上能把整条导入链路（含落库）跑在真实引擎上，
不再只覆盖到「假管理器」。

### 2. 播放失败：界面只出现一句人话

- 新增 `PlayerErrorText.describe`（`lib/core/player/player_error.dart`）：按能认出来的
  模式翻译——HTTP 状态码（401/403/404/410/5xx 各给对应说法）、离线与域名解析失败、
  超时、格式/编码不支持、取消、无权限、本地文件不存在；认不出来时剥掉
  `PlatformException(…)` 包装与尾部 `, null, null)` 噪声并截断。
  **只改展示文案**，原始文本照旧进运行日志。
- AVPlayer 的两处错误出口（`initialize()` 抛错、`errorDescription`）都走归一；
  MPV 侧本来就说中文，不动。
- 视频页：地址栏下面那行只留给「地址本身有问题」（地址无效），不再把同一句播放
  错误重复显示两遍；画面位置的那句改成居中、可读的样式。

## 三、明确不做（附理由）

- **不给 `dns` / `net` / `tls` / `http2` / `worker_threads` 加垫片**：这类脚本要的是
  真 socket 与端口监听，垫片只会把「导入就被拦下」变成「导入成功、调用时才炸」，
  对用户更糟。若将来出现**只需要 dns** 的脚本，再按「网络请求走 fetch」的同一条
  纪律加一个宿主解析的 `dns` 垫片（`InternetAddress.lookup`）。
- 不做「导入时自动识别是不是服务端程序并拒绝」的花式判断：现在按能力特征给定向
  说明已经够用，且不会误伤。

## 四、测试

| 文件 | 覆盖 |
|---|---|
| `test/source_import_failure_test.dart`（新，3 例，真实 QuickJS + 真实落库链路） | 猫源 `require('dns')` → 提示点名 dns 且带「自建服务端程序」说明；语法错误 → 提示带 `SyntaxError` 且不带服务端说明；函数式脚本 → 照旧导入成功并落库 |
| `test/player_error_test.dart`（新，5 例） | 用户截图那条 404 原文 → 「打开失败：服务器上找不到这个视频（HTTP 404）」；401/403/500；离线 / 超时 / 编码不支持；包装剥离与截断；空输入兜底 |
| `test/cat_engines_test.dart`（改） | 引擎替身补新端口成员 |

验证：`flutter analyze` 零告警；全量 **479 例**通过。
