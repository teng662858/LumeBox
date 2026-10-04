# Lume Box · Phase3 最终项：Android 专属 Node-Mobile 猫源后端（方案 A）：已批准基线 + 延后待办

验收口径来自任务书「Phase3 最终任务：Android 专属 Node-Mobile 猫源后端」的 5 条要求。
本文档记录已批准基线、批准的 Phase1 改动豁免范围与延后待办
（**本轮交付边界：仅完成 Dart 上层框架**；Android 原生 NDK 编译与双引擎真机验证延后）。

## 一、已确认口径（批准时定稿）

| 口径 | 取值 |
|---|---|
| 本轮交付边界 | **仅 Dart 上层框架**：引擎端口与提供方登记表、Node-Mobile 的 Dart 引擎与通道契约、猫源引擎门与选择、Android-only 的切换 UI。原生集成与真机验证延后 |
| Phase1 改动 | 批准的最小附加改动：3 个文件、69 增 17 删（见第三节逐处清单）；`lume_js_engine.dart` 零改动 |
| 平台矩阵 | Android：QuickJS-NG / Node-Mobile 二选一；iOS：仅 QuickJS-NG；其余平台无引擎（板块维持骨架） |
| Node-Mobile 原生未集成时的行为 | 如实降级为「不可用」：设置页置灰、`callResult` 返回 unsupported——不假装能跑 |

## 二、已批准基线（5 条要求 → 落点 → 证据）

| 验收项（任务书口径） | 落点 | 证据 |
|---|---|---|
| 1. 仅限 Android；iOS / Windows 只放 UI 占位骨架，禁止接入 Node-Mobile | `SourceEngineRegistry` 内置登记表用 `if (Platform.isAndroid)` 决定是否登记 Node-Mobile；iOS / Windows 的 `CatEngines.choices` 不含它、原生不进构建 | `cat_engines_test.dart`「默认登记：本机（非 Android）只有 QuickJS」「iOS：仅 QuickJS，切换项隐藏」「无引擎平台：choices 为空」 |
| 2. 运行时分支：Android 二选一，iOS 仅 QuickJS | `CatEngineSettings.engineKindFor(section, db)`（只有猫源读自己的选择，其余板块恒为 QuickJS）+ `SourceRegistry.engineFor/import` 经 `SourceEngineRegistry.create` 分流 | 「engineKindFor：只有猫源读自己的选择」「引擎选择持久化」3 例（保存读回 / 脏值回退 / 板块隔离落在 `sections/cat/cat.db`） |
| 3. 实例隔离：每图源独立实例、超时销毁、异常回收、网络/IO 经桥接 | `node_mobile_engine.dart`：`start` 带 sourceId（一图源一实例）；**超时即回收原生实例、下次重建（generation 递增）**；原生异常同样回收；回包按沙箱同一套结果信封解码；引擎自身没有任何 fs/http 面，只连通道与端口（原生注入时只允许连 Dart 桥接层，见待办 1.6） | `node_mobile_engine_test.dart` 6 例：契约往返、超时回收与重建、原生异常回收、回包不合契约按协议错、起实例失败不循环、原生未集成如实降级 |
| 4. UI 仅 Android 显示引擎切换项 | `CatEngines.showsEngineSwitch(section)`（仅 Android 的猫源为真）；入口在 `source_section_page.dart` 的 AppBar 受门控；`cat_engine_settings_page.dart` 为设置页 | 「板块页入口」3 例（Android 猫源显示并进入 / Android 非猫源隐藏 / iOS 猫源隐藏）+「引擎设置页」2 例（不可用置灰、切换落库） |
| 5. 禁止修改 Phase1 已有代码 | 经批准的**最小附加改动**（下表），既有行为不变 | 既有 **291 个用例零回归**；`lume_js_engine.dart` 零改动 |

## 三、Phase1 改动逐处清单（批准的豁免范围）

| 文件 | 改动 | 规模 |
|---|---|---|
| `lib/core/js/source_registry.dart` | 引擎表类型 `LumeJsEngine` → `SourceEngine` 端口；`engineFor`/`import` 改为经登记表创建并按板块分流；新增 `_engineAvailable`（猫源走 `CatEngines.available`，其余板块维持 iOS 口径） | 含在 39 增 17 删内 |
| `lib/core/source/lume_sources.dart` | 新增 `runtimeAvailableFor(section)`；6 个静态入口与 `_LumeSourceManager.runtimeAvailable` 换用板块口径；无参 `runtimeAvailable` 语义不变 | 同上 |
| `lib/features/source/source_section_page.dart` | AppBar 增加受门控的「猫源引擎」动作 + 转跳方法 | +18 |
| `lib/core/js/lume_js_engine.dart` | **零改动** | 0 |

## 四、变更清单

新增：`lib/core/js/source_engine.dart`（229，端口 / 登记表 / 适配器）、
`lib/core/js/cat_engines.dart`（117，平台门 / 选择 / 持久化）、
`lib/core/js/node_mobile_engine.dart`（200，Node-Mobile Dart 引擎）、
`lib/features/cat/cat_engine_settings_page.dart`（186，切换 UI）；
测试新增 2 文件 19 例（Node-Mobile 6 + 猫源引擎门/持久化/设置页/入口 13）。

## 五、延后待办

### 待办 1 · Android 原生 NDK 编译与双引擎真机验证（本轮确认不做）

| # | 待办项 | 说明 |
|---|---|---|
| 1.1 | Android 构建环境（JDK + AVD/真机；本机当前无 JDK、无 AVD、无加速） | 一切 Android 验证的前置 |
| 1.2 | QuickJS-NG 在 Android 上的加载验证 | 插件含四 ABI 的 CMake 构建，Phase1 已有 `.so` 候选名（`libfastdev_quickjs_runtime.so`）；需真机确认可加载并跑通图源 |
| 1.3 | **Node-Mobile 原生集成（NDK）**：Kotlin 模块 + libnode 按 ABI 打包（上游 prebuilt 或自编）+ 实现 `lumebox/node_mobile` 通道契约（isSupported / start{sourceId} / loadScript / metadata / call / dispose），契约已由 Dart 侧测试固定 | 任务书第 1、3 条的落地主体 |
| 1.4 | 双引擎切换真机验证：选择落库 → 运行时分支生效 → 图源导入与加载成功 | 用同一份猫源脚本对两套引擎各跑一遍 |
| 1.5 | 超时销毁 / 异常回收在真机上的表现：实例被杀干净、内存回收、连跑多次无泄漏 | 对应任务书第 3 条 |
| 1.6 | 网络 / IO 沙箱限制在 Node 侧落实：原生不暴露 node 的 fs / http，注入的桥只连 Dart 桥接层 | 与 QuickJS 侧同一条纪律 |
| 1.7 | 体积与许可证评估：libnode 按 ABI 打包的体积增量、Node 的 MIT 许可证与补丁说明 | 需要授权时另行提请 |

### 待办 2 · 与既有真机/待办清单的关系

Phase1 真实沙箱、Phase2 系统相册与旋屏、Phase3 播放器 PiP / 扩展仓库 / 杂项设置 /
猫源垫片的真机项记录在各自板块文档里；本清单只覆盖本项，互不替代。

## 六、验证状态

`flutter analyze` 零问题；全量 **310 个测试通过**（基线 291 + 本轮 19）。
无新增依赖、无 WebView；Phase1 改动为经批准的最小附加改动，
并以「既有 291 用例零回归 + `lume_js_engine.dart` 零改动」留证。
