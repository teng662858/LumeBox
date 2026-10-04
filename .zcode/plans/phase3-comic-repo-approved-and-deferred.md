# Lume Box · Phase3 漫画扩展仓库支持：已批准基线 + 延后待办

验收口径来自任务书「Phase3 任务：漫画扩展仓库支持」的 5 条要求。
本文档记录已批准基线、两条事实基础（含已确认的 APK 口径）与延后待办
（含 iOS 真机验证清单，本轮不执行）。

## 一、两条事实基础（解析契约与载体口径）

### 事实 1 · 两类仓库的真实格式（对着远端真实索引核对后实现）

- **Mihon / Tachiyomi**（`index.min.json`）：条目
  `name / pkg / apk / lang / code / version / nsfw / sources[]`，
  `sources[]` 元素为 `{name, lang, id, baseUrl}`；载体 **`.apk`**。
- **Venera**（`index.json`）：条目 `name / fileName / key / version`，
  `fileName` 指向 **`.js`** 脚本（同 `key` 可有多个条目，标识用 `fileName`）。

两种格式字段与载体都不同 → 两个独立解析器，只在一份归一模型上汇合
（任务书第 1 条）。

### 事实 2 · APK 载体在 iOS 不能运行（**已确认口径**）

| 载体 | 仓库管理 | 浏览扩展列表 | 安装 / 启用 / 卸载 |
|---|---|---|---|
| `.js`（Venera） | ✅ | ✅ | ✅ 真实可用（下载脚本 → 与「导入图源」同一条校验与落库链路 → 漫画板块图源表） |
| `.apk`（Mihon） | ✅ | ✅ | ❌ 如实拒绝：界面标注「APK 载体需要 Android 运行时，本平台不能运行」，安装入口置灰，不做假的安装流程 |

## 二、已批准基线（5 条要求 → 落点 → 证据）

| 验收项（任务书口径） | 落点 | 证据 |
|---|---|---|
| 1. 仅漫画板块生效；Mihon/Tachiyomi 与 Venera 两类格式独立解析 | `repo/comic_repo_models.dart`（归一模型 + `RepoKind` / `ExtensionArtifact`）、`repo/comic_repo_mihon_parser.dart`、`repo/comic_repo_venera_parser.dart`、`repo/comic_repo_parser.dart`（按类型分派） | `test/comic_repo_parser_test.dart` 7 例：字段映射、nsfw 三种写法、绝对地址、条目容错、**载荷互换解析不出扩展**（不共用解读逻辑） |
| 2. 仓库列表 UI：添加 / 删除 / 刷新，浏览可用扩展列表 | `comic_repo_page.dart`（列表 + 添加对话框 + 刷新 + 删除二次确认）、`comic_extension_page.dart`（扩展列表）；入口挂在漫画板块外壳 `comic_page.dart`（只有漫画板块有） | `test/comic_repo_page_test.dart` 6 例：空态 / 添加 / 刷新 / 删除 / JS 全流程 / APK 拒绝 / 非 iOS 无入口 |
| 3. 扩展下载、安装、启用/禁用、卸载流程 | `repo/comic_repo_service.dart`：安装 = 抓脚本 → `SourceManager.importScript`（漫画板块图源表）→ 记安装记录；启停 = 图源启停；卸载 = 摘除图源 + 清记录；失败一律可读原因 | `test/comic_repo_service_test.dart` 13 例：安装成功 / APK 拒绝 / 下载失败 / 导入失败 / 启停 / 卸载 / 删除仓库不卸载扩展 / 启用状态来自图源表 / 板块守卫 |
| 4. 严格隔离：只属于漫画模块，其他板块不能调用解析代码 | 代码全在 `lib/features/comic/repo/`；服务构造校验板块（非漫画 `ArgumentError`）；存储 `open()` 不接受 Section 且库内自证 `owner_section = comic`（不符 `StateError`）；库文件 `sections/comic/repo.db` 与图源库、阅读库分文件 | `test/comic_repo_isolation_test.dart` **源码级守卫**（模块外引用即失败）+ `test/comic_repo_store_test.dart` 5 例（含错归属拒绝打开、其他板块目录不落文件） |
| 5. Android / Windows 仅 UI 骨架占位 | 漫画板块在非 iOS 平台连板块骨架都不打开（`LumeSources.runtimeAvailable` 门），仓库入口不可达 | `test/comic_repo_page_test.dart`「非 iOS：漫画板块只有骨架，扩展仓库入口不可达」 |

本轮文件清单：新增 `lib/features/comic/repo/`（7 文件 875 行）、
`comic_repo_page.dart`（431）、`comic_extension_page.dart`（323）；
修改 `comic_page.dart`（仅加入口）；测试 5 个文件 32 例。

明确不做（未经要求，不得再提）：Mihon APK 的下载与文件管理、扩展更新检测、
仓库搜索与批量操作。

## 三、延后待办

### 待办 1 · iOS 真机验证（本轮确认不执行，待有 Mac / 真机时按清单过一遍）

| # | 验证项 | 为什么必须真机 | 落点 |
|---|---|---|---|
| 1 | **真机网络抓包**：仓库索引与扩展脚本的真实 HTTP 请求（User-Agent、重定向、超时、非 2xx 归错） | 本机用替身抓取器只验证了契约，真实网络行为与 `LumeHttp` 组合未在真机验证 | `repo/comic_repo_fetcher.dart` |
| 2 | 真实仓库端到端：添加真实 keiyoushi（Mihon）与 venera-configs（Venera）仓库，刷新计数与真实索引一致，APK 条目正确标注不可运行 | 解析器对着真实载荷的规模与细节（数千条目、字段变体）未在真机实测 | 两个解析器 + 服务 |
| 3 | **真实扩展导入**：从真实 Venera 仓库安装一个 JS 扩展 → 真实 QuickJS 沙箱加载（脚本可能依赖沙箱尚未实现的 API，需实测并按第 4 条纪律处置：异常只提示不闪退）→ 在漫画板块用它出图（分类 / 列表 / 详情 / 章节图片） | 本机的图源端口是替身；沙箱行为与脚本兼容性只能真机验证 | `comic_repo_service.dart` + 漫画板块浏览链路 |
| 4 | iOS 构建通过（新增代码在 iOS 上编译链接） | 本机无 Xcode，只过了 `flutter analyze` | 本轮全部改动 |
| 5 | 仓库库落点与隔离在 iOS 沙盒中的表现（`sections/comic/repo.db` 创建、重开、与图源库分文件） | path_provider 真实目录行为 | `repo/comic_repo_store.dart` |

### 待办 2 · 与既有真机待办的关系

Phase1 真实沙箱跑 JS 图源、Phase2 系统相册保存、Phase3 播放器 PiP 的真机项
记录在各自板块文档里；本清单只覆盖扩展仓库，互不替代。

## 四、验证状态

`flutter analyze` 零问题；全量 **257 个测试通过**（基线 225 + 本轮 32）。
无新增依赖、无 WebView、Phase1 沙箱 / 图源 / 阅读底座一行未改；
仓库解析与存储零外溢（有源码级用例把关）。
