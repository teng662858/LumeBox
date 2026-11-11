# 本地补丁说明（third_party/video_player_avfoundation）

## 2026-11-12 · 有缓冲但系统播放器停止推进

诊断包（App 1.0.317）中，同一 HLS 两次在约 21 秒出首帧后仍未推进，触发
`buffered-startup-stalled`，MPV 接管后约一秒开始推进。日志能证明系统播放器停滞，
但不能单独确定首次初始化较慢的原因，也不能断言哪一笔历史提交首次引入问题。

原生恢复存在明确缺口：关闭 `automaticallyWaitsToMinimizeStalling` 后，AVPlayer
缓冲耗尽会把 rate 归零并暂停。上游插件只在 `playbackLikelyToKeepUp` 改变时重发
播放；少量可播数据到达时该值可能仍为 false，`loadedTimeRanges` 原先只通知 UI。
依据：[Apple 自动等待说明](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling)。

现在缓冲更新后在主线程检查仍然有效的播放意图、初始化状态和未完成的 seek。
仅当当前位置至少有 250ms 连续数据、rate 为零且系统自动等待关闭时，使用
`playImmediatelyAtRate:` 恢复当前 AVPlayer，并保留倍速与原生速率能力限制。
用户暂停、seek 未结束、已释放或失败的播放器、远处孤立缓冲均不自动恢复。
保留原有内核回退机制作为最后保护，不扩大缓存、不缩短回退时间。

验证：`tool/check_ios_player_presentation.sh` 编译真实播放器和 helper（iOS 18），
并运行 `tool/avplayer_buffer_resume_smoke.m` 的 AVFoundation 替身行为检查。
该检查验证真实恢复函数，不等同于设备上的网络 HLS 验收；同一媒体在用户设备上的
启动速度、缓冲状态和系统画中画仍需新版真机复验。

本目录是 **`video_player_avfoundation` 2.12.0 的本地 vendored 副本**（来自 pub
镜像 `pub.flutter-io.cn`，上游仓库见 `pubspec.yaml` 的 `repository` 字段），
项目 `pubspec.yaml` 以 `dependency_overrides` 的**路径覆盖**引用它。
保留 vendored 副本的唯一原因是携带下面这一处补丁。

## 补丁 1 · 把播放缓冲参数应用到 AVPlayer

**新增文件**（都在
`darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/`，
会自动被 podspec 的 `source_files` 与 SPM 的 target 收进去，不需要改构建配置）：

- `FVPLumeBuffering.h` / `FVPLumeBuffering.m`：读取宿主写进 `UserDefaults` 的
  缓冲参数，应用到播放器。

**改动**：`darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/FVPVideoPlayer.m`

```objc
  _player = [avFactory playerWithPlayerItem:item];
  // Lume Box 本地补丁：应用宿主写入的缓冲参数（未配置时此调用什么都不做）。
  [FVPLumeBuffering applyToPlayer:_player];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
```

（另加一行 `#import "FVPLumeBuffering.h"`。）

### 为什么必须打这个补丁

真机反馈：**同一个地址，电脑上立刻能播，iPhone 上拿到播放地址之后要等 1–2 分钟
才出画面**。排查结论里 A（请求头在起播点被丢掉）已修，剩下的 B 是 AVPlayer 的
缓冲启动参数：

- `AVPlayerItem.preferredForwardBufferDuration`
- `AVPlayer.automaticallyWaitsToMinimizeStalling`

这两项**只存在于原生对象上**：`video_player` 的 `VideoPlayerOptions` 只有
`mixWithOthers` / `allowBackgroundPlayback`（已核对 2.14.1 源码），而
`video_player_avfoundation` 也不把 AVPlayer / AVPlayerItem 暴露给宿主——
它的实例（`FVPVideoPlayer.player`）只存在于插件内部，宿主拿不到引用。

因此只有**在插件内部、创建播放器的那一刻**才能把参数装上。宿主侧
（`ios/Runner/BufferingController.swift`）负责把参数写进 `UserDefaults`，
本补丁负责在创建时读取并应用——宿主没写过时（`lumebox.buffering.applied`
不存在）**完全不碰**，行为与上游一致。

### 升级注意

1. 上游升级时**不要直接 `flutter pub upgrade`**：`pubspec.yaml` 里的路径覆盖会
   一直指向本目录；
2. 要跟上游时，把新版本重新复制进来、把上面两处改动（1 行 import + 1 行调用 +
   2 个新文件）再打一遍，并同步改 `pubspec.yaml` 里的版本注释；
3. 补丁**只加不改**（唯一改动的两行是新增 import 与新增调用），因此回退方式很
   简单：删掉 `FVPLumeBuffering.*` 与那两行即可。

### 验证

- Dart 侧契约：`test/buffering_channel_test.dart`（通道名 / 方法名 / 参数形状）；
- iOS 侧编译与行为：CI 的 `flutter build ipa`（编译期）+ 真机起播对照（行为）。

## 与 upstream 的差异清单（便于核对）

| 文件 | 差异 |
|---|---|
| `FVPVideoPlayer.m` | +1 import、+1 调用 |
| `FVPLumeBuffering.h` / `.m` | 新增 |
| `pubspec.yaml` | `version: 2.12.0` 保持不变（路径覆盖在项目根 pubspec） |


## 2026-10-14 · 原生下载统计与预加载接手

`VideoPlayerPlugin.swift` 增加 `lumebox/av_network` 通道：根据对应 playerId 的
AVPlayerItem accessLog 累计传输字节，由 Dart 按采样间隔计算下载速度；未提供
accessLog 时返回 null，不把播放码率伪装成下载速度。`applyBuffering` 更新已存在
的播放器前向缓冲策略，用于接手下一集预加载后的正常播放。


## 2026-10-29 · HDR 原生显示与字幕轨道

宿主 `AvPlayer` 根据 HDR 偏好选择上游现有的 `VideoViewType.platformView`（AVPlayerLayer）或 SDR 纹理；切换时恢复播放进度。插件新增 `lumebox/av_presentation` 通道，根据 playerId 操作既有播放器，读取片源动态范围 / 音轨 / 输出设备 / 空间音频条件、选择内封字幕，并按偏好选择杜比或普通音轨。状态信息不把播放条件等同于实际 HDR / Atmos 输出。

外挂 SRT / VTT 在宿主的文字字幕层呈现；ASS 原样式由 MPV libass 提供。详细能力及验证方式见 [播放器展示说明](../../docs/player-presentation.md)。原生 helper 的 Swift 类型检查由 `tool/check_ios_player_presentation.sh` 完成；实际输出需真机验证。


### iOS 最低目标统一为 18

当前最低支持 iOS 18.0。App、自维护插件的 Pod / Swift Package 声明与原生检查脚本统一为 iOS 18；不再维护 iOS 13–17。`check_ios_player_presentation.sh` 在 IPA 编译前按 iOS 18 检查。

### 2026-11-11：主画面与画中画共享视频层

`FVPNativeVideoView` 以弱引用登记每个 AVPlayer 的可见 AVPlayerLayer。`lumebox/av_pip` 准备通知将该层交给宿主 PiP；宿主只借用，不移动该层，也不在清理画中画时清空其 player。纹理播放器没有可见 AVPlayerLayer，改用已有的 AVPlayerItemVideoOutput 解码帧路径，不再为画中画另建隐藏的 AVPlayerLayer。带弹幕的画中画仍使用解码帧。

`lumebox/av_network.readVideoState` 返回可见原生层是否存在、已挂载和准备好显示，供 iOS 播放回归检查使用。原生检查脚本编译实际 Objective-C 登记实现，并检查 Swift 桥接和生产 PiP 代码；集成用例同时覆盖画中画准备、弹幕切换、清理与 SDR 纹理路径。实际 HDR 输出和真机画中画仍需设备验收。

## 补丁 2 · seek 容差（拖动快进不卡）

**改动**：`darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/FVPVideoPlayer.m` 的 `seekTo:completion:`

```objc
  CMTime tolerance = position == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
  // Lume Box 本地补丁：宿主写入的 seek 容差（拖动预览用大容差跳关键帧）。
  NSNumber *toleranceMs = [[NSUserDefaults standardUserDefaults]
      objectForKey:@"lumebox.seek.toleranceMs"];
  if (toleranceMs != nil && toleranceMs.doubleValue > 0) {
    CMTime requested = CMTimeMakeWithSeconds(toleranceMs.doubleValue / 1000.0, 1000);
    if (CMTimeCompare(requested, tolerance) > 0) tolerance = requested;
  }
```

### 为什么

上游用的是 **精确 seek**（`tolerance = kCMTimeZero`）：AVPlayer 必须从上一个关键帧
解码到目标帧才算完成。长 GOP 的剧集 + 网络流下，这一步就是几秒到十几秒，用户感知
就是「快进要等很久」。宿主在拖动时写入 400ms 容差（`lumebox.seek.toleranceMs`），
AVPlayer 直接落到关键帧，松手时把容差写回 0 恢复精确 seek。

未写入该键时行为与上游完全一致。

**哨兵 -1**：写 `-1` 表示「吸附到前一个关键帧」——`toleranceBefore =
kCMTimePositiveInfinity`、`toleranceAfter = kCMTimeZero`（永远不越过目标时间）。
这是拖动预览的最快档，由播放器设置里的实验开关「快进吸附关键帧」打开；
松手时宿主写回 0 恢复精确 seek。
