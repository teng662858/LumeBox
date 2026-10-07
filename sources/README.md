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
