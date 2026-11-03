# 2026-11-03 明文 http 源打通（iOS ATS）+ INSAV 换域自愈

真机反馈：三个视频源同时打不开——直播盒子、火力视频、INSAV。三张截图对应三种不同的失败，
根因只有两类：**iOS ATS 拒发明文请求** 与 **INSAV 接口域轮换**。

## 一、三个现象与根因

| 源 | 真机报错 | 根因 |
|---|---|---|
| 直播盒子 | `接口打不开：/mf/json.txt (PlatformException(transport_security … code: -1022 …))` | 整站只有明文 http（`http://api.hclyz.com:81`），URLSession 被 ATS 拒发 |
| 火力视频 | `首页板块都没取到：接口主机可能换了…` | 同上：数据在两台明文 IP 主机（`http://81.70.213.11`、`http://107.148.42.248:83`），`home()` 吞掉单板块错误后只剩这句 |
| INSAV | `接口打不开：HTTP 405 (video/indexLists)` | 接口域轮换，旧域只剩跳转页：GET 得到 1.8 KB 的 Loading 页，POST 一律 405 |

关键区分：**站没挂，是客户端那一层被拦住**。同一时刻在桌面上直接用 curl 请求这三个站，
列表/详情/直播流全部 200（`/mf/json.txt` 19 KB、`you_new_play/getList` 正常返 JSON、
直播 flv 200 `video/x-flv`）。

## 二、App：ATS 拒绝后的第二条通道

ATS 只约束 URLSession / WebKit，`dart:io` 自己开 socket，完全不受影响。所以不是加一堆
`NSExceptionDomains`（域名换了就失效、IP 主机还要逐条例外），而是**认准失败码再换通道**：

- `lib/core/net/ats_fallback.dart`（新增）：`sendWithoutAts(request)` 用
  `IOClient(HttpClient())` 重发同一请求（方法、头、体、跟随跳转、超时、读取上限全沿用）。
- `lib/core/net/ios_image_network.dart`：捕获 `PlatformException` 且
  `code == 'transport_security'` 时改走上面那条通道；其它失败（`network`、`tls_handshake`、
  `certificate`）行为完全不变，不会被兜底掩盖。

为什么不在 `Info.plist` 加例外：`lao4j` 的数据主机是**裸 IP**，站点换 IP 就得再发一次包；
而跳转页/镜像域是变量。兜底放在网络层一次就覆盖所有明文源（含之后新加的）。

## 三、源：INSAV 换域自愈（1.1.0 → 1.2.0）

旧域 → 跳转页 → 站方跳转服务 → 新域，全链路（本机实测）：

```
GET  https://dcuj77.com/                      200  1799 B  ← Loading 页，内含 window.atob("aHR0cHM6Ly9pbnNhd3MucGdwcTMzLmNvbQ==")
GET  https://insaws.pgpq33.com/?u=<b64 旧域>&p=<b64 路径>   302 → https://fnay47.com
POST https://fnay47.com/api/video/indexLists  200  12.7 KB（AES 解开 total=60）
```

源里的做法（`sources/video/insav.js`）：

1. `postOnce(host, …)` 单台主机请求，`405`（或 403＋跳转页特征）判为「只剩跳转页」；
2. 判为跳转页时 `discoverFrom(host)`：GET 旧域 → 正则取 `window.atob("…")` →
   解 base64 得跳转服务地址 → 拼 `?u=&p=` → 读 `reply.url` 的 origin（App 的 HTTP 桥跟完 302）；
3. 成功域写 `host.json`（`+12h` 有效，换源设置里的域名即失效重探），后续请求直接用；
4. 失败时报具体主机与状态码，不再笼统说「接口可能变了」。

同时修封面：`yik.yanyunhome.com` 把整张图包成 `data:image/jpeg;base64,…` 纯文本下发
（响应头还写着 `image/jpeg`），源里给条目挂 `x-lume-image-encoding: data-uri`；
App 侧 `image_bytes_decoder.dart` 新增 `data-uri` 解码分支（明文图原样放行）。

## 四、验证

```text
node tools/lume-source-check.mjs sources/video/insav.js
  → PASS：home/list/detail/chapters/content 全 ok，封面 URL 200
  另外把镜像首项换成已死的 dcuj77.com 复跑：
  405(dcuj77) → GET 跳转页 → insaws.pgpq33.com 302 → fnay47.com 200 → 后续全部复用新域（home 2.3s）
node tools/lume-source-check.mjs sources/video/livebox.js  → PASS（直播流 200 video/x-flv）
node tools/lume-source-check.mjs sources/video/lao4j.js    → PASS（两台 IP 主机 200）
flutter test test/ats_fallback_test.dart test/image_data_uri_encoding_test.dart  → 7 项全过
flutter test test/image_bytes_decoder_test.dart test/image_data_uri_test.dart \
             test/network_queue_test.dart test/source_http_routing_test.dart \
             test/image_verified_session_test.dart  → 47 项全过
dart analyze（改动文件）→ No issues found
```

两线路（源仓库 `main`）：

- `raw.githubusercontent.com/teng662858/LumeBox-Sources/main/video/INSAV视频.js`
  → 200，19302 B，sha256 `eb45c00f…9dae`，`version=1.2.0`
- `cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/video/INSAV视频.js`
  → 200，19302 B，sha256 `eb45c00f…9dae`，`version=1.2.0`

## 五、限制

- 兜底只解决「系统不让发」，不解决线路本身被拦：http 站点在运营商劫持/DNS 污染时依旧打不开。
- 直播盒子的 flv 是 `wsSecret/wsTime` 时效签名，播放前必须重新拉列表（源里已按此实现）。
- 火力视频仍要登录才能播（`m=play` 匿名返回「请登录后再操作！」），播放在内嵌网页里完成。
- INSAV 原生播放仍要用户自己在源设置里粘 token（登录强制图形验证码）。
- ATS 兜底是**客户端改动**：需要重新打包安装才生效，旧 IPA 不会变。
