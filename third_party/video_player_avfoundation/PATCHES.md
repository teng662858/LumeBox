# 本地补丁说明（third_party/video_player_avfoundation）

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
