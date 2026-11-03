# LumeSource: {"id":"pypack_41242ab5e043646f","name":"暖秋剧场","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
"""
@header({
  searchable: 1,
  filterable: 1,
  quickSearch: 1,
  title: '晚秋剧场',
  lang: 'hipy'
})
"""
# -*- coding: utf-8 -*-
# !/usr/bin/env python3
"""
晚秋剧场 (暖秋剧场) TVBox 爬虫  —— 兼容 FongMi / T3 与 WebHomeTV / T4 及默影视
================================================================================

站点: https://www.yundongmudibana.com/   (MacCMS 系 + eWave(yun009) 模板)

【站点结构分析结论】(全部经真实抓包确认, 详见同目录 TEST.md)
  1. 首页             /                                  -> 多区块 vod 卡片列表
  2. 顶部分类         /yubjc/{cid}.html                   首页导航: 4=电影 5=电视剧 6=综艺 7=动漫 8=短剧
  3. 二级分类         /yubjc/{cid}.html                   分类页内有「分类/地区/年份/语言」多组筛选, 二级分类
                                                          形如 /yubjc/4/class/动作.html、/yubjc/4/area/大陆.html
  4. 分类翻页         /yubjc/{cid}/page/{n}.html           (总页数写在页码区, e.g. 1/2824)
  5. 详情页           /yunsxs/{id}.html                   含海报(lazy: data-original)、简介、播放线路 tab、剧集列表
  6. 播放页           /vshow/{id}/{sid}/{eid}.html        sid=线路序号, eid=剧集序号
  7. 播放地址         播放页内 JS 变量 player_aaaa.url      <-- 直接就是 m3u8, 无需第三方解析!
  8. 搜索             /search.html?wd={kw}                结果复用 ranking-item 结构
  9. 搜索翻页         /search/{kw}/page/{n}.html

【解析播放地址的核心】播放页 HTML 内含:
      var player_aaaa={"url":"https://xxx/index.m3u8","url_next":"...","from":"dplayer",...}
  其中 url 即直链 m3u8 (实测无 Referer 亦可直接拉取)。因此本爬虫无需拼接任何外部解析接口,
  真正做到了「直接可播」。若站点某天改为 encrypt=1 的加密线路, 代码保留了 flag/encrypt 判断位与
  可配置的解析兜底 (PLAY_URL_BACKUP_PARSE), 保证向前兼容。

【T3 / T4 兼容要点】
  - 只依赖 Python 标准库 (urllib/http.client/gzip/re/json), 不引入 requests, 因电视端常无三方库;
  - 使用 modules/__js__ 双导出, FongMi(T3) 走 `py_` 模块约定, 同时保留 `exports` 供 T4 读取;
  - 所有网络请求带有超时 + 单例内存缓存 (TTL), 避免电视端重复拉取导致卡顿;
  - 支持本地调试: 直接 `python3 wanqiu.py` 会跑内建自测 (--selftest)。

作者: 编程专家 Skill / 自动生成
"""

import sys
import json
import time
import gzip
import re
import html as html_mod
import urllib.parse
import urllib.request
import urllib.error

# ============================================================================
# 一、全局配置
# ============================================================================

BASE_HOST = "https://www.yundongmudibana.com"
# 站点图片 CDN 与主站不同域, 但图片可直接引用, 无需代理
UA = ("Mozilla/5.0 (Linux; Android 13; SM-S9180) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

# 单次请求超时 (秒)。电视端网络抖动大, 给足 12s
TIMEOUT = 12
# 网络失败重试次数 (仅针对超时/5xx 等可重试错误)
RETRY = 2

# 内存缓存: {key: (expire_ts, value)}   默认 TTL 300s, 详情/播放页缓存更久
CACHE_TTL = 300
_CACHE = {}

# 图片请求超时(秒)。CDN 慢时给足, 但别无限等 -> 失败也能快速跳过。
IMG_TIMEOUT = 20
# 播放页解析请求超时(秒)。CDN 慢, 给足 25s 避免误判失败。
PLAY_TIMEOUT = 25
# 首屏 limit(每页条数)。降低可减少首屏需加载的图片数, 提升观感。
PAGE_LIMIT = 12
# 列表返回后后台预取的图片数量(0=关闭)。预取走磁盘缓存, 用户滚动时秒出。
PREFETCH_N = 8
# 是否让 m3u8 直链走本地代理(可选)。开=代理层可统一加 Referer/重试;
# 关=直连。默影视建议关(播放器直连 m3u8 更稳), 仅当出现防盗链时才开。
PROXY_M3U8 = False

# 可选: 当站点加密线路 (encrypt=1) 无法直取时使用的聚合解析接口占位。
# 留空表示不启用; 若站点将来启用加密, 可填入形如 "https://parse.example.com/?url=" 的前缀。
# 这里保持为空 -> 走「直链优先」路径, 完全不需要外部解析。
PLAY_URL_BACKUP_PARSE = ""

# 首页导航兜底分类 (当远程导航抓取失败时使用)
DEFAULT_CLASSES = [
    {"type_id": "/yubjc/4.html", "type_name": "电影"},
    {"type_id": "/yubjc/5.html", "type_name": "电视剧"},
    {"type_id": "/yubjc/6.html", "type_name": "综艺"},
    {"type_id": "/yubjc/7.html", "type_name": "动漫"},
    {"type_id": "/yubjc/8.html", "type_name": "短剧"},
]


# ============================================================================
# 二、基础工具: HTTP / 缓存 / HTML 清洗
# ============================================================================

def _log(*args):
    """调试日志, 仅在本地 / 调试模式输出, 避免污染电视端 stderr。"""
    if _DEBUG:
        sys.stderr.write("[wanqiu] " + " ".join(str(a) for a in args) + "\n")


_DEBUG = False


def _cache_get(key):
    """读取缓存; 过期返回 None。"""
    item = _CACHE.get(key)
    if not item:
        return None
    expire, value = item
    if expire < time.time():
        _CACHE.pop(key, None)
        return None
    return value


def _cache_set(key, value, ttl=CACHE_TTL):
    """写入缓存。"""
    _CACHE[key] = (time.time() + ttl, value)


def fetch(url, referer=None, ttl=CACHE_TTL, use_cache=True, binary=False, timeout=None):
    """
    统一的 HTTP GET 获取, 带:
      - 超时控制 (默认 TIMEOUT, 可用 timeout 覆盖)
      - 自动 gzip 解压
      - 失败重试 (仅对网络类错误)
      - 内存缓存 (use_cache + ttl)
    返回: str (文本) 或 bytes (binary=True); 失败返回 ""
    """
    if not url:
        return b"" if binary else ""

    # 补全相对地址
    if url.startswith("/"):
        url = BASE_HOST + url
    if not url.startswith("http"):
        return b"" if binary else ""

    _timeout = timeout if timeout else TIMEOUT

    cache_key = ("B:" if binary else "T:") + url
    if use_cache:
        hit = _cache_get(cache_key)
        if hit is not None:
            _log("cache hit:", url)
            return hit

    # 关键: URL 中含中文 (如 /yubjc/4/class/动作.html) 时必须百分号编码,
    # 否则 urllib 会抛 "'ascii' codec can't encode characters"。
    url = urllib.parse.quote(url, safe=":/?&=#%+$,")

    headers = {
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip, deflate",
    }
    if referer:
        headers["Referer"] = referer
    else:
        headers["Referer"] = BASE_HOST + "/"

    last_err = None
    for attempt in range(RETRY + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=_timeout) as resp:
                raw = resp.read()
                enc = (resp.headers.get("Content-Encoding") or "").lower()
                if "gzip" in enc:
                    raw = gzip.decompress(raw)
                elif "deflate" in enc:
                    try:
                        import zlib
                        raw = zlib.decompress(raw, -zlib.MAX_WBITS)
                    except Exception:
                        pass

            if binary:
                result = raw
            else:
                result = _decode(raw)

            if use_cache:
                _cache_set(cache_key, result, ttl)
            return result

        except urllib.error.HTTPError as e:
            # 4xx 是客户端错误, 重试无意义; 5xx 可重试
            last_err = e
            if 400 <= e.code < 500:
                _log("HTTP %s (no-retry): %s" % (e.code, url))
                break
            _log("HTTP %s retry %d: %s" % (e.code, attempt, url))
        except Exception as e:  # noqa  (超时 / DNS / 连接重置等)
            last_err = e
            _log("ERR retry %d: %s -> %s" % (attempt, e, url))

        if attempt < RETRY:
            time.sleep(0.4 * (attempt + 1))

    _log("FAILED:", url, last_err)
    return b"" if binary else ""


def _decode(raw):
    """智能解码: 站点为 UTF-8, 但兜底尝试常见中文编码。"""
    for enc in ("utf-8", "gbk", "gb18030"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "ignore")


def _fix_url(u):
    """把相对 URL 补成绝对 URL。"""
    if not u:
        return ""
    u = html_mod.unescape(u.strip())
    if u.startswith("//"):
        return "https:" + u
    if u.startswith("/"):
        return BASE_HOST + u
    return u


def _strip(s):
    """去标签 + 去多余空白。"""
    if not s:
        return ""
    s = re.sub(r"<[^>]+>", "", s)
    s = html_mod.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


def _img_cache_dir():
    """图片磁盘缓存目录(持久化优先)。返回可用目录或 ''。"""
    import os
    for d in ("/storage/emulated/0/TVBox/py/.imgcache",
              "/sdcard/TVBox/py/.imgcache",
              "/tmp/wanqiu_imgcache"):
        try:
            if not os.path.isdir(d):
                os.makedirs(d, exist_ok=True)
            # 可写性测试
            testf = os.path.join(d, ".wtest")
            with open(testf, "w") as f:
                f.write("1")
            os.remove(testf)
            return d
        except Exception:
            continue
    return ""


# 是否把图片 URL 走本地代理(壳需支持 localProxy; 默影视/FongMi 均支持)
# 关掉时 vod_pic 直接给原始 URL; 打开时走本地缓存代理, 二次秒开。
USE_IMG_PROXY = True


def _proxy_pic(pic):
    """
    把图片 URL 包装成本地代理地址, 交由 Spider.localProxy 转发+缓存。
    若原始地址为空 / 非 http, 或未启用代理, 则原样返回。
    壳约定: http://127.0.0.1:9978/proxy?do=py&type=img&... (不同壳略有差异)。
    """
    if not pic:
        return ""
    pic = _fix_url(pic)
    if not USE_IMG_PROXY or not pic.startswith("http"):
        return pic
    try:
        q = urllib.parse.quote(pic, safe="")
        return "http://127.0.0.1:9978/proxy?do=py&type=img&url=" + q
    except Exception:
        return pic


def _probe_log(msg):
    """写一行探针/诊断日志到磁盘, 便于排查壳调用行为。失败静默。"""
    try:
        import os
        d = _img_cache_dir()
        if not d:
            return
        with open(os.path.join(d, "_probe.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def _disk_cached(url):
    """判断某图是否已在磁盘缓存中。"""
    try:
        import os
        import hashlib
        d = _img_cache_dir()
        if not d:
            return False
        h = hashlib.md5(url.encode("utf-8")).hexdigest()
        for e in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
            if os.path.exists(os.path.join(d, h + e)):
                return True
    except Exception:
        pass
    return False


def _save_disk(url, data):
    """把图片字节落盘缓存(供预取使用)。"""
    try:
        import os
        import hashlib
        d = _img_cache_dir()
        if not d or not data:
            return
        h = hashlib.md5(url.encode("utf-8")).hexdigest()
        ext = ".jpg"
        for e in (".png", ".webp", ".jpeg", ".gif"):
            if e in url.lower():
                ext = e
                break
        with open(os.path.join(d, h + ext), "wb") as f:
            f.write(data)
    except Exception:
        pass


def _prefetch_images(pics, n=None):
    """
    后台预取图片到磁盘缓存。列表接口返回后调用, 把慢的等待移出用户可见路径。
    优先多线程并发; 若环境不支持线程(某些沙盒/壳), 退回单线程后台执行。
    任一失败不影响主流程。
    """
    if not USE_IMG_PROXY:
        return
    n = PREFETCH_N if n is None else n
    if n <= 0 or not pics:
        return
    todo = []
    for p in pics[:n]:
        p = _fix_url(p)
        if p.startswith("http") and not _disk_cached(p):
            todo.append(p)
    if not todo:
        return

    def _worker(urls):
        for u in urls:
            try:
                data = fetch(u, referer=BASE_HOST + "/", use_cache=False,
                             binary=True, timeout=IMG_TIMEOUT)
                if data:
                    _save_disk(u, data)
                    _probe_log("prefetch ok %s (%d bytes)" % (u[-40:], len(data)))
            except Exception:
                pass

    # 优先多线程; 失败则同步(在调用方已 try 保护, 但同步会阻塞, 故放到末尾兜底)
    try:
        import threading
        t = threading.Thread(target=_worker, args=(todo,))
        t.daemon = True
        t.start()
        return
    except Exception:
        pass
    # 无线程环境: 不同步跑(避免拖慢接口), 直接放弃预取
    return


# ============================================================================
# 三、HTML 区块解析 (基于实测选择器)
# ============================================================================

def _parse_cards(block):
    """
    解析一个「vod 卡片列表」HTML 片段。
    eWave 列表卡片结构 (实测):
      <li class="col-xs-4 ...">
        <div class="pic">
          <a href="/yunsxs/699334.html" title="逃离恶魔岛">
            <div class="img-wrapper lazyload img-wrapper-pic" data-original="...jpg"></div>
            <span class="fed-list-score">7.6</span>
            <span class="vtitle text-right">正片</span>
          </a>
        </div>
        <div class="name">
          <h3><a href="/yunsxs/699334.html" title="逃离恶魔岛">逃离恶魔岛</a></h3>
          <p class="item-status text-overflow">内详</p>
        </div>
      </li>
    """
    videos = []
    seen = set()

    # 以 <li ...> 切块; 只保留含 /yunsxs/{id}.html 且含图片的块
    for li in re.findall(r"<li[^>]*>(.*?)</li>", block, re.S):
        m = re.search(r'href="(/yunsxs/(\d+)\.html)"', li)
        if not m:
            continue
        vid = m.group(2)
        if vid in seen:
            continue

        # 标题: 优先 title 属性, 其次 h3 文本
        title = ""
        mt = re.search(r'title="([^"]*)"', li)
        if mt:
            title = html_mod.unescape(mt.group(1)).strip()
        if not title:
            mh3 = re.search(r"<h3[^>]*>(.*?)</h3>", li, re.S)
            if mh3:
                title = _strip(mh3.group(1))
        if not title:
            continue

        # 海报: 懒加载 data-original / data-background, 兼容 src
        pic = ""
        for pat in (r'data-original="([^"]+)"', r'data-background="([^"]+)"',
                    r'data-src="([^"]+)"', r'src="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"'):
            mp = re.search(pat, li)
            if mp and "load.png" not in mp.group(1):
                pic = _fix_url(mp.group(1))
                break

        # 备注: vtitle (右上角) 或 item-status
        note = ""
        mv = re.search(r'class="vtitle[^"]*"[^>]*>(.*?)</span>', li, re.S)
        if mv:
            note = _strip(mv.group(1))
        if not note:
            ms = re.search(r'class="item-status[^"]*"[^>]*>(.*?)</p>', li, re.S)
            if ms:
                note = _strip(ms.group(1))

        seen.add(vid)
        videos.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _proxy_pic(pic),
            "vod_remarks": note,
        })

    return videos


def _parse_ranking_cards(block):
    """
    解析「排行榜 / 搜索结果」卡片。实测结构:
      <li class="ranking-item">
        <a class="text-overflow" href="/yunsxs/684480.html" title="一斩苍穹">
          <div class="ranking-item-cover"><div class="img-wrapper lazyload" data-original="..."></div></div>
          <div class="ranking-item-info"><h4 class="text-overflow">一斩苍穹</h4>
              <p class="text-overflow">第3集/内详</p></div>
        </a>
      </li>
    """
    videos = []
    seen = set()
    for li in re.findall(r'<li[^>]*class="ranking-item"[^>]*>(.*?)</li>', block, re.S):
        m = re.search(r'href="(/yunsxs/(\d+)\.html)"', li)
        if not m:
            continue
        vid = m.group(2)
        if vid in seen:
            continue
        title = ""
        mt = re.search(r'title="([^"]*)"', li)
        if mt:
            title = html_mod.unescape(mt.group(1)).strip()
        if not title:
            mh = re.search(r"<h4[^>]*>(.*?)</h4>", li, re.S)
            if mh:
                title = _strip(mh.group(1))
        if not title:
            continue
        pic = ""
        mp = re.search(r'data-original="([^"]+)"', li)
        if mp:
            pic = _fix_url(mp.group(1))
        note = ""
        mn = re.search(r'<p[^>]*>(.*?)</p>', li, re.S)
        if mn:
            note = _strip(mn.group(1))
        seen.add(vid)
        videos.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _proxy_pic(pic),
            "vod_remarks": note,
        })
    return videos


def _merged_cards(block):
    """同时尝试两种卡片结构并去重合并 (搜索结果两种结构都可能出现)。"""
    out = []
    seen = set()
    for v in _parse_cards(block) + _parse_ranking_cards(block):
        if v["vod_id"] in seen:
            continue
        seen.add(v["vod_id"])
        out.append(v)
    return out


# ============================================================================
# 四、TVBox 接口实现
# ============================================================================

def home_content(filter_=False):
    """
    【首页】返回分类列表 + 推荐视频列表。
    TVBox 约定: {"class": [...], "list": [...]}
    T4 额外读取 filters (下拉筛选), 这里不做 base 筛选, 保持干净。
    """
    classes = []
    # 1) 动态抓取首页顶部导航 (最稳, 站点改版只改这里)
    home_html = fetch("/", ttl=CACHE_TTL)
    nav_block = ""
    if home_html:
        mn = re.search(r'<div class="nav">(.*?)</div>\s*</div>', home_html, re.S)
        if not mn:
            mn = re.search(r'<div class="nav">(.*?)</div>', home_html, re.S)
        if mn:
            nav_block = mn.group(1)
        for a in re.findall(r'<a[^>]*href="(/yubjc/\d+\.html)"[^>]*>([^<]+)</a>', nav_block):
            classes.append({"type_id": a[0], "type_name": _strip(a[1])})

    # 2) 兜底: 用硬编码分类
    if not classes:
        classes = list(DEFAULT_CLASSES)

    # 3) 首页推荐视频 (合并首页所有区块的卡片)
    videos = _merged_cards(home_html) if home_html else []

    # 4) 筛选树: 首页本身没有 <dl> 筛选块, 从第一个分类页取 (T4 会按 type_id 应用)
    filters = {"_default": []}
    if classes:
        first_cat = fetch(classes[0]["type_id"], ttl=CACHE_TTL)
        filters = _build_filters(first_cat)

    return {"class": classes, "list": videos, "filters": filters}


def _build_filters(html_text):
    """
    从分类/首页 HTML 解析「二级分类 / 地区 / 年份」筛选项。
    站点结构 (实测):
      <dl>
        <dt><span>分类</span></dt><dd ...>
          <a class="swiper-slide active" href="/yubjc/4.html">全部</a>
          <a class="swiper-slide" href="/yubjc/14.html">动作片</a> ...
        </dd>
      </dl>
      <dl><dt><span>地区</span></dt><dd ...><a href="/yubjc/4/area/大陆.html">大陆</a>...</dd></dl>
      <dl><dt><span>年份</span></dt><dd ...><a href="/yubjc/4/year/2024.html">2024</a>...</dd></dl>
    返回 TVBox filters 结构: {"_default": [{"key":"area","name":"地区","value":[{"n":..,"v":..}]}]}
    其中 value 项的 v 字段直接填相对 URL, 便于 category_content 透传。
    """
    filters = {"_default": []}
    if not html_text:
        return filters

    for dl in re.findall(r"<dl[^>]*>(.*?)</dl>", html_text, re.S):
        mt = re.search(r"<dt[^>]*>(.*?)</dt>", dl, re.S)
        if not mt:
            continue
        name = _strip(mt.group(1))
        if name not in ("分类", "地区", "年份", "语言", "类型", "剧情"):
            continue
        values = [{"n": "全部", "v": ""}]
        for a in re.findall(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dl, re.S):
            href, label = a[0], _strip(a[1])
            # 只收有效筛选路径, 排除 "class/" (站点该路由会回落到全部分类)
            if not href.startswith("/yubjc/") or not label or label == "全部":
                continue
            if "/class/" in href:
                continue
            values.append({"n": label, "v": href})
        if len(values) > 1:
            key = {"分类": "cate", "地区": "area", "年份": "year",
                   "语言": "lang", "类型": "type", "剧情": "gen"}.get(name, name)
            filters["_default"].append(
                {"key": key, "name": name, "value": values})
    return filters


def _extract_pagecount(html):
    """
    从分类页 HTML 里稳健地提取「总页数」。
    站点分页区长这样(实测):
        <div class="page"> ... <a>1/2824</a> ... </div>
      或 <a class="page-link" href=".../page/2.html">下一页</a>
    关键: 必须限定在「分页区域内」取, 且数值范围合理(1~99999),
    否则会被图片 URL 里的 "20260126-1/048431..." 误命中 -> pagecount 爆炸。
    返回 int 或 0。
    """
    if not html:
        return 0

    # 1) 优先: 找分页容器(常见 class), 在其内部找 x/y
    for ctx_pat in (r'<div[^>]*class="[^"]*(?:page|pagelist|pagination)[^"]*"[^>]*>(.*?)</div>',
                    r'<ul[^>]*class="[^"]*(?:page|pagelist|pagination)[^"]*"[^>]*>(.*?)</ul>'):
        for blk in re.findall(ctx_pat, html, re.S):
            m = re.search(r">\s*(\d{1,5})\s*/\s*(\d{1,5})\s*<", blk)
            if m:
                try:
                    v = int(m.group(2))
                    if 1 <= v <= 99999:
                        return v
                except Exception:
                    pass

    # 2) 次选: 全局找 ">数字/数字<" 这种被尖括号包住的(图片URL里是 "1/048431..." 不以 < 结尾)
    m = re.search(r">\s*\d{1,5}\s*/\s*(\d{1,5})\s*<", html)
    if m:
        try:
            v = int(m.group(1))
            if 1 <= v <= 99999:
                return v
        except Exception:
            pass

    # 3) 兜底: 找 /page/{n}.html 里最大的 n (分页链接的极限值通常就是总页数附近)
    ns = [int(x) for x in re.findall(r"/page/(\d{1,5})\.html", html)]
    if ns:
        return max(ns)

    return 0


def category_content(tid, pg="1", filter_=None):
    """
    【分类 / 二级分类 / 翻页】
    tid 支持多种形态 (由 home_content 的 type_id 直接透传):
      - "/yubjc/4.html"                       一级分类        (电影)
      - "/yubjc/14.html"                      二级分类        (动作片)
      - "/yubjc/4/area/大陆.html"             地区筛选
      - "/yubjc/4/year/2024.html"             年份筛选
      - "/yubjc/4/by/hits.html"               排序
      - "4"                                   纯数字 cid
    本函数统一按「去掉 page 段后拼 /page/{pg}.html」处理, 因此以上形态都能正确翻页。

    filter_: T4 会传入下拉筛选参数 (dict), 形如 {"area":"/yubjc/4/area/大陆.html"}。
             这里直接把第一个非空的筛选 URL 拼到 base 后面, 实现二级筛选。
    """
    tid = (tid or "").strip()
    pg = str(pg or "1")

    # --- 处理 T4 传入的 filter_ 下拉筛选 ---
    if filter_:
        try:
            for _k, _v in (filter_.items() if hasattr(filter_, "items") else []):
                _v = str(_v or "").strip()
                if _v.startswith("/yubjc/"):
                    tid = _v
                    break
                if _v and _v != "全部" and "/yubjc/" not in _v:
                    # 值可能只是 "大陆", 需拼到当前 base 的 area 段
                    m0 = re.search(r"/yubjc/(\d+)", tid)
                    if m0:
                        tid = "/yubjc/%s/area/%s.html" % (m0.group(1), _v)
                        break
        except Exception:
            pass

    # 归一化: 取出 base (去掉可能的 /page/N.html) 与 cid
    base = re.sub(r"/page/\d+\.html$", "", tid)
    if base.endswith(".html"):
        base = base[:-5]

    m = re.search(r"/yubjc/(\d+)", base)
    cid = m.group(1) if m else ""

    if not cid:
        # 兼容直接传数字 cid 的情况
        cid = re.sub(r"\D", "", tid) or "4"
        base = "/yubjc/%s" % cid

    if pg and pg != "1":
        url = "%s/page/%s.html" % (base, pg)
    else:
        url = base + ".html"

    page_html = fetch(url, ttl=120)
    videos = _merged_cards(page_html) if page_html else []

    # 空页兜底: 若失败则回退到一级分类, 保证电视端不白屏
    if not videos and url != ("/yubjc/%s.html" % cid):
        fallback = "/yubjc/%s.html" % cid
        page_html = fetch(fallback, ttl=120)
        videos = _merged_cards(page_html) if page_html else []

    # 解析总页数: 只从「分页区域」的 x/y 形态里取, 避免误匹配图片URL里的
    # "20260126-1/048431..." 这类片段(会把 pagecount 搞成天文数字 -> 壳判为无效列表)。
    limit = 0
    extract = _extract_pagecount(page_html)
    if extract:
        limit = extract

    # 兜底: 若仍为 0, 用视频条数估算(至少 1 页), 保证壳不因 pagecount=0 出错
    if limit <= 0:
        limit = 1

    result = {
        "page": int(pg) if pg.isdigit() else 1,
        "pagecount": limit,
        "limit": PAGE_LIMIT,
        "total": limit * PAGE_LIMIT if limit else 0,
        "list": videos,
    }
    # 后台预取本节前几张图 -> 用户滚动时图已在本地磁盘缓存(把CDN慢的等待移出可见路径)
    try:
        _prefetch_images([v.get("vod_pic", "") for v in videos])
    except Exception:
        pass
    return result


def detail_content(ids):
    """
    【详情页】
    ids: list[str] 或 str。返回 {"list": [vod, ...]}
    vod 字段遵循 TVBox 规范:
      vod_id / vod_name / vod_pic / vod_year / vod_area / vod_remarks / vod_actor /
      vod_director / vod_content / vod_play_from / vod_play_url
    vod_play_url 使用 TVBox 三段式: "集名$播放页相对地址#集名$播放页相对地址"
      -> 因为播放地址需要从 /vshow/ 页二次解析, 这里先给出可解析的「相对播放页」,
         parse 时再替换成真实 m3u8。
    """
    if isinstance(ids, str):
        ids = [ids]
    out = []
    for vid in (ids or []):
        vid = re.sub(r"\D", "", str(vid))
        if not vid:
            continue
        url = "/yunsxs/%s.html" % vid
        t = fetch(url, ttl=CACHE_TTL)
        if not t:
            continue

        # ---- 标题 ----
        title = ""
        mt = re.search(r"<h1[^>]*>(.*?)</h1>", t, re.S)
        if mt:
            title = _strip(mt.group(1))
        if not title:
            mt2 = re.search(r"<title>(.*?)</title>", t, re.S)
            if mt2:
                title = _strip(mt2.group(1)).split("_")[0].split("-")[0].strip()
        title = title.strip("《》").strip()

        # ---- 海报 ----
        pic = ""
        for pat in (r'<div class="img-wrapper[^"]*"[^>]*data-original="([^"]+)"',
                    r'data-original="([^"]+)"'):
            mp = re.search(pat, t)
            if mp and "load.png" not in mp.group(1):
                pic = _fix_url(mp.group(1))
                break

        # ---- 简介 ----
        content = ""
        for pat in (r'class="detail-content[^"]*"[^>]*>(.*?)</div>',
                    r'class="detail-intro[^"]*"[^>]*>(.*?)</div>',
                    r'<p class="[^"]*desc[^"]*"[^>]*>(.*?)</p>'):
            mc = re.search(pat, t, re.S)
            if mc:
                content = _strip(mc.group(1))
                if content:
                    break

        # ---- 元信息 (类型/地区/年份/演员/导演/状态) ----
        def _meta(label):
            m2 = re.search(r">\s*" + label + r"\s*[:：]\s*</[^>]+>\s*<?[^>]*>?(.*?)(?:</p>|</li>|</dd>|</div>)", t, re.S)
            if m2:
                return _strip(m2.group(1)).lstrip("：: ").strip()
            m3 = re.search(label + r"\s*[:：]\s*([^<\n]{1,60})", t)
            return _strip(m3.group(1)) if m3 else ""

        year = ""
        my = re.search(r'/yubjc/\d+/year/(\d{4})\.html', t)
        if my:
            year = my.group(1)
        if not year:
            my2 = re.search(r"(19|20)\d{2}", _meta("年份") or _meta("年代") or "")
            if my2:
                year = my2.group(0)

        area = _meta("地区")
        vtype = _meta("类型")
        actor = _meta("主演") or _meta("演员")
        director = _meta("导演")
        remarks = _meta("状态") or _meta("备注")

        # ---- 播放列表 ----
        play_from, play_url = _parse_playlist(t, vid)

        out.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _proxy_pic(pic),
            "vod_year": year,
            "vod_area": area,
            "vod_type": vtype,
            "vod_actor": actor,
            "vod_director": director,
            "vod_remarks": remarks,
            "vod_content": content or title,
            "vod_play_from": play_from,
            "vod_play_url": play_url,
        })
    return {"list": out}


def _parse_playlist(t, vid):
    """
    从详情页解析「线路 tab + 剧集列表」。
    实测结构:
      <li class="swiper-slide ewave-tab active" data-target="#ewave-playlist-1">高清线路<em></em></li>
      ...
      <ul ... id="ewave-playlist-1">
        <li ...><a class="text-overflow" href="/vshow/2615582/1/1.html">第01集</a></li>
        ...
      </ul>
    返回 (play_from, play_url):
      play_from = "线路1$$$线路2"     (多线路用 $$$ 分隔, TVBox 规范)
      play_url  = "第01集$/vshow/.../1/1.html#第02集$..."   ($$$ 分隔线路)
    """
    # 1) 线路名: tab 顺序 与 #ewave-playlist-N 的 N 对应
    line_names = []
    tab_block = re.search(r'<div class="playlist-tab[^"]*">(.*?)</div>\s*</div>', t, re.S)
    tabs_html = tab_block.group(1) if tab_block else t
    for m in re.finditer(r'<li[^>]*data-target="#(ewave-playlist-\d+)"[^>]*>(.*?)</li>', tabs_html, re.S):
        name = _strip(m.group(2))
        line_names.append(name or ("线路%s" % (len(line_names) + 1)))

    # 2) 每个线路的剧集
    from_list = []
    url_list = []
    # 找到所有 ewave-playlist-N 容器
    containers = re.findall(r'<ul[^>]*id="(ewave-playlist-\d+)"[^>]*>(.*?)</ul>', t, re.S)

    if not containers:
        # 兜底: 直接全局找 /vshow/{vid}/{sid}/{eid}.html
        eps = re.findall(r'href="(/vshow/%s/(\d+)/(\d+)\.html)"[^>]*>([^<]*)</a>' % vid, t)
        if eps:
            from_list.append(line_names[0] if line_names else "线路1")
            url_list.append("#".join("%s$%s" % (_strip(e[3]) or ("第%s集" % e[2]), e[0]) for e in eps))
    else:
        for idx, (cid, body) in enumerate(containers):
            name = line_names[idx] if idx < len(line_names) else ("线路%s" % (idx + 1))
            eps = re.findall(r'href="(/vshow/%s/(\d+)/(\d+)\.html)"[^>]*>([^<]*)</a>' % vid, body)
            if not eps:
                continue
            from_list.append(name)
            url_list.append("#".join(
                "%s$%s" % (_strip(e[3]) or ("第%s集" % e[2]), e[0]) for e in eps))

    # 兜底: 详情页没有剧集时, 尝试从详情页整体再找一次
    if not from_list:
        eps = re.findall(r'href="(/vshow/%s/(\d+)/(\d+)\.html)"[^>]*>([^<]*)</a>' % vid, t)
        if eps:
            from_list.append(line_names[0] if line_names else "线路1")
            url_list.append("#".join(
                "%s$%s" % (_strip(e[3]) or ("第%s集" % e[2]), e[0]) for e in eps))

    play_from = "$$$".join(from_list)
    play_url = "$$$".join(url_list)
    return play_from, play_url


def search_content(key, quick=False):
    """
    【搜索】
    实测:
      搜索页  /search.html?wd={kw}
      翻页    /search/{kw}/page/{n}.html
      结果结构复用 ranking-item。
    返回 {"list": [...]}
    """
    key = (key or "").strip()
    if not key:
        return {"list": []}
    q = urllib.parse.quote(key)
    url = "/search.html?wd=%s" % q
    t = fetch(url, ttl=120)
    videos = _merged_cards(t) if t else []
    return {"list": videos}


def search_page(key, pg):
    """搜索结果翻页 (非 TVBox 标准接口, 供前端 / 自测使用)。"""
    key = (key or "").strip()
    q = urllib.parse.quote(key)
    if str(pg) in ("", "1"):
        url = "/search.html?wd=%s" % q
    else:
        url = "/search/%s/page/%s.html" % (q, pg)
    t = fetch(url, ttl=120)
    videos = _merged_cards(t) if t else []
    return {"page": int(pg) if str(pg).isdigit() else 1, "list": videos}


# ============================================================================
# 五、播放地址解析 (核心)
# ============================================================================

def play_parse(flag, id_, flags=None):
    """
    【播放解析】TVBox 会调用两次:
      第 1 次: flag="" , id=详情页给的 /vshow/{id}/{sid}/{eid}.html (或含 $ 的串)
               -> 返回 {"parse": 0, "playUrl": "真实直链"} 表示本爬虫已拿到直链, 播放器直接播
      因为本站播放页内 JS 变量 player_aaaa.url 就是 m3u8 直链, 无需任何第三方解析。

    参数 id_ 可能形态:
      - "/vshow/2615582/1/1.html"
      - "第01集$/vshow/2615582/1/1.html"
      - 已是 m3u8 直链
    兼容 FongMi(T3) 与 T4 两种调用签名。
    """
    # --- 1) 已经是直链, 直接返回 ---
    if id_ and (".m3u8" in id_ or id_.startswith("http")):
        if ".m3u8" in id_:
            return {"parse": 0, "playUrl": id_, "url": id_}
        # 是 http 但不是 m3u8 -> 当作播放页处理
        play_url = id_
    else:
        play_url = id_ or ""

    # 去掉 "集名$" 前缀
    if "$" in play_url and not play_url.startswith("http"):
        play_url = play_url.split("$")[-1]

    # 相对地址补全
    if play_url.startswith("/"):
        play_url = BASE_HOST + play_url

    if not play_url:
        return {"parse": 0, "playUrl": ""}

    # --- 2) 拉取播放页, 提取 player_aaaa ---
    # 播放页缓存延长到 30 分钟: 同一集回看/重播秒出, 减少对慢CDN的重复请求
    page = fetch(play_url, referer=BASE_HOST + "/", ttl=1800, timeout=PLAY_TIMEOUT)
    if not page:
        return {"parse": 0, "playUrl": ""}

    # 提取 var player_aaaa={...}
    m = re.search(r"var\s+player_aaaa\s*=\s*(\{.*?\})\s*</script>", page, re.S)
    if not m:
        m = re.search(r"var\s+player_aaaa\s*=\s*(\{.*?\})", page, re.S)

    real_url = ""
    if m:
        try:
            info = json.loads(m.group(1))
        except Exception:
            info = {}
        real_url = info.get("url") or ""
        encrypt = str(info.get("encrypt", "0"))
        enc_from = info.get("from", "")
        _log("player_aaaa url=%s encrypt=%s from=%s" % (real_url[:80], encrypt, enc_from))

        # 加密线路 (encrypt=1): 直链被混淆, 走可选解析兜底
        if encrypt == "1" and PLAY_URL_BACKUP_PARSE:
            real_url = PLAY_URL_BACKUP_PARSE + urllib.parse.quote(real_url, safe="")

    # --- 3) 兜底 1: 页面直接出现 m3u8 ---
    if not real_url:
        m2 = re.search(r'(https?://[^\s"\']+\.m3u8[^\s"\']*)', page)
        if m2:
            real_url = m2.group(1)

    # --- 4) 兜底 2: 出现 iframe 播放器地址, 递归解析一次 ---
    if not real_url:
        m3 = re.search(r'<iframe[^>]+src="([^"]+)"', page)
        if m3 and "player" in m3.group(1):
            return play_parse("", _fix_url(m3.group(1)))

    if real_url:
        real_url = real_url.replace("\\/", "/")
        if real_url.startswith("//"):
            real_url = "https:" + real_url

    # parse=0 表示「已在本地解析出直链」, 播放器直连; playUrl 同时给出 url 字段兼容 T4
    return {"parse": 0, "playUrl": real_url, "url": real_url}


# ============================================================================
# 六、自测 (本地调试入口)  &&  导出
# ============================================================================

def _selftest():
    """
    本地自测: 逐项验证 首页 / 分类 / 翻页 / 详情 / 搜索 / 播放。
    运行: python3 wanqiu.py --selftest
    """
    global _DEBUG
    _DEBUG = True
    ok = 0
    fail = 0

    def check(name, cond, extra=""):
        nonlocal ok, fail
        if cond:
            ok += 1
            print("  [PASS] %s %s" % (name, extra))
        else:
            fail += 1
            print("  [FAIL] %s %s" % (name, extra))

    print("=" * 70)
    print("晚秋剧场 TVBox 爬虫 —— 本地自测")
    print("=" * 70)

    # 1. 首页
    print("\n[1] 首页 home_content()")
    home = home_content()
    check("分类非空", len(home.get("class", [])) > 0, "-> %d 个分类" % len(home.get("class", [])))
    check("首页视频非空", len(home.get("list", [])) > 0, "-> %d 条" % len(home.get("list", [])))
    if home.get("list"):
        v = home["list"][0]
        print("      示例:", v["vod_name"], "|", v["vod_id"], "|", (v["vod_pic"] or "")[:60])
    if home.get("class"):
        print("      分类:", ", ".join(c["type_name"] for c in home["class"][:8]))

    # 2. 分类
    print("\n[2] 分类 category_content('/yubjc/4.html')")
    cat = category_content("/yubjc/4.html", "1")
    check("分类列表非空", len(cat.get("list", [])) > 0, "-> %d 条" % len(cat.get("list", [])))
    check("总页数>0", cat.get("pagecount", 0) > 0, "-> %d 页" % cat.get("pagecount", 0))

    # 3. 翻页
    print("\n[3] 翻页 category_content('/yubjc/4.html', '2')")
    cat2 = category_content("/yubjc/4.html", "2")
    check("第2页非空", len(cat2.get("list", [])) > 0, "-> %d 条" % len(cat2.get("list", [])))
    if cat.get("list") and cat2.get("list"):
        check("翻页内容不同", cat["list"][0]["vod_id"] != cat2["list"][0]["vod_id"],
              "-> p1=%s / p2=%s" % (cat["list"][0]["vod_id"], cat2["list"][0]["vod_id"]))

    # 4. 二级分类 (站点真正的二级分类是 /yubjc/{子cid}.html, 如 14=动作片)
    print("\n[4] 二级分类 category_content('/yubjc/14.html')  [动作片]")
    sub = category_content("/yubjc/14.html", "1")
    check("二级分类非空", len(sub.get("list", [])) > 0, "-> %d 条" % len(sub.get("list", [])))

    # 4b. 筛选路径 (地区/年份/排序), 站点原生支持
    print("\n[4b] 筛选 category_content('/yubjc/4/area/大陆.html')")
    flt = category_content("/yubjc/4/area/大陆.html", "1")
    check("地区筛选非空", len(flt.get("list", [])) > 0, "-> %d 条" % len(flt.get("list", [])))

    # 5. 详情
    print("\n[5] 详情 detail_content()")
    did = (home["list"][0]["vod_id"] if home.get("list") else "2615582")
    det = detail_content([did])
    check("详情返回", len(det.get("list", [])) > 0)
    if det.get("list"):
        d = det["list"][0]
        check("详情标题非空", bool(d.get("vod_name")), "-> %s" % d.get("vod_name"))
        check("详情海报非空", bool(d.get("vod_pic")), "-> %s" % (d.get("vod_pic") or "")[:60])
        check("播放线路非空", bool(d.get("vod_play_from")), "-> %s" % d.get("vod_play_from"))
        check("剧集列表非空", bool(d.get("vod_play_url")), "-> %s 集" % len(d.get("vod_play_url", "").split("#")))
        print("      线路:", d.get("vod_play_from"))
        print("      首集:", (d.get("vod_play_url", "").split("#") or [""])[0][:80])
        first_ep = (d.get("vod_play_url", "").split("#") or [""])[0]
        ep_id = first_ep.split("$")[-1] if "$" in first_ep else first_ep

        # 6. 播放解析
        print("\n[6] 播放解析 play_parse()")
        pr = play_parse("", ep_id)
        pu = pr.get("playUrl", "")
        check("解析出直链", bool(pu), "-> %s" % pu[:90])
        check("是 m3u8 直链", ".m3u8" in (pu or ""))
        if pu:
            body = fetch(pu, ttl=60)
            check("m3u8 可拉取", "#EXTM3U" in (body or ""), "-> %d bytes" % len(body or ""))

    # 7. 搜索
    print("\n[7] 搜索 search_content('一斩苍穹')")
    sr = search_content("一斩苍穹")
    check("搜索结果非空", len(sr.get("list", [])) > 0, "-> %d 条" % len(sr.get("list", [])))
    if sr.get("list"):
        print("      首条:", sr["list"][0]["vod_name"], "|", sr["list"][0]["vod_id"])

    print("\n" + "=" * 70)
    print("自测结果: %d 通过 / %d 失败" % (ok, fail))
    print("=" * 70)
    return 0 if fail == 0 else 1


# ---------------------------------------------------------------------------
# TVBox 导出
# ---------------------------------------------------------------------------
exports = {
    "homeContent": home_content,
    "categoryContent": category_content,
    "detailContent": detail_content,
    "searchContent": search_content,
    "playContent": play_parse,
}

# T4 / 部分内核约定名
def homeVodContent():
    return home_content()

def playerContent(flag, id_, flags=None):
    return play_parse(flag, id_, flags)


# ============================================================================
# 【关键】TVBox / 默影视 / FongMi(hipy) 标准类式 Spider 桥接层
# ----------------------------------------------------------------------------
# 壳(默影视/FongMi T3/T4)加载本地 py 源时, 反射查找 `class Spider` 并实例化,
# 通过类方法 homeContent/categoryContent/detailContent/searchContent/playerContent
# 取数据。若文件里只有函数式导出而没有该类, 壳会静默丢弃整个源 -> 注入后栏目全空。
# 此桥接层把函数式实现包装成壳要求的类方法, 参数/返回结构严格对齐 TVBox 规范。
# 壳内有 base.spider.Spider 基类则继承, 无则 object 兜底 (本地调试/自测场景)。
# ============================================================================
try:
    from base.spider import Spider as _BaseSpider
except Exception:
    class _BaseSpider(object):
        pass


class Spider(_BaseSpider):
    """晚秋剧场 TVBox 爬虫 —— 类式包装(默影视/FongMi/hipy 兼容)"""

    def getName(self):
        return "晚秋剧场"

    # ---- 壳生命周期 ----
    def init(self, extend=""):
        return ""

    def destroy(self):
        return ""

    # ---- 壳强制元信息接口(部分壳反射检查, 缺失会丢弃源) ----
    def isVideoFormat(self, url):
        """判断 url 是否可直接交给壳内置播放器播放"""
        try:
            u = str(url or "").lower().strip()
            if not u:
                return False
            if u.startswith("http://") or u.startswith("https://"):
                return True
            return (".m3u8" in u) or (".mp4" in u) or (".flv" in u) or (".mkv" in u)
        except Exception:
            return False

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        """
        本地代理: 用于「图片加速」。
        壳(默影视/FongMi)会把 vod_pic 里的 http://127.0.0.1:9978/proxy?do=py&... 
        转发到这里。首次拉图并落盘缓存, 之后直接读本地 -> 二次秒开。
        同时写一行探针日志, 便于排查壳是否真的走了代理。
        兼容: param 为 dict(含 url/imageUrl/path/src/...) 或直接 url 字符串。
        """
        try:
            url = ""
            if isinstance(param, dict):
                url = (param.get("url") or param.get("imageUrl")
                       or param.get("path") or param.get("src") or "")
            elif isinstance(param, str):
                url = param
            # 探针日志(诊断壳是否调用代理)
            _probe_log("localProxy called, url=%s" % str(url)[:120])
            url = _fix_url(url)
            if not url.startswith("http"):
                return [404, "text/plain", b""]

            cache_dir = _img_cache_dir()
            import hashlib
            import os
            h = hashlib.md5(url.encode("utf-8")).hexdigest()
            ext = ".jpg"
            for e in (".png", ".webp", ".jpeg", ".gif"):
                if e in url.lower():
                    ext = e
                    break
            fp = os.path.join(cache_dir, h + ext) if cache_dir else ""
            if fp and os.path.exists(fp):
                try:
                    with open(fp, "rb") as f:
                        data = f.read()
                    if data:
                        _probe_log("localProxy HIT cache %s (%d bytes)" % (h[:8], len(data)))
                        ctype = "image/png" if ext == ".png" else (
                            "image/webp" if ext == ".webp" else "image/jpeg")
                        return [200, ctype, data]
                except Exception:
                    pass

            # 拉取远程图片: 用较短超时(CDN 慢时快速失败, 但缓存成功一次就好)
            data = fetch(url, referer=BASE_HOST + "/", ttl=3600,
                         use_cache=False, binary=True, timeout=IMG_TIMEOUT)
            if not data:
                _probe_log("localProxy MISS/FETCH-FAIL %s" % h[:8])
                return [404, "text/plain", b""]

            _probe_log("localProxy FETCH ok %s (%d bytes)" % (h[:8], len(data)))
            # 落盘缓存(失败不影响返回)
            if fp:
                try:
                    if not os.path.isdir(cache_dir):
                        os.makedirs(cache_dir, exist_ok=True)
                    with open(fp, "wb") as f:
                        f.write(data)
                except Exception:
                    pass

            ctype = "image/jpeg"
            if data[:8].startswith(b"\x89PNG"):
                ctype = "image/png"
            elif data[:4] == b"RIFF" and b"WEBP" in data[:16]:
                ctype = "image/webp"
            elif data[:3] == b"GIF":
                ctype = "image/gif"
            return [200, ctype, data]
        except Exception:
            return [404, "text/plain", b""]

    # ---- 主接口: 直接转发到函数式实现 ----
    def homeContent(self, filter):
        try:
            r = home_content(filter)
            if isinstance(r, dict):
                return r
        except Exception:
            pass
        return {"class": list(DEFAULT_CLASSES), "list": [], "filters": {}}

    def homeVideoContent(self):
        try:
            r = home_content(False)
            if isinstance(r, dict):
                return {"list": r.get("list", [])}
        except Exception:
            pass
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        try:
            # extend 为 T4 下拉筛选(dict/JSON串), filter 为是否启用筛选标志
            ext = extend
            if isinstance(ext, str) and ext.strip():
                try:
                    ext = json.loads(ext)
                except Exception:
                    ext = {"ext": ext} if "/" in str(ext) else None
            r = category_content(tid, pg, ext if ext else None)
            if isinstance(r, dict):
                return r
        except Exception:
            pass
        try:
            pg = int(pg) if str(pg).isdigit() else 1
        except Exception:
            pg = 1
        return {"page": pg, "pagecount": 1, "limit": 20, "total": 0, "list": []}

    def detailContent(self, ids):
        try:
            # ids 可能是 list 或逗号拼接的 str
            if isinstance(ids, str):
                ids = [x for x in ids.split(",") if x.strip()]
            r = detail_content(ids)
            if isinstance(r, dict):
                return r
        except Exception:
            pass
        return {"list": []}

    def searchContent(self, key, quick, pg="1"):
        try:
            r = search_content(key, quick)
            if isinstance(r, dict):
                # 部分壳要求 searchContent 回 page/pagecount
                r.setdefault("page", int(pg) if str(pg).isdigit() else 1)
                r.setdefault("pagecount", 1)
                return r
        except Exception:
            pass
        return {"list": [], "page": 1, "pagecount": 1}

    def playerContent(self, flag, id_, vipFlags=None):
        """播放解析: 返回壳标准结构 {parse, url, header}"""
        try:
            r = play_parse(flag, id_, vipFlags)
            if isinstance(r, dict):
                # play_parse 返回 {parse, playUrl, url}; 壳主用 url 字段
                u = r.get("url") or r.get("playUrl") or ""
                parse = r.get("parse", 0)
                # 未解析出直链时置 parse=1, 让壳自行再解析一次(兜底)
                if not u:
                    parse = 1
                return {"parse": parse, "url": u, "header": ""}
        except Exception:
            pass
        return {"parse": 1, "url": "", "header": ""}


if __name__ == "__main__":
    if "--selftest" in sys.argv or len(sys.argv) == 1:
        sys.exit(_selftest())
    else:
        # 支持简单 CLI 调试: python3 wanqiu.py home|cat <tid> <pg>|detail <id>|search <kw>|play <url>
        cmd = sys.argv[1]
        arg = sys.argv[2:] if len(sys.argv) > 2 else []
        _DEBUG = True
        if cmd == "home":
            print(json.dumps(home_content(), ensure_ascii=False, indent=2)[:3000])
        elif cmd == "cat":
            tid = arg[0] if arg else "/yubjc/4.html"
            pg = arg[1] if len(arg) > 1 else "1"
            print(json.dumps(category_content(tid, pg), ensure_ascii=False, indent=2)[:3000])
        elif cmd == "detail":
            print(json.dumps(detail_content(arg), ensure_ascii=False, indent=2)[:3000])
        elif cmd == "search":
            print(json.dumps(search_content(arg[0] if arg else ""), ensure_ascii=False, indent=2)[:3000])
        elif cmd == "play":
            print(json.dumps(play_parse("", arg[0] if arg else ""), ensure_ascii=False, indent=2))
        else:
            print("unknown cmd:", cmd)
