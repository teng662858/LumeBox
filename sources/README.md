## 2026-11-04 酷18（`comic/cool18.js`，详见 [源记录](../docs/2026-11-04_酷18综合源.md)）

`cool18_comic`：酷18（cool18.com）综合成人论坛，**综合源**（小说 / 图片 / 视频，已在
`metadata/mixed-sources.json` 登记）。进门先过年龄门 → 全部请求带 `Cookie: isok=true`。

- **分类 9 个板块**：禁忌书屋（`/bbs4/`）· 情色趣闻（`/bbs5/`）· 性趣论坛（`/bj/`）文字；
  性趣贴图（`/bbs/`）· 情色靓影（`/bbs2/`）· 私房自拍（`/bbs6/`）· 色色动漫（`/bbs7/`）·
  卡通漫画（`/enter6/`）图片；成人影视（`/bbs3/`）视频（站点要登录才有播放器，源里明确提示）
- **排序 3 档**：最新（页面内联 `const _PageData` JSON，201~261 帖/页）· 热门（`act=hot`，100 条榜单表）
  · 精华（`act=gold`，200 条）
- **筛选**：全成人区搜索 `/search.php?keyword=…&sa=全成人区搜索` 跨板块 200 条；
  板块内 `act=threadsearch` 兜底
- **正文**：`div#content-section` 的 `<pre>` —— 文字帖按 `<p></p>`/`<br>` 折行（实测 21694 字）；
  图片帖收集 `<img src>` 并给 `imageHeaders`（实测 54 张，playable 200）

## 2026-11-04 次元姬（`comic/ciyuanji.js`，详见 [源记录](../docs/2026-11-04_次元姬源.md)）

`ciyuanji_novel`：次元姬（www.ciyuanji.com，Next.js **SSR** 成人轻小说站）。**必须桌面 UA**（手机 UA 只给空壳）。
首页 `/index` 的 `regionList` 7 区块；分类用 `/tags` 的 **67 个标签**，`/tags/{id}` 给书单；
详情 `/book_detail/{id}` 给书名/作者/字数/简介/**完整目录**（实测 329 章）；正文
`/chapter/{bookId}_{chapterId}.html`。

**关键点：正文是 DES-ECB 密文**。站点 `_app` 里的解密函数是
`DES.decrypt(content, Utf8.parse(rk), {ECB, Pkcs7})`，`rk` 来自 `./config/index.ts`，
取前 8 字节 **`ZUreQN0E`** 即可（CryptoJS 用整串但 DES 只吃 8 字节）。App 沙箱没有 crypto 模块，
所以源里**内联了一份纯 JS DES**（IP/FP/E/P/PC1/PC2/S 盒 + 16 轮 + base64 + PKCS7 + UTF-8），
与 CryptoJS 结果逐字一致。

`lume-source-check` **真站点全绿**：home 7 板块 / categories 67 / list 20 / detail ok / chapters 203 /
content text 2270 字。带 `params` 密文的 `/library/card/…`、`/rank/card/…` 没做（标签已够）。

## 2026-11-04 69书吧（`comic/69shuba.js`，详见 [源记录](../docs/2026-11-04_69书吧源与次元姬卡点.md)）

`shuba_novel`：69书吧（69shuba.com，jieqi 模板，**全站 Cloudflare managed challenge + GBK 编码**）。
13 个分类 `/novels/class/{0-12}.htm` + 5 个榜单（hot/male/female/full/last）；列表取
`#article_list_content`；详情读 `h1` / 封面 / `bookinfo`（作者·分类·标签）；目录 `/book/{id}/` 一次给全
（实测 569 章）；正文 `/txt/{书号}/{章节号}` 取 `.txtnav` 里广告之后的段落；搜索
`POST /modules/article/search.php`。

**CF 走正规路子**：所有请求 403/挑战页时抛 `NEED_WEBVIEW_VERIFY`，由 App 网页视图让用户本人过校验、
之后复用 `cf_clearance`（不绕过任何校验）。页面 GBK，App 侧走 iOS 原生 gb18030 解码通道。
解析层验证方式：用真实 Chrome 过完 CF 后抓到的 HTML 离线回放五入口——
list 50 条 / detail 书名·作者·分类·标签 / chapters 569 / content 1208 字。
（无 Cookie 的 Node 打测器会停在 403，属预期。）

同批的 `ciyuanji.com` **不是 CF 问题**：书详情是 `/bookDetails?params=<24 字节密文>`，
直接打开只落回首页外壳、`__NEXT_DATA__` 里没有书的内容、也没有任何书籍接口 XHR；
API 基址已知（`/api/pc/cms`）但端点运行时拼、抓不到。卡点与需要的东西写在源记录第五节。

## 2026-11-04 禁漫天堂 · H動漫（`video/jmcomic-video.js`）· JM文庫（`comic/jmcomic-novel.js`）

详见 [源记录](../docs/2026-11-04_禁漫天堂H動漫与JM文庫源.md)。漫画源（`comic/禁漫天堂.js`）是仓库里原有的，本次没动。

**先解决域名**：`18comic.vip` / `jmcomic.me` 本机一律 `403 Just a moment...`（CF managed challenge），
公共 CORS 代理也全挂；发布页里的 **`18comic.ink` 直连 200**，所以两个源默认走 `.ink`，
`.vip` / `.me` 留在 mirrors（请求到它们会抛 `NEED_WEBVIEW_VERIFY` 并提示换镜像）。

`jmcomic_video`：H動漫 `/videos?o={mr|mv|mp|tr|md|tf}&t={a|t|w|m}&page=N`（48 条/页，排序/时间/翻页都实测生效）；
卡片 `<a href="/video/{id}/…">` + `.thumb-overlay img[data-original]` + `.video-factory/.video-view/.video-added`；
播放页内联签名 m3u8（`ms18comic-2.iiooxx.rocks/…/hls/{iphone|hd}/{id}.mp4/index.m3u8?e=&st=`），
源里按序试前 4 条、命中的放 `qualities`，实测 206 + `#EXTM3U`。

`jmcomic_novel`：禁漫小說 `/novels?o=`（单页 78 部、无翻页；`?t=` 实测 0 条 → 只给排序）；
详情 `h1` = 「[作者] 标题 | 原名」，封面 `/media/novels/{id}_tmb.jpg`；
章节 `/novelchapters/{n}`（详情页块级 `<a><li>…`，实测 14 章）；正文 `#ncc1`+`#ncc2` 两栏（第 1 章 4317 字、第 13 章 2865 字，未登录可读）。

## 2026-11-04 乐成漫画短剧（`video/lcm.js`，详见 [源记录](../docs/2026-11-04_乐成漫画短剧源.md)）

`lcm_video`：乐成漫画（lcmhx.cc，Nuxt2 SSR 的成人漫画 + AI 成人短剧站）。本源只做**已验证的短剧频道**
`/mctype/5/`（28 条/页）：条目标题在 `img title` / `.hv-title` 里，详情页 `<video data-hls-src=…>`。
**取流要绕防盗链**：`s.chigua.media` 直连 403（referer blocked），源里统一改写成站点代理
`/media.php?url=`，实测 206 + `#EXTM3U`（2302 B），分片 200 + `video/mp2t` 901 KB。
站点漫画分类的图片域 `img5.qy0.ru` 在本机出口一律 403「链接已失效」（封面域 t4.qy0.ru 正常），
拿不到就验证不了，所以漫画分类没有写进源。

同批给的 `www.ciyuanji.com`（次元姬）**没交付**：Next.js SPA，书的 id 是 24 字节不透明参数，
`__NEXT_DATA__` 只有推荐位与 SEO、没有书籍内容，`/api/book/*` 全 404，站内 JS chunk 直接 GET 返回 SPA 外壳，
拿不到接口与参数加密方式，按约定不猜接口。证据见源记录第四节。

## 2026-11-04 月亮小说（`comic/yueliang.js`）· 荔枝短剧（`video/liz.js`）

详见 [源记录](../docs/2026-11-04_月亮小说与荔枝短剧源.md)。

`yueliang_comic`：月亮小说（yueliangxiaoshuo.com，带 R-18 分区的中文小说站，全免费免登录）。
新书 `/novel/new?p=N`（30 条/页）、榜单 `/novel/ranking?mode=daily|weekly|monthly|rookie|total`
+ 分级 `r18=0|1|2`（普通 22 条 / 全部 50 条 / R-18 25 条，三档首条不同）；书 `/novel/series/{id}`
（目录 30 章/页、`?p=N`，实测一本 1385 章 47 页，源里 6 路并发）、单章 `/novel/show/{id}`
正文 `div#novel-body`、搜索 `/search/novels?q=&p=`。`r18` 只对榜单生效（`/novel/new?r18=` 实测无效），
源里只在榜单通道用它。

`liz_video`：荔枝短剧（liz01.com，Nuxt3 + SSR，AI 成人短剧）。频道 `/category/`、`/original/`、
`/featured/` + 24 个题材 `/en/tag/{slug}/`；单集 `/en/drama/{id}/ep-{n}/` 的 JSON-LD
`VideoObject.contentUrl` 是 SSR 现签的 `/api/v1/cdn/video/{uuid}/manifest.m3u8?t=&sign=`，
实测 206 + `#EXTM3U`（22,969 B master）。**封面是 AES-128-CBC 密文**（`media.lizdj009.com`，
解出来是真 JPEG），源里用 `lume-enc://aes-cbc/…` 交 App 原生解密。排序按钮是前端 JS、`?sort=` 无效 → 不声明排序。

同批给的 `www.69shuba.com` **没交付**：全站被 Cloudflare managed challenge 挡着（`/`、`/book/`、`/txt/`、
`/modules/` 全 403「Just a moment...」，各镜像同样），且页面是 GBK 系编码，本机无法在挑战之后取到真实 HTML
做五入口验证，按约定没有进 catalog/订阅。证据与后续步骤见源记录第四节。

## 2026-11-04 草榴小说视频（`video/mycall.js`，详见 [源记录](../docs/2026-11-04_草榴小说视频源.md)）

`mycall_video`：**综合站**（mycall.biz，小说 / 视频 / 图集三形态混在一个源里）。
小说频道 `/threadlist?group=RecentThread|PopularThread|HotThread` + 7 个分类（诱骗/改编/变身/乱伦/
古典情色/武侠/玄幻）；视频 `/category/6095467d69deb6073dc6d6d7?sort=`；图片 `/images?sort=`；
搜索 `/search?type=all|novel|video&q=`。排序做成筛选（最新/最多浏览/最多点赞），小说换 `group=`、
视频与图片换 `?sort=`，三处实测都生效。
帖子按 `<body class>` 分派：`novel-reader` 用 `?chapter=N` 取 `#chapter-content` 纯文本（实测 957 章）；
`video-watch-page` 走 `GET /api/v1/video/thread/{id}/play` → `manifest/master.m3u8`（200 + `#EXTM3U`）；
`image-viewer-page` 取 `data-gallery-preview` 的 960 预览图（20 张，首图 200 image/jpeg）。
⚠ 站点全站列表**单页 24 条、没有翻页参数**（`page=`/`p=` 实测被忽略）→ `hasMore` 恒 false；
小说帖子页没有封面图。

## 2026-11-04 八叉书库（`comic/8csk.js`，详见 [源记录](../docs/2026-11-04_八叉书库源.md)）

`8csk_comic`：8xsk 字站的成人小说（`8csk.org`，发布页 `8csk.xyz` 给 18 个同内容域名，全实测 200）。
按**文字小说**交付（`mediaType: novel`）。分类 `/booklist1…9`（分页是「页号 − 1」）、榜单
`/latest` `/release` `/popular` `/completed`（分页 `index_N.html`）、题材 `/genre/{slug}/`
（站点没有题材索引，30 个 slug 从书页反查；题材会覆盖分类，站点没有组合参数）。
搜索 `/e/search/index.php?keyboard=` 带 `searchid` 翻页（源里按词缓存 30 分钟）。
**正文不在 HTML 里**：章节页内嵌一次性令牌，源里回放 `POST /conapi.php`
（`url/mobile/isk/novel/chapter/t/n/sign`）取纯文本，实测第 1 章 4617 字、第 500 章 2027 字，无付费墙。
目录两个坑都处理了：顶部「最新章节」块不认（只认 `#list-chapter`）、隐藏诱饵章节
（`left:-99999px`）跳过；1001 章的书 6 路并发 5.3 秒抓完。封面在 `img.8xsk.top`（webp 实测 200）。

## 2026-11-04 91大事件（`video/91dasj.js`）· 西瓜书屋（`comic/xiguashuwu.js`）

详见 [源记录](../docs/2026-11-04_91大事件与西瓜书屋源.md)。

`91dasj_video`：Typecho + Mirages + DPlayer 的吃瓜爆料站（用户给的入口 `campus.ravwriau.cc`，
canonical 指 `91dasj.com`，同内容直连 200）。12 分类 + 24 个「标签」筛选 + 站内搜索（`/search/{词}/{N}/`
实测 12 页）；帖子详情里 1–3 个 DPlayer 的 `data-config` 直给原生 m3u8（`op.udhhzr.cn`，实测 206 +
`#EXTM3U`），多段视频全展开成章节；封面是 **AES-128-CBC 密文**（key `f5d965df75336270` /
iv `97b60394abc2fbe1`，与 91吃瓜同源），交 App 原生解密。站点没有排序参数，源里不放假选项。

`xiguashuwu_comic`：成人小说站（`www.xiguashuwu2.com`，原 simishuwu）。分类 16 个（0–15）、
筛选「默认 / 完本 / VIP」、排序「总榜 / 周榜 / 月榜」，三类实测首条互不相同；详情 `/book/{id}/`、
目录 `/book/{id}/catalog/{页}.html`（100 章/页）、正文 `/book/{id}/{章节}.html`（长章节再拆 `_2.html`，
源里顺着接起来）。**VIP 书（vipok 角标 / `isvip=1`）正文照样全量下发**，4 本书首中末章各 1.1–1.8 千字，
按普通书读。唯一缺口：第二分页的敏感词是 30×30 位图字（`/wzbodyimg/{hash}.png`，文件名与字无推导关系、
站上无字典），源里跳过这些图片字，正文主干完整。搜索 `/search/{词}` 在 Cloudflare managed challenge 后面，
挡到抛 `NEED_WEBVIEW_VERIFY`，并用浏览过程攒下的本地索引先顶着。

## 2026-11-03 懂片帝（`video/dongpiandi.js`，详见 [源记录](../docs/2026-11-03_懂片帝源.md)）

AI 找片 + 片单 + 播放的聚合前端（`dongpiandi.ai`，标题「懂片帝AI」）：React SPA + 同源 `/v1/*` JSON 接口，
首页 HTML 只有 4 KB，所有数据走接口。**每个请求都要 HMAC-SHA256 签名**
（`x-ai-movie-timestamp/nonce/signature`，msg = `METHOD\npath?query\nts\nnonce`，key 取自
`/assets/movie-card-runtime-*.js` 的 `Jo="…"`）；实测只校验这三个头，不校验客户端版本号，
站点换前端版本不影响本源。源里用宿主原生 `tools.hmac` 算，失败自动退回纯 JS 实现，
并对设备时钟偏差按响应 `Date` 做一次校正重试。

交付形态：板块 `video`，`contentCategory: movie`（同架构的看剧AI 源同口径）。分类 id 直接用站点查询串
（`kind=movie` / `sort=trending&window=day` / `hot_list_key=tv_korean` …），首页板块的「更多」由
`section.browse.params` 转成同一套编码；筛选组从 `/v1/runtime/bootstrap` 的 `catalog_ui` 实时取
（分类/地区/语言/年份/排序，短剧多「状态」「形式」两行且站点自己标了不可用）；genre 不支持多选，取第一个。

播放**不逐条探活**：站点 32 条线路里总有一两条 CDN 已挂、要等宿主 6 秒超时，串行探活会把 `content`
拖到 16 秒被判超时。改成按「站点权重 + 资源站实测稳定性」排序后直接给地址，前 5 条进 `qualities`
供切换，默认走第三方直链（`resolve_mode:"direct"`，免费不扣额度），官方 `resolve://` 票券线路
只在直链一条都没有时兜底。实测 `content` 213–899 ms、直链 206 + `#EXTM3U`，签名头与 Dart 侧
HMAC 在真 QuickJS 沙箱里逐字一致。

**v1.1.0 补上账号与线路偏好**（2026-11-03 用真实账号实测结论）：**不填账号也能用全部片库** ——
登录前后线路表逐条一致（34 条：25 直链 + 9 官方票券），连「新4K-限时等级专属」「4K海外-官方C」
这些票券线路匿名换也返回 201 + 真地址。登录只多出站内那套（`/v1/users/me/quota` 每日词元、
收藏、历史、午夜剧场且要确认 18+）。所以源里把账号做成可选：`POST /v1/users/password/login`
（字段名是 `account` 不是 `username`，登录不要验证码），会话取 `ai_movie_session=ums2_…`
存 `fs` 复用，401 重登一次，密码错只写 30 分钟 TTL 的 `login_fail.json` 不阻塞播放。
另加 `lineMode`（直链优先 / 官方优先）与设置页两个动作「检查账号与额度」「退出站点登录」。

**v1.2.0：午夜剧场没有接入**（有实测依据，不是省事）。它是站点「AI 现生成今晚片单」的玩法，
不是片库：`POST /v1/midnight-theater/playlists`（前端超时 45 秒）→ 轮询
`/generations/{id}` → `POST .../playlists/{id}/play` 拿播放请求 → 再进 `/v1/playback`，
每次生成按次扣大量词元。更关键的是**这个账号没有资格**：走完站点自己的成年确认
（`PUT /v1/users/me/preferences {"adult_confirmed":true}` → 200 返回 `adult_confirmed_at`）之后，
`GET /v1/midnight-theater/access` 仍回
`403 {"code":"midnight_theater_not_eligible","message":"当前账号暂不符合开放条件"}`，
`discovery` 同 403，`eligibility` 是 `{eligible:false}`（前端文案提到「今日生成次数」「加速升级解锁」，
是等级/灰度门槛）。没资格就拿不到任何可验证的响应结构，按写源规则不猜。所以只加了两个能验证的
动作：「确认已满 18 岁（站点账号）」和「查午夜剧场资格」（把 5 种 code 翻成人话，实测输出
「账号暂不符合开放条件（练气1层不开放）」）。资格一到，按上面那条流程接分类即可。

v1.2.0 同时修了线路选择：站点给的头几条偶尔是 403/404 的资源站（实测 `dytt-tvs` 403、
`bfeng11` 404），直接播黑屏。现在单条探活最多 1 秒、总预算 2.2 秒，只验前几条，命中就停，
全不通转官方票券，票券也没有才把第一条直链原样交出去；`content` 仍在 2.5 秒内。

**v1.3.0 把分类 / 筛选 / 排序补全**（2026-11-03 参数矩阵实测）：

- 分类 17 个、全部出内容，15 个首条唯一（重复的两个是「今日热播 / 本周热播」——榜首都是
  《嫁金钗》，站点数据本身重合，第 2 页起就不同）；分页 p1/p2/p5 三页互不相同。
  kind 分类显式带 `sort=heat_desc`：实测「不带 sort」时站点按最新出，不显式给就和「最近更新」撞首屏。
- 筛选组按分类给不同表：bootstrap 的 5 个 kind 走 `catalog_ui`；**documentary / sports
  bootstrap 里没有，但参数照样生效**，补本地表（genre 从片库反查：纪录片/音乐/历史/传记…、
  体育/体育赛事）；`all` 与两个热播分类给通用组（实测「不带 kind」时 area/year/genre 也生效）；
  7 个榜单不给组 —— 实测榜单会丢附加参数（`hot_list_key + area` 的 area 不生效、`+ sort`
  反而把榜单顶掉）。
- **多选只有地区支持**：`area=中国大陆,中国香港` 会混出两地结果，而 `genre=喜剧,爱情`、
  `language=国语,粤语` 都回 0 条。源里只对 `area` 做逗号拼接，其它组取第一个。
- 排序只认 `updated_desc` / `heat_desc`（`sort=whatever` 被丢掉）+ 榜单专用 `trending` +
  `window=day|week`；筛选里的「排序」组能覆盖分类默认（实测《空枪》→ 选「最新」变《半山腰的索玛花》）。
- 没有的维度（实测静默忽略，不做假声明）：`rating_gte` / `score_gte` / `duration_lte` /
  `is_finished` / `status` / `free` / `playable_only` / `actor` / `channel` / `region` / `lang`；
  短剧的「状态」「形式」两行站点自己标了 `enabled:false`。

**v1.4.0 把午夜剧场接成第 18 个分类**（`midnight`）：走 `discovery → play → timeline` 而不是 catalog，
`chapters()` 把 `timeline.segments` 展开成章节，`content()` 按段取 `media_sources[].url`，
`play` 结果缓存 10 分钟避免重复扣词元。**请求侧已实测打通**：`play_request_id` 必须标准 UUID v4
（纯随机 hex → `400 Invalid UUID`；改成 8-4-4-12、第三段首字符 `4`、第四段 `8/9/a/b` 后，
`random/play`、`top/play`、`playlists/{id}/play` 三个都从「400 格式错」变成「403 资格拦截」，
说明 body 形状被服务端接受）。**响应结构还没有真实样本**：账号练气1层走完成年确认后
`access`/`discovery`/`play` 全 403 `midnight_theater_not_eligible`，结构取自
`/assets/MidnightTheaterRoute-*.js` 的消费代码，解析全程防御式；资格放开后要拿一条真实片单复验。
没资格时分类会明确回报原因（不会静默返回空）。


## 2026-11-03 爱丽丝书屋（`comic/alicesw.js`，详见 [源记录](../docs/2026-11-03_爱丽丝书屋源.md)）

成人网络小说站 `alicesw.com`（全站 18+，diyquge 模板的静态 HTML，无接口无加密；发布页 `alicesw.click`，
镜像 `alicesw1.homes` 简体同源 / `alicesw.tw` 繁体）。本源按**文字小说**交付：列表与详情带
`mediaType:"novel"`，正文返回 `kind:"text"`，App 归入漫画板块的「小说」分类并打开文字阅读器。

结构要点：题材分类 `/lists/{id}.html?page=N`、总列表与「题材+排序」`/all[/id/{id}]/order/{排序}+desc.html`、
原创专区 `/original.html`、排行 `/other/rank_hits/order/hits*`（单页 30 条不分页）、
搜索 `/search.html?q=&f=_all&sort=relevance&p=N`；详情 `/novel/{id}.html`、目录 `/other/chapters/id/{id}.html`
（**一次给全**，实测 6972 章 666 KB 单页）、正文 `/book/{书号}/{章节hash}.html`。
**`/novel/{id}` 与 `/book/{书号}` 编号不同**，章节地址只能从目录页取。35 个分类 + 排序筛选
（最近更新/人气最高/字数最多，排行与原创专区不受排序影响）。详见 [源记录](../docs/2026-11-03_爱丽丝书屋源.md)。

1.1.0 补上**列表封面**：站点列表页没有封面，源里按 id 并发抓详情页取 `.imgbox img`（32 并发、
单请求 1500ms 超时、列表 2400ms / 首页 3200ms 预算），封面 URL 用 `LumeSource.fs` 缓存 12 小时、
最多 380 条。实测冷启动 `list()` 2.5s 覆盖 31/31，缓存命中 0.78s；`home()` 2.7s 覆盖 34/48（每板块前 6 条）。

## 2026-11-02 有爱爱 UAA 综合源（`video/uaa.js`，详见 [源记录](../docs/2026-11-02_UAA有爱爱综合源-VIP绕行.md)）

UAA 站群（`uaa002.com` 主用，`uaa001`–`uaa010` / `uaa2601`–`uaa2610` 共 21 个同内容域名，永久域名 `uaa.com`、
发布页 `uaadizhi.com`）是 Spring Boot SSR + JSON 接口的综合成人站：视频 / 有声 / 漫画 / 小说 四大库一个源全包，
29 个分类（视频 7 含排序与 origin 地区、有声 7、漫画 6、小说 9）。

**网页被 Cloudflare managed challenge 挡着（连 `/js/`、`/image/` 都挡），但 `/api/` 前缀不在校验规则里** ——
本源所有页面请求加 `/api/web` 前缀拿同一份 SSR HTML（列表/详情/章节/静态资源全通），取流走
`/api/video|audio/app/*` JSON，App 自带 UA 实测 200，不需要网页视图过校验。

**VIP / U币 全在前端**：视频 `code:1` 只代表「前端 60 秒试看」，`intro` 返回的 `model.url` 就是整片 m3u8
（`xc2026103109`：794 段、`#EXTINF` 合计 2381.3 秒 = 详情 `duration` 2381，分片 206）；有声 `chapter` 回
`code:1「请先登录」` 但照发 mp3；漫画章节 `price:0.3` 仍内联整话 `images`；小说「付费章节」正文照样是 SSR
的 `div.line`（页面自称「字数：N」，交付字符数与 N 完全相等）。额度记账是播满 60 秒才 POST
`/video/free/consume`，源里不调它并每次现生成 `viewId`。详见 [源记录](../docs/2026-11-02_UAA有爱爱综合源-VIP绕行.md)。

## 2026-11-02 橙涩视频（chengshe_video）

成人视频 H5（随机域名，当前 `6s9b2f4hkmbh.xyz`，发布页 `8if2pvzp.cc`）：接口全量 AES-CBC 加密，
匿名 `POST /user/tryLogin {deviceId}` 拿 token，请求 `encData`（key=iv=毫秒时间戳+000）/ 响应 `encData`
（key=iv=token 第 3–18 位倒序）；播放走 `/api/dec/m3u/ios/access.m3u8` 换 HLS。
**VIP 只锁交易（券/金币/会员），`canWatch:false` 时接口照常下发 videoUrl+access，换 m3u8 实测 200**，
无需会员态。搜索参数未公开，本源不提供搜索。详见 [记录](../docs/2026-11-02_橙涩视频源-加密链路与VIP绕过.md)。

## 2026-11-02 火力视频（video/lao4j.js，详见 [源记录](docs/2026-11-02_火力视频源与e938评估.md)）

舞艺吧系舞蹈站（web.lao4j.net，http + 独立 JSON API 主机）：擦边舞蹈/录屏短视频。列表、封面、搜索匿名可取
（标题是 HTML 实体要解码；video_id 是 11 位 YouTube ID）。**播放必须登录**：m=play 匿名一律「请登录后再操作！」，
注册要手机号+短信验证码，视频本体也不在图片 CDN 上（/vi/<id>/video.mp4 等全 404）。
所以本源把播放交给 App 内嵌网页（用户自己登录一次），list/detail/search 原生可用。

同批给的 e938ygef.com 是「果酱/小笛/香蕉…」十几个成人 APP 的**推广落地页**，站内没有内容库，未做源。

## 2026-11-02 黄色仓库（video/hsckzy.js，详见 [源记录](docs/2026-11-02_黄色仓库源.md)）

苹果CMS + ziyuan2 模板的资源站（hsckzy.vip，发布页 hsckzy.com 给 5 个备用域）：国产区/AV区/欧美区/动漫区/其他区
共 41 个分类入口（5 个大区 + 36 个叶子），6.9 万部。列表是纯文字表格（无封面，封面在详情页）。
详情页按来源分组内联地址：**「黄色仓库资源m3u8」那条是直链**（实测 master 200 → 子列表 22,550 B → 分片 200 video/mp2t 431 KB），
「黄色仓库云」是 share 网页（走内嵌网页播放），`chapters()` 把两条线路都列出来。搜索 /index.php/vod/search.html?wd= 可用（50 条/页）。

## 2026-11-02 夜社资源（video/yeshezy.js，详见 [源记录](docs/2026-11-02_夜社资源综合源.md)）

苹果CMS + panghu 模板的**综合**成人资源站（yeshezy1.com）：视频 / 有声 / 写真 / 漫画 / 小说 / 影视 七大类，
一个源全包：35 个分类入口（t1 全部 + 27 个视频/有声/写真/漫画/影视 + 7 个小说分类）。
详情页把播放地址**直接内联**（形如「第1集$m3u8」「1P$图片」），列表/详情/播放都不用再打播放页。
形态分派：视频 → kind video；有声三组 → kind audio；写真/漫画与小说 → kind webplayer
（App 视频板块只渲染 video/audio，图片与文本走内嵌网页）。HLS 实测 206 + #EXTM3U；
搜索 /vodsearch/词----------页---.html 可用（20 条/页）。采集 API /api.php/provide/vod 要授权域名，未用。

## 2026-11-02 ITsACG 漫画（`comic/itsacg.js`，详见 [源记录](docs/2026-11-02_ITsACG漫画源.md)）

Discuz + `jameson_manhua` 插件的绅士向漫画站（主站 www.itsacg.com，发布页 itsacg.top 给备用 itsacgaa123.space）。
**全匿名 GET，无登录无会员**：分类 `a=ku&category_id`（同人誌/單行本/雜誌&短篇/韓漫/3D&漫畫）、排行榜 `a=rank`、
详情 `a=bofang&kuid=`、阅读 `a=read&zjid=&nopage=1`（一次给整本图片，实测 132 张 = 分页 7×40 合并），
搜索 `a=search&keyword=`（**不需要 formhash**）。

解析踩坑：站点有**两套卡片布局**（分类页 `image-title`、排行页 `item-title`），只认一种会把 `<img>` 当标题；
详情页没有 og:image，封面取正文第一张图。大陆直连打不开主站（站点自己标注），镜像里放了备用站。

## 2026-11-02 橙涩视频 v2.2.0（`video/chengshe.js`，详见 [源记录](docs/2026-11-02_橙涩视频v2-VIP直连与短剧搜索.md)）

同站升级：**VIP/金币只是前端遮罩** —— `findVideoById` 对 `canWatch:false` 的付费片（price 5-9）照样下发 `videoUrl`，
`https://pic.tbem.org` + `videoUrl` 实测 **12/12 → 200 + #EXTM3U**（HLS 标准 AES-128，`index.key` 200/16 B），
不需要会员态也不需要买券。v2 把播放从 `/api/dec/m3u/ios/access.m3u8` 改成 **CDN 直连**（旧线路保留兜底），
并补上**短剧板块**（`/api/videoSerial/*`，整部一条播放列表，按「全集」一集处理）和**站内搜索**
（`POST /api/video/findVideoByTag {tagTitles}`，按标签命中）；首页改成排行榜 / 橙涩短剧 / 热门三个板块。\n**v2.1.0 补上「暗网」板块**：站点 `/dark-web` 页面只对「永久至尊」放开，但 `findClassifyList {needVip:true}`
与分类视频接口都不鉴权 —— 「暗网流出」(classifyId 11) 抽 3 页 36 条实测 **36/36 → 200 + #EXTM3U**（`restricted:true`/`reasonType:5`）。
**v2.2.0 把暗网板块里的分类补齐**：`findClassifyList {needVip:true}` 只回一条「暗网流出」(type=3 = SubClassify)，
站点上点进去先是 **5 个子分类**（`findSubClassify {classifyId:11}` → 圣水滋养 126 / 恐怖电影院 127 / 黄金盛筵 128 /
全球禁片 129 / 重口调教 130），子分类视频走 `findSubClassifyVideos {classifyId: 子分类 id}`。
本源对「暗网板块里 type=3 的分类」展开成独立分类项（`sc126`…，标题 `暗网 · 圣水滋养`），
顶层 11 保留（它是聚合，内容与子分类不同）。子分类抽测 20 条/页 + 封面 200 + HLS 200 + #EXTM3U。

## 2026-11-02 稳定性与起播优化

厂长资源 v1.0.3：明确识别网页校验并保留错误；详情与选集请求合并、复用 60 秒；连接失败时从官方发布页读取并验证新主地址。
可可影视 v1.0.2：动态读取站点图床、跳过详情 Logo；使用按源隔离的持久存储缓存校验会话（6 小时上限），过期重新获取；修复首次 503、重试成功仍报错；详情和选集合并请求、复用 60 秒。
播放入口移除重复媒体预检，新增解析、媒体就绪、播放进度开始三阶段耗时。实测及限制见 [记录](../docs/2026-11-02_源稳定性与起播优化.md)。

# LumeBox 视频源：站点转源结果

## 2026-11-01 六个新源（子子影视 / PPnix / 厂长资源 / 嘀嗒影视 / 多多追剧 / 爱壹帆）

详见 [源记录](../docs/2026-11-01_六源制作.md)。

- `video/ziziys.js` **子子影视**（发布页 ziziys.info；主用 ziziys.org、镜像 ziziys.net，ziziys.com 官方标注国内不可访问）：
  与 4k影视/两个BT 同一套 CMS，本源**自算 HMAC 签名**直接取 1080p m3u8（实测 200 + #EXTM3U 95,696 B）；
  4K 档站点只给客户端（403）、720 属会员（401），不绕过；分类/类型/地区/年份/标签/排序六组筛选实测可组合。
- `video/ppnix.js` **PPnix**（ppnix.com/cn）：`/cn/{movie|tv}/{类型}-{国家}-{年代}-{页码-1}-{排序}.html`，
  播放直接取站点 HLS 接口 `/info/m3u8/<id>/<集>.m3u8`（206 + #EXTM3U 205,464 B）；站点无付费墙。
- `video/czzy.js` **厂长资源**（导航页 cz01.vip → 4kcz.com）：WordPress + mibt，18 个栏目 + `paged` 翻页，
  筛选 `movie_bt_series/cat/tags/year` 实测组合生效；播放页 iframe 的 `url=` 即真 m3u8（200 + #EXTM3U 102,903 B）。
- `video/didahd.js` **嘀嗒影视**（didahd.xyz / dida.im）：苹果CMS + mytheme；列表走 `/index.php/ajax/data`（真分页 51 页）；
  明文线路直连，蓝光线路是 hex 密文（站点混淆脚本现解）→ 网页播放；网盘线路标注不可在线播放。
- `video/duoduo.js` **多多追剧**（发布页 duoduozhuiju.com，四条线路）：Vue3 SPA + `/api.php/web/*`（要 X-Client / web-sign 头）；
  分类/筛选/排序/搜索/详情/线路集数都是真数据；每集地址是令牌，解码要站点 protobuf+wasm 签名 → 网页播放。
- `video/iyf.js` **爱壹帆**（iyf.tv，同内容 aiyifan.tv / wyav.tv / flyv.tv / jssp.tv）：接口在 m10.iyf.tv，
  每个请求都要首页下发的 `pConfig` 签名（**纯 JS MD5 复现**，签名错会回「用户签名错误」）；
  电影/电视剧/综艺/动漫/纪录片 + 排行榜，筛选支持地区与连载状态；站点按出口限流（`访问过量`），源内已做 detail 缓存 + 重试。

## 2026-10-31 千千影视

`video/qqys01.js` 为千千影视公开影视目录源。支持首页推荐、电影/连续剧/综艺/动漫、公开筛选、搜索、详情、分集和站点公开播放配置；站点明确标注 VIP、积分或付费的内容会拒绝播放，不绕过授权。镜像与线路限制及实测结果见 [源记录](../docs/2026-10-31_千千影视源.md)。

## 2026-11-01 八号影视 / 可可影视（新源）

`video/bahaotv.js`（`bahaotv_video`）：八号影视。苹果CMS v10，电影/电视剧/动漫三栏，各栏独立
地区/类型/语言 + 年份 + 排序筛选（实测全生效可组合）。播放页 `player_aaaa` → 第三方 iframe →
**AES-128-CBC** 解出直链（mp4，206 可播）；详情页多条线路（实测 3 线 × 8 集）全部保留。
默认走证书匹配的 `www.bhtv001.com`（`bahaotv.com` 证书名不匹配，作镜像）。详见
[源记录](../docs/2026-11-01_八号影视与可可影视源.md)。

`video/kkys.js`（`kkys_video`）：可可影视。入口有 **cdndefend 反爬挑战**（纯 JS SHA-1 现算 PoW
自动过，首次 1-2 秒）。电影/连续剧/动漫/综艺 + 类型/地区/语言/年份/排序筛选 + 站内搜索（需页面 `t` 令牌）；
详情页最多 **37 条线路**，每条线路分集全列；播放页直出 m3u8。v1.0.2 改为读取站点 RDUL 图床配置，封面不再请求受挑战保护的主站；会话按域名和 UA 缓存，失效重取，详情/选集共用请求。

`video/libvio.js`（`libvio_video` v2.0.0）：**LIBVIO**（真实站 `www.libvio.io`；旧域名
libvio.host / www.libvio.to / libviobd.com 已停用为停车页）。站点用 CDN 浏览器校验挡非浏览器请求
（403 `x-cdn-challenge`），本源按约定抛 `NEED_WEBVIEW_VERIFY`，由 App 网页视图**由用户本人**过校验后自动重试，
不绕过任何校验。5 栏 + 地区/年份筛选 + 站内搜索；播放页 `player_aaaa` 里就是明文 mp4
（实测 206 + video/mp4，播放器 readyState=4）。详见 [源记录](../docs/2026-11-01_LIBVIO地域限制.md)。

## 2026-11-01 两个BT影视 v2.0.1 · 八号影视 v1.0.1（会员核查，详见 docs/2026-11-01_两个BT与八号影视会员核查.md）

**两个BT 的 720/480 破不了**：不是签名或前端的问题，是服务端按账号判会员。实测 `q=720/480` → `401 需要VIP会员`、
`q=4k` → `403 仅客户端`，`q=1080` 的响应里 4K 那档是 `{isvip:true,locked:true,url:"1"}` 占位值。
换清晰度编码（`q=1…5/hd/sd/fhd/2160/all/…`，只有 1080、4k 两个特判）、换客户端 UA 与 `&client/&app/&platform`、
CDN 路径推导（`m3u8/<32位hash>` 采样 6 条，md5 各种拼法全不符；加 `_720` 等后缀回 `404 token 不存在或已过期`）、
接口越权（`/api/vod` 只有统计；`/api/video/play`、`/video/playall`、`/api/app/config` 全 404；wasm 只导出 `build_play_url`）、
「影片下载」（跳 `btbtla.com`，不给磁力）、同库镜像（4k影视/子子影视 同样 401）—— 全部排除。
`/api/register` 要邮箱验证码，属于「要用户账号」，按约定不做。→ 源里只取 1080 免费档，**v2.0.1** 改成按清晰度从高到低挑、
`content()` 多给 `qualities`、401 拆成「整片会员专享 / 只是清晰度要会员」两种文案，文件头写清整张排除表。

**八号影视没有会员墙**：抽样 8 条首集播放页全是 `trysee=0 / points=0`，iframe 配置解出来就是完整 mp4
（206 + video/mp4 + `ftypisom`）；`/label/vip.html`、`/user/index.html` 都是「网站维护中」，站点不卖会员。
**v1.0.1** 只补核查记录，播放逻辑不动。

## 2026-11-01 两个BT影视 v2.0.0（bttwo_video，详见 docs/2026-11-01_两个BT影视源升级.md）

`video/bttwo.js`：两个BT影视（发布页 https://bttwo.vip/；实测可用域名 bttwo.life / .org / .top / .me，旧的 bttwoo.com、bttwo.net 已失效）。与 4k影视同一套 CMS，但**本源自己算播放签名、直接拿 m3u8**：播放页每个分集有自己的 slug 与 dataid，`s = HMAC-SHA256(key=slug, msg="dataid:t:slug")[:32]`、`k = base64(xor("nbmovie2024secretkey", userlink))`（游客 userlink 页面上就有，`k=0` 亦可）。站点只把 **1080p 免费**开放给游客，720/480 需 VIP、4K 仅官方客户端，本源只取 1080，不绕过付费墙。分集逐项可播；筛选 `classify/types/areas/years/tags/sort_by` 六组实测生效且可组合。

## 2026-10-31 两个BT影视（v1.0.0 历史记录，详见 docs/2026-10-31_两个BT影视源.md）

`video/bttwo.js`：两个BT影视（发布页 bttwo.vip；bttwo.life/.org/.top/.me、bttwoo.com、bttwo.net）。与 4k影视同一套 CMS（`/play/ch…`、`/filter?page=N`、同一份 `nbmovie_wasm`）：全部影片/电影/剧集/动漫 + 站内搜索；播放地址由站点 wasm 现算签名 → `content()` 打开 `/play/<slug>`（网页播放器，选集在页面里点）。

## 2026-11-01 歪比巴卜 v3.0.0（wbbb_video，详见 docs/2026-11-01_歪比巴卜源v3.md）

`video/wbbb.js` 现在**原生直链**，不再走网页播放器。播放地址是两层加密，两层都在源里用纯 JS 复现：

1. **拿载荷**：`Q = 密文 + '&next=' + …`、`key22 = md5(Q) 后 20 位 + ' P'`、
   `key = base64(rc4(key22, md5(Q+'stray')))`、`ckey = base64(rc4(key22, md5(播放器域名+'stray')))`，
   `POST https://xn--qvr2v.850088.xyz/player/api.php`（key/ckey 错一个就 404，vkey 不校验）；
2. **解媒体地址**：`K = rc4(key22, atob(aes_key))`、`IV = rc4(key22, atob(aes_iv))`，
   再 `AES-128-CBC(PKCS#7)(atob(resp.url), K, IV)` —— **坑是 aes_key/aes_iv 要先过一遍 RC4**，
   直接当 AES key 解出来是乱码。

实测：电影整片 mp4（`wxs…stodownload…filename=BBA.mp4`，206 + video/mp4，976 MB）、
剧集 HLS（`…/醉梦EP01.m3u8`，206 + #EXTM3U 40,452 B）。`content()` 先试直链，解不出才退回网页播放器。
章节按「线路 × 分集」全量展开（高清C · 1080P / 蓝光B · 1080P / BF有广 · HD …）。
站点对高频请求回 429，连续验证要间隔几十秒。

## 2026-11-01 歪比巴卜 v2.0.0（wbbb_video，详见 docs/2026-11-01_歪比巴卜源v2.md）

`video/wbbb.js`：歪比巴卜（发布页 xn--clr79vmzkema.com；节点 wbbb1.com / v.wbbb1.com / www.wbbb1.com）。
苹果CMS v10 主题站：栏目 `/show/{1-4}-----------.html`（真翻页）、详情 `/detail/{id}.html`、播放 `/vplay/{id}-{线路}-{集}.html`。
首访 403 Cookie 门（源里自动重试一次）。**v2 改掉了「打开详情页」的老做法**：

- 详情页 `#y-playList` 的播放源 tab（高清C / 蓝光B / BF有广 / LZ有广…）与分集面板按顺序配对，
  **线路 × 分集全部展开成章节**（`高清C · 1080P · 第 1 集` …）；
- `content()` 读出这一集 `player_aaaa` 的密文与 `link_next`，拼出站点自己的播放器地址
  `https://xn--qvr2v.850088.xyz/player/?url=<密文>&next=<下一集>&title=<标题>` 交给 App 网页播放器 ——
  **点哪一集就直接打开那一集的播放器**，不再落回详情页；
- 解析接口的签名也逆出来了（`key22 = md5(Q) 后 20 位 + ' P'`、`enplay = base64(RC4(key22, md5(Q+'stray')))`、
  `ckey` 用播放器域名，`aesplay` 就是标准 RC4），实测能拿到 `{"code":200,...}` 的播放载荷，
  但载荷里的媒体地址是站点 `aes_key/aes_iv` 二次加密的，这一层未破 → 仍走网页播放器，不伪造 `video()`。
- 站内搜索被 WAF 拦 → 用本地索引（浏览过的条目可搜）。

## 2026-10-31 歪比巴卜 v1.0.0（历史记录，详见 docs/2026-10-31_歪比巴卜源.md）

`video/wbbb.js`：歪比巴卜（发布页 xn--clr79vmzkema.com；节点 wbbb1.com / v.wbbb1.com / www.wbbb1.com）。
苹果CMS v10 主题站：栏目 `/show/{1-4}-----------.html`（真翻页）、详情 `/detail/{id}.html`、播放 `/vplay/…`。
首访 403 Cookie 门（源里自动重试一次）；播放地址由站点前端现算签名（解析服务对出口有限制），
**多条线路交给站点自己的选择界面** → `content()` 打开 `/detail/{id}.html`（线路 + 分集都在那一页换）；
站内搜索被 WAF 拦 → 用本地索引（浏览过的条目可搜）。

## 2026-10-31 4k影视（fourk_video，详见 docs/2026-10-31_4k影视源.md）

`video/4kvm.js`：4k影视（发布页 4kvm.site；9 个同内容域名，主用 www.4kvms.org）。Alpine SSR 站点，
栏目 `/movie` `/tv` `/anime`（服务端单页）+ 全量片库 `/filter?page=N`（30 条/页真分页）+ 搜索 `/search?q=`。
**播放地址由站点的 wasm 现算签名**（`/video/play?...&s=<hmac-ish>&t=`，改 s 即 403），
本源不复制签名 → 播放交给 App 的网页播放器（打开源站 `/play/<slug>`，选集在播放器里点）。

## 2026-10-31 看剧AI（kanju_ai_video，详见 docs/2026-10-31_看剧AI源.md）

`video/kanju-ai.js`：看剧AI（主站 kanju24.com，镜像 kanju.ai / kanju13.com / www.kanju24.com）是 React SPA，
数据全走同源 `/v1/*`，每个请求要 **HMAC-SHA256 签名**（key 与算法从 `movie-card-runtime-*.js` 挖出，
源内纯 JS 实现）。5 个分类（电视剧/电影/动漫/综艺/短剧）+ 分类/地区/语言/年份/状态/形式/排序筛选（从
`/v1/runtime/bootstrap` 实时取）+ 站内搜索。
播放先走**第三方直链**（`resolve_mode:"direct"`，实测占 25/34 条，m3u8 直连、不需要登录、不扣额度，逐条探活后
把可用线路放进 `qualities`）；直链全挂时才用官方票券线路（`POST /v1/users/anonymous` 拿游客 Cookie →
`POST /v1/playback/resolve-line`），每集扣 30000–60000 token，游客 900000/天。

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
├── haijiao.js     海角（www.haijiao.com）Vue2 SPA + /api，三重 Base64；**匿名只给线路名不给地址** → 播放走 webplayer(/watch?id=)，填账号后可取原生地址
├── aido8.js       爱豆（ww15.aido8.icu）  /awsapi 加密 JSON；匿名整片；封面是反转 JPEG（占位图）
├── tangtoutiao.js 汤头条（p1.wgbqoiqv.com）Nuxt 壳 + 独立接口域，AES-256-CFB 签名；付费仅 ~2 分钟试看
├── h4dh3.js       hxc（壳域 jhqjg.com / 9zx3x.com）**VIP 真破解**：getPreUrl 签名只覆盖路径，删 start/end 即整片；接口主机从 H5 包 `VUE_APP_API_BASE_URL` 自发现
├── lxxlxx.js      LXXLXX（zhs.lxxxxlxxx.com）繁中短片站；`/vjs` 三段链取 mp4；源站 2026-11-02 全球挂（CF 522），脚本按 mirrors 自动换台
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
├── d9y1w.js       四色视频（www.m9y7a.top，3 天换域名）maomi 模板站；标题 AES-256-CBC、卡片链接 base64 混淆，播放 m3u8 直链；
│                  v1.2.0 换域名自愈两条腿：旧域 302 的最终地址 reply.url 取 origin 探活 + 站方跳转服务 good.0827.la 兜底
├── akmh.js        18ak漫画·视频（www.18akmanhua.com，来自「暮色」App 内置源）接口 /api 带 md5 签名 + AES-256 响应密文；
│                  v1.1.0 起改用宿主原生 tools.digest / tools.aes（不再手写纯 JS，源 10 KB）；
│                  /videoLists 1531 条（type 0=漫画改编 1=真人）、付费片 pay_url 直发可播，m3u8 实测 200 + #EXTM3U
├── kkav.js        KKAV（www.32auqm.com；37tmrj → 73tfhk → 85fazc → 32auqm）成人视频站；接口 XOR2 加密（源内纯 JS 解）、
│                  列表自带 mp4 直链（down.baidu.com 改写为 down.mm7878.com，206）；v1.2.0 从旧域跳板页
│                  `url2.push("新域")` 自愈（旧域换域后 /api/* 直接 406），SEED_HOSTS + JUMP_HOSTS 两段式发现
├── x8x8.js        8x8x（8x8x.fun / 随机跳板域）SPA 外壳 + bodyRoot 内容页；频道/标签 SSR、推荐流 AES-256-GCM，播放三线路 HLS
├── pornbest.js    第一女優網 / PornBest（www.pornbest.org，镜像 www.av01.org）Yii2 SSR + video.js；**需代理**；大陆出口 302 到封锁页，另有 CDNLah WAF 的 PoW（源内纯 JS SHA-256 自动解）；详情页 `<source>` 直给 m3u8
├── 91pornplus.js  91PornPlus（91pornplus.com 站群）Angular SPA + 单入口 `POST /js`；响应 AES(passphrase=xxx) 密文（源内纯 JS MD5+AES-256-CBC），**接口域名国内直连**，匿名给 m3u8
├── pornlulu.js    Pornlulu / 撸撸（www.pornlulu.net，镜像 .com 同库）Yii2 SSR；**需代理**，CDNLah WAF 的 PoW 自动解；栏目 /cat/<id>、排序 sort、搜索 ?q=、播放 m3u8
├── 9188porn.js   9188色情网（www.9188porn.com）macCMS；**需代理**；列表直链播放页，player_aaaa 给 m3u8
├── mtav.js       蜜桃视频（mtav.art）macCMS/TKTube；**需代理**；/vod/show/id/<N>/ 三区、搜索 /vod/search.html?wd=（导航里的 tmav.art 是天美AV，不同站，不作镜像）
├── heroero.js    HeroEro（heroero.com）KVS；**需代理**；/latest-updates/、/categories/<slug>/，详情 flashvars 直给 mp4（Range 1KB）
├── qinav.js      Qinav（www.qinav.com）；**需代理**；/site/5/<N>-<P>.html 分类分页、/search.html?wd=，embed 页 const url 给 m3u8
├── kpkuang.js    看片狂人（kpkuang.com，镜像 www.kpkuang.one / kpkuang.one）macCMS「vfed」；48 条/页真分页，国产剧/短剧/电影分类型共 16 组；
│                 单条 4–26 条线路（4K/2160P、1080P、睿映HD、720高清云…），`data-play` 前缀+base64 → m3u8 直链，外链线路转 webplayer；
│                 搜索走站点 JSONP 接口（/vodsearch 被 Cloudflare 挡）
├── gimy.js       劇迷（gimy.org，海外镜像站）Bootstrap SSR；大陆/港/台/韩/日/美 + 电影/综艺/动漫 9 组，24 条/页；
│                 单集 13–27 条 m3u8 线路（`/_gimy_plays/{id}/{ep}`），源内按顺序探活前 4 条再定默认线
├── bfzy.js       暴风资源（bfzyapi.com）苹果CMS v10 JSON 接口；17 万条库、**分钟级更新**（比聚合站更快出片），国产剧 9228 条；
│                 叶子分类 16 组 + 搜索；`vod_play_url` 即 m3u8（实测 1080P），chapterId 直接编 URL，播放零额外请求
├── zy360.js      360资源（360zy.com）同套苹果CMS 接口，片库与暴风互补；7.4 万条、国产剧 4551 条，master 实测 `RESOLUTION=1920x1080`
└── yingshidao.js 影视岛（tv.yingshidao.com，面向海外）**条目带 has4k 字段**（真 4K 档位，电视剧首页 20 条里 12 条有 4K）；
                  8 类 + 类型/地区/年份筛选 + 搜索全走开放接口；v2.0.2 统一网页播放并保留所选集数，游客额度耗尽需在网页正常登录，会员/4K 以站点实际权益为准
```

- `video/kanju-ai.js` —— 看剧AI（kanju24.com；镜像 kanju.ai / kanju13.com / www.kanju24.com）：
  React SPA + 同源 `/v1/*` 接口，**每个请求要 HMAC-SHA256 签名**（key 来自 `/assets/movie-card-runtime-*.js`，源内纯 JS 实现）；
  分类 = kind（电视剧/电影/动漫/综艺/短剧），筛选从 `/v1/runtime/bootstrap` 实时取；
  播放默认走第三方直链（m3u8 直连、不登录、不扣额度），官方线路兜底时用游客会话换票券（扣 30000–60000 token/集）。

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
| 海角 | 否 | 3 块 | 9 分类 + 6 组筛选 | 20 | 20（`keyword`） | ok | 3 线路 | **video（帖子视频：登录即得 m3u8，探活 206 + `#EXTM3U`）/ webplayer（视频中心收费片走 /watch?id=）** |
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
| 四色视频（18+） | 否 | 3 块 | 27 分类 | 20 | 30（剧情/视频/精品三频道合并） | ok | 2 线路 | **video（m3u8 直链 + AES-128 key 与分片同域，实测 200 + `#EXTM3U` 32.9 KB）** |
| 8x8x（18+） | **是** | 2 块 | 5 频道 + 12 组标签 | 23 | 28（`/api/search/video`） | ok | 3 线路 | **video（`data-route1..3` + `data-m3u8`，探活 200 + `#EXTM3U` 158 B master）** |
| 第一女優網（18+） | **是** | 2 块 | 51 分类 | 48 | 24（`/q/<词>`） | ok | 1 | **video（详情页 `<source>` / ld+json `contentUrl` → `voddadaizi5.com:…/index.m3u8`，探活 200 + `#EXTM3U` 300 KB）** |
| 91PornPlus（18+） | 否 | 2 块 | 12 栏目 | 24 | 24（`/searchSevenVideos`，time/views 两种排序） | ok | 1 | **video（`POST /js` 加密接口 → 详情 `m3u8s[0]` = `tm.pppsuccess.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| Pornlulu（18+） | **是** | 2 块 | 69（3 排序 + 66 分类） | 48 | 50（`/?q=<词>`；表单 name=q） | ok | 1 | **video（`<source>` → `2609.lajiao2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`；WAF 弹 492 时自动解 PoW）** |
| 9188色情网（18+） | **是** | 1 块 | 19 | 20 | 20（`/vod/search.html?wd=`） | ok | 1 | **video（播放页 `player_aaaa` → `2609.senlin2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| 蜜桃视频（18+） | **是** | 1 块 | 4（3 区 + 全部） | 12 | 12（`/vod/search.html?wd=`） | ok | 1 | **video（播放页 `var uul` → `t36.cdn2020.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| HeroEro（18+） | **是** | 2 块 | 23 | 40 | 55（`/search/<词>/`） | ok | 1 | **video（详情 `flashvars.video_url` → mp4 `/get_file/…`，Range 206 + video/mp4）** |
| Qinav（18+） | **是** | 2 块 | 18（2 排序 + 16 分类） | 52 | 52（`/search.html?wd=`） | ok | 1 | **video（`/embed/<id>.html` 的 `const url` → `2609.lajiao2026.com/…/index.m3u8`，探活 200 + `#EXTM3U`）** |
| 麻豆TV（18+） | **是** | 1 块 | 60 频道（麻豆/糖心/蜜桃/天美/SWAG/JVID…） | 24 | 0（接口无搜索） | ok | 1 | **video（/video/listcache 条目自带 ideo_url → m3md.n6uem8.xyz/…/index.m3u8，探活 200 + #EXTM3U；接口 AES-256-CBC + md5 签名）** |
| 蜜桃网（18+） | **是** | 1 块 | 2 列表（今日/热门）+ 9 分类 | 40 | 23（/search/<词>/） | ok | 1 | **video（详情 data-config.video.url → hls.ohjzmm.cn/videos5/…/index.m3u8，探活 200 + #EXTM3U）** |
| 蜜桃视频（18+） | **是** | 1 块 | 6 频道（国产/日韩/网黄/欧美/AI剧/动漫）+ 最新/推荐 | 20 | 0（无搜索） | ok | 1 | **video（/play/<id> 的 APP_DATA → p.xionganzhengwu.com/…/video.m3u8?sign=，签名 md5(path-ts-rand-0-密钥) 已在源内复刻，探活 200 + #EXTM3U）** |
| 看片狂人 | 否 | — | 16 组（国产剧/港台剧/日韩剧/欧美剧/海外剧/台剧/泰剧/韩剧/短剧细分/电影分类型/综艺/动漫/纪录片） | 48 | 15（站点 JSONP 接口，`/vodsearch` 被 CF 挡） | ok | 4 线路 | **video（`data-play` 前缀+base64 → `svip.ryiplay18.com/…/index.m3u8`，探活 200 + `#EXTM3U` 1080x608）；外链线路（腾讯/优酷/B站/Abyss/mixdrop）转 webplayer** |
| 劇迷 | 否 | — | 9 组（大陸/港/台/韩/日/美剧 + 电影/综艺/动漫） | 24 | 24（`/search?q=`） | ok | 1（集内 13–27 线路） | **video（`/_gimy_plays/{id}/{ep}` → `bfikuncdn.com/…/index.m3u8`，源内探活前 4 条，200 + `#EXTM3U` 1920x1080）** |
| 暴风资源 | 否 | — | 16 叶子组（国产剧/各国剧/动作·剧情·科幻片/国产动漫/综艺/短剧细分） | 20 | 20（`?wd=`） | ok | 全部分集 | **video（`vod_play_url` → `v.fengbao14.com/…/index.m3u8`，206 + `#EXTM3U`；分片 ffprobe 1920x1080 h264，分钟级更新）** |
| 360资源 | 否 | — | 16 叶子组（国产剧/各国剧/电影类型/国产动漫/综艺/短剧细分） | 20 | 20（`?wd=`） | ok | 全部分集 | **video（`vod1.maowushi.com/…/index.m3u8`，200 + `#EXTM3U` `RESOLUTION=1920x1080`）** |
| 影视岛（4K 库） | 否 | — | 8 类（电视剧/电影/动漫/综艺/短剧/微剧/纪录片/少儿）+ 类型·地区·年份筛选 | 20 | 20（`/api/v1/video/search`） | ok | 全量分集 | **webplayer（`/video/<id>?play=1&ep=<episode_id>`）**：v2.0.2 不预发游客播放请求；游客额度耗尽需网页登录，会员/4K 按账号实际权益开放 |
| **有爱爱 UAA（18+·综合）** | 否 | 5 板块（视频/有声/漫画/小说/排行） | 29 分组（视频 7 + 有声 7 + 漫画 6 + 小说 9） | 视频/有声/漫画/小说各 48（排行 100） | 20（`/api/video/app/video/search`，仅视频库） | ok | 视频单集 / 有声分集 / 漫画整话 / 小说全章 | **video·audio·images·text 四形态齐全**：视频 m3u8 实测 200 + `#EXTM3U`（整片 2381 秒 = duration）；有声 mp3；漫画 48 张 webp/jpg 首图 200；小说正文逐段。**页面直连被 CF 挡，走 `/api/web` 前缀绕过校验；VIP/U币 只在前端，接口给全量** |

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
- **有爱爱的 `/api/` 是唯一通路**：站点根路径（含 `/js/`、`/image/`）都在 Cloudflare managed challenge 后面，只有 `/api/` 前缀放行 —— 页面侧一律加 `/api/web`，取流走 `/api/video|audio/app/*`。哪天站方把 `/api/` 也纳进校验，源会抛 `NEED_WEBVIEW_VERIFY`。JSON 接口（`intro` / `chapter`）必须带 `viewId`，否则回「非法操作」；额度记账靠播满 60 秒 POST `/video/free/consume`，源里不调它、每次现生成 `viewId`，所以 60 秒试看与每日 10 部/话额度都不生效。站内搜索只有视频库可用（`/api/comic|novel|audio/app/<svc>/search` 一律 500）；排行页固定 100 条不吃 `page`。小说分类跑测时 `playable` 会报「没有给出绝对地址」，属工具对纯文本载荷的限制。
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
- **4k影视是「网页播放型」**：播放地址由 `/static/wasm/nbmovie_wasm.js` 现算签名（`s` 只随 dataid/slug/t 变，
  改任何一位 → 403），salt `nbmovie2024secretkey` 已取出但算法在 wasm 里、沙箱跑不了 wasm，
  所以 `content()` 返回 `webplayer`，由 App 打开源站 `/play/<slug>` 播放（实测 m3u8 200 + `#EXTM3U`）。
  另外：`/movie` `/tv` `/anime` 服务端只有一页，要翻页用「全部影片」（`/filter?page=N`）；搜索首次直连会返回 0 条，
  源里会先摸一次首页拿会话 Cookie 再重搜。
- **看剧AI 的播放靠两套线路**：默认用第三方资源站的 m3u8 直链（实测 25/34 条，免费、不需登录，源里逐条探活挑可用的）；
  直链全挂时才换官方票券线路，需要游客会话（`POST /v1/users/anonymous`，同一 anonymous_id 复用同一账号）并按集扣
  30000–60000 token，游客额度 900000/天（约 15–30 集），用尽后给可读错误。**签名 key 轮换**时接口返回
  `invalid_request_signature`，把新 `main-*.js` 里的 `lo="…"` 抄进 `SIGN_KEY` 即可（源里不写站点版本号，发版不影响）。
- **四色视频的标题与链接都是站点自己的加密**：标题/分类名/菜单链接是 AES-256-CBC（key、iv 在 `/assets/js/common/encrypt.js`，**iv 只有 10 字节 + 固定后缀 `883346`**，见 `common.js` 的 `decodeString2`），卡片 href 是 `/cYc` + base64(明文路径)。明文路径（`/juqing/play-438649.html`、`/juqing/list-麻豆传媒.html`）直接可访问，所以源里**只解不拼**：链接先 base64 还原再取页，AES 用源内纯 JS 实现（沙箱没有 atob/Buffer/crypto）。站点换 key 时源会抛「标题一条都解不开（站点换加密 key 了？）」。
- **四色视频的封面别用站点自己的图片主机**：卡片 `data-base64` 指到 `base4s.0827.la`，回来的是 `data:image/jpg;base64,…` **文本**，App 图片管线不吃文本 body；但**同一个路径在媒体 CDN（2026-11-01 实测 `4sv.0827.la` / `s4.dt188.site`）上就是真 JPEG**，所以封面改用 play 页 `m3u8_host` 拼，域名随站点轮换自动跟着换。老的 `www.0734.la`（连不上）与 `s5.sanheyiliao.xyz`（NXDOMAIN）已从兜底里去掉。
- **四色视频 3 天换一次域名，脚本会自己去问站方要当前域名**：官方 `/help/help.html` 写明这点，并给出长期地址 `https://www.zie2.com` 和找回邮箱 `liumangtu@mail.com`。旧域还在响应，但**整站 302 到新域的 `/enter/index.html`**——脚本靠**页面形态**（有 `enter-content` / `qrcodeSmall`、没有 `video-item`）认出这张「进入页」，先按 `MIRRORS` 换台（成功的主机缓存 12 小时，`host.json`）；已知域名全废时走**域名自发现**：请求站方跳转服务 `http://good.0827.la/?u=<b64 种子>&p=<b64 路径>`（种子用永久地址 `zie2.com` 或跳板 `af284.com`；用站点自己的域名当种子只会回 `code:1007`），宿主把跟随 302 后的最终地址放进 `reply.url`，取 origin 再探活首页，能开就记下来（`discover.json` 记失败退避 10 分钟）。这台机器的证书已过期，所以走 http。当前可用：`www.y1c5w.top`（主）、`www.q5h7m.top`（镜像）。

## 七、免责

这些脚本只是把你本来就能在浏览器里看到的公开页面**换成 App 里的浏览/播放体验**，
不破解任何付费内容、不绕过登录、不下载不存储视频；仅供本地自用研究，请勿传播或商用。

### 综合源的文字小说与类型分流

综合站可以在同一源里返回小说、漫画、视频。身份头使用 `contentTypes` 数组声明实际支持的两种或更多内容类型（`video`、`comic`、`novel`、`photo`、`audio`）；成人综合源仍须保留 `contentCategory: "adult"`。已验证的综合源还需登记源仓库 `metadata/mixed-sources.json`，生成独立综合订阅，同时保留在原有视频订阅中。列表/详情应提供 `mediaType: "novel" | "comic" | "video"`，章节分别返回 `text` / `images` / `video` 载荷；缺少明确类型时 App 按实际章节内容识别。小说必须提供目录和正文，不得把简介或网页链接当正文。源的存储归属仍是现有 `video` / `comic`，不新增 `novel` 板块标识。见 [小说与综合源说明](../docs/2026-11-02_小说阅读与综合源类型识别.md)。

## 2026-11-03 阅读归类与声明修复

漫画、美图、文字小说、有声与 Kazumi 统一在漫画板块；TVBox 在视频板块独立显示。`novel` / `audiobook` / `kazumi` 分类对应漫画存储归属，普通视频仍归视频。火力视频 `lao4j_video` 2.0.1 将密码字段改为受支持的 text 类型，敏感输入由 App 遮挡。单个源声明错误不再中断整份订阅的后续导入。见 [本次变更说明](../docs/2026-11-03_阅读分类与抽屉交互.md)。


## 2026-11-03 PY 合集订阅

用户提供的 PY 合集按完整内容去重后，304 份通过当前生产宿主离线加载，已接入独立 PY 总订阅和现有总订阅；13 份加载失败脚本保留在 archive/python，不自动安装。详情、验证边界及 4kyingshi.net 的 HTTP 403 排查见 [合集记录](../docs/2026-11-03_PY合集入库与4K源排查.md)。离线加载不代表逐站播放可用。

2026-11-04 在受限实站复核后移除 8 份持续空列表或 404 的源，并移除 5 份重复源，现余 291 份；有声源和 Spider 父类初始化的宿主兼容修复需更新 App。证据与边界见 [PY 源可用性排查](../docs/2026-11-04_PY源可用性排查.md)。


## 2026-11-03 小说封面与源图标

爱丽丝书屋 1.1.1 改善慢线路列表补图并复用详情封面；App 小说详情页补上实际封面控件。蚂蚁搬运 1.0.1 声明站点图标。验证与生效范围见 [修复记录](../docs/2026-11-03_小说封面与蚂蚁源图标修复.md)。

## 2026-11-03 爱丽丝访问错误分类

爱丽丝书屋 1.1.2 区分真实网页挑战与普通 HTTP 拒绝/限流，并在普通 403 时尝试已知正文镜像；会话内复用可用镜像。真正挑战仍需网页验证。见 [本聊天验收记录](../docs/2026-11-03_本聊天验收清单.md)。
