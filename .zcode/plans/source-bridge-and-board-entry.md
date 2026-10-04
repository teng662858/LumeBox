# Lume Box · 板块图源管理入口核实 + QuickJS‑NG 桥接全局 LumeSource

来源：用户反馈的两条问题——

1. **UI 路由**：四个板块右上角入口应当打开【本板块专属图源管理页】；播放器设置
   应挪到板块图源管理页内的子入口，或底部 Tab「设置」；
2. **沙箱**：报错「脚本错误: 全局对象不存在: LumeSource」，要求严格按
   「建虚拟机 → 注入 Polyfill（console / 定时器 / require / Buffer / process）→
   注入桥接全局 LumeSource（HTTP、沙盒文件 IO）→ 载入用户脚本」的顺序执行。

## 一、Bug1：路由核实（代码已在上一提交修好，本轮只补回归）

| 现象 | 根因 | 结论 |
|---|---|---|
| 视频页右上角是三横线（`Icons.tune`）＝播放器设置，点进去没有图源列表 | 上一个提交（`36fbd63`）之前的视频页 AppBar 只有「播放器设置」+「+」，四个板块都没有图源管理入口 | **已在 `36fbd63` 修复**：四块统一「图源管理」+「+」，打开本板块 `SourceSectionPage`（查看 / 启停 / 重命名 / 导出 / 删除 / 浏览） |
| 播放器设置的落点 | 用户给的两种方案 | 已落两条：底部 Tab「设置」→ 播放器设置（写视频板块自己的库）；视频板块播放控制栏齿轮（`36fbd63`）；设置页里的「播放器内核 · 故障逃生入口」保留不动 |

本轮补的回归：`test/board_source_entry_test.dart` 增加**猫源板块**用例
（板块页本身就是「猫源 · 图源管理」），四个板块的入口口径现在都有断言。

> 现场复现的那台设备跑的是 `36fbd63` 之前的构建：需要重新出包（Actions 的
> 未签名 IPA → 本地重签名）并重装，才能看到新入口。

## 二、Bug2：桥接全局 `LumeSource`

### 根因

引擎一直按 `LumeSource.<method>` 调用，而 `LumeSource` 此前**只由脚本自己声明**
（契约 v2 的 `var LumeSource = { … }`）。脚本若按更常见的写法只提供顶层函数
（`async function getList(page)`），全局 `LumeSource` 根本不存在，于是
`__lumeInvoke` 抛出「全局对象不存在: LumeSource」——脚本内容完全正确，却一行都跑不了。

### 修复：严格启动顺序 + 宿主注入桥接对象

| 顺序 | 动作 | 落点 |
|---|---|---|
| 1 | 建 QuickJS‑NG 虚拟机（JSRuntime + JSContext） | `SandboxContext.create` |
| 2 | 注入 Polyfill：console / 定时器（沙箱 prelude）、`fetch`、猫源的 process / Buffer / 简易 require | `SandboxContext._bootstrap` → `PolyfillRegistry` |
| 3 | 注入桥接全局 `LumeSource`（宿主 HTTP + 沙盒文件 IO + 五个契约方法的派发器） | 新增 `LumeSourceBridgePolyfill`（`source_bridge.dart`），登记在**最后**（`requires: lume.source.fetch`） |
| 4 | 载入并执行用户图源脚本 | `LumeJsEngine.loadScript` |

桥接对象解决的写法差异（`locate` 三步查找，顺序固定）：

| 脚本写法 | 例子 | 派发口径 |
|---|---|---|
| 函数式（顶层函数） | `async function getList(page)`、`getSearch(keyword, page)`、`getDetail(id)`、`getChapters(id)`、`getContent(id, chapterId)`、`getCategories()` | **位置参数**（搜索走 `getSearch`，否则 `getList`） |
| 对象式（契约 v2） | `LumeSource.list = …` 或 `var LumeSource = { list: … }` | **对象入参**`{page, categoryId, keyword}` / `{id}` / `{id, chapterId}` |
| 词法声明 | `const LumeSource = { … }` | 取全局词法绑定（它优先于全局对象属性） |

- 脚本对全局 `LumeSource` 的**赋值合并进桥接对象**：脚本自己读到的仍是同一个桥接
  对象，因此 `LumeSource.http` / `LumeSource.fs` 不会被脚本对象盖掉
  （`http` / `fs` 是保留名）。
- 脚本可用宿主能力：
  - `LumeSource.http.request({url, method, headers, body})` / `.get(url, opts)` /
    `.post(url, body, opts)` → 走 `fetch` → `LumeBridge.invoke('http.fetch')` → `LumeHttp`；
  - `LumeSource.fs.readText / writeText / exists / remove / list` → 新增
    `SandboxStore`（**按图源隔离的进程内存储**，条数 64 / 单条 64 KiB / 总量 512 KiB，
    不落盘，随引擎释放）。
- 缺实现不再报「全局对象不存在」：改为点名该写哪个函数，例如
  「图源脚本没有实现 list 方法：请定义顶层函数 getList，或在脚本里给 LumeSource.list 赋值」。

### 宽容解析（让函数式脚本的返回值真的能显示）

| 位置 | 新增容忍 |
|---|---|
| 列表信封 `parseSourceList` | `{list: [...], hasMore}` 与 `{items: [...]}`、裸数组同义（`items` 优先） |
| 条目 `SourceItem.parse` | `url` 兼作 `id`、`name` 兼作 `title`（视频类脚本常见的 `{title, url}`） |

### 边界（明确不做）

- 元信息仍由脚本声明：对象式读 `LumeSource.id / name`，函数式**必须**写头部注释
  `// LumeSource: {"id":"…","name":"…"}`（导入口径不变，失败提示点名这一行；
  导入弹窗与内置示例里都补了这句说明）。
- 猫源之外的板块不注入 process / Buffer / require：垫片补全只对猫源开放是既有隔离
  口径（`cat_polyfills_test` 有断言），桥接对象则是四个板块都注入。
- 沙盒文件 IO 不落盘、不做真实文件系统：进程内、有上限、随引擎释放。
- 视频板块本身仍是「播放器 + 地址栏」；图源列表走通用浏览页（图源总管理 / 板块
  图源管理的「浏览」）。从列表直接起播属于 Phase1 之外的播放器接线，未做。

## 三、测试

| 文件 | 覆盖 |
|---|---|
| `test/source_bridge_test.dart`（新，5 例） | 注入顺序（环境垫片在前、桥接最后）、四板块都注入、别名表与契约同名同序、源码不含占位符且不引入新系统能力、别名表可注入 |
| `test/source_bridge_native_test.dart`（新，9 例，真实 QuickJS） | **用户验证脚本（顶层 `getList(page)`）跑通并解析出条目与页码**、函数式全套（分类 / 搜索 / 详情 / 章节 / 内容）、`LumeSource.http` + `LumeSource.fs` 落到宿主与沙盒存储、对象式脚本合并后桥接能力仍在、`const/let` 写法、反复赋值、**启动顺序**（脚本执行时桥接与垫片已就位）、猫源环境垫片与桥接共存、缺实现给出可读报错 |
| `test/source_store_test.dart`（新，12 例） | 路径归一、上限（单条 / 总量 / 条数）、实例隔离、宿主代理五个方法、非法入参拒绝、dispose 清空 |
| `test/source_contract_test.dart`（+3 例） | `{list: [...]}` 信封、`items` 优先、`{title, url}` / `{name, …}` 条目 |
| `test/board_source_entry_test.dart`（+1 例） | 猫源板块页即本板块图源管理页 |

验证：`flutter analyze` 零告警；全量 **461 例**通过（含真实 QuickJS 原生命中）。
