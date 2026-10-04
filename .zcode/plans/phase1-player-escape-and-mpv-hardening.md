# Lume Box · Phase1 紧急修复：逃生入口 / MPV 卡死防护 / id 白名单

三条修复对应任务书「紧急修复 3 处问题」。改动只落在**播放器选择 UI、MPV 初始化
逻辑、脚本解析模块**：导航、数据库、QuickJS 沙箱底层一行未改。

## 1. 逃生入口（播放器内核选择）

| 落点 | 内容 |
|---|---|
| `lib/features/video/player_kernel_picker.dart`（新增） | 内核选择列表抽成**唯一一份**组件 |
| `lib/features/video/player_settings_page.dart` | 视频板块右上角快捷菜单改用该组件（保留原位） |
| `lib/features/video/player_kernel_section.dart`（新增） | 自包含区块：打开视频板块自己的设置库 → 渲染同一份列表 → 只改内核写回 |
| `lib/features/settings/settings_page.dart` | 全局设置页**内嵌**该区块（故障逃生入口） |

口径说明：**内嵌而不是再跳一层页面**——逃生场景要点得最少；区块与快捷菜单
共用 `PlayerKernelPicker`，两处保证"一模一样"。逃生入口只改内核，倍速与字幕
原样保留；列表里不可用的内核点不动并显示原因。

## 2. MPV 卡死防护

| 落点 | 内容 |
|---|---|
| `lib/core/player/player_kernel_launcher.dart`（新增） | 内核启动器：**异步创建 + 超时 + 丢弃 + 回退** |
| `lib/core/player/player_factory.dart` | `mpvInitTimeout = 8s`、MPV 熔断开关（内存态）、`isAvailable` 纳入熔断 |
| `lib/features/video/video_page.dart` | 创建走启动器；回退时弹提示并把设置改成实际生效的内核后才落库 |

具体行为：
1. **不在同步路径上创建内核**：启动器先让出一帧再把创建排到事件循环后续任务里，
   页面先渲染「正在准备播放器」，`build` / `initState` 绝不碰原生库；
2. **8 秒超时**：`.timeout` 之外再做一次**耗时复核**——原生初始化是同步阻塞调用，
   Dart 无法抢占式中断它，那种情况下定时器可能被已完成的 future 抢先，因此
   只要实际耗时超过预算就判定失败；
3. **失败即丢弃 + 回退**：超时/抛错都调用 `dispose()` 丢掉刚建出来的实例，改用
   AVPlayer，并弹提示「MPV初始化失败，已自动切换回AVPlayer播放器」；
4. **失败的内核不落库**：只有实际生效的内核才写进视频板块的设置库；
   MPV 同时在**本次运行内熔断**（内存态，不写持久化），设置页与逃生入口会显示
   「MPV 初始化失败（本次运行已自动回退 AVPlayer）」。

## 3. 图源 id 白名单与失败提示

| 落点 | 内容 |
|---|---|
| `lib/core/js/source_script.dart` | `_idPattern = ^[A-Za-z0-9_-]{1,64}$`；新增 `idIssue` / `headerIdOf` / `describeImportFailure` |
| `lib/core/js/source_registry.dart` | 导入失败改用诊断文案（点名到字符） |

- **白名单收紧**：id 只允许英文字母、数字、短横「-」、下划线「_」；**长破折号
  （U+2014）、en dash、全角字母/句点、半角句点、空格等一律拒绝**（此前点号是
  允许的，这是本次收紧的口径）；
- **失败提示可操作**：诊断会点名"哪个 id、哪个字符不合规（含码位）"，并提示检查
  脚本头部的 `// LumeSource` 元信息与 id 字符规则；连头部声明一起诊断——
  用户最可能改的就是那一行；
- 只有到 `SourceRegistry.import` 的失败信息里，页面（`AddSourceButton` 的
  SnackBar）会原样透出，用户能直接照着手改。

## 验证

- `flutter analyze` 零告警；全量 **409 例**通过（本轮新增/改写 21 例）：
  - `test/player_kernel_launcher_test.dart`：异步（调用瞬间不碰工厂）、正常创建、
    抛异常回退、超预算回退并**释放被丢弃的实例**、熔断后目录口径、无兜底内核时
    返回 null；
  - `test/player_kernel_section_test.dart`：设置页内嵌同一份列表、逃生切换只改
    内核、不可用内核点不动且能切回 AVPlayer、库打不开给可读提示；
  - `test/video_page_test.dart`（新增用例）：MPV 初始化失败 → 弹提示 + 回退
    AVPlayer + **库里仍是 avplayer**（禁止把 MPV 写进配置）；
  - `test/source_script_test.dart`：id 白名单（长破折号 / en dash / 全角 / 点号 /
    空格 / 中文 / 斜杠逐个拦住）、`idIssue` 点名字符与码位、`describeImportFailure`
    三种诊断路径；原先带点号的用例按新口径改成合法 id。

## 如实记录的边界

- 8 秒超时**不能抢占**正在执行的原生同步调用：超时后我们会立即丢弃实例并回退，
  但若底层调用本身耗时很久，UI 线程在那一小段里仍会被占住（FFI 固有性质）。
  本轮的改进是：**绝不出现"没有回退、一直卡着"的状态**，且失败不会被写进配置
  反复复现。
- 熔断是**内存态**：重启 App 会给 MPV 一次新机会（避免一次偶发失败永久禁用）；
  若真机上每次都失败，用户会稳定看到提示并自动用 AVPlayer。
