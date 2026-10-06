# Lume Box · 真机反馈后的补充轮：三份独立 demo / MPV 复测 / Venera 桥接 / 全量冒烟

> 真机反馈：小说 demo 正常；同一份示例脚本在漫画板块打开报「该章节不是图片内容：
> 源返回了文本」，在视频板块报「不是视频内容」。——这是**内容类型守卫**在起作用
> （源返回文本，漫画阅读器要图片、播放器要视频地址），不是 bug。本轮按用户给的
> 顺序做完四件事。

---

## 一、三份独立 demo 脚本（各自对应板块）

设备上看到的现象，根因是「用了一份通用示例脚本去开三个板块」。上一轮其实已经写好
三份各自独立的示例源，本轮把它们**核验到位并补上跨板块拒绝的断言**：

| 脚本 | 板块 | 内容形态 | 演示的能力 |
|---|---|---|---|
| `assets/test_sources/demo_novel_source.js` | 小说 | `kind: 'text'` | JSON 接口 + 分页 + 搜索 + 沙盒存储缓存 |
| `assets/test_sources/demo_comic_source.js` | 漫画 | `kind: 'images'` | HTML 列表页正则解析 + 相对地址补全 |
| `assets/test_sources/demo_video_source.js` | 视频 | `kind: 'video'` | JSON + 独立搜索接口 + 选集 + 直链与防盗链头 |

三份脚本都在**头部注释与运行时**声明了 `category`（novel / comic / video），因此：

- 导入到**对应板块**：正常；
- 导入到**别的板块**：在导入阶段就被拦下，报「跨板块」并点名两个板块
  ——不会再出现「导入成功、点开才报内容类型不对」这种困惑。
  本轮新增用例把「小说→漫画/视频、漫画→小说、视频→漫画」四组跨板块导入全部断言了一遍。

设备上自测的用法：把脚本顶部的 `BASE_URL` 改成你自己的测试站点（电脑上起个静态
JSON 服务、手机与电脑同一局域网即可），再按板块分别导入。

## 二、MPV 切换复测

上一轮的修复（播放页四态 + 控制栏常在 + 重试/切回出口 + 重建异常安全）在本轮
补了两条断言，把用户报的「右上角消失」两种读法都钉住：

- 失败态下**控制栏齿轮**（「播放器设置」）仍在 ✓（上一轮已覆盖）；
- 失败态与回退后**板块顶栏入口**（「追剧日历」「源管理」）仍在 ✓（本轮新增）。

`test/player_switch_recovery_test.dart` 7 例全绿；真机上再切一次 MPV 即可确认。

## 三、Venera 漫画源桥接（新增能力）

### 做了什么

Venera 的图源脚本只写一个类：

```js
class Komiic extends ComicSource {
  name = "Komiic"; key = "Komiic"; version = "1.0.3"
  explore = [{ title: "最新", type: "multiPageComicList", load: async (page) => ({ comics, maxPage }) }]
  search = { load: async (keyword, options, page) => ({ comics, maxPage }) }
  loadInfo = async (id) => ({ title, cover, chapters: { 章节id: 标题 } })
  loadEp = async (comicId, epId) => ({ images: [url, ...] })
}
```

本项目里原先会直接报 `ComicSource is not defined`——那是 Venera 宿主提供的全局基类。
新增 `lib/core/js/venera_bridge.dart`（`lume.comic.venera` 垫片）把这条链路补齐：

1. **注入全局**：`ComicSource`（基类）、`Network`、`Convert`、`UI`、
   `HtmlDocument` / `HtmlElement` / `HtmlNode`、`createUuid` / `randomInt` /
   `randomDouble`；垫片注入在脚本执行**之前**，所以 `class X extends ComicSource`
   直接可用。
2. **认领子类**：Venera 脚本没有任何注册语句、类名也不挂在 `globalThis` 上，
   因此宿主从脚本文本里读出类名（`VeneraScriptSource.classNameOf`，**先剥注释与
   字符串**——真实脚本的注释里经常写着示例类名，不剥会认错），
   再让垫片 `new` 出来、跑一次 `init()`。
3. **元信息与板块自报**：实例的 `key / name / version` 写进桥接全局 `LumeSource`，
   `category` 写成 `comic`。于是**导入、元信息读取、板块校验全部沿用既有链路**，
   本层没有新增导入口径。
4. **契约映射**：`explore / categoryComics / search → list`、
   `loadInfo → detail + chapters`（支持 `{id: 标题}` 与分组两层映射）、
   `loadEp → content(images)`。上层（引擎、注册表、适配器、页面）**一行未改**。
5. **存储**：`loadData / saveData / deleteData` 落在按图源隔离的沙盒存储里
   （与 `LumeSource.fs` 同一张表、同一套隔离）。
6. **实例方法外挂**：脚本自己写的其它方法（探针、将来的可选能力如弹幕）
   一并挂到桥接全局，经同一条调用链可达。

### 能力边界（如实声明，不做「假装支持」）

| 能力 | 状态 |
|---|---|
| `explore` / `categoryComics` / `search` / `loadInfo` / `loadEp` | ✅ |
| `Network.get/post/put/delete/patch/fetchBytes`、`fetch` | ✅（都走宿主网络层：并发限制、UA/代理、退避重试） |
| `loadData` / `saveData` / `deleteData` | ✅（按图源隔离的进程内存储） |
| `Convert.encodeUtf8/decodeUtf8/encodeBase64/decodeBase64/hexEncode/hexDecode` | ✅（纯 JS） |
| `Convert.md5` | ✅（**计算在宿主**：复用 Dart 侧那份经过标准向量验证的实现，JS 里不再写第二份） |
| `HtmlDocument` 选择器：标签 / `.类` / `#id` / `[属性]` / `[属性=*^$]` / 后代 / 子代 / 逗号分组 | ✅ |
| `Convert.sha1/sha256/sha512/hmac/AES/RSA`、`UI` 交互类、账号登录、收藏夹、评论、排序点赞、`Network` cookie | ❌ **明确报错**并点名能力（`Venera 源的这个能力尚未接入：…（当前支持：…）`） |
| HTML 伪类 / 兄弟选择器 | ❌ 明确报错（按错的规则抓网页比抓不到更糟） |
| 图片级请求头（`onImageLoad` 返回的 headers） | ⚠️ 暂不透传（本项目图片管线当前只吃一个地址）；命中时记一条日志，便于排查 403 |

### 落在哪

- `lib/core/js/venera_bridge.dart`：垫片 + 纯 Dart 侧的脚本识别；
- `lib/core/js/lume_js_engine.dart`：通用登记表加入该垫片（**猫源表不加**）、
  脚本载入成功后认领子类；引擎新增 `section` 字段；
- `lib/core/js/sandbox/sandbox_host.dart` + `lume_js_engine.dart`：
  宿主新增 `util.digest`（当前支持 md5，其余算法可读报错）。

**为什么兼容层放在通用登记表而不是只给漫画板块**：Venera 源被导入小说 / 视频板块时，
如果那儿没有 `ComicSource`，用户看到的是「ComicSource is not defined」——看不出是
板块问题。放进通用表后，脚本能载入、自报 comic，于是**既有的跨板块校验**会给出
「跨板块」这句人话。猫源有自己的登记表（Node 环境不外借），拿不到这一层。

### 验证

`test/js_sandbox/venera_bridge_test.dart`（6 例，真 QuickJS + 本机示例站）：

- 脚本识别（含注释剥离：注释里写着 `class X extends ComicSource` 也不会认错）；
- JSON 型源：`key/name/version` 成为图源身份、板块自报为漫画、导入小说板块被拒；
- JSON 型源全链路：分类（explore）/ 列表 / 搜索 / 详情 / 章节 / 图片；
- HTML 型源：`querySelectorAll('div.list > a.item')` 抓列表 + 详情 + 图片；
- `HtmlDocument` 子集行为（`.类` / `[属性=值]` / `#id` 命中；伪类明确报错）；
- `Convert.md5('abc')` = `900150983cd24fb0d6963f7d28e17f72`（标准向量，宿主计算）、
  `sha256` 与 `login` 点名报错、`saveData/loadData` 往返成功。

两份示例源：`assets/test_sources/venera_demo_json.js`、`venera_demo_html.js`
（同样从磁盘读、不进 App 资源包）。

## 四、全量冒烟：一条命令

`flutter test test/js_sandbox/smoke_test.dart` —— 覆盖用户点名的两类检查，
跑完打印一张汇总表：

```
[冒烟汇总]
  · 小说 demo：分类 2 个 · 列表 2 条 · 正文 24 字 ✓
  · 漫画 demo：分类 3 个 · 列表 2 条 · 本章图片 3 张 ✓
  · 视频 demo：列表 1 条 · 选集 2 个 · 播放地址 https ✓
  · 跨板块拒绝：3 组全部被拦下并给出跨板块原因 ✓
  · 死循环：instructions 判定 · 代数 1→2 · 重建可用 ✓
  · 上下文隔离：同名存储跨板块读不到（小说侧为空）✓
```

它是**冒烟级**（每项一条，给人看结论）；细粒度断言仍在
`demo_sources_test` / `security_audit_test` / `deadloop_timeout_test` 里。

## 五、验证

- `flutter analyze` 零问题；`flutter test` **947 例全绿**（本轮新增 10 例；
  937 例基线无回归，其中 `source_bridge_test` 的注入顺序断言按新组成更新）。
- 真机仍有待确认的一条：切 MPV 是否还会转圈（页面状态机已保证有出口，
  若再遇到，日志里会有 `[player]` 的初始化耗时 / 失败记录可定位）。
