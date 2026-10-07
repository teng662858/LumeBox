# LumeBox 扩展源集合

本目录包含为 LumeBox 项目编写的扩展源脚本。

## 📦 包含的扩展源

### 1. 99xs_novel.js - CA情色小说源
- **类型**: 小说 (type: 0)
- **网站**: https://99xs.sbs
- **说明**: 基于 WordPress 的小说网站，支持分类浏览和搜索
- **特点**:
  - 无需认证
  - 支持多个分类（乱伦、人妻、校园等）
  - 单章节小说

### 2. daniao5_comic.js - 大鸟禁漫源
- **类型**: 漫画 (type: 1)
- **网站**: https://daniao5.com
- **说明**: 成人漫画网站，基于 MacCMS 系统
- **特点**:
  - 高清图片
  - 多章节支持
  - 懒加载图片处理

### 3. gztv5_video.js - 瓜子影视源（部分支持）
- **类型**: 视频 (type: 2)
- **网站**: https://gztv5.com
- **说明**: 基于 Nuxt.js 的视频网站
- **当前状态**:
  - 分类和首页首屏列表使用已确认的 `/Pc` POST API
  - 搜索在首屏结果内过滤
  - 详情、选集和播放接口仍因站点加密协议未实现而明确报错

### 4. dage_video.js - 大哥视频源（暂不支持）
- **类型**: 视频 (type: 2)
- **网站**: https://dage.one
- **说明**: 基于 Vue + Element Plus 的视频网站
- **当前状态**:
  - 已保留站点元信息和分类接口
  - 站点 API 返回自定义加密数据，列表、详情、选集和播放会明确提示未支持

### 5. vv3nwjk_video.js - 金牌影院源（受站点 WAF 限制）
- **类型**: 视频 (category: `video`)
- **网站**: https://www.vv3nwjk.com
- **说明**: Next.js 前端 + 自建 JSON API（`/api/mw-movie/anonymous/**`）
- **已实现**（逻辑均已独立验证）:
  - 完整还原了站点请求签名：`t = Date.now()`，`sign = sha1(md5(参数&key=<SIGN_KEY>&t=<t>))`，
    用线上抓包逐个核对通过（3/3 命中）
  - 纯 JS 的 MD5 / SHA1（沙箱无 Node crypto / atob），标准向量 + 站点真实签名双重校验
  - 分类、双列分页、搜索、详情、选集、多清晰度播放地址
  - `deviceId` 用 `LumeSource.fs` 持久化
- **当前状态（重要）**: 站点整站（含 API）挂在 **OKooK-CDN 的 Google
  reCAPTCHA v3 WAF** 后面，未过验证的 HTTP 客户端一律 `521`。该放行状态绑定
  「完成验证的浏览器会话 + 服务端信誉」，**不落在可读 Cookie 上、也无法被
  HTTP 客户端复现**（实测：curl / Node / curl_cffi 模拟各浏览器指纹全部 521；
  `curl_cffi` 不行、真实浏览器带 Electron UA 却能过；把浏览器 Cookie 拷给
  curl 仍 521）。
  - 结论：脚本在 LumeBox 沙箱里直连会稳定返回 `521`，脚本对这种情况给出
    点名到原因的中文提示（不会再只报「HTTP 521」）。
  - 出路：在同一网络放一个「已过 WAF」的代理/桥接，把 `SITE_URL` 指过去
    （参见 `docs/lumesource-guide.md` 附录 B 的远端代理模式）。

### 6. luttt_video.js - 北觅影视源
- **类型**: 视频 (category: `video`)
- **网站**: https://v.luttt.com
- **说明**: MacCMS-10 + conch(hl) 模板，服务端渲染 HTML，直连可用
- **已实现**:
  - 分类（`/vodtype/{id}.html`）、分页列表（`/vodshow/{type}--------{page}---.html`）
  - 关键词搜索（`/vodsearch/{kw}----------{page}---.html`）
  - 详情（`h2.hl-dc-title` / `hl-dc-pic` / 影片信息逐条解析）
  - 选集（`ul#hl-plays-list`，支持多线路多集）
  - 播放地址：解析 `/vodplay/{id}-{line}-{n}.html` 里的内联 `player_aaaa` JSON 取 m3u8
  - 内置 `home()` 多板块首页、Cloudflare 兜底 `NEED_WEBVIEW_VERIFY`
- **状态**: 已用真实站点实测通过（列表/搜索/详情/选集/播放，含 18 集剧集）

### 7. p5mh_comic.js - P5漫画源
- **类型**: 漫画 (category: `comic`)
- **网站**: https://www3.6p5mh3.click （规范域 p5mh.com）
- **说明**: 成人韩漫站，服务端渲染 HTML，直连可用
- **已实现**:
  - 列表（`/booklist?page=N`，可叠加 `area` / `end` 筛选；`area=1` 韩漫、`end=1` 完结优选）
  - 搜索（`/search?keyword=`）与分页
  - 详情（`h1` / `p.content` 简介 / `p.subtitle` 作者别名 / `p.tip` 状态地区 / 标签）
  - 章节图片：`img.lazy[data-original]`（cfpic imgBridge 代理图）
  - **一章可能多页**：`?page=N`，以 `#nextPage` 是否存在判断翻页，自动拼接全部图片
  - 内置 `home()` 多板块首页
- **状态**: 已用真实站点实测通过（详情 7 话、单话 60 图 = 4 页拼接）

### 8. xxiaoshuo_novel.js - X小说源
- **类型**: 小说 (category: `novel`)
- **网站**: https://book.xn--x-ny6am91b6ug0se.com （规范域 X小说.com）
- **说明**: 成人小说站，服务端渲染 HTML，前置 Cloudflare
- **已实现**:
  - 列表（`/books`、`/books/page/N`）、分类（`/category/{n}`）
  - 搜索（`/search?q=&page=`）
  - 兼容两种作品形态：单篇（`/read/{bookId}/{nid}`）与连载（`/book/{id}` + `ul.chapter-grid`）
  - 正文（`div.reader-body#bookcontent`），剥离站点注入的 `span.brand-mark` 广告句、去文末「下集…」引导
  - 内置 `home()` 多板块首页、Cloudflare 兜底 `NEED_WEBVIEW_VERIFY`
- **状态**: 已用真实站点实测通过（单篇 + 32 章连载均正常）

### 9. xchina_novel.js - xChina 小说源（需网页视图过 Cloudflare）
- **类型**: 小说 (category: `novel`)
- **网站**: https://xchina.co （小黄书 xChina 成人小说区，需代理）
- **说明**: Cloudflare 后面的成人小说站
- **已实现**:
  - 列表（`/fictions/{page}.html`）、分类：标签 `/fictions/tag-{n}/{p}.html`、
    按热度 `/fictions/sort-read/{p}.html`、按评论 `/fictions/sort-comment/{p}.html`、
    按篇幅 `/fictions/length-{1,2,3}/{p}.html`
  - 详情/目录（`/fiction/id-{hash}.html`）：标题、封面、作者、系列、字数、标签、章节表
  - 章节正文（`div.fiction-body` 的 `<p>`），兼容「合集/长篇」与「短篇单页」两种形态
  - 内置 `home()` 多板块首页
- **当前状态（重要）**: 列表页多数可直连，但**详情/正文页经常返回
  `403 + cf-mitigated: challenge`**（Cloudflare 浏览器校验页）。这是**可复用 Cookie 型**
  挑战，脚本对这种情况抛 `NEED_WEBVIEW_VERIFY`，由 App 弹出内置网页视图过一次校验、
  把 `cf_clearance` 等 Cookie 存下来复用。已用 `chrome131` 指纹抓取真实页面快照，
  对列表/详情/目录/正文的解析逻辑做了离线端到端验证。

## 🚀 使用方法

### 安装

在 App 里**导入脚本文件**（小说 / 漫画 / 视频 / 猫源各板块右上角的「+」→ 导入本地
脚本），或在板块源管理里粘贴脚本内容。不是往仓库目录里拷文件。

## ⚙️ 代理配置

这些网站可能需要代理访问。在测试时使用了：

```
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
```

确保 LumeBox 的网络请求配置了代理（如果需要）。

## 🔧 调试和测试

### 测试单个源

```javascript
// 在 LumeBox 中测试
const source = require('./99xs_novel.js');

// 测试列表
const result = source.list(1);
console.log(result);

// 测试搜索
const searchResult = source.search('关键词', 1);
console.log(searchResult);
```

## ⚠️ 注意事项

1. **网站可能变更**: 这些源基于 2026-10-07 的网站结构编写，网站更新可能导致源失效

2. **反爬虫**: 某些网站可能有反爬虫机制，需要：
   - 设置合适的 User-Agent
   - 控制请求频率
   - 使用代理

3. **Cookie 认证**: `dage.one` 需要 Cookie `x-index-auth=authed`

4. **API 变化**: `gztv5.com` 和 `dage.one` 使用 API，API 端点可能需要通过抓包确定实际地址

5. **内容合规**: 这些网站包含成人内容，使用时请遵守当地法律法规

## 🛠️ 维护和更新

如果源失效，可能的原因：

1. **网站结构变更**: 检查 HTML 结构是否改变
2. **API 端点变更**: 使用浏览器开发者工具查看实际 API 请求
3. **反爬虫升级**: 可能需要添加更多 Headers 或处理验证码
4. **域名变更**: 更新 `baseUrl`

## 📝 开发新的扩展源

**以 `docs/lumesource-guide.md` 为准**（本目录早期几份文档里写的 `type: 0/1/2`
与 `function list(page, category)` 是**错误的**旧格式，本 App 不认；照那个写会导入失败）。

真实的契约是最小可用脚本只要两样东西——**身份**与**至少一个入口**：

```js
// LumeSource: {"id":"my-source","name":"我的源","version":"1.0.0","category":"novel"}

var LumeSource = {
  id: 'my-source', name: '我的源', version: '1.0.0', category: 'novel',
  async categories() { return [{ id: 'all', title: '全部' }]; },
  async list(argument) {   // argument: { categoryId?, keyword?, page }
    return { items: [{ id: '1', title: '第一条' }], hasMore: false };
  },
  async detail(argument) { return { id: argument.id, title: '标题' }; },
  async chapters(argument) { return [{ id: 'ch-1', title: '第 1 章' }]; },
  async content(argument) {
    return { kind: 'text', text: '正文' };          // 小说
    // 漫画：{ kind: 'images', images: ['https://…/1.jpg'] }
    // 视频：{ kind: 'video', url: 'https://…/index.m3u8', headers: {…} }
  }
};
```

要点：
- `category` 写 `novel` / `comic` / `video`，与导入板块不一致会在解析阶段被拒（跨板块）；
- 网络请求走 `fetch` 或 `LumeSource.http.get(url, { headers })`（由 App 代发）；
  **`require` 只提供 Node 的一部分内建模块**（buffer / process / console / timers /
  crypto / events / path / util / assert / stream / http / https / fs(内存盘) / os / url），
  沙箱不支持的模块（net / tls / dns / http2 / child_process…）**require 不报错、
  用到才报错**——顺手 require 一堆模块不会挡住导入；
- 真引擎验证：`flutter test test/source_scripts_native_test.dart`
  （用实时抓下来的页面快照跑生产调用链，站点临时不可达不会让用例失效）。

## 📄 许可证

这些扩展源仅供学习和研究使用。请遵守目标网站的 robots.txt 和服务条款。

---

**编写日期**: 2026-10-07  
**LumeBox 版本**: 基于项目文档 v1.0  
**作者**: LumeBox Community
