# Lume Box · Phase3 播放器增强与 iOS 画中画 PiP：已批准基线 + 延后待办

验收口径来自任务书「Phase3 任务：播放器增强与iOS画中画PiP实现」的 4 条要求。
本文档记录已批准基线与本轮确认延后的事项（含 Mac 真机验证清单）。

## 一、已批准基线（4 模块）

| 验收项（任务书口径） | 落点 | 验证 |
|---|---|---|
| 1. 播放器设置页：运行时切换内核 / 倍速 / 字幕基础配置 | `player_settings.dart`（模型：`PlayerKernel` avplayer·mpv·mdk、`SubtitleSize`、`PlayerSettings` 含归一回退）、`video_player_settings.dart`（落在「自定义视频」板块独占的 `sections/video/reading.db`，与其他板块分库分文件）、`player_settings_page.dart`（内核行 + 倍速六档 0.5–2.0 + 字幕开关与字号） | `test/player_settings_test.dart` 7 例（含真实 sqlite：保存读回 / 脏值回退 / 板块隔离）、`test/player_settings_page_test.dart` 5 例 |
| 1′. 运行时不换内核**真实生效** | `abstract_player.dart` 新增 `applySettings`；`av_player.dart` 倍速真实生效（`setPlaybackSpeed`，加载后补挂）；`video_page.dart` 切换内核 = 拆旧 → 建新 → 重载媒体 → 恢复位置与播放状态 → 落库 | `test/video_page_test.dart`「启动：按本板块设置创建内核并立即应用设置」「运行时切换内核：拆旧建新，媒体与位置接回，设置落库」「倍速改动即时生效并落库」 |
| 2. iOS PiP：AVPlayer 原生 / MPV·MDK 桥接 | **原生侧未落地（见延后待办 2）**；Dart 侧全部就绪：`pip_channel.dart` 固定 `lumebox/pip`（isSupported/start/stop）与 `lumebox/pip/events`（entered/exited/restored/failed）契约，原生未接入时如实降级为不支持 | `test/pip_channel_test.dart` 5 例（契约往返、事件解码、降级、模拟原生事件端到端） |
| 3. 状态生命周期：进入 / 退出事件回调 + 资源边界检查 | `pip.dart`：`PipState`（unavailable/idle/entering/active/exiting）、`PipSession` 状态机、事件回调、边界检查（不支持 / 已销毁 / 媒体未就绪 / 切换中 / 已开启各自被拒并可读）、失败收敛（超时、原生抛错、原生 failed 事件一律回可重试状态，不向页面抛异常）、`dispose` 先退 PiP 再释放 | `test/pip_session_test.dart` 10 例；`test/video_page_test.dart`「画中画：未加载媒体时进入被拒，加载后全链路可用」「退出页面：先退画中画、再释放播放器、最后关库」 |
| 4. Android / Windows 仅 UI 骨架占位 | `video_page.dart`：平台目录无可用内核时渲染骨架占位（保留原骨架文案 + 「播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位」），不打开板块库、不建播放器、不做 PiP | `test/video_page_test.dart`「非 iOS（平台目录）：渲染 UI 骨架占位，不接线播放与画中画」 |

### 如实记录的两条边界事实（不得当作已完成）

1. **现有 AVPlayer 内核无 PiP 落点**：内核由 `video_player` 插件驱动（纹理渲染），
   插件源码（`video_player_avfoundation` 2.12.0）全文检索 `pictureinpicture` 0 命中，
   不暴露 `AVPlayer` / `AVPlayerLayer`。系统 PiP 需要自持 AVPlayerLayer 或
   `AVSampleBufferDisplayLayer` 的内容源。
2. **MPV / MDK 内核尚未接入**：设置页如实列出三套内核，仅 AVPlayer 可用（iOS），
   另两套标注「内核尚未接入」并置灰不可选——不假装可切换。

本轮文件清单：`lib/core/player/player_settings.dart`（119）、`pip.dart`（353）、
`pip_channel.dart`（72）、`lib/features/video/video_player_settings.dart`（47）、
`player_settings_page.dart`（224）、`video_page.dart`（522，重写接线）；
`abstract_player.dart` / `av_player.dart` / `player_factory.dart` 修改；
5 个测试文件新增 34 例。

## 二、延后待办

### 待办 1 · 字幕样式生效（本轮确认延后）

- **现状**：字幕开关与字号已存储、并随 `applySettings` 传给内核；AVPlayer 内核当前
  不消费（`video_player` 只按系统样式渲染自带字幕、不暴露样式接口），代码里如实注释。
- **落点**：需要自研字幕层（自绘图层的字幕渲染）或随内核替换一并解决。
- **再次实现时**：`PlayerSettings.subtitleSize.scale` 已预留相对基准字号；页面侧无需改动。

### 待办 2 · iOS 原生 PiP 接入（落地方式待选，需 Mac 构建与真机验证）

- **现状**：Dart 侧会话 / 生命周期 / 边界检查 / 通道契约全部就绪并由测试固定；
  原生（Swift）未写——写不能编译、不能验证的占位不符合纪律。
- **落地方式（三选一，待确认）**：
  a. 自研 AVPlayer 内核（Swift：AVPlayerLayer + `AVPictureInPictureController`，
     播放与画中画一体）——路线最正，工作量最大；
  b. 引入支持 PiP 的播放内核依赖（需授权新增依赖，先给候选与影响面）；
  c. 维持现状，等 iOS 侧条件具备再接。
- **配套改动**：`ios/Runner/Info.plist` 需加后台模式
  `Audio, AirPlay, and Picture in Picture`；`AVAudioSession` 类别按画中画要求配置。

### 待办 3 · MPV / MDK 内核接入

- 任务书第 1、2 条的完整达成依赖它（含 `AVSampleBufferDisplayLayer` 桥接）。
- 建议单独立项：原生库体积、依赖授权、Mac 验证。

### 待办 4 · Mac 真机验证清单（本轮所有需要 Mac / 真机的验证项）

本机（Windows）只验证到 Dart 链路与契约打桩，以下必须真机跑一遍：

| # | 验证项 | 为什么必须真机 | 落点 |
|---|---|---|---|
| 1 | iOS 构建通过（`flutter build ios`，含 xcodebuild 链接） | 本机无 Xcode，只过了 `flutter analyze` | 本轮全部改动 |
| 2 | 视频板块真实播放链路：加载网络 / 本地媒体、播放 / 暂停 / 停止 / 进度拖动 | 本机用替身播放器验证接线，真实解码在 iOS | `video_page.dart`、`av_player.dart` |
| 3 | 倍速真机生效（真实 AVPlayer 的 `setPlaybackSpeed`） | 本机只验证到「设置 → 内核」的调用链 | `av_player.dart` |
| 4 | 设置持久化真机落点：`sections/video/reading.db` 在 iOS 沙盒中的创建、重开与隔离 | path_provider 真实目录行为 | `video_player_settings.dart` |
| 5 | 画中画契约真机一致：`isSupported` / `start` / `stop` 与四类事件 | 本机用方法通道打桩验证契约 | `pip_channel.dart` |
| 6 | 画中画真机行为：进入 / 退出 / 用户返回（restored）、锁屏与前后台切换 | 系统 PiP 行为无法在本机验证 | `pip.dart` 状态机 |
| 7 | 后台模式与 AVAudioSession 配置（待办 2 一并做） | 原生 PiP 的硬性要求 | `ios/Runner/Info.plist` |
| 8 | 退出页面时的释放顺序（先退 PiP 再释放播放器）在真机上的表现 | 本机是替身断言顺序，真机涉及系统资源 | `video_page.dart` `dispose` |

> 既有的跨轮 Mac 待验证项（Phase1 真实沙箱跑 JS 图源、Phase2 系统相册保存等）
> 记录在各自的板块文档里，与本清单互不替代。

## 三、验证状态

`flutter analyze` 零问题；全量 225 个测试通过（基线 191 + 本轮 34）。
无新增依赖、无 WebView、Phase1 沙箱 / 图源 / 阅读底座一行未改。
