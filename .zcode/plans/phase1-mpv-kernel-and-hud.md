# Lume Box · Phase1 MPV 内核完整适配 + 播放器 HUD

验收口径来自任务书「Phase1：完成 MPV 播放器完整适配 AbstractPlayer 抽象层，
实现 HUD 参数展示」的 6 条约束。只动播放器相关代码：导航、图源、数据库、缓存
一行未改。

## 一、内核落点

| 层 | 文件 | 职责 |
|---|---|---|
| 抽象层 | `lib/core/player/abstract_player.dart` | 新增 `ValueListenable<PlayerStats> stats`：HUD 参数是抽象层的一部分，各内核自己填 |
| HUD 模型 | `lib/core/player/player_stats.dart`（新增） | 编码 / 码率 / 帧率 / 缓冲状态 / 分辨率 + `chips`（固定顺序、缺项自动省略） |
| AVPlayer 内核 | `lib/core/player/av_player.dart` | 用 video_player 真拿得到的项填（分辨率、前方已缓冲时长、缓冲中）；编码 / 帧率 / 码率它拿不到 → 留空 |
| MPV 引擎端口 | `lib/core/player/mpv_engine.dart`（新增） | `MpvEngine` / `MpvMediaRequest` / `MpvEngineSnapshot`：把 libmpv 挡在端口后面，`MpvPlayer` 不 import 任何 mpv 类型 |
| MPV 真实绑定 | `lib/core/player/media_kit_mpv_engine.dart`（新增） | **media_kit（内核即 libmpv）**：订阅 media_kit 的流拼装快照；HUD 原始字段取自 libmpv 的轨道与视频参数（`codec` / `demux-bitrate`（bps→kbps）/ `demux-fps` / `video-params.w·h` / `buffer` 流）；显式关掉它自带的控制栏（`NoVideoControls`） |
| MPV 内核 | `lib/core/player/mpv_player.dart`（新增） | `MpvPlayer implements AbstractPlayer`：全量实现 load / play / pause / seek / stop / applySettings / buildView / dispose / snapshot / stats |
| 工厂 | `lib/core/player/player_factory.dart` | iOS：AVPlayer 与 **MPV** 均可用；**MDK 只预留接口**（不可用并给出原因）；`create` 按内核分派 |
| 上层 HUD | `lib/features/video/player_hud.dart`（新增）+ `video_page.dart` | HUD 叠加在画面左下角，只吃 `PlayerStats` |

初始化：`MediaKit.ensureInitialized()` 放在 `MediaKitMpvEngine` 构造里（幂等），
因此 `main` 与上层都不需要知道播放内核的初始化细节。

## 二、逐条对齐任务书约束

1. **完整实现 AbstractPlayer**：MpvPlayer 实现全部抽象成员；`test/mpv_player_test.dart`
   逐个方法验证（含 stop 后回到起点、dispose 后调用安全）。
2. **HUD 由内核内部实现**：编码 / 码率 / 帧率 / 缓冲 / 分辨率全部在 MPV 引擎层从
   libmpv 取；上层只渲染 `PlayerStats.chips`，不认识任何 mpv API（`player_hud.dart`
   只 import `player_stats.dart`）。
3. **设置页列表**：三套内核本来就全列；MPV 现在按平台目录变为**可选**，
   AVPlayer 保留，MDK 标注「只预留接口（Phase1 未实现）」并置灰。
4. **换内核上层零改动**：`video_page.dart` 只认 `AbstractPlayer`；用例
   「HUD：显示当前内核给出的参数，换内核不改上层 UI」在页面级证明——切到 MPV 后
   HUD 直接显示 MPV 的参数（HEVC / 1920×1080 / 30FPS / 1.8Mbps / 缓冲），
   旧内核参数不残留。
5. **只改播放器相关代码**：改动集中在 `lib/core/player/`、`lib/features/video/`
   与对应测试；`pubspec.yaml` 新增 media_kit 三件套（播放器依赖）。
6. **测试与交付**：`flutter analyze` 零告警；新增 21 例；全量 393 例通过；
   随后 commit + push 触发未签名 IPA 构建（**含 libmpv 链接**——这是本轮唯一
   无法在本机验证的一环，见下）。

## 三、如实记录的边界与待办

- **依赖与体积**：MPV 的真实运行时是 **libmpv**，由 `media_kit`（Dart API）+
  `media_kit_video`（渲染）+ `media_kit_libs_ios_video`（iOS 预编译 xcframework，
  pod install 时从 media-kit 官方 release 下载并校验 sha256）提供。
  IPA 体积会明显变大（libmpv + ffmpeg），属于 MPV 内核的固有代价。
- **平台边界不变**：Android / Windows 仍是骨架（只随 iOS 打包 libmpv），
  目录对它们如实回答「仅 iOS 提供」。
- **仍待自研字幕层**：字幕**开关**在 MPV 上真实生效（libmpv 轨道选择）；
  字幕**字号** MPV 侧可用 `sub-font-size` 落地，但需要真机核对观感，
  与 AVPlayer 的字幕样式一起留在 Phase3 待办里。
- **本机验证边界**：Windows 上只能验证到「AbstractPlayer 契约 + HUD 组装 + 页面
  复用」（替身引擎），libmpv 的装载、iOS 纹理渲染、真实参数采集必须在真机确认；
  iOS 构建链接由 CI 的 IPA 构建验证。
- **PiP**：仍是既有延后项（`AbstractPipController` 契约已就绪）；MPV 的画中画需
  `AVSampleBufferDisplayLayer` 桥接，不在本轮范围。
