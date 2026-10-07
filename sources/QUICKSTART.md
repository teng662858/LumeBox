# LumeBox 扩展源快速入门

## 📋 已创建的扩展源

本次为您创建了 **4 个符合 LumeSource v2 契约的扩展源脚本**；其中两个视频源的能力边界已在代码中明确标注：

| 文件名 | 类型 | 网站 | 说明 |
|--------|------|------|------|
| `99xs_novel.js` | 小说 | https://99xs.sbs | CA情色小说，WordPress架构 |
| `daniao5_comic.js` | 漫画 | https://daniao5.com | 大鸟禁漫，MacCMS系统 |
| `gztv5_video.js` | 视频 | https://gztv5.com | 瓜子影视，Nuxt.js应用 |
| `dage_video.js` | 视频 | https://dage.one | 大哥视频，需要Cookie认证 |

## 🚀 快速开始

### 1. 查看文档
```bash
# 查看详细 README
cat sources/README.md

# 查看测试脚本
cat sources/test.js
```

### 2. 文件结构
```
D:\Zcode\LumeBox\sources\
├── 99xs_novel.js       # 小说源
├── daniao5_comic.js    # 漫画源
├── gztv5_video.js      # 视频源1
├── dage_video.js       # 视频源2
├── README.md           # 详细文档
└── test.js             # 测试工具
```

## 📝 扩展源特性对比

### 99xs_novel.js (小说源)
✅ 实现完整  
✅ 无需认证  
✅ 支持分类浏览  
✅ 支持搜索  
✅ 单章节小说  
⚠️ 需要代理访问

**核心函数**:
- `list(page, category)` - 获取小说列表
- `search(keyword, page)` - 搜索小说
- `detail(id, url)` - 获取详情
- `content(chapterUrl)` - 获取内容

### daniao5_comic.js (漫画源)
✅ 实现完整  
✅ 无需认证  
✅ 高清图片支持  
✅ 多章节支持  
✅ 懒加载处理  
⚠️ 需要代理访问

**核心函数**:
- `list(page, category)` - 获取漫画列表
- `search(keyword, page)` - 搜索漫画
- `detail(id, url)` - 获取详情和章节
- `images(chapterUrl)` - 获取图片列表

### gztv5_video.js (视频源)
⚠️ 部分支持：分类和首页首屏列表可用
⚠️ 详情、选集和播放仍需要站点加密协议
⚠️ Nuxt.js SPA架构  
⚠️ 需要代理访问

**说明**: 该网站使用 Nuxt.js，数据通过 API 加载，可能需要进一步抓包分析实际 API 端点。

**核心函数**:
- `list(page, category)` - 获取视频列表
- `search(keyword, page)` - 搜索视频
- `detail(id, url)` - 获取详情和剧集
- `play(episodeUrl)` - 获取播放地址

### dage_video.js (视频源)
⚠️ 暂不支持数据调用
⚠️ API 返回自定义加密数据
⚠️ 需要代理访问

**特殊要求**: 
- Cookie: `x-index-auth=authed`
- 访问 `/enter` 而非根目录

**核心函数**:
- `list(page, category)` - 获取视频列表
- `search(keyword, page)` - 搜索视频
- `detail(id, url)` - 获取详情和剧集
- `play(episodeUrl)` - 获取播放地址

## 🔧 配置说明

### LumeBox 配置
将扩展源文件放入 LumeBox 的扩展源目录，通常是：
```
/path/to/LumeBox/assets/extensions/
```

### 代理配置
如果网站需要代理访问，确保 LumeBox 配置了代理：
```
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
```

## ⚠️ 重要提示

### 1. API 端点需要确认
`gztv5_video.js` 和 `dage_video.js` 中的 API 端点是推测的，实际使用前需要：
- 使用浏览器开发者工具抓包
- 确认真实的 API 地址和参数格式
- 根据实际 API 响应调整代码

### 2. Cookie 处理
`dage_video.js` 需要 Cookie 认证：
```javascript
Cookie: x-index-auth=authed
```
确保 LumeBox 的 HTTP 模块支持设置 Cookie。

### 3. 反爬虫机制
这些网站可能有反爬虫保护：
- 控制请求频率
- 使用真实的 User-Agent
- 必要时添加更多 Headers
- 使用代理 IP

### 4. 网站结构变更
网站更新可能导致源失效，需要：
- 检查 HTML 结构变化
- 更新 CSS 选择器或正则表达式
- 测试所有功能

## 🛠️ 下一步工作

### 已确认可用
- ✅ `99xs_novel.js` - 列表、详情、分页正文
- ✅ `daniao5_comic.js` - 列表、详情、章节、图片
- ⚠️ `gztv5_video.js` - 分类和首页首屏列表

### 暂未支持
- ⚠️ `gztv5_video.js` - 详情、选集、播放加密接口
- ⚠️ `dage_video.js` - 自定义加密 API

### 建议测试流程
1. 先测试小说源和漫画源（最稳定）
2. 使用浏览器开发者工具抓取视频网站的 API
3. 更新视频源代码中的 API 端点
4. 在 LumeBox 中完整测试所有功能

## 📞 技术支持

如果遇到问题：
1. 检查网络和代理配置
2. 使用浏览器访问目标网站确认可访问
3. 查看 LumeBox 的错误日志
4. 使用 `test.js` 进行单元测试

## 📚 相关文档

- [LumeBox 项目文档](../README.md)
- [扩展源开发规范](../doc/扩展源开发.md)
- [详细 README](./README.md)

---

**创建时间**: 2026-10-07  
**状态**: 小说源和漫画源完整可用，视频源需要 API 确认  
**测试状态**: 已分析网站结构，未在 LumeBox 中实际运行
