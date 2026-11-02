# 2026-11-02 LXXLXX 与 hxc：一个源站真挂了，一个接口被网络拦

两个源报的错不一样，结论也不一样——先分清楚「站点挂了」和「脚本/网络的问题」，别乱改解析。

## 一、LXXLXX：站方源站全球挂（脚本没坏）

### 现象

App 首页报：

```
站点源站当前不可达（4.5 秒内没有响应）；源站可能正在换域名/宕机，稍后重试
```

### 排查

| 目标 | 结果 |
|---|---|
| `zhs.lxxxxlxxx.com/new/` | 连接超时 |
| `zhs.lxxlxx.com` / `www.lxxlxx.com` / `hk.lxxlxx.com` / `m.lxxlxx.com` | 连接超时 |
| `zhx.lxxlxx.com` / `zhy.lxxlxx.com` | 瞬间回 **301 → https://zhs.lxxxxlxxx.com** |
| 第三方代理取 `lxxlxx.com`、`lxxxxlxxx.com` | 一律 **522**（Cloudflare 连不回源站） |
| DNS（DoH） | `lxxlxx.com` → 172.67.142.224 / 104.21.46.219（CF 正常解析） |

结论：域名、DNS、证书都在，**源站（CF 后面的机器）挂了**，跟脚本没关系。
站方自己的 zhx/zhy 也还指着那台挂掉的新域，说明它们也没把源站拉起来。

### 改了什么（1.1.0）

站点挂的时候，唯一能做的是「别让用户干等、别把话说错」：

- **镜像自动换台**：以前只按 `config.domain || defaultBase` 打一台，镜像表形同虚设。现在
  `hosts()` 把「用户手选 → 当前 → 默认 → mirrors」去重排好，`get()` 每次请求最多试 **2 台**，
  总预算 **8.5 秒**（单台软超时 4.5s 递减），换到能开的那台就记住（`this.base`）。
- **报错说人话**：把两台失败原因拼在一起（`4500ms 内没有响应（…）；连不上（…）`），
  并按是不是 52x 给出不同判断——52x 说「站方源站挂了」，纯超时说「镜像全没响应，可能宕机或换域」。
- **镜像补到 4 台**：`zhs.lxxxxlxxx.com` / `zhs.lxxlxx.com` / `www.lxxlxx.com` / `hk.lxxlxx.com`。
- **加「打开站点」按钮**：指向站方 301 的目标 `https://zhs.lxxxxlxxx.com/`，源站恢复后一键进站。
- 60 秒「本站不可达」退避保留：期间点重试直接失败，不再连等两轮。

### 验证

```
node tools/lume-source-check.mjs sources/video/lxxlxx.js
```

- 现在（源站挂着）：`home` 8.5s 后给出上面那句可读错误，`categories` 照旧 10 项（本地表，不依赖网络）。
- **换台逻辑单独验过**：把副本改成 `dead.invalid` + `httpbin.org` 两台，请求链是
  `dead.invalid（fetch failed）→ httpbin.org（200/404）`，说明第二台真的会被试到、会被记住。
- 站方恢复后无需改源：`/new/`、`/best/`、`/tags/<Tag>/`、`/search/?key=`、`/video/<Slug>.html`
  与三段播放链（`/vjs/<n>.js` → player js → mp4）都是原样，2026-11-01 已逐页实测过。

## 二、hxc：脚本没坏，是接口域名被网络拦了

### 现象

```
脚本错误: 接口线路都打不通（接口返回的不是 JSON：/base/getTimeStamp）
可点【网页视图】过校验（目标站：https://www.jhqjg.com/base/getTimeStamp）
```

### 排查

- 壳域名换了一轮：`www.9zx3x.com/home` → **302 → `https://www.jhqjg.com/home`**（title 含羞草）；
  `www.h4dh3.com` 已 ECONNRESET。
- 接口主机 **仍是** `a84i.ux51l.com` / `a96u.t3nwc.com`，从海外实测 https/http 都回
  `{"code":0,…,"timeStamp":…}`；整条链（getList → getInfo → getPreUrl → m3u8 206）在
  `tools/lume-source-check.mjs` 里全绿。
- 手机上报「返回的不是 JSON」= 请求到了 200 但 body 是网页 —— 运营商/代理把这两个接口域名
  换成了自己的提示页（或 TLS 握手被掐，-1200）。壳域名 `www.jhqjg.com/base/getTimeStamp` 本身回
  **405 nginx 纯文本**，也会命中同一句报错，所以错误文案把两个原因都写清楚了。

### 改了什么（1.0.4）

1. **接口主机自发现**：从站点自己的 H5 包里回读当前接口主机——
   `shell /home`（**必须用手机 UA**，桌面 UA 给的是 PC 版 Vue 包）→
   `…/h5/assets/js/app.<hash>.js` → `VUE_APP_API_BASE_URL:"https://a84i.ux51l.com,https://a96u.t3nwc.com"`。
   常量改名时还有兜底（包内 `<随机>.<ux51l|t3nwc>.com` 主机名）。结果缓存 6 小时（`bases.json`）。
   **只在已知主机全废时才回读**（两跳请求），日常不增加开销。
2. **https 被拦就换 http 再试同一台**：`post()` 捕获「200 但不是 JSON」，把 `https://` 换成
   `http://` 重试一次——有的线路只掐 443 的 SNI，明文 80 反而能过。
3. **壳域名/镜像更新**：`mirrors` → `www.jhqjg.com` / `www.9zx3x.com` / `9zx3x.com`；
   接口请求的 `Origin`/`Referer` 跟着换成 `https://www.jhqjg.com`。
4. 错误文案：明确「接口主机全部失败先查手机网络/代理（-1200 或被换成提示页），到
   「源设置 → 站点网络」切代理线路」，并说明脚本会自己回读接口主机。

### 验证

```
node tools/lume-source-check.mjs sources/video/h4dh3.js
```

- 五入口 + `filters` 全绿，`content()` 给 `t04c.beikept.com/…/index.m3u8`，探活 `206 #EXTM3U`。
- 日常路径**没有**多余请求（自发现是懒加载，只在全废时才跑）。
- **自发现实测**：把 `DEFAULT_BASES` 改成两台死域名再跑，请求链变成
  `jhqjg.com/home（4423B H5 壳）→ j04l…/h5/assets/js/app.00b8d4b7.js（571KB）→
  a84i.ux51l.com/base/getTimeStamp → …`，五入口依旧全绿。

## 三、限制 / 用户侧怎么办

- **LXXLXX**：源站挂着就真的没内容，等站方拉起来；脚本已经会自动换台，恢复后点「重试」即可。
- **hxc**：国内必须走代理。若仍报「不是 JSON」/`-1200`，到「源设置 → 站点网络」切到代理线路，
  或换网络重试；接口主机以后换了不用再改源。
