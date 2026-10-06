# Lume Box · Phase2 全局浅色主题一轮：现状核对 / 口径 / 落点 / 验证

> 任务口径：漫画详情页批量下载之后，做一轮全局浅色主题优化（分层 + 玻璃磨砂），
> 覆盖小说 / 漫画 / 视频 / 猫源 / 设置全部页面；只改样式、颜色、装饰 UI；
> 小说阅读页保持独立主题；图标同步提亮；完成后 `flutter analyze` + `flutter test`；
> 真机验证不阻塞开发。
>
> 本文档记录：改之前的样子与问题、新主题的口径、每个落点的位置、怎么验证的、
> 以及这一轮刻意没做的事。

---

## 一、改之前的现状（为什么要改）

- **一个色到底**：页面背景是深色渐变（`#161634 → #0B0B12 → #1D1038`），
  卡片是「半透明白 + 模糊」，视觉上底与卡几乎同色，层次靠描边硬撑；
- **白色当文字色**：全仓库 40+ 个文件里 `Colors.white` 被当作主文本、
  `LumeTheme.muted`（= `Colors.white70`）当辅助文本、`Colors.white12` 当分割线；
- **卡片逐格开模糊**：`GlassCard` 默认带 `BackdropFilter`，书架、章节列表
  这类动辄上百张卡的页面每格都在算模糊；
- **分割靠线**：多处 `Divider(color: Colors.white12)` 与白色描边。

## 二、新主题的口径（`lib/core/theme/lume_theme.dart`）

### 三层色（层次只靠色差与阴影，不靠描边）

| 层 | 色值 | 用在哪 |
|---|---|---|
| 底 | `#F7F7F9`（带 `#F9F9FB → #F5F5F8` 极浅渐变） | 页面最底层 |
| 卡 | `#FFFFFF` | 卡片、条目、面板 |
| 卡内嵌 | `#FBFBFC` | 输入框、芯片、内嵌块 |

### 文字三档 + 一个点缀色

| 角色 | 色值 | 说明 |
|---|---|---|
| 主文本 | `#1A1A1A` | 标题、条目标题 |
| 辅助说明 | `#707076` | 副标题、说明、`LumeTheme.muted` 指向它 |
| 占位提示 | `#99999F` | 输入提示、空态补充 |
| 点缀（品牌紫） | `#7C5CFF` | 按钮、选中态、下划线、可交互图标 |

语义色在浅底上换成可读的深色版本：成功 `#2E7D4F` / 危险 `#C0392B` /
警告 `#B26A00` / 信息 `#2F6FB5`（原先的 `#81C784` / `#FF8A80` / `#FFD180`
在白底上对比度不够）。

### 玻璃只给「浮在内容之上」的条

`GlassPanel`（半透明白 `#B8FFFFFF` + `BackdropFilter` 模糊）用于顶部栏、
底部 Dock、阅读器工具栏；**卡片不再默认开模糊**——铺在浅色底上的卡片开模糊
等于白付代价，那种场景要的是白底 + 阴影分层（`GlassCard` 新实现，
只在「压在封面 / 图片之上」时传 `frosted: true`）。

### 阴影两档（都很淡）

- `cardShadow`：`0x0D1A1A1A` / blur 16 / offset (0,4)——「轻微浮起」；
- `floatShadow`：两段叠加——底部 Dock 这种悬在内容之上的元素。

### 分割

`divider = 0x12000000`、`hairline = 0x14000000`、`fill = 0x0A000000`；
能靠间距分层就不用线。

## 三、落点

### 基础设施

| 文件 | 改了什么 |
|---|---|
| `lib/core/theme/lume_theme.dart` | 整套浅色主题重写：三级底色、三档文字、语义色、阴影、`ThemeData`（AppBar / 对话框 / 底部面板 / 输入框 / 芯片 / 分段按钮 / 页签条 / 开关 / 进度条 / 弹出菜单 / SnackBar） |
| `lib/shared/widgets/glass_card.dart` | `GlassCard` 改为「白底 + 极浅描边 + 柔和阴影」（可选磨砂）；新增 `GlassPanel`（磨砂层）、`GlassAppBar`（玻璃顶栏）、`GlassScaffold.behindBar`（内容穿栏）+ `barHeight` / `barInset`（让出顶栏高度） |
| `lib/features/shell/app_shell.dart` | 底部 Dock 改浅色玻璃（半透明白 + 模糊 + 柔和阴影 + 品牌紫选中底座）；桌面侧栏改浅色 |
| `lib/features/shell/board_tabs.dart` | 页签条改为「顶栏的一部分」（`BoardTabHeader`，46pt），`BoardTabs` 只渲染内容区，内容从玻璃条下穿过 |

### 页面扫色（40 个文件）

映射规则（一次性批量替换 + 逐文件复核）：

| 旧 | 新 |
|---|---|
| `Colors.white`（文字 / 图标） | `LumeTheme.textPrimary` |
| `Colors.white70` | `LumeTheme.textSecondary` |
| `Colors.white54` | `LumeTheme.textHint` |
| `Colors.white.withValues(alpha: 0.0X)`（填充） | `LumeTheme.fill` / `fillStrong` |
| `Colors.white12` / `white24`（线 / 底座） | `LumeTheme.divider` / `fillStrong` |
| `Color(0xFF12121E)` / `Color(0xFF1B1B2A)`（面板底） | `LumeTheme.surface` |
| `#FF8A80` / `#81C784` / `#80D8FF` | `LumeTheme.danger` / `success` / `info` |

**刻意保留深色的地方**（它们压在画面 / 封面上，深色才是对的）：
视频手势提示浮层、亮度遮罩、播放器 HUD、弹幕图层、
海报卡封面上的角标与底部渐变、抽屉遮罩。

### 详情页「大图背景」

漫画 / 小说详情页原本是「封面放大模糊 + 深色压图 + 白字」；浅色主题下改为
**浅色晕染**：封面以 0.34 不透明度铺底 + 白到透明的渐变，标题与元信息用深色。
两页的顶部栏换 `GlassAppBar`，内容穿栏（列表从磨砂条下滚过）。

### 漫画阅读器（阅读页的边界）

- **底色不动**：仍是阅读设置里的纯黑 / 深灰 / 护眼绿 / 纯白；
- **工具栏与面板改浅**（顶栏玻璃 + 深色图标、底部面板与目录 / 书签 / 长按面板
  改白底深字），压在黑底上也读得清。

### 小说阅读器（不动）

`novel_reader_page` / `novel_page_painter` / `novel_turn_view` / `novel_speech_panel`
/ `novel_bookmarks` / `novel_typesetting` / `novel_pagination` 七个文件
**零 `LumeTheme` 引用、零共享玻璃组件引用**（已核验），主题独立性由结构保证。

### 图标

`tool/app_icon_test.dart` 程序化生成亮色图标 → `assets/icon/app_icon_1024.png`
→ `flutter_launcher_icons` 出 iOS 全套（无 Alpha）。

## 四、验证

- `flutter analyze`：零问题；
- `flutter test`：**917 例全绿**（含本轮新增的批量下载 10 例）；
- **界面快照**：`tool/ui_snapshot_test.dart` 把关键页面渲染成 PNG
  （`build/ui_snapshot/*.png`），人工过一遍版面：导航壳 / 漫画书架（含滚动后
  的穿栏效果）/ 漫画详情（含下载面板与结果卡）/ 漫画阅读器工具栏 /
  小说阅读页 / 视频板块 / 猫源 / 设置页（含滚动后）。
  快照工具做了两件让截图贴近真机的事：加载真字体（Roboto + MaterialIcons +
  中文字形，否则测试环境全是方块）、注入平台可用性与替身图源。
- 真机验证：按任务口径不阻塞开发，留待用户侧反馈。

## 五、这一轮刻意没做

- **不做暗色模式**：需求是「全局浅色」，没有要求跟随系统 / 可切换；
  `ThemeMode` 与暗色配色未引入（小说阅读页的暗色主题是它自己的，不受影响）。
- **不动业务**：沙箱、图源、播放器、数据库、缓存目录、阅读进度一律未改；
  本轮 63 个文件的改动全部在颜色 / 装饰 / 栏层次上。
- **不追加大面积动效**：只保留既有的 180ms 过渡，没有新增动画。
- 角色卡片横滑、探索页多维筛选、分享 / 保存到相册：仍在延后待办里（见
  `deferred-todo.md` 与本轮之前的漫画计划文档）。
