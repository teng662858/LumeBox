# Lume Box · 主导航五 Tab 壳 + 板块页「+」添加图源 + 图源脚本文本预处理

本条改动对应任务书「主导航改造对齐文档 / 板块页 UI 补齐 / 修复图源解析 Bug」。
范围严格限制在**导航 UI、按钮组件、脚本文本预处理**三处；QuickJS 沙箱、
播放器抽象层、数据库与缓存隔离等底层业务逻辑未改动。

## 一、主导航（五 Tab）

| 要求 | 落点 | 说明 |
|---|---|---|
| 移除卡片仪表盘首页 | `lib/features/shell/home_page.dart` 删除（原仪表盘页） | `app.dart` 直接挂导航壳，启动即五页签 |
| 底部悬浮 Dock，5 个 Tab | `lib/features/shell/app_shell.dart` | 顺序：小说 / 漫画 / 视频 / 猫源 / 设置；毛玻璃胶囊，选中态白字 + 高亮图标 |
| 桌面端自动换侧边栏 | 同上：`Platform.isWindows/MacOS/Linux` → `NavigationRail` | 移动端 Dock / 桌面端侧栏是同一套页签 |
| 全屏页隐藏 Dock，退出恢复 | `lib/features/shell/shell_dock.dart`（`ShellDockController` + `ShellDockObserver` + `ShellDockScope`） | 阅读器 / 详情 / 二级页压栈即隐藏（`PageRoute` 才触发，弹窗不影响）；视频页播放中经令牌隐藏，暂停 / 停止 / 离开板块恢复 |
| 展示文案「自定义视频」→「视频」 | `core/session/section.dart` 的 `label` | **只改展示文案**：`id` 仍是 `video`，库 `sections/video/video.db`、缓存 `sections/video/cache`、图源归属全部不变 |
| 设置作为第五个 Tab | `settings_page.dart` | 保留子页面【图源总管理】（`GlobalSourcePage`），页内入口于本轮补回 |

资源纪律：导航壳**只把当前页签的页面挂在树上**，切页签即销毁旧页面、重建新页面，
沿用「进板块打开、退出板块释放」的既有口径（不是 `IndexedStack` 全挂载）。

## 二、板块页「+」添加图源

| 要求 | 落点 |
|---|---|
| 四个板块页右上角统一「+」 | `lib/features/source/add_source_button.dart`（`AddSourceButton`），接入小说 / 漫画 / 视频 / 猫源四个板块页的 `AppBar.actions` |
| 本地 JS 文件导入 | 系统文件选择器（`file_selector`，iOS 走文档选择器），读出字节 → UTF-8 解码 → 剥 BOM；也可直接粘贴脚本 |
| 远程订阅链接导入 | 经宿主网络层 `LumeHttp` 拉取；正文是脚本则直接导入，正文是「一行一个地址」的清单则逐个拉取（上限 20 条） |
| 归属当前板块 | 按钮绑定一个 `SourceManager`，只写本板块的库，不提供跨板块入口 |
| 平台边界 | 没有图源运行时的平台（Android / Windows）按宪法只留骨架，「+」不出现 |

## 三、图源脚本文本预处理（BOM 修复）

`core/js/source_script.dart` 新增 `stripScriptBom`（剥离开头 `\uFEFF`）与
`SourceMetadata.parseHeader`（正则匹配 `// LumeSource: {...}` 头部元信息，
支持 `//` / `/* */`、`:` / `=`、`@` 前缀与 `key=value` 列表写法）。

导入链路（`core/js/source_registry.dart`）：

1. 读入脚本 → **先剥 BOM**；
2. 头部元信息正则 → 命中即用；
3. 未命中 → 退回运行时的 `LumeSource.id/name/version`（JS 契约 v2 不变）；
4. 剥 BOM 后的文本落库，`engineFor` 载入前再兜一次。

带 BOM 的合法脚本因此不再误报「脚本缺少 LumeSource 元信息」。
`assets/js/example_source.js` 补了一行头部声明作为格式示例。

## 四、证据

- `test/source_script_test.dart`：BOM 剥离（含「只剥开头」）＋头部元信息
  各写法＋带 BOM 的核心回归＋内置示例脚本声明可解析。
- `test/add_source_button_test.dart`：本地文件导入（含 BOM 剥离）、空输入拦截、
  订阅单脚本 / 清单 / 多行地址、拉取失败与非法地址、失败不触发刷新回调、
  运行时不可用无入口。
- `test/app_shell_test.dart`：五页签顺序与文案、桌面端侧栏、切页签只留当前页、
  全屏页压栈隐藏 / 出栈恢复、弹窗不影响 Dock、令牌隐藏与恢复。
- `test/widget_test.dart`（重写）：启动即导航壳、旧仪表盘文案消失、板块页标题、
  非 iOS 平台边界。
