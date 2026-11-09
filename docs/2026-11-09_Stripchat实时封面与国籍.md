# Stripchat 直播源：实时封面 + 封面国籍（2026-11-09）

源：`sources/video/stripchat.js` 1.1.1 → **1.2.0**；App 侧新增「封面角标」能力。

## 一、这次改了什么

### 1. 封面改成站方快照，真的会动

- 旧写法：`previewUrlThumbSmall + '?v=' + snapshotTimestamp`。站方这只 preview 是**静态**图，
  query 只是防缓存用的版本号，图本身不换 —— 列表看着像死了。
- 新写法：`https://img.doppiocdn.net/thumbs/<秒级时间戳>/<modelId>`，站点自己用的快照接口
  （模型页 state 里的 `snapshotUrlTemplate: https://img.doppiocdn.net/{type}/{timestamp}/{modelId}`）。
  地址里的时间戳按 10 秒一档取当前时间，配合浏览页已有的「`mediaInfo.liveCover: true` → 每 20 秒
  重取本页」，每轮都落到新地址、取到「刚刚那一帧」。
- 实测：12 个在播主播 × 3 组时间戳（当前 / 当前 / 120 秒前）= 36 个地址全部 `200 image/webp`；
  列表条目按当前时间戳构造的封面 `200 image/webp`（6~17 KB）。

### 2. 副标题带人数，角标带国籍

- 站方 `/api/front/models` 的 `viewersCount` → `公开直播 · 421 人在看`（≥1 万转「万人在看」）。
- 站方 `country`（两字母 ISO，约 27% 在播主播填了）→ 国旗 emoji + 中文名，例如 `🇹🇼 台湾`；
  没填就不加角标，不猜。
- `detail()` 的 description 同样按「国籍 · 直播间 · 人数」拼。

### 3. App 新增 `coverLabel`（封面角标）

| 位置 | 表现 |
|---|---|
| 三列网格 / 双列网格（标题外置） | 角标压封面**左下角**，半透明黑底白字，最多 84 宽、单行省略 |
| 三列网格（标题遮罩内置） | 角标放**左上角**（底部被标题遮罩占满），与右上徽章同排 |
| 单列 / 双列列表行 | 角标贴封面底部，左右各让 3 |

契约：条目顶层 `coverLabel` 或 `mediaInfo.coverLabel` 都认；空白、非字符串、超过 12 个字符
（或 24 个 UTF-16 单元）丢弃。App **不**从标题/标签里猜国旗，也不做 ISO 码推导——文本由源给。

### 4. 换图不再「闪成占位图」

封面地址每轮都变，旧实现一换地址就先 `release()` 旧位图，占位图顶上来 → 列表每 20 秒集体闪一下。
`SectionImage` 现在把上一帧挂成 `_stale` 继续显示，等新帧解码完成再归还引用（管线按引用计数保护，
不会被 LRU 淘汰）；新帧失败时也继续显示旧帧并照常重试。用例：
`test/section_image_stale_frame_test.dart`。

## 二、播放：为什么还在网页播放器

用户要求「在 App 播放器里播放」，这一条**没有**改成原生取流，原因是站方 2025 年底起给直播分片名
加了混淆（PSCH v2 / MOUFLON）。实测证据（2026-11-09，全部走真实请求 + 真浏览器对照）：

1. `https://edge-hls.doppiocdn.net/hls/<stream>/master/<stream>_auto.m3u8?playlistType=lowLatency`
   返回多码率 master，但 `#EXT-X-MOUFLON:PSCH:v2:<pkey>` 是必须的回执：不带
   `&psch=v2&pkey=<pkey>` 去取 `media-hls` 的分片列表，只会拿到 **689 字节的贴片广告 VOD**
   （`#EXT-X-MOUFLON-ADVERT` + `b-hls-XX/cpa/v2/chunk_*.m4s`，`ENDLIST`）。
2. 带上 `pkey`（master 里 11 个 PSCH token 都能用）后拿到真列表，但**分片 URI 被改名**：
   ```
   #EXT-X-MOUFLON:URI:https://media-hls.../<stream>_480p_h264_675_QHfBbHadICs+aUV1mzeGma_<ts>.mp4
   #EXTINF:2.000
   https://media-hls.doppiocdn.net/b-hls-15/media.mp4      ← 标准 URI 是占位符
   ```
   `media.mp4` 固定 404；MOUFLON 里的名字也是诱饵，直接取同样 404（`x-cache: Error from cloudfront`）。
3. 真浏览器（Chrome 155）里同一条列表，播放器请求的是 `<stream>_720p_h264_648_<16位token>_<ts>.mp4`，
   与列表里的 22 字节 token 不同 —— 映射是 mmp 播放器（`mmp.doppiocdn.com/player/mmp/v2.15.0/`）
   在客户端按 `psch` scheme 算出来的，代码是混淆过的（`_playlistDecryptHandler`、
   `mmpCorruptionScheme`、`#EXT-X-MOUFLON:FILE/EXT-REF`）。
4. 试过的旁路都不成立：VLC/ffmpeg/ExoPlayer/iPhone UA、`playlistType=standard|lowLatency|event`、
   `_HLS_msn` 分块重载、`includeParts=0`、`doppiocdn.com/.net/.org/.live` 四个域、
   `/api/front/v2/models/username/<u>/cam`（418 反爬）。
5. token → 真名的变换也试过：base64 解出 16 字节 vs 真名 12 字节，用 pkey / 播放器常量
   `Ft = 9a04f07998404286ab92e65be0885f95` / md5/sha1/sha256(pkey) 做 AES-128 ECB/CBC/CTR
   加解密、XOR、HMAC 逐个比对，全部对不上 —— 说明密钥不在客户端可见的这几个位置。

结论：现阶段第三方播放器拿不到可播分片，源保持 `kind: 'webplayer'`（App 里打开站方网页播放器），
并把这个事实写进源设置的站点说明。要真·原生，得先把 mmp 播放器那段混淆的「分片名还原」逆出来
（或等站方换协议），属于单独一项工作。

## 三、验证

- `node tools/lume-source-check.mjs sources/video/stripchat.js` → 五入口 PASS（filters/list/detail/
  chapters/content 全通，content = webplayer）。
- 分类对照：`girls` / `men` / `chinese` 首条 id 各不相同；`--filter age=ageMilf` 后首条 id 与默认不同、
  条数 20 → 22，说明筛选真的传给站点。
- 封面探活：列表条目 `cover` 全部 `200 image/webp`。
- App：`flutter test test/cover_label_test.dart test/poster_caption_test.dart` 全绿；
  `dart analyze lib/core/source lib/features/reading lib/features/video` 无告警。

## 四、限制

- 只收 `status = public` 的公开直播（`groupShow` 票价秀、私密秀不列）。
- 国籍只在站方填了 `country` 时出现（实测约 27%）。
- 直播封面每轮刷新都是新网络图，挂 20 多张卡时约 20 KB/s 量级，属正常。
- 播放仍是网页播放器：有广告、有登录引导，且不提供原生弹幕 / 手势 / 画中画。
