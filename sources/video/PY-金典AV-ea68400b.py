# LumeSource: {"id":"pypack_ccbbb52aea68400b","name":"金典AV","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
============================================================
 Erotic Movies (eroticmv.com)  TVBox/影视仓/OK影视 爬虫
============================================================
站点特性：
  - WordPress + Vidorev 主题 + Yoast SEO
  - 封面/播放地址均在详情页 HTML 的 og meta 中：
      og:image      -> 封面原图（wp-content/uploads，明文直连）
      og:video:url  -> "http://" + Base64(真实m3u8) + ".m3u8" 混淆
  - 播放源: vidcdn2.eroticmv.com（HLS，直连可播）

分类体系（WordPress 分类树，parent=0 三个维度）：
  Genre   题材   53 个子分类（Asian Erotica/Classic Erotica/Cheating...）
  Decades 年代    7 个子分类（1960s~2020s）
  Country 国家   28 个子分类（USA/Japan/India/Italy...）
  每个影片同属多维度分类，列表页按 URL 路径 /category/{组}/{子}/ 过滤

接口方式（纯 HTML 解析，零依赖）：
  列表/分类  /category/{group}/{slug}/page/{N}/   或首页 /page/{N}/
  详情       /{slug}/          -> og meta + entry-content
  搜索       /?s={kw}/page/{N}/
  播放       vidcdn2 域名 m3u8（Base64 解码还原）

播放线路（单线路，直连）：
  vidcdn2 CDN 实测（2026-10-14）对 m3u8 与 .ts 分片均不校验 Referer，
  明文 HLS 可直连播放。详情页解码 og:video:url 得到真实 m3u8 后
  **直接下发 http(s) 直连地址**，播放器自行拉取列表与分片；
  playerContent 附带 UA + Referer 头作双保险。
  （2026-10-15 起由代理线路改为直连；localProxy 仅保留向后兼容
  壳内旧缓存的 proxy:// 线路）
============================================================
"""

import base64
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SITE = "https://eroticmv.com"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}
TIMEOUT = 20

# ============================================================
# 分类树（构建时动态拉取，失败时用内置兜底）
# ============================================================

# 内置兜底分类：{组名: [(名称, slug), ...]}
BUILTIN_TREE = {
    "genre": [
        ("Asian Erotica", "asian-erotica"), ("Classic Erotica", "classic-erotica"),
        ("Cheating", "cheating"), ("Classic Porn", "classic-porn"),
        ("Newage Erotica", "newage-erotica"), ("Lesbian", "lesbian"),
        ("Exploitation", "exploitation"), ("Threesome", "threesome"),
        ("Incest", "incest"), ("School", "school"),
        ("Comedy", "comedy"), ("Young And Old", "young-and-old"),
        ("Historical", "historical"), ("Prostitution", "prostitution"),
        ("MILF", "milf"), ("Orgy", "orgy"),
        ("Science Fiction", "science-fiction"), ("Supernatural", "supernatural"),
        ("Newage Porn", "newage-porn"), ("Violence", "violence"),
        ("Bondage", "bondage"), ("Interracial", "interracial"),
        ("Cops", "cops"), ("Office", "office"),
        ("Maid", "maid"), ("Swinging", "swinging"),
        ("Voyeur", "voyeur"), ("Blackmail", "blackmail"),
        ("Prison", "prison"), ("Religious", "religious"),
        ("BDSM", "bdsm"), ("Fantasy", "fantasy"),
        ("Educational", "educational"), ("Nurse", "nurse"),
        ("Harem", "harem"), ("Mind Control", "mind-control"),
        ("Nuns", "nuns"), ("Gangbang", "gangbang"),
        ("Vampire", "vampire"), ("Monster", "monster"),
        ("Ghost", "ghost"), ("Chikan", "chikan"),
        ("Cuckold", "cuckold"), ("Femdom", "femdom"),
        ("Gay", "gay"), ("Snuff", "snuff"),
        ("Witches", "witches"), ("Animation", "animation"),
        ("Cosplay", "cosplay"), ("Parody", "parody"),
        ("Gender Bender", "gender-bender"), ("Infantilism", "infantilism"),
        ("Vanilla", "vanilla"),
    ],
    "decades": [
        ("2020s", "2020s"), ("2010s", "2010s"), ("2000s", "2000s"),
        ("1990s", "1990s"), ("1980s", "1980s"), ("1970s", "1970s"),
        ("1960s", "1960s"),
    ],
    "country": [
        ("USA", "usa"), ("Japan", "japan"), ("India", "india"),
        ("Italy", "italy"), ("France", "france"), ("Korea", "korea"),
        ("China", "china"), ("Germany", "germany"), ("Thailand", "thailand"),
        ("Spain", "spain"), ("Philippines", "philippines"), ("Brazil", "brazil"),
        ("Canada", "canada"), ("Denmark", "denmark"), ("Sweden", "sweden"),
        ("England", "england"), ("Switzerland", "switzerland"),
        ("Australia", "australia"), ("Austria", "austria"), ("Greece", "greece"),
        ("Israel", "israel"), ("Mexico", "mexico"), ("Poland", "poland"),
        ("Russia", "russia"), ("Scotland", "scotland"), ("Turkey", "turkey"),
        ("Hungary", "hungary"), ("Netherlands", "netherlands"),
    ],
}

# TVBox 一级分类
CLASSES = [
    {"type_id": "all",     "type_name": "最新更新"},
    {"type_id": "genre",   "type_name": "题材 Genre"},
    {"type_id": "decades", "type_name": "年代 Decades"},
    {"type_id": "country", "type_name": "国家 Country"},
]

_GROUP_NAMES = {"genre": "题材", "decades": "年代", "country": "国家"}
_TREE = None
_TREE_TS = 0.0
_IDS = {"_root": {}}  # {group: {slug: 分类id}, "_root": {group: 父分类id}}


def _http(url, retry=2):
    last = None
    for i in range(retry + 1):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            return urllib.request.urlopen(req, timeout=TIMEOUT).read()
        except Exception as e:  # noqa: BLE001
            last = e
            if i < retry:
                time.sleep(0.4 * (i + 1))
    raise RuntimeError("请求失败: %s -> %s" % (url, last))


def _http_text(url, retry=2):
    return _http(url, retry=retry).decode("utf-8", errors="ignore")


def _load_tree():
    """从 WP REST API 拉分类树 + 分类 ID 映射（10 分钟缓存）"""
    global _TREE, _TREE_TS, _IDS
    now = time.time()
    if _TREE is not None and now - _TREE_TS < 600:
        return _TREE
    try:
        cats = []
        page = 1
        while page <= 6:
            body = _http("%s/wp-json/wp/v2/categories?per_page=100&page=%d" % (SITE, page), retry=1)
            batch = json.loads(body.decode("utf-8", errors="replace"))
            if not isinstance(batch, list) or not batch:
                break
            cats.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        tree, ids = {}, {"_root": {}}
        for group in ("genre", "decades", "country"):
            parent = [c for c in cats if c.get("slug") == group and c.get("parent") == 0]
            if parent:
                ids["_root"][group] = parent[0]["id"]
            subs = [c for c in cats if c.get("parent") and _group_of_slug(c) == group]
            ids[group] = {c["slug"]: c["id"] for c in subs}
            count_by_id = {c["id"]: c.get("count", 0) for c in cats}
            slug_count = {c["slug"]: count_by_id.get(c["id"], 0) for c in subs}
            tree[group] = sorted([(c["name"], c["slug"]) for c in subs],
                                 key=lambda kv: -slug_count.get(kv[1], 0))
        if all(tree.get(g) for g in ("genre", "decades", "country")):
            _TREE, _IDS, _TREE_TS = tree, ids, now
            return tree
    except Exception:  # noqa: BLE001
        pass
    return BUILTIN_TREE


def _wp_total(cat_id=None):
    """用 WP REST API 响应头拿精确 X-WP-Total，失败返回 0"""
    url = "%s/wp-json/wp/v2/posts?per_page=1" % SITE
    if cat_id:
        url += "&categories=%d" % cat_id
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        resp.read()
        return int(resp.headers.get("X-WP-Total") or 0)
    except Exception:  # noqa: BLE001
        return 0


def _group_of_slug(cat):
    """判断 WP 分类属于哪个维度：link 路径 /category/{group}/{slug}/"""
    link = cat.get("link") or ""
    m = re.search(r"/category/([a-z0-9-]+)/([a-z0-9-]+)/", link)
    if not m:
        return None
    parent_group = m.group(1)
    if parent_group in ("genre", "decades", "country"):
        return parent_group
    return None


# ============================================================
# HTML 解析
# ============================================================

_ITEM_RE = re.compile(
    r'<a data-post-id="(\d+)"\s+href="([^"]+)"\s+title="([^"]*)"\s+class="blog-img"'
    r'(.{0,2500}?)</a>',
    re.S)


def _parse_list(html):
    """解析列表页 article 块 -> [ {id, name, pic, link} ]"""
    out = []
    seen = set()
    for m in _ITEM_RE.finditer(html):
        pid, link, title, tail = m.group(1), m.group(2), m.group(3), m.group(4)
        if pid in seen:
            continue
        seen.add(pid)
        # 封面：优先 data-srcset 最大尺寸 -> 去掉尺寸后缀拿原图
        pic = ""
        srcset = re.search(r'data-srcset="([^"]+)"', tail)
        if srcset:
            cands = [c.strip().split(" ")[0] for c in srcset.group(1).split(",") if c.strip()]
            cands = [c for c in cands if c.startswith("http")]
            if cands:
                pic = cands[-1]
        if not pic:
            msrc = re.search(r'data-src="([^"]+)"', tail)
            if msrc:
                pic = msrc.group(1)
        # 去尺寸后缀取原图（-165x248 / -360x540 -> 原图）
        if pic:
            pic = re.sub(r"-\d+x\d+(\.\w+)$", r"\1", pic)
        title = re.sub(r"<[^>]+>", "", title).strip()
        title = title.replace("&amp;", "&").replace("&#038;", "&")
        out.append({"vod_id": pid, "vod_name": title, "vod_pic": pic, "link": link})
    return out


def _parse_pagemax(html, current):
    """解析分页数字链接取最大页；解析不到返回 current"""
    pages = [int(x) for x in re.findall(r'/page/(\d+)/', html)]
    pages = [p for p in pages if p > 0]
    return max(pages) if pages else current


def _decode_play_url(raw):
    """og:video:url -> 真实 m3u8：
       http://<Base64(真实URL)>.m3u8 -> 解码"""
    if not raw:
        return ""
    s = raw.strip()
    if s.startswith("http://") or s.startswith("https://"):
        s = re.sub(r"^https?://", "", s)
    if s.endswith(".m3u8"):
        s = s[:-5]
    # 补齐 base64 padding 后解码
    try:
        pad = "=" * (-len(s) % 4)
        url = base64.b64decode(s + pad).decode("utf-8", "replace")
        if url.startswith("http"):
            return url
    except Exception:  # noqa: BLE001
        pass
    # 兜底：整串按 base64 解（自动忽略非法字符）
    try:
        pad = "=" * (-len(s) % 4)
        url = base64.b64decode(s + pad).decode("utf-8", "replace")
        if url.startswith("http"):
            return url
    except Exception:  # noqa: BLE001
        pass
    return raw if raw.startswith("http") else ""


# ============================================================
# 本地代理（向后兼容：壳内旧缓存的 proxy:// 线路仍可回源）
# ============================================================
# vidcdn2.eroticmv.com CDN 行为（2026-10-14 实测）：
#   m3u8 与 .ts 分片均不强制校验 Referer，明文 HLS 可直连播放。
# 播放线路自 2026-10-15 起改为**直连**：详情页解码 og:video:url 后
# 直接下发真实 m3u8 地址，播放器自行拉取列表与分片。此处 localProxy
# 仅用于兼容旧缓存/旧配置里的 proxy://do=py 线路（含 type= 路由），
# 代理返回时同样只把分片 URI 绝对化为 https 直连地址——播放器 HLS
# 解码器只认 http(s) scheme，嵌套 proxy:// 会「能加载列表但播不出画面」。

# type=<spiderName> 为 TVBox 标准 localProxy 路由参数:
# 壳(真机)与测试器都靠它把 proxy:// 请求路由回本 spider;
# 缺 type 时测试器多源同载场景下无法定位宿主 → 分片 400 → 播放器误报「解码失败」
PROXY_PREFIX = "proxy://do=py&type=%s&url=" % urllib.parse.quote("Erotic Movies")

# 代理响应缓存（VOD 静态内容；播放器拖动进度条会重复请求同一分片）
_PROXY_CACHE = {}
_PROXY_CACHE_LOCK = threading.Lock()
_PROXY_CACHE_TTL = 600          # 10 分钟


def _proxy_url(target):
    """真实地址 -> 本地代理触发地址"""
    return PROXY_PREFIX + urllib.parse.quote(target, safe="")


def _proxy_fetch(target, timeout=30, retry=3, use_cache=True):
    """
    代理请求：强制附加 UA + Referer（CDN 必需）。
    CDN 存在抖动（偶发超时），重试抵御；VOD 静态内容带 TTL 缓存。
    """
    if use_cache:
        with _PROXY_CACHE_LOCK:
            hit = _PROXY_CACHE.get(target)
            if hit and time.time() - hit[0] < _PROXY_CACHE_TTL:
                return hit[1]
    headers = dict(HEADERS)
    headers["Referer"] = SITE + "/"
    last = None
    for i in range(retry):
        try:
            req = urllib.request.Request(target, headers=headers)
            body = urllib.request.urlopen(req, timeout=timeout).read()
            if use_cache:
                with _PROXY_CACHE_LOCK:
                    if len(_PROXY_CACHE) > 500:
                        _PROXY_CACHE.clear()
                    _PROXY_CACHE[target] = (time.time(), body)
            return body
        except Exception as e:  # noqa: BLE001
            last = e
            if i < retry - 1:
                time.sleep(0.5 * (i + 1))
    raise last if last else RuntimeError("proxy fetch failed")


def _abs_uri(uri, base):
    """相对 URI -> 绝对地址（已是 http(s) 的原样返回）"""
    if uri.startswith("http://") or uri.startswith("https://"):
        return uri
    return base + uri


def _rewrite_m3u8(text, base_url):
    """
    重写 m3u8：分片/子列表 URI 一律绝对化为 https 直连地址。
    **不包 proxy:// 前缀**——播放器底层 HLS 解码器只认 http(s) scheme，
    嵌套 proxy:// 会导致分片请求发不出去（能加载列表但播不出画面）。
    CDN 实测不校验 Referer，分片直连可播；m3u8 列表本身由 localProxy
    代请求（附加 UA + Referer），兼顾丢头场景。
    支持 media playlist（.ts）与 master playlist（子 m3u8）两级。
    """
    if not text:
        return text
    base = base_url.rsplit("/", 1)[0] + "/"
    out_lines = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            # EXT-X-KEY:URI="..." / EXT-X-MAP:URI="..." 内嵌 URI 也绝对化
            if s.startswith("#") and "URI=\"" in s:
                def _sub(m):
                    return "URI=\"%s\"" % _abs_uri(m.group(1), base)
                line = re.sub(r"URI=\"([^\"]+)\"", _sub, line)
            out_lines.append(line)
            continue
        # 非 # 行 = 分片/子列表地址（相对或绝对）-> 绝对化后直连
        out_lines.append(_abs_uri(s, base))
    return "\n".join(out_lines)


def _parse_detail(html):
    """详情页 og meta + 正文"""
    d = {}

    m = re.search(r'og:image"\s+content="([^"]+)"', html)
    d["pic"] = m.group(1) if m else ""
    m = re.search(r'og:video:url"\s+content="([^"]+)"', html)
    d["play"] = _decode_play_url(m.group(1)) if m else ""
    m = re.search(r"<title>([^<]+)</title>", html)
    d["title"] = m.group(1).strip() if m else ""
    # 分类（category/genre/xxx 链接）
    cats = re.findall(r'/category/([a-z0-9-]+)/([a-z0-9-]+)/"[^>]*class="category-item[^"]*"[^>]*>([^<]+)<', html)
    d["cats"] = [{"group": g, "slug": s, "name": n.strip()} for g, s, n in cats]
    # 简介：优先 Description 段，其次 Also known as 之后的正文，最后 entry-content 首段
    intro = ""
    m = re.search(r"Description:</strong>\s*(.{20,900}?)(?:</p>|<br\s*/?>|<strong|Also known as|<iframe)", html, re.S)
    if m:
        intro = m.group(1)
    if not intro:
        m = re.search(r"Description:\s*(.{20,900}?)(?:</p>|<br\s*/?>|<strong|Also known as|<iframe)", html, re.S)
        if m:
            intro = m.group(1)
    if not intro:
        m = re.search(r'class="[^"]*entry-content[^"]*"[^>]*>(.{0,3000})', html, re.S)
        if m:
            seg = re.sub(r"<script.*?</script>", "", m.group(1), flags=re.S)
            seg = re.sub(r"<iframe.*?</iframe>", "", seg, flags=re.S)
            seg = re.sub(r"<style.*?</style>", "", seg, flags=re.S)
            txt = re.sub(r"<[^>]+>", "\n", seg)
            lines = [l.strip() for l in txt.split("\n")
                     if len(l.strip()) >= 20 and not l.startswith("Click to rate")
                     and not l.startswith("Also known as")]
            intro = lines[0] if lines else ""
    d["intro"] = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", intro)).strip()[:800]
    return d


# ============================================================
# TVBox 标准蜘蛛接口
# ============================================================

class Spider(object):

    def init(self, extend=""):
        pass

    def getName(self):
        return "Erotic Movies"

    # -------------------- 首页 --------------------

    def homeContent(self, filter):
        result = {"class": CLASSES}
        if filter:
            tree = _load_tree()
            filters = {}
            for c in CLASSES:
                flt = []
                for group in ("genre", "decades", "country"):
                    items = [{"n": "全部", "v": ""}] + [
                        {"n": name, "v": slug} for name, slug in tree.get(group, [])]
                    flt.append({
                        "key": group,
                        "name": _GROUP_NAMES[group],
                        "value": items,
                    })
                filters[c["type_id"]] = flt
            result["filters"] = filters
        return result

    def homeVideoContent(self):
        result = {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}
        try:
            html = _http_text(SITE + "/")
            items = _parse_list(html)
            result["list"] = [self._to_vod(x) for x in items]
            result["pagecount"] = _parse_pagemax(html, 1)
            result["total"] = len(items)
        except Exception:  # noqa: BLE001
            pass
        return result

    # -------------------- 分类列表 --------------------

    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg or 1)
        result = {"list": [], "page": pg, "pagecount": 1, "limit": 20, "total": 0}

        # extend -> {genre, decades, country}
        ext = {}
        if extend:
            if isinstance(extend, str):
                try:
                    ext = json.loads(extend)
                except Exception:  # noqa: BLE001
                    ext = dict(urllib.parse.parse_qsl(extend))
            elif isinstance(extend, dict):
                ext = dict(extend)

        # 确保分类树已加载（壳可能直接调本方法）
        _load_tree()

        group = slug = ""
        # 优先级 genre > decades > country
        for g in ("genre", "decades", "country"):
            v = str(ext.get(g) or "").strip()
            if v:
                group, slug = g, v
                break

        # 构造列表 URL（WP 路径分页 /page/N/）
        if group and slug:
            url = "%s/category/%s/%s/" % (SITE, group, slug)
        elif tid in ("genre", "decades", "country"):
            url = "%s/category/%s/" % (SITE, tid)
        else:
            url = SITE + "/"
        if pg > 1:
            url = url.rstrip("/") + "/page/%d/" % pg

        # 精确 total（X-WP-Total 头）；pagecount 以 HTML 页码链接为准
        cat_id = None
        if group and slug:
            cat_id = (_IDS.get(group) or {}).get(slug)
        elif tid in ("genre", "decades", "country"):
            cat_id = (_IDS.get("_root") or {}).get(tid)
        wp_total = _wp_total(cat_id)

        try:
            html = _http_text(url)
            items = _parse_list(html)
            result["list"] = [self._to_vod(x) for x in items]
            if wp_total:
                result["total"] = wp_total
            else:
                result["total"] = len(items)
            pagecount = _parse_pagemax(html, pg)
            if pagecount <= 1 and wp_total and items:
                # 页码链接解析失败时按每页篇数估算
                pagecount = (wp_total + len(items) - 1) // len(items)
            result["pagecount"] = max(1, pagecount)
        except Exception:  # noqa: BLE001
            if wp_total:
                result["total"] = wp_total
                result["pagecount"] = 999
        return result

    # -------------------- 详情 --------------------

    def detailContent(self, ids):
        vid = str(ids[0])
        url = ""
        if vid.startswith("http"):
            url = vid
        else:
            url = "%s/?p=%s" % (SITE, vid)  # WP 按 ID 访问
        try:
            html = _http_text(url)
        except Exception:  # noqa: BLE001
            return {"list": []}

        d = _parse_detail(html)
        if not d.get("title"):
            return {"list": []}

        cat_names = [c["name"] for c in d.get("cats", [])]
        year = ""
        mt = re.search(r"\((\d{4})\)", d.get("title") or "")
        if mt:
            year = mt.group(1)

        # 标题清洗: "Watch Babyface (1977) - Erotic Movies" -> "Babyface (1977)"
        name = d["title"]
        name = re.sub(r"\s*-\s*Erotic Movies\s*$", "", name)
        name = re.sub(r"^Watch\s+", "", name)

        play = d.get("play") or ""
        if play and not play.startswith("http"):
            play = ""

        # 单线路（直连）：og:video:url 解码后即为 vidcdn2 明文 m3u8，
        # CDN 实测不校验 Referer，直接下发 http(s) 地址由播放器拉取
        # 列表与分片；playerContent 附带 UA + Referer 头作双保险。
        # 解码失败时用 post id 兜底，播放时现场再解码。
        froms, urls = [], []
        froms.append("直连线路")
        urls.append("正片$%s" % (play if play else vid))

        vod = {
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": d.get("pic") or "",
            "vod_remarks": year,
            "vod_year": year,
            "vod_area": " / ".join([c["name"] for c in d.get("cats", []) if c["group"] == "country"]) or "",
            "vod_class": " / ".join([c["name"] for c in d.get("cats", []) if c["group"] == "genre"]) or "",
            "type_name": " / ".join(cat_names),
            "vod_actor": "",
            "vod_director": "",
            "vod_content": d.get("intro") or "",
            "vod_play_from": "$$$".join(froms),
            "vod_play_url": "#".join(urls),
        }
        return {"list": [vod]}

    # -------------------- 搜索 --------------------

    def searchContent(self, key, quick):
        return self._search(key, 1)

    def searchContentPage(self, key, quick, pg):
        return self._search(key, int(pg or 1))

    def _search(self, key, pg):
        q = urllib.parse.quote(str(key or "").strip(), safe="")
        result = {"list": [], "page": pg, "pagecount": 1, "limit": 20, "total": 0}
        if not q:
            return result
        try:
            # WP 搜索分页: /page/{N}/?s={kw}
            if pg > 1:
                url = "%s/page/%d/?s=%s" % (SITE, pg, q)
            else:
                url = "%s/?s=%s" % (SITE, q)
            html = _http_text(url)
            items = _parse_list(html)
            result["list"] = [self._to_vod(x) for x in items]
            result["pagecount"] = _parse_pagemax(html, pg)
            result["total"] = len(items)
        except Exception:  # noqa: BLE001
            pass
        return result

    # -------------------- 播放 --------------------

    def playerContent(self, flag, id, vipFlags):
        """
        id 形式：
          https://...m3u8          -> 直连地址，透传 + header（UA/Referer）
          proxy://do=py&url=<enc>  -> 旧缓存代理线路，原样透传
                                       （播放器会自动调用 localProxy，向后兼容）
          数字/其他                 -> 视为 post id，拉详情页解码后直连下发
        """
        result = {"parse": 0, "playUrl": "", "url": "", "header": {}}
        try:
            sid = str(id or "")
            if sid.startswith("proxy://"):
                result["url"] = sid
                result["playUrl"] = sid
                # m3u8 由 localProxy 代请求；返回的 m3u8 里分片是 https 直连
                # 地址，播放器直接请求 CDN，此处 header 随播放器下发（双保险）
                result["header"] = {
                    "User-Agent": UA,
                    "Referer": SITE + "/",
                }
                return result
            if sid.startswith("http"):
                result["url"] = sid
                result["playUrl"] = sid
                result["header"] = {
                    "User-Agent": UA,
                    "Referer": SITE + "/",
                }
                return result
            # id = post id：拉详情页解码 og:video:url，直连下发真实 m3u8
            # （vidcdn2 不校验 Referer；header 由壳随 m3u8 请求下发，双保险）
            url = "%s/?p=%s" % (SITE, sid)
            html = _http_text(url)
            d = _parse_detail(html)
            play = d.get("play") or ""
            if play and not play.startswith("http"):
                play = ""
            result["url"] = play
            result["playUrl"] = play
            result["header"] = {
                "User-Agent": UA,
                "Referer": SITE + "/",
            }
        except Exception:  # noqa: BLE001
            pass
        return result

    # -------------------- 兼容接口 --------------------

    def isVideoFormat(self, url):
        return bool(re.search(r"\.(m3u8|mp4|flv|ts)", url, re.I))

    def isImageFormat(self, url):
        return bool(re.search(r"\.(jpg|jpeg|png|gif|webp)", url, re.I))

    def localProxy(self, param):
        """
        本地代理：TVBox/FongMi 请求 proxy://do=py&url=<target> 时回调。
        - target 为 .m3u8：代请求（强制 UA + Referer），返回的 m3u8 中
          分片 URI 被绝对化为 https 直连地址，播放器直连 CDN 播放。
        - target 为 .ts 等分片：直接代理下载返回（保留兼容）。
        请求统一附加 UA + Referer。
        返回 [status, mime, body] 三元组（TVBox 通用约定）。
        """
        try:
            if isinstance(param, dict):
                target = param.get("url") or ""
            elif isinstance(param, str):
                target = param
            else:
                target = ""
            target = str(target).strip()
            # 兼容 proxy:// 入口（含 type= 参数）：剥壳取出内层真实地址再回源。
            # 测试器/壳会把完整 proxy://do=py&type=...&url=<enc> 传进来，
            # 旧逻辑只认 http 开头导致直接返回空 text/plain（"回源 200 但响应非媒体"）。
            if target.lower().startswith("proxy://"):
                # proxy:// 不是标准 scheme, urlparse 会把 do=py&... 当 netloc,
                # 必须剥壳后把剩余部分当 query 串解析
                rest = target.split("://", 1)[1]
                qs = urllib.parse.parse_qs(rest)
                inner = (qs.get("url") or [""])[0].strip()
                if inner and not inner.lower().startswith(("http://", "https://")):
                    inner = urllib.parse.unquote(inner)
                target = inner
            if not target or not target.lower().startswith(("http://", "https://")):
                return [404, "text/plain", b"no url"]
            low = target.lower()
            # 分片/媒体用更长超时（CDN 慢时单分片需 15s+）
            if ".m3u8" in low:
                timeout = 30
            else:
                timeout = 40
            body = _proxy_fetch(target, timeout=timeout)
            if ".m3u8" in low:
                text = body.decode("utf-8", "ignore")
                text = _rewrite_m3u8(text, target)
                return [200, "application/vnd.apple.mpegurl",
                        text.encode("utf-8")]
            if ".ts" in low or ".m4s" in low or ".mp4" in low:
                return [200, "video/mp2t", body]
            if ".jpg" in low or ".jpeg" in low or ".png" in low or ".webp" in low:
                return [200, "image/jpeg", body]
            return [200, "application/octet-stream", body]
        except Exception:  # noqa: BLE001
            return [500, "text/plain", b""]

    def destroy(self):
        pass

    # -------------------- 内部 --------------------

    def _to_vod(self, item):
        return {
            "vod_id": item["vod_id"],
            "vod_name": item["vod_name"],
            "vod_pic": item["vod_pic"],
            "vod_remarks": "",
            "vod_year": "",
            "vod_area": "",
            "type_name": "",
        }


# ============================================================
# 本地自测入口（python3 eroticmv.py）
# ============================================================

if __name__ == "__main__":
    sp = Spider()

    print("=" * 60)
    print("【homeContent】分类 + 筛选器")
    home = sp.homeContent(True)
    print("分类:", [(c["type_id"], c["type_name"]) for c in home["class"]])
    gf = home["filters"]["genre"]
    for g in gf:
        print("  %s(%d项):" % (g["name"], len(g["value"]) - 1),
              [v["n"] for v in g["value"][1:6]])

    print("=" * 60)
    print("【homeVideoContent】首页最新")
    hv = sp.homeVideoContent()
    print("本页:", len(hv["list"]), "总页:", hv["pagecount"])
    for v in hv["list"][:5]:
        print("  -", v["vod_name"][:40], "|", v["vod_pic"][:70])

    print("=" * 60)
    print("【categoryContent】题材 Lesbian 第2页")
    cat = sp.categoryContent("genre", 2, True, {"genre": "lesbian"})
    print("total:", cat["total"], "pagecount:", cat["pagecount"], "本页:", len(cat["list"]))
    for v in cat["list"][:4]:
        print("  -", v["vod_name"][:40], "|", v["vod_pic"][:70])

    print("=" * 60)
    print("【categoryContent】国家 Japan")
    cat = sp.categoryContent("country", 1, True, {"country": "japan"})
    print("本页:", len(cat["list"]))
    for v in cat["list"][:3]:
        print("  -", v["vod_name"][:40])

    print("=" * 60)
    print("【detailContent】")
    vid = hv["list"][0]["vod_id"] if hv["list"] else "31882"
    det = sp.detailContent([vid])
    if det["list"]:
        vod = det["list"][0]
        print("名称:", vod["vod_name"])
        print("封面:", vod["vod_pic"])
        print("年代:", vod["vod_year"], "| 题材:", vod["vod_class"], "| 国家:", vod["vod_area"])
        print("简介:", (vod["vod_content"] or "")[:90])

    print("=" * 60)
    print("【playerContent】")
    play = sp.playerContent("HLS", vid, {})
    print("parse:", play["parse"])
    print("url:", play["url"])

    print("=" * 60)
    print("【searchContent】babyface")
    sr = sp.searchContent("babyface", False)
    print("本页:", len(sr["list"]), "总页:", sr["pagecount"])
    for v in sr["list"][:5]:
        print("  -", v["vod_name"][:44])

    print("=" * 60)
    print("全部接口自测完成")
