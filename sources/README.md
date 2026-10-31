# LumeBox 视频源：站点转源结果

## 2026-10-31 听书 HTML / 咕噜 Python

`video/咕噜咕噜.py` 为 Python 1.0.1 单文件源：视频板块 → Python 源 → 本地文件导入，或同步现有影视订阅。分类不再发网络请求；网络失败显示原因，分集编码与播放请求头已修复。验证见 [本次审核记录](../docs/2026-10-31_听书导入与工作区审核.md)。

`web/听书合集.html` 是网页主页，版本标记 1.0.1：视频源管理 → 网页 → 导入 HTML 文件。它不属于 JS/Python 源订阅；有声小说筛选下同样保留 HTML 导入入口。修改后的 App 需安装新版才能获得入口与文件类型兼容修复。

## 2026-10-30 新增 13 源（详见 docs/2026-10-30_批量新增13源.md）

`laosiji_video` 老司机在线 · `fplayer_video` 飞播 · `forcedcinema_video` ForcedCinema ·
`avbebe_video` Avbebe · `cartoonporn_video` CartoonPorn · `pmvtube_video` PMVtube ·
`sexbjcam_video` sexbjcam · `xxxfollow_video` XXXfollow · `gifscroll_video` GifScroll ·
`xiaohuangniao_video` 小黄鸟 · `ogfap_video` OGFAP · `hstream_video` hstream ·
`p91pinse_video` 91PinSe

均为 18+（已在 `source_content_rating.dart` 与源仓库 `metadata/content-ratings.json` 登记）。

## 源约定（新增源必须遵守）

1. **先找主站，镜像尽量配满**：拿到站点先确认哪个是主站（官方/首发域名），源默认用主站；
   主站之外**能验证的镜像都写进 `mirrors`（下标 0 = 主站；每组最多 20 个，设置页首屏只列 3 个，
   其余收在「更多镜像」里）**，用户在 App 源设置里可直接切换。只收**实测同内容**的地址；官方公布但本机打不开的（DNS 污染/被墙）
   可以放进 `mirrors` 供手选，但不要放进脚本的自动解析路径（`SEEDS`），否则会把超时算进每次调用。
2. **标注网络要求**：头部 JSON 里写 `"network"`：
   - `"direct"`：直连可访问（实测不走代理能打开）；
   - `"proxy"`：需要代理（实测直连超时 / RST / 403 挑战）；
   - 不写 = 未标注。App 的「源设置 → 站点网络」会显示这条提示。
3. **分类与筛选必须真正生效**：`categories()` 返回的每个 id 都要能被 `list({categoryId})` 解释成不同内容；
   `filters()` 里每个 option 的 id 都要在 `list({filters})` 里被用上。做完用下面的办法自测：
   ```bash
   node tools/lume-source-check.mjs sources/video/xxx.js        # 五入口
   # 再对比两个分类 / 两个筛选的返回：首条 id 相同 = 分类（筛选）没生效
   node tools/lume-source-check.mjs sources/video/xxx.js --call list --category ""
   node tools/lume-source-check.mjs sources/video/xxx.js --call list --category <分类id>
   node tools/lume-source-check.mjs sources/video/xxx.js --call list --category <分类id> --filter <组>=<选项>
   ```
   顺手记两条真机上踩过的坑（2026-10-29，详见 `docs/2026-10-29_八源体检-失效封面分类修复.md`）：
   - **video 类源的沙箱没有 `atob` / `Buffer`**：要解 base64 就自己写纯 JS 实现，
     否则解码静默失败，很容易被误判成「站点改版」；
   - **「解不出来」不能当「广告」**：判空后直接过滤会把整页清空。
4. **列表页有内容就不要绕去详情页**：优先用列表里已经带出来的播放地址/封面，减少请求。
5. **失败要如实报**：空分类返回空列表并说明原因，不要拿别的分类的内容顶替。
6. **新源默认清单（2026-10-29 起）**：源设置页的区块**只有源声明了才出现**，按下面写：
   - **必写**：`category`、`contentCategory`（`adult` / `movie`）、`version`、`network`、`icon`、`mirrors`；
   - **有就写**：`home` / `categories` / `filters`（必须真实生效，见第 3 条）；
   - **建议每条源带一条 `info`「站点说明」**：写站点特性、限制、是否需要登录/代理，用户在设置页
     就能看懂（`ptt-drama`、`yuese` 都是这么写的）；
   - **站点真有对应结构才写**：`commonSettings`（`pageSize` / `quality` / `playbackMode` /
     `searchMode` / `autoNext`，写了就要在脚本里读 `LumeSource.config.commonSettings` 并落实；
     `playbackMode` 由 App 裁决）、`settings`（toggle/select/text/number/action，action 走
     `settingsAction`）、`endpoints.images` / `endpoints.video`（多个**可互换**的图床/CDN，
     App 按前缀替换）；
   - **不要为了「功能全」而声明**：App 只校验格式、范围和能力，不会验证脚本是否真的用了；
     假声明（例如声明 `pageSize` 但列表根本不按它请求）只会把用户带进无效设置。
7. **站点有发布页/地址发布页时写进扩展功能**：用一条 `{"type":"action","action":"openWebsite",
   "url":"https://发布页/","title":"打开发布页"}`，再配一条 `info` 说明（发布页给出当前域名、邮箱、
   备用地址）。用户在 App 源设置里能一键打开或复制，站点换域名后不至于失联；发布页地址本身不要
   当镜像写进 `mirrors`（它不是站点本体）。例：`comic/巴卡漫画.js`（发布页 bakamh.app）、`video/8x8x.js`。

## 已发布的订阅链接（推送到 LumeBox-Sources 仓库）

| 用途 | 订阅地址 |
|---|---|
| **影视综合 7 源（推荐）** | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos-hd` |
| 影视综合 7 源 · 国内网络用（jsDelivr） | `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn` |
| **18+ 成人向（Hentai2W）** | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos-18plus` |
| 18+ · jsDelivr 版 | `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-18plus-cdn` |
| 总订阅（漫画 + 全部视频，含以上两份） | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/all` |
| 原有视频订阅（不含新增） | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos` |

App → 视频板块 → 源管理 → 订阅 → 填上面的地址 → 同步即可。脚本实体在
`https://github.com/teng662858/LumeBox-Sources/tree/main/video`（中文文件名，可单独下载导入）。

### 「手机上更新了却没有新源」怎么排查

1. **「一键更新全部订阅」不会发现新清单**：它只刷新**已保存**的订阅地址（`SourceSubscriptionSync.sync`
   只遍历本机 `subscriptions.json` 里的记录）。`videos-hd` 是新清单，必须先添加一次：
   视频板块 → 源管理 → **订阅管理** → 底部「添加订阅地址」填 `videos-hd` → 点「添加订阅并导入」。
   之后「一键更新全部订阅」才会带上它。
2. **想一次到位**：设置 → 总订阅导入导出 → 粘贴 `.../all` → 「导入总订阅」（会把 `videos-hd` 一起加进来并立即同步）。
3. **切到「已有订阅」页签不会多出源**：如果当初加的只是老的 `videos`，那份清单里没有这 7 个源
   （新增的 7 个在独立清单里，避免撞单次订阅 20 条的导入上限）。
4. **国内网络打不开 `raw.githubusercontent.com`**（表现为「订阅拉取失败」，容易被当成"没更新"）：
   改用 jsDelivr 镜像清单 `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn`。
   代价是 jsDelivr 对 `@main` 有缓存（最长约 12 小时），脚本改动要立刻生效时仍用 raw 那份。

订阅端到端复验（从线上拉清单 → 下载每个脚本 → 跑五个入口）：

```bash
node tools/check-subscription.mjs          # 需要能访问 raw.githubusercontent.com
node tools/check-subscription.mjs --manifest https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn
```

---

本目录是给 **LumeBox 视频板块**用的图源脚本（`// LumeSource: {...}` 单文件形态，导入即用）。
全部**在本地按 App 的桥接语义实跑过**：真实访问源站、真实取列表/详情/选集、真实探播放地址。
仅本地自用研究，不传播、不商用。

```
sources/video/
├── ysxq-boju.js   播剧网（ysxq.cc）      苹果CMS JSON 接口，424 万+ 影片，最稳的一个
├── a123tv.js      A123TV（a123tv.com）   服务端渲染 HTML + 播放页内嵌 m3u8
├── fdzys.js       饭搭子影视（fdzys.com） 定制模板 HTML + player_aaaa，搜索走 suggest 接口
├── flixflop.js    飞流视频（flixflop.com）Next.js flight 数据里直出播放串
├── duanju2.js     短剧网（duanju2.com）   短剧站，player_aaaa + suggest 搜索
├── olehdtv.js     欧乐影院（olehdtv.com） 苹果CMS HTML，**需代理**
├── huavod.js      华视影院（huavod.com）  **需代理**，播放走网页播放器（P2P 频道）
├── yue5xi5.js     快猫（yue5xi5.xyz）     AES-128-CBC 加密接口，游客号过登录，mp4 直链
├── thepornjoy.js  ThePornJoy（thepornjoy.org）KVS tube，详情页内联签名 mp4，直连可用
├── haoqi7.js      好妻网（haoqi7.com）    TanStack SSR，免 token serverFn，整片 m3u8（VIP 只在前端），**需代理**
├── xfdxv.js       41看片（xfdxv….lifestyle）Fernet 配置解出 apiBase，m3u8 直链（543786/542372 的落点）
├── spankbang.js   SpankBang（spankbang.com）**CF JS 挑战**，需网页视图过校验后复用 Cookie
├── hstv.js        HSTV（d1nu1x3tadacmt.cloudfront.net）匿名设备登录拿 JWT；免费篇整片，金币/VIP 篇服务端只发 15 秒
├── jiuxse.js      9sex（9sex.com）        ThinkPHP；info 接口要 Accept-Language+XHR 三件套；**需代理**
├── mwx43zd.js     快猫镜像站（mwx43zd.xyz）AES hex 密文 + md5(升序query+salt)；免费整片，付费/VIP/搜索服务端 401
├── yuese.js       月色视频（ys.ph3ywdns.icu）Flutter Web 的 REST（dart2js 常量）；switch_line 绕游客配额
├── haijiao.js     海角（haijiao.com）     三重 Base64；**播放地址只对登录态下发**，需填账号
├── aido8.js       爱豆（ww15.aido8.icu）  /awsapi 加密 JSON；匿名整片；封面是反转 JPEG（占位图）
├── tangtoutiao.js 汤头条（p1.wgbqoiqv.com）Nuxt 壳 + 独立接口域，AES-256-CFB 签名；付费仅 ~2 分钟试看
├── h4dh3.js       hxc（h4dh3.com）        **VIP 真破解**：getPreUrl 签名只覆盖路径，删 start/end 即整片
├── cf3.js         Butterfly2（d17rhkrwip15vt.cloudfront.net）同 SDK 另一运营方；API 域与页面域分离
├── hentai2w.js    Hentai2W（hentai2w.com）**18+**，**需代理**，Inertia props + 自动过年龄门
├── zhilian-duanju.js 栀莲短剧（yklyo880.lldj1.xyz）短剧站，SPA + `/api/v1` JSON 接口；游客登录获取当前会话获准播放的地址，锁定集转源站网页
├── 91cg1.js       91吃瓜（www.91cg1.com）Typecho HTML；短片地址在帖子页内嵌的 DPlayer 配置里（新 CDN op.udhhzr.cn，实测 m3u8 200）
├── betareel.js    BetaTok（betareel.com）Firebase + R2；`/api/betatok/feed` 给预签名清单，**清单 27 MB 用 Range 窗口读**
├── gamebus.js     绅游巴士（gamebus001.cc）`/api/video/page/N` 接口；HLS 是 fMP4（init.mp4 + seg_*.m4s），实测 m3u8 200
└── tanhua.js      探花视频 / 91大神（同一套内容库的两个域名）；SSR 无接口，播放地址在详情页 DPlayer 配置里
├── f016.js        在线影院 / 91吃瓜（同一站群，前者是超集）；hash slug 路径，搜索走站点自带的 Meilisearch
├── resao.js       91热爆（www.resao.com）KVS 站；**VIP 专享片靠 CDN 路径可预测直接取流**（去掉 ?k=&t= 也 200）
├── yuxiu.js       玉羞园（yhh.yxy881p.icu）xvideos 镜像站；媒体直连 xvideos CDN，无 VIP
├── tianlula.js    天撸啦（ttbd067.top:51000）视频频道；接口密文 AES-128-CBC，源内自带纯 JS 解密
├── haijiaoqing.js 海角情（haijiaolove.xyz）WordPress 站；列表/详情走 wp-json，正文内嵌 abyssplayer 走 webplayer
├── aiboaibo.js    爱播爱播（994555.xyz）SvelteKit SSR + /category/__data.json（devalue）；51 个分类（来源 11/12 栏目）、每条自带 m3u8，发布页 didizhi.pages.dev
├── jizeyy.js      AV仓库（jizeyy.com）Typecho 主题；取流走 ?action=get&p=1 里的 jx.php?url=<m3u8>
├── hsex.js        好色TV（hsex.men）列表可直连、详情 CF 挑战 → content 走 webplayer
├── reddxxx.js     ReddXXX（reddxxx.com）列表取 sitemap 视频索引、播放走 webplayer
├── theavporn.js   TheAVPorn（theavporn.com）KVS；播放地址由 id 推导（bytt.jb-aiwei.cc，去掉 ttl/dsc 仍 200）
├── s618.js        618影院（618208.xyz 地址表 → 618<码>.xyz 站群）；文字 XOR 0x80，列表 href 的 ?v= 即 m3u8
├── ptt-drama.js   蝴蝶影院（ptt01.com 站群）线上看；系列页给分集，单集页内嵌整集 m3u8
├── huangguo-duanju.js 黄果短剧（huangguoai.com）AI 短剧，**需代理**；播放页直给签名 m3u8
├── juzhi.js       橘汁 - 影视（juziapp.hzhcbkj.cn，从橘汁 APK 里挖出的官方后端）；开放 JSON 端点 + 换流接口
├── hqvod.js       点播-高清（hqvod.com）苹果CMS 站；列表走 ajax 数据接口，播放页有滑块 → webplayer
├── d9y1w.js       四色视频（www.d9y1w.top）maomi 模板站；标题 AES-256-CBC、卡片链接 base64 混淆，播放 m3u8 直链
├── x8x8.js        8x8x（8x8x.fun / 随机跳板域）SPA 外壳 + bodyRoot 内容页；频道/标签 SSR、推荐流 AES-256-GCM，播放三线路 HLS
├── pornbest.js    第一女優網 / PornBest（www.pornbest.org，镜像 www.av01.org）Yii2 SSR + video.js；**需代理**；大陆出口 302 到封锁页，另有 CDNLah WAF 的 PoW（源内纯 JS SHA-256 自动解）；详情页 `<source>` 直给 m3u8
├── 91pornplus.js  91PornPlus（91pornplus.com 站群）Angular SPA + 单入口 `POST /js`；响应 AES(passphrase=xxx) 密文（源内纯 JS MD5+AES-256-CBC），**接口域名国内直连**，匿名给 m3u8
├── pornlulu.js    Pornlulu / 撸撸（www.pornlulu.net，镜像 .com 同库）Yii2 SSR；**需代理**，CDNLah WAF 的 PoW 自动解；栏目 /cat/<id>、排序 sort、搜索 ?q=、播放 m3u8
├── 9188porn.js   9188色情网（www.9188porn.com）macCMS；**需代理**；列表直链播放页，player_aaaa 给 m3u8
├── mtav.js       蜜桃视频（mtav.art）macCMS/TKTube；**需代理**；/vod/show/id/<N>/ 三区、搜索 /vod/search.html?wd=（导航里的 tmav.art 是天美AV，不同站，不作镜像）
├── heroero.js    HeroEro（heroero.com）KVS；**需代理**；/latest-updates/、/categories/<slug>/，详情 flashvars 直给 mp4（Range 1KB）
└── qinav.js      Qinav（www.qinav.com）；**需代理**；/site/5/<N>-<P>.html 分类分页、/search.html?wd=，embed 页 const url 给 m3u8
```

**漫画 / 图片类图源**不在 video/ 下：
- `comic/gamebus.js` —— 同一站绅游巴士的 H 漫（`/api/comic/{chapterId}/pages` 直接给整话图片）；
- `photo/91cg1.js` —— 91吃瓜的图集（图片在帖子页 `data-xkrkllgl` 属性里）。
- `comic/巴卡漫画.js` —— 巴卡漫画（Madara/WordPress）：分类页 `/manhwa/` 等、条目 `/manga/<slug>/`、章节正文 `reading-content`；发布页 bakamh.app，镜像 bakamh.com / bakamh.ru / baka3.cfd / baka1.cfd / baka2.cfd；Cloudflare 后面，需要网页验证时会给 `NEED_WEBVIEW_VERIFY`。

---

## 一、怎么导入

**推荐用订阅**（上面那个 `videos-hd` 地址）。也可以手动导入 ——
App → 视频板块 → **源管理** → 导入，三种方式任选：

1. **选文件**：把对应 `.js` 下载/传到手机，导入时选中它；
2. **粘贴**：把 `.js` 全文粘进导入框（脚本自带 `// LumeSource:` 身份头，App 会自动识别）；
3. **订阅链接**：把本目录的文件挂到你自己的静态地址上，用「订阅」方式填 URL（可多个，一行一个）。

> 导入后建议先跑一次「图源管理 → 测试连通性」；它走与浏览完全相同的调用链。

## 二、逐站实测结果（本机复验于 2026-10）

| 源 | 需代理 | 首页 | 分类 | 列表条目 | 搜索 | 详情 | 选集 | 播放 |
|---|---|---|---|---|---|---|---|---|
| 播剧网（ysxq） | 否 | 20 | 9 | 15 | 20 | ok | 28 | **video（m3u8 直链）** |
| A123TV | 否 | 18 | 54 | 36 | 12 | ok | 16 | **video（m3u8 直链）** |
| 饭搭子影视 | 否 | 18 | 6 | 24 | 2 | ok | 18 | **video（m3u8 直链）** |
| 飞流视频 | 否 | 18 | 7 | 48 | 不支持 | ok | 2 | **video（m3u8 直链）** |
| 短剧网 | 否 | 12 | 3 | 24 | 20 | ok | 1 | **video（m3u8 直链）** |
| 欧乐影院 | **是** | 18 | 29 | 60 | 1 | ok | 2 | **video（m3u8 直链）** |
| 华视影院 | **是** | 18 | 5 | 246 | 17 | ok | 2 | webplayer（网页播放器） |
| 快猫（yue5xi5） | 否 | 2 块 | 2 | 20 | 本地过滤（站点无搜索接口） | ok | 1 | **video（mp4 直链）** |
| ThePornJoy | 否 | 3 块 | 42 | 24 | 24 | ok | 1 | **video（mp4 直链，206）** |
| 好妻网 | **是** | 1 块 | 14 | 20 | 16 | ok | 1 | **video（m3u8 整片，46KB）** |
| 41看片 | 否 | 2 块 | 6 | 20 | 20 | ok | 3 | **video（m3u8 直链）** |
| SpankBang | **是** | — | — | — | — | — | — | 403 → 网页视图过校验（解析已按真实 HTML 实测：列表 82 条、播放三码率） |
| HSTV | 否 | 2 块 | 2 | 20 | 20 | ok | 1 | **video（m3u8；免费篇整片，金币篇 15 秒）** |
| 9sex | **是** | — | 29 | — | — | ok | 1 | **video（m3u8）** |
| 快猫镜像站 | 否 | 2 块 | 5 | 20 | 本地过滤 | ok | 1 | **video（m3u8 整片）** |
| 月色视频 | 否 | 2 块 | 76 | 24 | ok | ok | 1 | **video（m3u8 整片，2–3 清晰度）** |
| 海角 | **是** | — | 6 组 | ok | ok | ok | — | 需登录（账号登入）后才有播放地址 |
| 爱豆 | 否 | 4 块 | 9 | ok | ok | ok | 1 | **video（m3u8 整片）** |
| 汤头条 | 否 | 2 块 | 8 | 10 | 20 | ok | 1 | **video（免费整片；付费 2 分钟试看）** |
| hxc | 否 | 2 块 | ok | ok | ok | ok | 1 | **video（m3u8 整片，删 start/end 后）** |
| Butterfly2 | 否 | 2 块 | ok | ok | 本地过滤 | ok | 1 | **video（m3u8 整片）** |
| 栀莲短剧 | 否 | 3 块 | 10 | 20 | 20 | ok | 18 | video / webplayer（获准播放的地址直连，锁定集转源站） |
| 91吃瓜 | 否 | 4 块 | 23 | 19~30 | 30 | ok | 1 | **video（m3u8 直链 + AES key/分片逐个签名）** |
| BetaTok | 否 | 1 块 | 84 频道 | 19~20 | 窗口内过滤 | ok | 1 | **video（mp4，Worker 302 到 R2 预签名地址，实测 206）** |
| 绅游巴士 | 否 | 2 块 | 3 排序 | 30 | 30 | ok | 1 | **video（m3u8，fMP4：init.mp4 + seg_*.m4s，实测 200）** |
| 绅游巴士漫画 | 否 | 3 块 | 4 排序 | 30 | 30 | ok | 10 | **images（一整话 136 张 webp，首图 200）** |
| 探花视频 | 否 | 4 块 | 42 分类 | 30 | 无搜索接口 | ok | 1 | **video（m3u8，实测 200 + #EXTM3U；另一域名 91大神 同库同地址）** |
| 在线影院 | 否 | 3 块 | 31 分类 | 40 | 40（Meilisearch） | ok | 1 | **video（m3u8，master→variant 实测 200；另一域名 91吃瓜 是子集，404 自动回落）** |
| 91热爆 | 否 | 3 块 | 12 分类 | 20 | 20（站内搜索） | ok | 1 | **video（CDN 直连：`/{dir}/{id}/{id}.mp4/index.m3u8` 去掉签名也 200；VIP 专享片同样可播）** |
| 海角情 | WordPress：`/wp-json/wp/v2/posts?per_page=20&page=N`（X-WP-Total 1156）、`/wp-json/wp/v2/posts/{id}`；正文是 Elementor 生成的 HTML | 播放器是正文里的 `<iframe src="https://player.abyssplayer.com/{code}">`，播放器页 JS 渲染、HTML 无 m3u8 → 按 `kind: webplayer` 交给 App 网页播放器；一个帖子 1–3 个源，做成 chapters。封面取正文首个 `<img>`（多为 gif）。 |
| 爱播爱播 | SvelteKit SSR + `__data.json`：首页/搜索页 HTML 内嵌 `{id,name,pic,m3u8,…}`，卡片链接 `/<sourceKey>-<id>`；分类 `/category/__data.json?source=<11\|12>&tid=<栏目>&page=N`（devalue 扁平数组，解出 classes/vods/totalPages）；详情 `/<sourceKey>-<id>/__data.json` | 每条自带 m3u8（`t27.cdn2020.com/…/index.m3u8`），加不加 Referer 都能播；来源 11 有 20 个栏目、来源 12 有 30 个栏目，同名去重后 51 个分类；分页真实生效（s11:0 = 1346 页）。 |
| 天撸啦 | 综合站拆三源：`Api-vod_list&cid&limit&page`（视频，total 284,145）、`Api-vod_search&wd`、`Api-vod_detail&id`（`vod_url` 是 m3u8）；`Api-news_list&cid&type=pic\|text`（图集/小说）、`Api-news_detail&id`（`news_content` 是一整段 HTML）；分类树在 `Api-list_all` 的 `children` 里 | **接口返回体是 AES-128-CBC 密文**（key `bfd7257d9bee742c`、iv `506ecf5490eeb552`，同为 ASCII），沙箱没有 crypto/atob，所以三个源各自内联一份纯 JS AES-128-CBC（FIPS-197 向量 + 站点真实密文双向核对）；图集把 `news_content` 里的 `<img>` 抽成 images 列表并统一 http→https；小说把 HTML 去标签转纯文本。 |
| 玉羞园 | 否 | 3 块 | 38 分类 | 48 | 27（站内搜索 `/?k=`） | ok | 1 | **video（hls_low.m3u8 200 206B master；mp4_sd 200 93 MB 整片可直下）** |
| 天撸啦 | 否 | 4 块 | 52 分类 | 20 | 20（`Api-vod_search`，探花 7718 条） | ok | 1 | **video（`vod_url` = m3u8，实测 200 + #EXTM3U 3790 B）** |
| 天撸啦图集 | 否 | 3 块 | 9 分类 | 20 | 无搜索接口 | ok | 1 | **images（一套 17 张直链，首图 200）** |
| 天撸啦小说 | 否 | 3 块 | 9 分类 | 20 | 无搜索接口 | ok | 1 | **text（正文 1.2 万字，HTML 去标签）** |
| 海角情 | 否 | 1 块 | 7 分类 | 20 | 20（wp-json `search=`） | ok | 3 | **webplayer（正文内嵌 player.abyssplayer.com，多线路）** |
| 爱播爱播 | 否 | 1 块 | 51 分类 | 20~50 | 搜索页 SSR（30 条） | ok | 1 | **video（m3u8 直链，探活 200 + #EXTM3U；分类分页真实生效）** |
| AV仓库 | 否 | 3 块 | 8 分类 | 20 | 无搜索接口 | ok | 1 | **video（`?action=get&p=1` → jx.php?url=<m3u8>；直连 CDN 在本机被 RST，地址本身正确）** |
| 好色TV | 否 | 3 块 | 5 栏目 | 24 | 40（search.htm） | ok | 1 | **webplayer（列表/封面可 HTTP 取，详情页有 CF 挑战 → 交给 App 内嵌浏览器）** |
| ReddXXX | 否 | 1 块 | — | 1004（一个 sitemap 分片） | 无 | ok | 1 | **webplayer（列表来自 sitemap-videos 视频索引，播放走内嵌浏览器）** |
| TheAVPorn | 否 | 3 块 | 3 栏目 | 24 | 无 | ok | 1 | **video（`bytt.jb-aiwei.cc/contents/videos/{dir}/{id}/index.m3u8` 免登录，探活 200 + #EXTM3U 1382B）** |
| 618影院 | 否 | 3 块 | 10 个区 | 20 | 无 | ok | 1 | **video（列表 href 的 `?v=` 即 m3u8，探活 200 + #EXTM3U 1080x1922；二/三区是 webplayer）** |
| Hentai2W（18+） | **是** | 4 板块 | 24 | 24 | 24 | ok | 1 | **video（m3u8 直链）** |
| 蝴蝶影院 | 否 | 1 块 | 8 分类 | 48 | 本地索引过滤（站点搜索接口 503） | ok | 47 | **video（单集页 `<source>` m3u8，实测 200 + mpegurl，1080x608）** |
| 黄果 - 短剧（18+） | **是** | 1 块 | 6 分类 | 47 | 30（`/search/video/<词>/`） | ok | 1~3 | **video（m3u8，实测 200 + `#EXTM3U`，AES-128 key）** |
| 橘汁 - 影视 | 否 | 3 块 | 8 分类 | 24 | 本地索引过滤 | ok | 1 | **video（`videoParse/test/videoUsableUrl` 换流，实测 200 + `#EXTM3U` 59 KB）** |
| 点播 - 高清 | 否 | 1 块 | 5 分类 | 10 | 本地索引过滤 | ok | 5 线路 | **webplayer（播放页滑块人机校验，脚本 403 → App 网页视图过校验后播）** |
| 四色视频（18+） | 否 | 3 块 | 27 分类 | 20 | 30（剧情/视频/精品三频道合并） | ok | 2 线路 | **video（m3u8 直链 + AES-128 key 与分片同域，实测 200 + `#EXTM3U` 79 KB）** |
| 8x8x（18+） | **是** | 2 块 | 5 频道 + 12 组标签 | 23 | 28（`/api/search/video`） | ok | 3 线路 | **video（`data-route1..3` + `data-m3u8`，探活 200 + `#EXTM3U` 158 B master）** |
| 第一女優網（18+） | **是** | 2 块 | 51 分类 | 48 | 24（`/q/<词>`） | ok | 1 | **video（详情页 `<source>` / ld+json `contentUrl` → `voddadaizi5.com:…/index.m3u8`，探活 200 + `#EXTM3U` 300 KB）** |
| 91PornPlus（18+） | 否 | 2 块 | 12 栏目 | 24 | 24（`/searchSevenVideos`，time/views 两种排序） | ok | 1 | **video（`POST /js` 加密接口 → 详情 `m3u8s[0]` = `tm.pppsuccess.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| Pornlulu（18+） | **是** | 2 块 | 69（3 排序 + 66 分类） | 48 | 50（`/?q=<词>`；表单 name=q） | ok | 1 | **video（`<source>` → `2609.lajiao2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`；WAF 弹 492 时自动解 PoW）** |
| 9188色情网（18+） | **是** | 1 块 | 19 | 20 | 20（`/vod/search.html?wd=`） | ok | 1 | **video（播放页 `player_aaaa` → `2609.senlin2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| 蜜桃视频（18+） | **是** | 1 块 | 4（3 区 + 全部） | 12 | 12（`/vod/search.html?wd=`） | ok | 1 | **video（播放页 `var uul` → `t36.cdn2020.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| HeroEro（18+） | **是** | 2 块 | 23 | 40 | 55（`/search/<词>/`） | ok | 1 | **video（详情 `flashvars.video_url` → mp4 `/get_file/…`，Range 206 + video/mp4）** |
| Qinav（18+） | **是** | 2 块 | 18（2 排序 + 16 分类） | 52 | 52（`/search.html?wd=`） | ok | 1 | **video（`/embed/<id>.html` 的 `const url` → `2609.lajiao2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |

「播放」列是**真去请求那个地址**验的：`video` 表示拿到播放地址且 HTTP 200 + `#EXTM3U`（HLS 清单）；
`webplayer` 表示拿不到可直连的 m3u8，交给 App 内置网页播放器去跑源站自己的播放器。

### 复验命令（本机）

```bash
# 一次跑完清单里的全部源（自带分组：该走代理的走代理），输出上面那张表
node tools/check-all-sources.mjs

# 单跑一个源，看五个入口的详细结果 + 每个请求的状态码/耗时
node tools/lume-source-check.mjs sources/video/a123tv.js --keyword 寒战

# 只看某站「App 同款 HTTP 栈」能不能通（直连 vs 走代理）
dart run tools/site_reachability.dart
```

`tools/lume-source-check.mjs` 不是 App 的一部分，是**开发期跑测器**：它在本机复刻
`lib/core/js/source_bridge.dart` 的桥接语义（`LumeSource` 全局对象、脚本赋值被吸收进桥、
`config` 只读快照…），再调 `categories / list / detail / chapters / content`。

## 三、两个站要挂代理（重要的环境事实）

用 **App 同款 Dart HTTP 栈**实测（`dart run tools/site_reachability.dart`）：

| 站点 | Dart 直连 | Dart 经本机代理 |
|---|---|---|
| ysxq / a123tv / fdzys / flixflop / duanju2 / dongpian12 | 200 | 200 |
| **欧乐 olehdtv** | **403（空响应）** | 200 |
| **华视 huavod** | **403（Cloudflare 拦截页）** | 200 |

所以 `olehdtv.js` / `huavod.js` 在国内直连会先被 WAF 拦住，两个办法：

1. **给该源配代理**：源设置 → 网络 → 代理，填你自己的代理地址（例如 `http://192.168.1.10:7890`）；
2. **走网页视图过校验**：脚本在 403 时抛的是 `NEED_WEBVIEW_VERIFY`，App 会给出「网页视图」入口，
   过完人机校验后 Cookie 会存进该源的会话并自动复用。

> 顺带一提：这两个站的拦截是**按客户端指纹**判的——本机用 PowerShell/.NET 直连是 200，
> 用 curl 直连也是 200，但 App 用的 Dart 客户端直连就是 403。所以「我用浏览器能打开」
> 不代表 App 里能打开；要判断 App 行为只能看上面这张 Dart 表。

## 四、懂片帝AI（dongpian12.com）为什么没有源

这个站**不是点播站**，是「AI 找片 + 对话」类应用（React SPA + `/v1/threads` 会话接口 +
邀请/配额/TV cast 一堆登录态接口）。我把它的前端包拆开确认过：

- 没有分类列表 / 搜索 / 详情 这类可脚本化的公开接口（`/v1/` 下全是会话、配额、用户、cast）；
- 播放要 `player-token` + `player-hls-p2p-policy`（P2P 频道 key），要登录态与 AI 线程上下文；
- 页面上也没有可直接播的 m3u8。

硬凑一个只会得到「能导入、点开就报错」的假源，所以**故意不提供**。
想用它就用 App 自带的**网页源**（把 `https://dongpian12.com/` 加成网页源，在内置浏览器里看）。

## 五、各源实现要点（改站点结构时看这里）

| 源 | 数据来源 | 播放地址怎么拿 |
|---|---|---|
| 播剧网 | 苹果CMS `api.php/provide/vod/`（`ac=detail` 带 `vod_play_url`） | `vod_play_url` 里 `$` 后的 m3u8 |
| A123TV | 列表 `/t/{类型}/p{页}.html`、详情 `/v/{slug}.html`、搜索 `/s/{关键词}.html` | 播放页 `div.w4-player[data-src]` |
| 饭搭子 | 列表 `/{分区}/all?page=N`、详情 `/{分区}/{slug}`、搜索 `/index.php/ajax/suggest` | 页面内嵌 `var player_aaaa={…}`（encrypt 0/1/2 都支持） |
| 飞流视频 | 列表 `/explore/{分类}?page=N`、详情 `/streams/{id}/detail` | Next.js flight 数据里 `"url":"第01集$https://…m3u8#…"`，章节 id 直接就是 m3u8 |
| 短剧网 | 列表 `/show/{类型}---{分类}-----{页}---.html`、详情 `/vod/{id}.html`、搜索 suggest | 播放页 `/play/{id}-{线路}-{集数}.html` 里的 `player_aaaa` |
| 欧乐影院 | 列表 `/index.php/vod/show/id/{类型}/page/{页}.html`、搜索 `search.html?wd=` | 播放页 `player_aaaa` |
| 华视影院 | 列表 `/vodtype/{类型}.html`（一次铺完 246 部）、搜索 suggest | 播放页只有 iframe `/Player/ec?episode=…`，直链是 P2P 频道 key（直连 403）→ 返回 webplayer |
| 快猫 | `POST /api/videos/listAll`（最新）/ `listHot`（最热）/ `detail`（详情+播放），全部 AES-128-CBC 加密 + md5 签名，脚本内置纯 JS 实现；**无搜索/分类接口** | `detail` 的 `mv_play_url`（列表里的老 CDN `119.28.204.36` 已死）；`is_play=0` 时按身份池重试并探无水印变体 |
| ThePornJoy | KVS：`/latest-updates/`、`/most-popular/`、`/top-rated/`、`/categories/{slug}/{N}/`、`/search/{词}/`（分页 `?from=24`）、`/videos/{id}/{slug}/` | 详情页内联 `video_url: '…/get_file/…/{id}_720p.mp4/?v-acctoken=…'`，实测 206 + video/mp4；登录只影响收藏/评论，播放免费 |
| 好妻网 | TanStack Start SSR：分类/列表/搜索走**免 token** 的 `POST /_serverFn/{hash}`（body 是 seroval 序列化），`/api/v1` 那层 token 中间件根本不碰 | `/play/{id}` 的 SSR 内联 `initialDetail.m3u8Url` ＝ **整片**（前端播放器才用 `files[0].url` 试看）⇒ VIP 锁只在前端；媒体域每次现取 |
| 41看片 | 首页 `window.CONFIG` 是 Fernet 串 → 解出 apiBase `sm-api.wieuc.com`；`/api/vod/video?page=&per_page=&site_id=6&orderby=`、`/api/vod/tag_group`、`/search/vod/?search=`、`/api/vod/video/{id}` | 详情给 3 条线路，播放 `https://<线路>/videos…/index.m3u8`，实测 200 + `#EXTM3U` |
| SpankBang | 纯 HTTP 全路径/UA/头组合均 403（CF `Just a moment...`，只有 `/robots.txt` 放行；带浏览器导出的 cookie 用 curl 也 403） | 抓取层抛 `NEED_WEBVIEW_VERIFY`；**解析已用真实 HTML 实测**：`data-testid="video-item"` 卡片 + `/{short}/video/{slug}` + `tbi.sb-cd.com` 封面 + `video-item-length`；播放取详情页 `var stream_data.m3u8`（240p/480p/720p，实测 200 + mpegurl）与 `…-720p.mp4`（206） |
| HSTV | Vue3 前端 + `/api/app/*`，响应自定义 AES-256-CBC（interfaceKey 派生）；**`POST /mine/login/h5` 匿名设备登录即得 JWT**（`Authorization: <JWT>`，不加 Bearer） | `POST /video/play` → `playPolicy.result`：`FULL` 整片 m3u8；`PREVIEW` 服务端截断 15 秒（4 段/18.48s + ENDLIST），换 scene/videoType 无效 ⇒ VIP 锁在服务端 |
| 栀莲短剧 | React SPA + `/api/v1`：`/home`（分类+最新+推荐）、`/dramas?sort=&category_id=&keyword=&page=&size=`、`/dramas/{id}`（带客户端头时返回 `{drama, episodes}`）、`/dramas/{id}/episodes/{number}` | **`POST /api/v1/auth/guest` 游客登录**（`requestKey` 必须是 base64url(32 随机字节)，43 字符）；`video_url` 只对带 `Authorization` 的请求下发。没有下发媒体地址时转源站网页显示权限要求，不构造播放路径。 |
| 91吃瓜 | Typecho + Mirages：`/`、`/page/N/`、`/category/{slug}/N/`、`/search/{词}/N/`、`/archives/{pid}/`；卡片 = `<a href="/archives/{pid}/">` + `loadBannerDirect('封面')` + `<h2 class="post-card-title">`（搜索页的链接是绝对 URL，两种都要认） | 帖子页内嵌 DPlayer：`"video":{"url":"https://op.udhhzr.cn/videos5/…/index.m3u8?auth_key=…"}`，`\/` 还原成 `/` 即可直连（清单 200 + `#EXTM3U`，key/`.ts` 都在 as.ucjosl.cn 上逐条签好）。图片在 `data-xkrkllgl` 属性（`<img src>` 只是占位图）。栖影那套 `hls.ffxddn.cn` / `op.vkjyoi.cn` 已死。 |
| BetaTok | Firebase 项目 + R2：`GET /api/betatok/feed` → `{manifestUrl(预签名), mediaBase, mediaQuery, expiresAt}`；清单是 **27 MB / 34466 条**的整包 JSON（对象本身 gzip 3.7 MB） | **Range 窗口**：每次只取前 N KB 压缩（64 KB ≈ 550 KB 文本 ≈ 680 条），用 `},{"id":"` 切条、只 `JSON.parse` 需要的那几条；`/api/betatok/media/{videoKey}?{mediaQuery}` → 302 到 R2 预签名 mp4（实测 206，单个 60 MB）；封面走同一代理 `{posterKey}`。`locked:true` 的付费片不列。 |
| 绅游巴士 | Quasar SSR + `/api`：`POST /api/comic/page/{N}`（`sort`=last_chapterAt/createdAt/views/likes）、`GET /api/comic/{id}`、`GET /api/comic/chapters?comicId=`、`GET /api/comic/{chapterId}/pages`；`POST /api/video/page/{N}`、`GET /api/video/{id}`。接口表来自 `/assets/index-Cq4bvF8R.js` | 漫画：`/comic/{chapterId}/pages` 直接给 `pages[].image_path`（webp，一话最多三百多页）；短片：详情里的 `hlsUrl` 是 `image.gamebus001.cc/…/index.m3u8`（fMP4，`init.mp4` + `seg_*.m4s`，实测清单与分片都 200，无 AES key、不需要 Referer）。`vipOnly` 只给可读错误。 |
| 探花视频 / 91大神 | SSR 无接口：首页 `/index-{cat}-{N}.html`、详情 `/content-{id}.html`；分类导航随域名不同（探花=题材，91大神=大神名） | 详情页 DPlayer 配置里直接写 `url: '…index.m3u8'`（`2609.sysl2026.com` / `voddadaizi2.com:52866` / `vostrely.com` / `play2.laoyacdn.com` 等历史 CDN 轮换），实测 200 + `#EXTM3U`。**两个域名同 id 同 m3u8**，做成一个源 + mirrors。 |
| 91热爆 | KVS：`/latest-updates/`、`/most-popular/`、`/private/`（VIP专享）、`/categories/{slug}/`，翻页 `{path}N/`；详情 `/videos/{id}/{slug}/`（**必须带 slug**，无 slug 会 404） | **播放地址不吃页面**：`https://delivery.douyinpaly.com/hls/contents/videos/{dir}/{id}/{id}.mp4/index.m3u8`，`dir=floor(id/1000)*1000`；页面里的 `?k=&t=` 签名是装饰，去掉照样 200，`_720p` 变体也在。所以游客限流与 VIP 锁都影响不到播放。 |
| 在线影院 / 91吃瓜 | hash slug 站：首页 `/`+`/page/N/`、分类 `/{slug}/`+`/{slug}/page/N/`、详情 `/{slug}/{2字母}/{10字母}.html`；搜索是站点自带 Meilisearch：`POST /search/indexes/indexes/articles/search`（`Authorization: Bearer <search-config.js 里的 apiKey>`，路径里 host 段出现两次） | `<video poster>` + 页面内直给 m3u8（`hsm3.hwzcfz.com`、`lsbbf11.com`…）。**B(在线影院) 是超集、A(91吃瓜) 是子集**：A 的条目在 B 上 16/20 命中，B 的条目在 A 上 0/20，同路径同 m3u8；A 的 404 是「HTTP 200 + 标题 404」的软 404，脚本按标题判缺失并回落到 B。 |
| 蝴蝶影院 | 列表 `/?page=N`、分类 `/?category_id=NN&page=N`（19 大陆 / 20 香港 / 81 台湾 / 83 日本 / 82 韩国 / 22 欧美 / 92 泰国 / 23 其他）、系列页 `/v/<id>`、单集页 `/<id>/<集数>`；站点首页有「继续访问」门（只写 `x-index-auth=authed`），脚本每个请求自带该 Cookie | 单集页 `<source src="…/index.m3u8">`，实测 200 + `application/vnd.apple.mpegurl`（1080x608 master）。`/node/search` 对脚本环境一律 503 ⇒ 搜索用本地索引（浏览时累积）过滤 |
| 黄果 - 短剧 | 分类 `/{ai-duanju\|ai-manju\|ai-mogai\|ai-huanlian}/`、`?page=N`、热榜 `/ranks/hot/`、搜索 `/search/video/<词>/`；卡片 `.hg-drama-card`（`data-src` 封面）；详情 = 第 1 集 `/video/<id>/`，后续集 `/video/<id>/ep-N/`（总数在 `data-track-total-episode`） | 播放页内联签好名的 `yd-hls.hzjvlo.cn/videos5/…/index.m3u8?auth_key=…`（AES-128 key 在 `tp4.drleao.cn`），实测 200 + `#EXTM3U`；`auth_key` 有时效，`content()` 每次现取 |
| 点播 - 高清 | 苹果CMS v10：`api.php/provide/vod/` 已关（`ac=list` → `closed`），改走站内 ajax 接口 `/index.php/ajax/data?mid=1&tid=<分类>&page=<页>`（13.4 万条、**每页固定 10 条**）；详情 `/xiangqing/<id>.html` 取 `/bofang/<id>-<线路>-<集>.html` 选集 | 播放页 `/bofang/*` 挂滑块人机校验（`/huadong_*.js`），脚本请求 403，返回 `webplayer` 交 App 网页播放器；**站点连续请求会短时封 IP**，本源每次调用只发一个请求 |
| 橘汁 - 影视 | APP 后端 `juziapp.hzhcbkj.cn`：`/api/v3/drama/treeCategory`（分类）、`/api/v3/debug/drama/list?page&pagesize&typeId`（列表，含 `videos[].path/source`）、`/api/ex/v3/videoParse/test/videoUsableUrl?vodPlayFrom=&playUrl=`（换流）；OpenAPI 在 `/v3/api-docs` | 换流接口返回真实 m3u8（实测 200 + `#EXTM3U` 59 KB）。**正式接口 `/api/proto/v5/*`、`/api/ex/v3/security/*` 要「公共参数」签名头**，未签名时只有每部作品第 1 集可播 |

三个「苹果CMS」系源都自带纯 JS 版 base64 / 百分号解码（沙箱没有 `atob`/`unescape`），
所以 `encrypt=1/2` 的站点换了编码也不用改脚本。

## 六、已知限制

- **飞流视频没有搜索**：它的搜索是 Next.js Server Action（POST + 加密 action id），没有可脚本化的 GET 路由；分类浏览、详情、播放都正常。`list({keyword})` 返回空列表而不是乱造地址。
- **华视影院是网页播放**：拿不到可直连 m3u8（P2P 频道 key 需要它的 meshplay SDK），所以走 App 的网页播放器；如果 App 的网页播放器对该站不兼容，就只能回到源站网页看。
- **华视影院分类页没有分页**：站方一次铺完 246 部，`hasMore` 恒为 false。
- **站点改版就会失效**：这些源靠 HTML 结构/正则吃饭，源站换模板后需要按新结构改（每站文件头都写了它是怎么解析的）。失效时先在 App 里「测试连通性」，再跑 `tools/lume-source-check.mjs` 看是哪一步断了。
- **成人分区**：A123TV 有「福利」分类（站点自带），这些源不对内容做过滤，请自行按需使用。
- **栀莲短剧使用游客会话**：令牌到期或接口返回 401 时重新登录，已有游客身份按站点分别缓存。仅使用该集接口实际下发的播放地址；锁定集转源站网页显示会员或付费要求。
- **91吃瓜的图片域与站点分离**：图片在 `pic.hdhwqx.cn`（直连 200，不需要 Referer），视频清单/分片在 `op.udhhzr.cn` 与 `as.ucjosl.cn`；站点每篇都同时带图集和短片，所以分成了 `photo/91cg1.js`（图集）与 `video/91cg1.js`（短片）两个源。
- **BetaTok 的清单没法整包读**：`manifests/betatok.json` 解压后 27 MB / 34466 条，沙箱 64 MB 堆装不下；本源用 Range 分窗，所以**搜索与频道筛选只作用于当前窗口**（上限 256 KB 压缩 ≈ 2.8 千条），无过滤的翻页窗口按页数自动放大；窗口文本 5 分钟内复用。
- **BetaTok 的工具跑测会「假失败」**：`tools/lume-source-check.mjs` 验播放时会把整段 mp4 拉完，60 MB 的资源必然超时；手工用 `Range: bytes=0-262143` 复验是 `206 + video/mp4 + content-range …/60540624`。
- **BetaTok 的付费片不列**：`locked:true`（PPV，price 单位钻石）直接从列表里滤掉，不代下单。
- **绅游巴士不能按分类/标签过滤**：列表接口只吃 `page` / `pageSize` / `sort` / `keyword`（`categoryId`、`tagId`、`categoryIds` 实测全被忽略，total 恒为 5279），站点 UI 的分类芯片是前端筛的，脚本拿不到全量就没法复刻，所以只给排序 + 站内搜索。它的 `/product` 是游戏下载站（`/cloud-link/{id}` 出网盘），LumeBox 没有对应板块，没做。
- **探花视频 / 91大神 是同一套内容库**：同一 id 取到的 m3u8 逐字相同，只做**一个**源（`tanhua_video`），另一个域名进 `mirrors`；两个都做成源会在 App 里出现两份相同内容。站点没有搜索接口（`search.php`/`so.html` 403）。域名都是 IDN，`mirrors` 里必须写 punycode（`xn--91-mu9cv53j.com` = 91大神.com，`xn--dzu640eo1e2qq.com` = 探花视频.com）。
- **VIP 一律先破解再决定怎么放** —— 判定顺序、三种打法（CDN 路径可推导 / 试看签名复用 / 同库镜像）、记录要求见 [docs/VIP处理约定.md](../docs/VIP处理约定.md)；同样规则也适用于此后新增的源。
- **618 影院是「地址表 + 站群」**：`618208.xyz` 首页只有 2×5 的区表（一区…漫画），每格由脚本用 `crypto.getRandomValues()%30` 从 95 个域名码里随机挑一个拼成 `618<码>.xyz/index.php/{vod|art}/type/id/{X}.html`（去重 847 个域名）；页面文字（导航、标题）用 **XOR 0x80** 混淆、浏览器里由内联脚本还原（`幨遨襆頑`→`全部视频`），所以直接抓 HTML 会看到乱码。本源自带 xor80 解码、并会解析地址表自动挑可用域名（缓存 30 分钟）。
- **TheAVPorn 的流是浏览器抓包定位的**：游客页只有 `no-player`（观看次数受限），但真实播放请求是 `https://bytt.jb-aiwei.cc/contents/videos/{dir}/{id}/index.m3u8?ttl=…&dsc=…`；实测**整段查询串去掉仍 200**、分片 `.ts` 也不带签名、另一个 id 同规则可播 → `content()` 只用 id 拼路径（`dir=floor(id/1000)*1000`）。换分发域时改 `CDN_HOSTS`。
- **jizeyy / hsex / reddxxx 的取流方式各不相同**：jizeyy 详情页按钮指向 `?action=get&p=1`，页面里是 `jx.php?url=<真 m3u8>`，URL 解码即得直链（`play4.laoyacdn.com` 在本机出口被 RST，换网络可播）；hsex 列表页可直连但详情页一律 CF 挑战、CDN 是逐条签名（`/hls/{id}/index.m3u8` 403），reddxxx 整站 Turnstile 但 **sitemap 未被挑战**（`/sitemap-videos/{N}`，N=0 最新，4214 个分片）——这两个都按 `webplayer` 交付，由 App 内嵌浏览器过 CF 后播放。
- **爱播爱播的分类在 `__data.json` 里**：首页/搜索页的 HTML 只内嵌 12 条（旧源就停在这里），真正的分类列表在 `/category/__data.json?source=<来源>&tid=<栏目>&page=N`，是 SvelteKit 的 devalue 扁平格式（对象/数组里的整数是下标），源内写了 30 行解码；来源 11/12 的栏目同名很多，去重后 51 个分类，分页真实生效。详情路径必须带 `sourceKey`（`/<sourceKey>-<id>`），从 SSR 卡片 href 里取。发布页 `didizhi.pages.dev` 已做成设置里的「打开发布页」。
- **hsex.men 与 reddxxx.com 无法做源**：两者的详情/接口全部返回 Cloudflare「Just a moment…」JS 挑战（`cf-mitigated`），App 的 HTTP 客户端过不去，源里只能拿 403 页面；除非改走浏览器内核。
- **天撸啦接口是密文**：`/res?s=Api-xxx` 的 `list`/`data` 字段 base64 后是 AES-128-CBC（PKCS7），密钥 iv 都写在 `assets/core.js` 的混淆里，用「挂钩 `CryptoJS.AES.decrypt` 抓参数」的办法取到 key/iv 后解出明文。站点改 key 时源会抛「密文解不开（站点换 key 了？）」，届时重抓一次即可。图集/小说**没有搜索接口**（`Api-news_search` 返回 code=0）。纯文本源在 `lume-source-check` 里 `playable` 一项会报「没有给出绝对地址」（没有 URL 可探活），属工具限制，其余入口都是 ok。
- **玉羞园是 xvideos 镜像**：内容就是 xvideos 公共库，媒体走 `hls-cdn77` / `mp4-cdn77`，`secure=` token 约 1 小时失效 → 每次现取详情页；分页是 0 基（`/new/{页码-1}`、`/c/{slug}/{页码-1}`、搜索 `&p={页码}` 从 1 起），两套卡片版式（`<img data-src>` 与 `<picture><source data-srcset>`）都要兼容。
- **91热爆的 VIP 不是绕过，是 CDN 裸奔**：`/private/` 的 VIP 片页面只给 `no-player` 占位（游客还有观看次数上限），但视频文件路径可预测且签名不校验，`content()` 只用 id 拼 CDN 就拿到整片；`delivery.douyinpaly.com` 换域时改脚本顶部 `CDN_HOSTS`。
- **在线影院 / 91吃瓜 是包含关系**：J(`bb.f016video.com`) 是超集、A(`ss.99utv.com`) 是子集（A 的条目 16/20 能在 B 上取到，B 的条目 0/20 能在 A 上取到）。所以只做一个源（`f016_video`），B 做默认、A 做镜像，并且**详情 404 自动回落**——A 的 404 是「HTTP 200 + 标题 404」的软 404，脚本按标题判缺失，不能只看状态码。列表最多 100 页，更早内容靠站内 Meilisearch 搜索。

- **橘汁只拿到第 1 集**：`/api/proto/v5/*`、`/api/ex/v3/security/*` 要「公共参数」签名头（无头时 `code 500 公共参数请求头不能为空`），开放 JSON 端点里 `videos[]` 只有一条，所以长剧只能播首集。签名算法未破前，这一点改不了；列表/封面/简介/取流都是真实数据。
- **点播高清是网页播放型**：`api.php` 关了、播放页有滑块，脚本拿不到 m3u8；列表/详情是真数据，播放要在 App 网页视图里过一次滑块。它按 IP 限流（实测连抓 5 页后整站 403，几分钟恢复），所以本源刻意只做单请求、不做预抓。
- **黄果直连不通**：`huangguoai.com` 在国内直连超时（实测 `fetch failed`，走代理 200），本机复验用 `node --use-env-proxy tools/lume-source-check.mjs …`。App 里要给这个源配代理。
- **蝴蝶影院的搜索接口对脚本 503**：`/node/search` 只对带完整浏览器上下文的请求放行，`list({keyword})` 改为本地索引过滤（列表/详情访问过的条目才能被搜到），索引为空时先抓第 1 页。
- **8x8x 的内容页在随机前缀下**：真实域根路径只有 347 字节外壳，`data-body-url=/4rov3/` 才是内容页前缀（每次改版会变，源里动态取并缓存 6 小时）；**站点根路径的 `/category/1/` 会被 SPA 兜底 302 到首页**，必须带前缀。推荐流 `/json/recommend/rmd_N` 是 AES-256-GCM 密文（key 由 base64+异或派生），源内自带纯 JS 实现。分类/标签是 SSR（23 张/页、`第 X / Y 页`），站点**没有排序控件**（`?sort=`/`?order=`/`/hot/` 全被忽略或 302），源里只给「最新 / 推荐」两种真实顺序；标签只认单个（`A+B`/`A,B` 都 302），多选取第一个。镜像按站点自己公布的永久域名排：`8x.vip`（实测直连 200、同内容，主站）+ `1azm0i.qcsw2b5yf.com`（跳板，302 跟真实域）+ `8x8x.com`（官方另一个永久域名，本机 DNS 被污染未复核，只供手选）；旧跳板 `qnzu16v.u85772.com` 已 NXDOMAIN 换掉。
- **App 的 HTTP 桥不回报最终 URL**：8x8x 靠跳板域 302 到真实域，`reply.url` 在 Node 检查器里有、在 App 里没有。源里读不到最终地址时用种子域兜底（后续请求照样被 302 带走）；只按 `reply.url` 判活会让真机误报「跳板域都打不开了」。
- **四色视频的标题与链接都是站点自己的加密**：标题/分类名/菜单链接是 AES-256-CBC（key、iv 在 `/assets/js/common/encrypt.js`，**iv 只有 10 字节 + 固定后缀 `883346`**，见 `common.js` 的 `decodeString2`），卡片 href 是 `/cYc` + base64(明文路径)。明文路径（`/juqing/play-438649.html`、`/juqing/list-麻豆传媒.html`）直接可访问，所以源里**只解不拼**：链接先 base64 还原再取页，AES 用源内纯 JS 实现（沙箱没有 atob/Buffer/crypto）。站点换 key 时源会抛「标题一条都解不开（站点换加密 key 了？）」。
- **四色视频的封面别用站点自己的图片主机**：卡片 `data-base64` 指到 `base4s.0827.la`，回来的是 `data:image/jpg;base64,…` **文本**，App 图片管线不吃文本 body；但**同一个路径在媒体 CDN（`www.0734.la` / `s4.dt188.site`）上就是真 JPEG**，所以封面改用 play 页 `m3u8_host` 拼，域名随站点轮换自动跟着换。它的 `m3u8_host1`（`s5.sanheyiliao.xyz`）已 NXDOMAIN，只作备用线路，`content()` 会先探一次再决定是否回落到线路一。

## 七、免责

这些脚本只是把你本来就能在浏览器里看到的公开页面**换成 App 里的浏览/播放体验**，
不破解任何付费内容、不绕过登录、不下载不存储视频；仅供本地自用研究，请勿传播或商用。
