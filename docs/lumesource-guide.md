# LumeSource 图源脚本开发文档

面向**写图源脚本的人**：怎么把一份 JS 脚本写成本 App 能导入、能跑、能出内容的图源。

- 适用范围：小说 / 漫画 / 视频三个板块（猫源见文末「猫源的特殊性」）；
- 配套示例：`assets/test_sources/demo_novel_source.js`、`demo_comic_source.js`、
  `demo_video_source.js` —— 三份都是**可真跑**的模板（本机起个静态站即可验证），
  照抄改地址就能用；
- 兼容层：Venera 生态的 `class X extends ComicSource` 写法**不用改一行**即可导入
  （见「附录 A」）。

---

## 一、最小可用脚本

一份能导入的脚本只需要两样东西：**身份**与**至少一个入口**。

```js
// LumeSource: {"id":"my-source","name":"我的源","version":"1.0.0","category":"novel"}

async function getList(page) {
  return [{ id: '1', title: '第一条' }];
}
```

导入时 App 会做四件事，任何一件不过都会给出**点名到原因**的失败提示：

| 步骤 | 检查 | 失败时的提示 |
|---|---|---|
| 1 | 脚本能载入（语法 / 运行时 / 沙箱能力） | 引擎原话，例如 `SyntaxError: …`、`沙箱不支持「dns」` |
| 2 | 至少有**一个**图源入口 | 「这不是本 App 的图源脚本」（并说明它像什么） |
| 3 | 有合法 id 与 name | 点名是哪个字符不合规 / 缺哪一项 |
| 4 | `category` 与目标板块一致 | 「跨板块源被拒绝」（点名两个板块） |

### 身份声明（两种写法，可混用）

```js
// 写法一：头部注释（函数式脚本**必须**用它，因为没有对象可读）
// LumeSource: {"id":"my-source","name":"我的源","version":"1.0.0","category":"novel"}

// 写法二：运行时对象（对象式脚本可用）
var LumeSource = {
  id: 'my-source',
  name: '我的源',
  version: '1.0.0',
  category: 'novel'
};
```

**id 规则**（硬约束）：只允许英文字母、数字、短横 `-`、下划线 `_`，最长 64 字符。
长破折号（—）与全角符号**会被拒绝**——它们肉眼几乎看不出区别，却会让 id 静默失效
（更新覆盖不生效、当前源选择失配）。头部与运行时都写了 `id` 时**以头部为准**。

`category` 是**可选**的，但强烈建议写：一旦声明，导入别的板块会在解析阶段直接被拒
（而不是导入成功、点开才报「内容类型不对」）。不写则归属完全由导入入口决定。

---

## 二、契约：五个入口

`categories` 可缺省（返回空列表即隐藏分类入口），其余四个是核心。

| 入口 | 入参 | 返回 |
|---|---|---|
| `categories()` | — | `[{id, title}]` |
| `list({categoryId?, keyword?, page})` | `page` 从 1 开始 | `{items: [{id, title, cover?, subtitle?}], hasMore}` |
| `detail({id})` | — | `{id, title, cover?, subtitle?, description?}`；找不到返回 `null` |
| `chapters({id})` | — | `[{id, title}]` |
| `content({id, chapterId})` | — | 见下表（**按板块返回不同形态**） |

### content 的三种形态（板块决定）

```js
// 小说：纯文本
return { kind: 'text', text: '正文……' };

// 漫画：图片地址列表
return { kind: 'images', images: ['https://…/1.jpg', 'https://…/2.jpg'] };

// 视频：播放地址（headers 可选，用于防盗链）
return { kind: 'video', url: 'https://…/play.m3u8', headers: { Referer: '…' } };
```

**形态必须与板块匹配**：漫画板块拿到 `text` 会报「该章节不是图片内容：源返回了文本」。
这不是 bug，是守卫——它说明脚本返回错了形态。

### 三种脚本写法（都认）

派发顺序固定，脚本可以任选一种：

```js
// ① 函数式：位置参数（注意 getList 收的是 page 这个数字）
async function getList(page) { … }
async function getSearch(keyword, page) { … }
async function getDetail(id) { … }
async function getChapters(id) { … }
async function getContent(id, chapterId) { … }
async function getCategories() { … }

// ② 对象式（契约 v2）：收对象入参
var LumeSource = {
  async list(argument) { var page = argument.page; … },
  async detail(argument) { var id = argument.id; … }
};

// ③ 词法声明：let / const LumeSource = { … }（与对象式等价）
```

`getSearch` 与 `search` 是 `list` 的别名——搜索就是「带 keyword 的列表」，
不需要单独实现：在 `list` 里判断 `keyword` 是否为空即可。

---

## 三、可用的宿主能力

### 网络：`LumeSource.http` 或 `fetch`

```js
var response = await LumeSource.http.get('https://example.com/api/list?page=1');
// response: { status, headers, body, text(), json() }
var data = response.json();

// 其它方法：request({url, method, headers, body}) / post(url, body, opts)
```

**所有请求都经宿主网络层发出**，因此自动获得：

- 全局与单域名双层并发限制（防封禁）；
- 全局 UA 与代理、单图源 UA / Cookie / 代理覆盖；
- 429 / 503 的指数退避重试；
- 超时控制。

**不要**在脚本里自己起服务、开端口或 require `net` / `http2` / `dns` / `child_process`
——沙箱没有端口与进程，这些模块会被明确拒绝（并告诉你「补上这个模块也跑不起来」）。
抓接口的源脚本用 `fetch` / `LumeSource.http` 就够了。

### 沙盒存储：`LumeSource.fs`（按图源隔离，进程内）

```js
await LumeSource.fs.writeText('cache/categories.json', JSON.stringify(list));
var cached = await LumeSource.fs.readText('cache/categories.json');
await LumeSource.fs.exists('cache/categories.json');
await LumeSource.fs.remove('cache/categories.json');
var keys = await LumeSource.fs.list();
```

用来做「目录缓存」这类跨调用复用。**按图源隔离**：同名路径在两个源之间互不可见；
**进程内**：重启应用即清空，不要拿它存需要持久化的东西。

### 抓 HTML（沙箱里没有 DOM）

正则解析是最通用的做法：

```js
var html = (await LumeSource.http.get(url)).body;
var pattern = /<a class="item"[^>]*data-id="([^"]+)"[\s\S]*?<img[^>]*src="([^"]*)"/g;
var matched;
while ((matched = pattern.exec(html)) !== null) {
  items.push({ id: matched[1], cover: absolute(matched[2]) });
}
```

**相对地址要自己补全**（`/img/1.jpg` → `https://站点/img/1.jpg`），示例源里
`__absolute()` 就是干这个的。

> Venera 风格脚本可用 `HtmlDocument` 选择器（标签 / `.类` / `#id` / `[属性]` /
> 后代 / 子代 / 逗号分组）；伪类与兄弟选择器**明确报错**（按错的规则抓网页比
> 抓不到更糟）。本项目自己的脚本**不注入** `HtmlDocument`，请用正则。

---

## 四、沙箱边界（写脚本前必须知道）

| 项 | 限制 |
|---|---|
| 执行预算 | 单次操作 3–5 秒墙钟 + 指令计数上限；超限即判失控、销毁上下文 |
| 内存 / 栈 | 有硬上限；无限递归与巨量分配会被中止 |
| 可中断 | 纯 CPU 死循环（`while(true){}`）会被**强制回收**，App 不会卡死 |
| 无能力 | 无端口、无进程、无线程、无真实文件系统、无 WebAssembly、无 `.node` 原生模块 |
| 失败后果 | 一个源失控**不影响**其它源（各自独立上下文），但该源会被销毁重建 |

因此：**不要把重活放在一次调用里**。大循环请分批；网络请求请让宿主发出（它自带
并发与重试）；不要在方法体里 `while(true)` 等异步结果。

**超时后的表现**：该次调用返回可读的超时/超指令错误，上下文被销毁，下一次调用
落在重建后的全新上下文里（脚本的全局变量会丢，`fs` 存储仍在）。

---

## 五、模板：照着改

### 小说（JSON 接口 + 文本正文）

见 `assets/test_sources/demo_novel_source.js`。要点：

- `content` 返回 `{kind: 'text', text}`；
- 分类结果可以用 `fs` 缓存（示例源演示了缓存命中不再打站点）；
- 分页把 `page` 真的传给站点（示例源的用例断言了这一点）。

### 漫画（HTML 列表 + 图片正文）

见 `assets/test_sources/demo_comic_source.js`。要点：

- 列表页用正则抓（沙箱无 DOM）；
- **相对地址补全**成绝对地址；
- `content` 返回 `{kind: 'images', images: [...]}`。

### 视频（多线路 + 直链）

见 `assets/test_sources/demo_video_source.js`。要点：

- 「章节」即选集 / 线路，`chapters` 返回 `[{id, title}]`；
- `content` 返回 `{kind: 'video', url, headers?}`，`headers` 用于防盗链；
- 搜索走站点自己的搜索接口时，在 `list` 里按 `keyword` 分支。

---

## 六、调试与排错

| 现象 | 看哪里 |
|---|---|
| 导入失败 | 提示里有引擎原话；「设置 → 运行日志」有完整记录 |
| 导入成功但列表空 | 用「图源管理 → 测试连通性」：它会真的取分类与首屏列表，并给出「没有实现 list 方法」这类点名提示 |
| 图片 403 | 图源可能需要 Referer；本项目图片管线当前只吃一个地址（逐图请求头尚未透传） |
| 内容形态报错 | 检查 `content` 的 `kind` 是否与板块匹配 |
| 报「跨板块」 | 脚本 `category` 与导入的板块不符；要么改 category，要么导入正确板块 |
| 报「这不是本 App 的图源脚本」 | 五个入口一个都没有；确认不是别的客户端的扩展程序包 |

**写脚本的三条纪律**（照做能省掉大部分排错）：

1. **失败要抛可读错误**，不要静默返回空：
   `throw new Error('拉取失败：HTTP ' + response.status + ' ' + path);`
   上层会把这句话原样展示给用户；
2. **参数真的传下去**（分页 / 关键词 / 章节 id），别在脚本里忽略掉；
3. **id 用白名单字符**，别用长破折号与全角符号。

---

## 附录 A：Venera 源脚本（免改兼容）

Venera 生态的脚本长这样，**本 App 可直接导入**（无需修改）：

```js
class Komiic extends ComicSource {
  name = "Komiic"; key = "Komiic"; version = "1.0.3"
  explore = [{ title: "最新", type: "multiPageComicList",
               load: async (page) => ({ comics, maxPage }) }]
  search = { load: async (keyword, options, page) => ({ comics, maxPage }) }
  loadInfo = async (id) => ({ title, cover, chapters: { 章节id: 标题 } })
  loadEp = async (comicId, epId) => ({ images: [url, ...] })
}
```

映射关系：`explore` / `categoryComics` / `search` → 分类与列表，`loadInfo` → 详情 +
章节，`loadEp` → 图片正文。类里的 `key` / `name` / `version` 成为图源身份，
板块自报为**漫画**（导入小说 / 视频板块会被既有的跨板块校验拦下）。

**已接入**：`Network.*`、`loadData` / `saveData` / `deleteData`、`Convert` 的编码与
`md5`、`HtmlDocument` 常用选择器。

**未接入**（调用时给出点名到能力的可读错误，不静默返回空）：账号登录、收藏夹、
评论、排序点赞、`Convert` 的 `sha*` / `hmac` / AES / RSA、HTML 伪类与兄弟选择器、
图片级自定义请求头（`onImageLoad`）。

示例：`assets/test_sources/venera_demo_json.js`（JSON 型）、`venera_demo_html.js`
（HTML 型）。

---

## 附录 B：猫源的特殊性

猫源（Node 生态）有自己的沙箱垫片（`buffer` / `process` / `crypto` / `events` /
`path` / `util` / `stream` / `http` / `fs`（内存盘）等），但**定位与四板块不同**：

- 真实猫源里常见的「自建服务端程序」（`require('http2')` + `.listen()` + 自带前端）
  **不是图源脚本**——它们需要端口、进程与自有宿主桥，iOS 上不具备运行条件。
  这类包会在导入阶段被识别并说明原因；
- 猫源脚本请同样提供图源入口（`getList` / `getDetail` / …），网络请求走宿主桥。

---

## 附录 C：验证脚本

导入后建议做两件事：

1. **图源管理 → 测试连通性**：它走与浏览完全相同的数据源接口，因此「测试通过」
   等价于「浏览能出内容」；
2. 本机起一个静态站，把脚本里的 `BASE_URL` 指过去，用三份示例源对照——
   本仓库的 `test/js_sandbox/smoke_test.dart` 就是这么做的
   （`flutter test test/js_sandbox/smoke_test.dart` 一条命令跑完三类内容形态）。
