# HDR、杜比、字幕与画质增强

播放器设置中的「HDR 与杜比」「画质增强」「字幕偏好」提供独立开关，设置保存在视频板块自己的数据库中。开关代表播放偏好；「播放与连接」里的信息显示内核报告的格式、显示路径和未生效参数。

当前主力平台为 iOS，最低支持版本统一为 iOS 18.0。HDR 亮度、杜比视界 Profile 兼容性和 Atmos 输出需要用实际设备、片源与输出设备验收；设备具备 HDR 条件、音轨是 EC-3、系统允许空间音频，均不能单独证明 HDR 或 Atmos 已实际输出。

## 调整播放效果

| 设置 | 默认 | 生效方式 |
| --- | --- | --- |
| 启用 HDR | 开 | AVPlayer 使用原生 AVPlayerLayer；关时使用已配置 BT.709 色调映射的 SDR 纹理 |
| HDR 策略 | 自动 | 自动按清晰度选流；优先 HDR 时优先 HDR 变体；兼容 SDR 时优先 SDR 变体 |
| 优先杜比视界 | 开 | HLS 有兼容变体时优先 DV；关闭时优先其他变体，不转换单一 DV 片源 |
| 优先杜比音频 | 开 | 加载时优先 Dolby 音轨；关闭时优先普通音轨；手动选择后，其他设置不会覆盖音轨 |
| 启用画质增强 | 关 | MPV 的缩放、锐化、去色带；AVPlayer / MDK 明示当前不支持 |
| 画质预设 | 清晰（总开关默认关） | 原画停止增强；清晰轻度锐化；动漫降低锐化并提高去色带阈值 |
| 高质量缩放 | 开（受总开关控制） | MPV spline36；总开关关闭恢复 bilinear |
| 轻度锐化 | 开（受总开关控制） | MPV 清晰 0.25、动漫 0.15；关闭归零 |
| 去色带 | 开（受总开关控制） | MPV 轻量单次处理；关闭即停止 |
| 显示字幕 | 开 | 独立于 HDR、杜比和增强；字幕面板中的原有总开关 |
| 记住同剧字幕选择 | 开 | 按作品身份保存内封字幕语言、标题或关闭状态；不依赖跨集不稳定的轨道 ID |
| 保留 ASS 原始样式 | 开 | MPV libass 渲染排版与特效；关闭时改用文字字幕层统一样式 |

HDR 开关或「兼容 SDR」改变 AVPlayer 显示路径时，会重新装载并恢复进度和播放状态。快速连续设置按顺序处理。HLS 变体偏好在下一次加载媒体时应用；只有一种格式的片源保留播放入口，由显示链路处理兼容性。

MPV 的当前 Flutter 纹理路径按 SDR 输出并进行色调映射。MDK 的 HDR 输出暂无法确认，因此选流优先 SDR。开启 HDR 偏好不会把这两条路径标记成已实现 HDR 直出。

## 导入和选择字幕

播放设置 → 外挂字幕 → 选择本地文件或从 HTTP(S) 链接导入。

| 能力 | AVPlayer | MPV | MDK |
| --- | --- | --- | --- |
| 内封字幕轨选择 | 原生 media selection | 内核轨道 | 内核轨道 |
| 外挂 SRT / VTT | 文字层，支持 UTF-8 / BOM UTF-16，上限 8 MiB | 内核加载 | 内核加载 |
| 外挂 ASS / SSA | 导入失败时提示改用 MPV | libass 原始排版 / 统一文字样式 | 交由内核 |
| 字号、颜色、描边、底色、阴影、位置 | 选中外挂文字字幕后开放 | 统一文字样式完整支持 | 当前不提供完整样式控制 |
| 延迟 | 外挂文字字幕，步长 0.1 秒 | 内核 sub-delay，步长 0.1 秒 | 内核 sub-delay |

统一文字样式会关闭 ASS 特效。嵌入字体和设备上不存在的字体可能回退。偏好语言可选简中、繁中、英语等；「跟随片源」兼容原有全局语言设置。字幕关闭时，自动语言选择不会擅自打开字幕。

同剧记忆保存内封轨道的语言 / 标题偏好，外挂文件本身不会在下一集自动复用，避免字幕内容与集数不匹配。弹幕沿用现有「避让底部字幕」独立开关。AVPlayer 外挂文字字幕和 MPV 统一文字字幕属于 Flutter 叠加层，系统原生画中画不会自动携带这些文字层。

## 验证修改

```powershell
flutter analyze --no-pub --fatal-infos lib test
flutter test --no-pub --reporter expanded
```

新回归覆盖独立开关、持久化及坏值回退、HLS 的 HDR / DV 选择及回退、音视频分组保留、SRT / VTT 时间轴与重叠字幕、UTF-16 导入、通道实例 ID、HDR / SDR 切换后的进度与播放状态保留。

macOS 上准备 Flutter iOS artifacts 后，可单独类型检查原生展示逻辑：

```bash
flutter precache --ios
bash tool/check_ios_player_presentation.sh
```

现有 `Build unsigned IPA (iOS)` 工作流的完整构建会编译该插件与全部 App 代码。单独的原生 helper 类型检查脚本用于 macOS 开发环境。

真机验收使用 SDR、HDR10、HLG、不同 DV Profile 片源，以及普通双声道、Dolby Audio 和带 Atmos 元数据的音轨。分别检查色彩、亮度、音轨切换、耳机与扬声器切换、横竖屏、字幕特效、画中画、退出播放页和长时间播放时的发热 / 掉帧。屏幕截图无法独立证明 HDR 亮度效果。

## 实现依据

- [Apple：HDR 与 Dolby Vision 播放](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
- [Apple：HDR 播放条件](https://developer.apple.com/documentation/avfoundation/avplayer/eligibleforhdrplayback)
- [Apple：系统空间音频与输出路由](https://developer.apple.com/videos/play/wwdc2021/10265/)
- [MPV：渲染、色调映射与字幕选项](https://mpv.io/manual/stable/)

## AetherEngine（iOS 18 起）

播放内核菜单新增 AetherEngine，保留 AVPlayer / MPV / MDK。SPM 固定 7.53.1；FFmpeg 解封装，VideoToolbox / 软件解码，AetherPlayerView 的原生 AVPlayerLayer / AVSampleBufferDisplayLayer 呈现，避免将 HDR 画面压进 SDR Flutter 纹理。最低目标统一升至 iOS 18.0，包括自维护插件与验证脚本。

现有 HDR / 杜比视界偏好传给 HLS 选流和 Aether 原生路由。关闭 DV 时对具备兼容基础层的片源使用基础层；无兼容基础层的 Profile 5 不做错误的强制剥离。SDR 偏好关闭 Match Content、优先选择 SDR 变体；单一 HDR 片源仍由系统处理，不承诺强制 SDR 转码。普通 EAC3 JOC 音轨可走原生音频链；未开启可选 TrueHDObjectAudio / DTSXObjectAudio / 双层 FEL 构建特性。

现有控制栏负责播放、暂停、进度、音量、倍速、缩放与旋转；内核提供音轨、内封和外挂字幕、后台音频与缓冲选项。Aether 7.53.1 视频倍速最高 2x（音频最高 3x），超过时由内核限制。字幕使用原生文字/位图叠加，不提供 libass 原始特效及完整字幕样式/延迟控制；此类需求可选 MPV。画中画沿用现有页面的内核能力判定和切换行为，本次未提供 Aether 独立 PiP 通路。

「播放与连接」分别展示片源动态范围、内核报告动态范围、播放路由及音频路径。Atmos 音轨标签不表示已验证 Atmos 输出；须按上述真机清单检查设备、耳机/HDMI 接收器和片源。新增桥接回归覆盖请求头/偏好传递、轨道 ID、状态回报，以及加载途中释放不阻塞、不更新已释放通知器。

上游代码和分发条款：[AetherEngine 7.53.1](https://github.com/superuser404notfound/AetherEngine/tree/7.53.1)。构建通过 SPM 链接其运行库；发行包须保留其及依赖的许可证，参见 third_party/AetherEngine-NOTICES.md。

同批保留按钮旁倍速菜单与分组偏好面板；补回全屏设置里的画质入口，并保留片头片尾的快捷标记与同剧记忆。相关回归通过新入口操作，仍验证切内核时的进度保留、旧实例释放与独立倍速偏好。

本次验证：静态检查无问题；常规回归 2800 项及原生串行回归 10 项通过，原有 11 项跳过。macOS 完整未签名 iOS 构建通过；检查产物确认 MinimumOSVersion 为 18.0，原生 Aether 通道、视图注册、运行库和许可证均在包内。HDR／杜比实际显示与 Atmos 输出仍需真机验收。
