# LumeSource: {"id":"pypack_d72d1f2cd7ae72f5","name":"暗网禁地-TVBox爬虫","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
============================================================
 暗网禁地 (haoaw45.top)  TVBox / 影视仓 / OK影视 爬虫
============================================================
站点特性（实测 2026-10-16）：
  - MacCMS (ewave/AXNHTHYUS 模板) 站，域名 haoaw45.top
    （页面 maccms 配置里遗留死门域名 haoaw53.top，已入池做故障转移）
  - 双层门禁：
    ① 假滑块验证码 (hua.js)：拖到右侧即"通过"，纯前端演戏
       通过后写两个 cookie：oneyou=<随机8位> 与 <随机8位>=<unix秒>
       服务端只校验存在与新鲜度 → 本脚本直接伪造，无需过码
    ② 间歇性限流：同 IP 连续请求会偶发 404（0 字节空响应），
       已内置退避重试 + 请求间隔 + 响应体量/特征校验
  - 视频 CDN：video{1,2}.lldvideo1.top / res{1,2}.lldtu4.top
    封面 res*.lldtu4.top，播放 video*.lldvideo1.top

路由规则（root 相对路径）：
  首页      /index.php                     热门 + 3 分类海报流 (vod-item-img)
  分类列表  /index.php/vod/type/id/{tid}/page/{pg}.html
  最新      /index.php/label/new           前100 (new-item 列表, 无分页)
  热门      /index.php/label/ranking       前100 (new-item 列表, 无分页)
  视频详情  /index.php/vod/detail/id/{vid}.html
            h1.detail-info-title + detail-info-desc 简介 + detail-img 封面
            + JSON-LD(uploadDate/duration) + 播放链接
  播放页    /index.php/vod/play/id/{vid}/sid/{s}/nid/{n}.html
            var player_aaaa={...,"url":"", "from":"ppvodm3u8", id/sid/nid}
            → url 为空，真正的地址在播放器 iframe 里
  播放iframe /index.php/m3u8play/play/id/{vid}/nid/{nid}/sid/{sid}
            var cur_PlayUrl = "https://video2.lldvideo1.top/...m3u8?token=..."
            token 一次性/短时效 → 每次播放都必须现场解析，严禁缓存
  搜索      /index.php/vod/search/page/{pg}/wd/{kw}.html
            结果 search-item 卡片（标题含 <span class="text-theme"> 高亮）

播放源（ppvodm3u8 线路，单集单线路）：
  cur_PlayUrl 为多码率 master 或媒体 playlist，直链 m3u8，
  分片 /index.php/m3u8/ts/*.ts 无鉴权；请求头需移动端 UA + Referer

分类（父子全遍历，本站无子分类，动态发现兜底）：
  9  小女孩视频   (68 页 / 1344 部)
  10 初中生视频   (104 页)
  11 萝莉视频     (361 页)
  label_new      暗网视频·最新 (前100)
  label_ranking  热门视频·排行榜 (前100)
============================================================
"""

import html as _html
import json
import random
import re
import ssl
import string
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# ============================================================
# 配置
# ============================================================

# 用户提供入口置首；haoaw53.top 为页面配置里的遗留死门域名（保留探测）
HOSTS = [
    "https://haoaw45.top",
    "https://haoaw53.top",
]

# 父分类（实测首页导航）；站点无子分类，_discover_subs() 会动态兜底
CATEGORIES = [
    ("9", "小女孩视频"),
    ("10", "初中生视频"),
    ("11", "萝莉视频"),
]
# 最新/热门 label 页（URL 形状与 type 页不同，壳里以特殊 type_id 暴露）
LABELS = [
    ("label_new", "暗网视频·最新"),
    ("label_ranking", "热门视频·排行榜"),
]

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 "
      "Mobile/15E148 Safari/604.1")
TIMEOUT = 20
# 请求最小间隔（秒）：站点对同 IP 高频请求会间歇 404
MIN_INTERVAL = 1.0
# 失败重试次数与退避基数（秒）：404 空响应/验证码页/体量不足都算失败
RETRY = 5
BACKOFF = 1.5

# ============================================================
# 基础 HTTP（oneyou 门禁 cookie 伪造 + 限流退避重试 + 缓存）
# ============================================================

_LAST_REQ_TS = [0.0]
_REQ_LOCK = threading.Lock()
_PAGE_CACHE = {}
_CACHE_LOCK = threading.Lock()
_SUBS_CACHE = {"ts": 0.0, "data": {}}
_CAT_CACHE = {"ts": 0.0, "data": []}


def _ssl_ctx_loose():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _rand8():
    """hua.js generateVerifyRandomString：首字符小写字母，其余小写字母+数字"""
    return random.choice(string.ascii_lowercase) + "".join(
        random.choice(string.ascii_lowercase + string.digits)
        for _ in range(7))


def _forge_cookie():
    """伪造滑块验证通过后的凭证：oneyou=<rnd8> ; <rnd8>=<unix秒>"""
    r = _rand8()
    return "oneyou=%s; %s=%d" % (r, r, int(time.time()))


def _throttle():
    """全局请求节流"""
    with _REQ_LOCK:
        now = time.time()
        wait = MIN_INTERVAL - (now - _LAST_REQ_TS[0])
        if wait > 0:
            time.sleep(wait)
        _LAST_REQ_TS[0] = time.time()


def _fetch(url, timeout=TIMEOUT, referer=None, retry=RETRY, min_size=4000):
    """
    单 URL 请求（带门禁 cookie 与退避重试）。
    站点特征：真 404/失败 = 0 字节；验证码页 = 3391B 含 sliderCaptcha；
    成功内容页 > 50KB。m3u8 playlist 本身很小(数百字节)，
    以 #EXTM3U 开头即认为有效，不受 min_size 限制。
    """
    last_err = None
    for attempt in range(retry):
        _throttle()
        headers = {
            "User-Agent": UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Cookie": _forge_cookie(),
        }
        if referer:
            headers["Referer"] = referer
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout,
                                        context=_ssl_ctx_loose()) as r:
                data = r.read()
            if data and (data[:7] == b"#EXTM3U"
                         or (len(data) > min_size
                             and b"sliderCaptcha" not in data)):
                return data
            last_err = "short/blocked(%dB)" % len(data or b"")
        except urllib.error.HTTPError as e:
            # 站点限流表现为 404 + 0 字节
            last_err = "HTTP %s" % e.code
        except Exception as e:  # noqa: BLE001
            last_err = str(e)
        if attempt < retry - 1:
            time.sleep(BACKOFF * (attempt + 1))
    raise IOError("fetch failed after %d tries (%s): %s"
                  % (retry, last_err, url))


def _cache_get(key, ttl):
    with _CACHE_LOCK:
        hit = _PAGE_CACHE.get(key)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
    return None


def _cache_put(key, data):
    with _CACHE_LOCK:
        if len(_PAGE_CACHE) > 300:
            _PAGE_CACHE.clear()
        _PAGE_CACHE[key] = (time.time(), data)


def _get(path, ttl=0, feature=None, referer=None, retry=RETRY):
    """
    多线路请求：path 为站内路径或完整 URL。
    feature：响应必须包含的特征串（防串页/防伪 404）。
    """
    is_abs = path.startswith("http")
    if is_abs:
        hosts, suffix = [""], path
    else:
        hosts = list(HOSTS)
        suffix = path
    last_err = None
    for host in hosts:
        url = (host + suffix) if host else suffix
        ck = url
        if ttl > 0:
            hit = _cache_get(ck, ttl)
            if hit is not None:
                return hit
        try:
            data = _fetch(url, referer=referer, retry=retry)
        except IOError as e:
            last_err = str(e)
            continue
        if (feature and isinstance(feature, str)
                and feature.encode("utf-8", "ignore") not in data):
            last_err = "feature missing"
            continue
        if ttl > 0:
            _cache_put(ck, data)
        return data
    if last_err:
        raise IOError(last_err)
    return b""


def _text(path, ttl=0, feature=None, referer=None):
    raw = _get(path, ttl=ttl, feature=feature, referer=referer)
    return raw.decode("utf-8", "ignore") if raw else ""


# ============================================================
# 解析辅助
# ============================================================

def _clean(text):
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", "", text)
    text = _html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _fix_url(url, host):
    if not url:
        return ""
    url = url.strip()
    if url.startswith("http"):
        return url
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("/"):
        return (host or HOSTS[0]) + url
    return url


# ---- 列表卡片：分类页/首页/详情相关推荐 (a.vod-item-img) ----
_CARD_RE = re.compile(
    r'<a class="vod-item-img" href="(/index\.php/vod/detail/id/(\d+)\.html)"'
    r'[^>]*>(.*?)</a>', re.S)
# ---- label 页卡片 (li.new-item) ----
_NEW_RE = re.compile(
    r'<li class="new-item clearfix">(.*?)</li>', re.S)
# ---- 详情页字段 ----
_H1_RE = re.compile(r'<h1 class="detail-info-title[^"]*"[^>]*>(.*?)</h1>', re.S)
_DESC_RE = re.compile(
    r'<div class="detail-info-desc[^"]*"[^>]*>\s*<p[^>]*>(.*?)</p>', re.S)
_DETAIL_PIC_RE = re.compile(
    r'<div class="detail-img">.*?<img class="suo" src="([^"]+)"', re.S)
_JSONLD_RE = re.compile(
    r'"uploadDate":"([^"]+)"[^}]*?"duration":"([^"]*)"', re.S)
# ---- 播放页 player_aaaa 字段（扁平 JSON，无需配平） ----
_PLAY_CONF_RE = {
    "id": re.compile(r'"id":"(\d+)"'),
    "sid": re.compile(r'"sid":(\d+)'),
    "nid": re.compile(r'"nid":(\d+)'),
    "from": re.compile(r'"from":"([^"]*)"'),
    "url": re.compile(r'"url":"([^"]*)"'),
    "name": re.compile(r'"vod_name":"((?:[^"\\]|\\.)*)"'),
    "cls": re.compile(r'"vod_class":"((?:[^"\\]|\\.)*)"'),
}
_PLAY_LINK_RE = re.compile(
    r'/index\.php/vod/play/id/(\d+)/sid/(\d+)/nid/(\d+)\.html')
_CUR_URL_RE = re.compile(r'var cur_PlayUrl = "([^"]+)"')
_CUR_IMG_RE = re.compile(r'var cur_Playimg = "([^"]+)"')
_PAGENUM_RE = re.compile(r'num">(\d+)/(\d+)<')
_PAGE_LINK_RE = re.compile(r'/page/(\d+)\.html')


def _parse_cards(html, host):
    """解析 vod-list 卡片流（分类页/首页/详情相关推荐）-> vod 列表"""
    vods, seen = [], set()
    if not html:
        return vods
    for m in _CARD_RE.finditer(html):
        vid, inner = m.group(2), m.group(3)
        if vid in seen:
            continue
        img = re.search(r'<img class="suo" src="([^"]+)"', inner)
        pic = _fix_url(img.group(1), host) if img else ""
        tm = re.search(r'<h[23] class="vod-item-title[^"]*"[^>]*>(.*?)</h[23]>',
                       inner, re.S)
        name = _clean(tm.group(1)) if tm else ""
        if not name:
            continue
        seen.add(vid)
        vods.append({"vod_id": vid, "vod_name": name[:120],
                     "vod_pic": pic, "vod_remarks": ""})
    return vods


def _parse_new_cards(html, host):
    """解析 label 页 (new-item) 卡片 -> vod 列表"""
    vods, seen = [], set()
    if not html:
        return vods
    for m in _NEW_RE.finditer(html):
        block = m.group(1)
        am = re.search(r'<h2 class="new-item-name">\s*'
                       r'<a[^>]*href="(/index\.php/vod/detail/id/(\d+)\.html)"',
                       block, re.S)
        if not am:
            continue
        vid = am.group(2)
        if vid in seen:
            continue
        img = re.search(r'<img class="suo" src="([^"]+)"', block)
        pic = _fix_url(img.group(1), host) if img else ""
        tm = re.search(r'<h2 class="new-item-name">(.*?)</h2>', block, re.S)
        name = _clean(tm.group(1)) if tm else ""
        if not name:
            continue
        num = re.search(r'<em class="new-item-num">(\d+)</em>', block)
        tim = re.search(r'<p class="new-item-time"><span>(.*?)</span>', block,
                        re.S)
        remark = _clean(tim.group(1)) if tim else ""
        if num:
            remark = ("No.%s " % num.group(1)) + remark
        seen.add(vid)
        vods.append({"vod_id": vid, "vod_name": name[:120],
                     "vod_pic": pic, "vod_remarks": remark[:60]})
    return vods


def _parse_search_cards(html, host):
    """解析搜索页 (search-item) 卡片 -> vod 列表（无详情链接，取播放链接 id）"""
    vods, seen = [], set()
    if not html:
        return vods
    for block in re.split(r'<div class="search-item row">', html)[1:]:
        pm = _PLAY_LINK_RE.search(block)
        if not pm:
            continue
        vid = pm.group(1)
        if vid in seen:
            continue
        img = re.search(r'<img class="suo" src="([^"]+)"', block)
        pic = _fix_url(img.group(1), host) if img else ""
        tm = re.search(r'<h2 class="search-item-title[^"]*"[^>]*>(.*?)</h2>',
                       block, re.S)
        name = _clean(tm.group(1)) if tm else ""
        if not name:
            continue
        dm = re.search(r'<div class="search-item-desc"[^>]*>\s*'
                       r'<p[^>]*>(.*?)</p>', block, re.S)
        remark = _clean(dm.group(1)) if dm else ""
        seen.add(vid)
        vods.append({"vod_id": vid, "vod_name": name[:120],
                     "vod_pic": pic, "vod_remarks": remark[:80]})
    return vods


def _parse_pagecount(html, pg):
    """从分页区提取总页数：优先 num">cur/total，其次最大 page 链接"""
    if not html:
        return pg
    m = _PAGENUM_RE.search(html)
    if m:
        try:
            return max(int(m.group(2)), pg)
        except Exception:  # noqa: BLE001
            pass
    max_pg = pg
    for mm in _PAGE_LINK_RE.finditer(html):
        try:
            max_pg = max(max_pg, int(mm.group(1)))
        except Exception:  # noqa: BLE001
            pass
    return max_pg


def _unescape_js(s):
    """player_aaaa 里的 \\uXXXX / \\/ 反转义"""
    if not s:
        return ""
    s = re.sub(r'\\u([0-9a-fA-F]{4})',
               lambda m: chr(int(m.group(1), 16)), s)
    return s.replace("\\/", "/").replace('\\"', '"')


def _play_conf(html):
    """从播放页提取 player_aaaa 关键字段（扁平 JSON 直接抓字段）"""
    conf = {}
    for key, rx in _PLAY_CONF_RE.items():
        m = rx.search(html or "")
        conf[key] = _unescape_js(m.group(1)) if m else ""
    return conf


def _iframe_url(vid, sid, nid):
    return "%s/index.php/m3u8play/play/id/%s/nid/%s/sid/%s" % (
        HOSTS[0], vid, nid or 1, sid or 1)


def _resolve_iframe(iframe_url):
    """拉 m3u8play iframe 页 -> cur_PlayUrl（token 一次性，现拉现用）"""
    html = _text(iframe_url, feature="cur_PlayUrl",
                 referer="%s/index.php/vod/play/id/%s.html"
                         % (HOSTS[0], re.search(r'/id/(\d+)/',
                                                iframe_url).group(1)))
    m = _CUR_URL_RE.search(html)
    return m.group(1) if m else ""


def _detail_info(vid):
    """拉详情页 -> 元数据 + 播放链接列表"""
    out = {"title": "", "pic": "", "type_name": "", "year": "",
           "area": "", "actor": "", "content": "", "plays": []}
    html = _text("/index.php/vod/detail/id/%s.html" % vid,
                 feature="detail-info-title", ttl=120,
                 referer="%s/index.php/vod/type/id/9.html" % HOSTS[0])
    if not html:
        return out
    h1 = _H1_RE.search(html)
    if h1:
        out["title"] = _clean(h1.group(1))
    dm = _DESC_RE.search(html)
    if dm:
        out["content"] = _clean(dm.group(1))[:500]
    pm = _DETAIL_PIC_RE.search(html)
    if pm:
        out["pic"] = _fix_url(pm.group(1), HOSTS[0])
    jm = _JSONLD_RE.search(html)
    if jm:
        out["year"] = jm.group(1)[:4]
        if jm.group(2):
            dur = re.match(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', jm.group(2))
            if dur and any(dur.groups()):
                h_, m_, s_ = (int(x or 0) for x in dur.groups())
                total = h_ * 3600 + m_ * 60 + s_
                if total:
                    out["area"] = "时长 %02d:%02d" % (total // 60, total % 60)
    tm = re.search(r"<title>(.*?)</title>", html, re.S)
    if tm and not out["type_name"]:
        parts = [p.strip() for p in _clean(tm.group(1)).split("-")]
        if len(parts) >= 2:
            out["type_name"] = parts[1]
    for m in _PLAY_LINK_RE.finditer(html):
        link = "/index.php/vod/play/id/%s/sid/%s/nid/%s.html" % m.groups()
        if link not in out["plays"]:
            out["plays"].append(link)
    return out


def _play_headers():
    return {"User-Agent": UA, "Referer": HOSTS[0] + "/"}


# ============================================================
# 分类动态发现（父子结构，本站无子分类，留兜底）
# ============================================================

def _discover_categories():
    """
    拉首页动态发现全部分类：
      - 父分类：导航区 (fixed-nav-item) 里的 type/id 链接
      - 子分类：页面上其它 type/id 链接（如下拉子菜单），按文档顺序
        归到最近的前置父分类下
    返回 (categories, subs)：categories=[(id,name)...], subs={父id:[(子id,name)...]}
    """
    now = time.time()
    if _CAT_CACHE["data"] and now - _CAT_CACHE["ts"] < 600:
        return _CAT_CACHE["data"], _SUBS_CACHE["data"]
    cats, subs = [], {}
    try:
        html = _text("/index.php", feature="fixed-nav", ttl=300)
    except IOError:
        html = ""
    if html:
        # 导航区（fixed-nav-item ... </li>）里的为父分类
        nav_block = html
        i = html.find("fixed-nav")
        if i > 0:
            j = html.find("</nav>", i)
            if j > 0:
                nav_block = html[i:j]
        parents = []
        for m in re.finditer(
                r'href="(/index\.php/vod/type/id/(\d+)\.html)"[^>]*>(.*?)</a>',
                nav_block, re.S):
            pid, name = m.group(2), _clean(m.group(3))
            if not name or "更多" in name:
                continue
            if (pid, name) not in parents:
                parents.append((pid, name))
        # 全页 type 链接（含导航外的子分类链接）
        all_links = []
        for m in re.finditer(
                r'href="(/index\.php/vod/type/id/(\d+)\.html)"[^>]*>(.*?)</a>',
                html, re.S):
            name = _clean(m.group(3))
            if name and "更多" not in name:
                all_links.append((m.group(2), name))
        parent_ids = {p[0] for p in parents}
        cur_parent = parents[0][0] if parents else None
        for pid, name in all_links:
            if pid in parent_ids:
                cur_parent = pid
                continue
            if pid in {c[0] for c in cats}:
                continue
            # 非父且未登记 -> 视为子分类
            if cur_parent:
                subs.setdefault(cur_parent, [])
                if (pid, name) not in subs[cur_parent]:
                    subs[cur_parent].append((pid, name))
        cats = parents
    # 与内置分类合并（内置优先，去重）
    merged = list(CATEGORIES)
    for cid, name in cats:
        if cid not in {c[0] for c in merged}:
            merged.append((cid, name))
    _CAT_CACHE["data"] = merged
    _CAT_CACHE["ts"] = time.time()
    _SUBS_CACHE["data"] = subs
    _SUBS_CACHE["ts"] = time.time()
    return merged, subs


# ============================================================
# Spider 主体
# ============================================================

class Spider(object):
    """暗网禁地 TVBox 爬虫：父子分类/分页/详情/播放/搜索/封面"""

    def init(self, extend=""):
        pass

    def getName(self):
        return "暗网禁地"

    def isVideoFormat(self, url):
        return bool(re.search(r"\.(m3u8|mp4|ts|flv)(\?|$)", url or "", re.I))

    def isImageFormat(self, url):
        return bool(re.search(r"\.(jpg|jpeg|png|gif|webp|bmp)(\?|$)",
                              url or "", re.I))

    def manualVideoCheck(self):
        return False

    # ---------- 首页 ----------

    def homeContent(self, filter):
        try:
            cats, subs = _discover_categories()
        except Exception:  # noqa: BLE001
            cats, subs = list(CATEGORIES), {}
        classes = [{"type_id": cid, "type_name": name}
                   for cid, name in cats]
        for lid, lname in LABELS:
            classes.append({"type_id": lid, "type_name": lname})
        filters = {}
        for cid, _name in cats:
            f = []
            sub_list = subs.get(cid) or []
            if sub_list:
                f.append({"key": "sub", "name": "子分类",
                          "value": [{"n": "全部", "v": ""}] +
                                   [{"n": n, "v": i} for i, n in sub_list]})
            filters[cid] = f
        return {"class": classes, "filters": filters}

    def homeVideoContent(self):
        try:
            html = _text("/index.php", feature="vod-item-img", ttl=120)
        except IOError:
            return {"list": []}
        return {"list": _parse_cards(html, HOSTS[0])[:30]}

    # ---------- 分类浏览（父子遍历 + label 页） ----------

    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = max(1, int(pg))
        except Exception:  # noqa: BLE001
            pg = 1
        if isinstance(extend, str):
            try:
                extend = json.loads(extend) if extend.strip() else {}
            except Exception:  # noqa: BLE001
                extend = {}
        extend = extend or {}
        tid = str(tid or "").strip()

        # label 页（前100，无分页）
        if tid == "label_new":
            html = _text("/index.php/label/new", feature="new-item", ttl=120)
            return {"list": _parse_new_cards(html, HOSTS[0]), "page": 1,
                    "pagecount": 1, "total": 0}
        if tid == "label_ranking":
            html = _text("/index.php/label/ranking", feature="new-item",
                         ttl=120)
            return {"list": _parse_new_cards(html, HOSTS[0]), "page": 1,
                    "pagecount": 1, "total": 0}

        # 子分类筛选（extend.sub 为子分类 id；本站无子分类时恒为空）
        sub = str(extend.get("sub", "") or "").strip()
        if sub:
            tid = sub
        path = "/index.php/vod/type/id/%s/page/%d.html" % (tid, pg)
        try:
            html = _text(path, feature="vod-item-img", ttl=60,
                         referer="%s/index.php" % HOSTS[0])
        except IOError:
            return {"list": [], "page": pg, "pagecount": pg, "total": 0}
        vods = _parse_cards(html, HOSTS[0])
        return {"list": vods, "page": pg,
                "pagecount": _parse_pagecount(html, pg), "total": 0}

    # ---------- 详情 ----------

    def detailContent(self, ids):
        vid = str((ids or [""])[0]).strip()
        if not vid.isdigit():
            return {"list": []}
        try:
            info = _detail_info(vid)
        except IOError:
            return {"list": []}
        if not info["title"] and not info["plays"]:
            return {"list": []}
        froms, urls = [], []
        for link in info["plays"]:
            m = _PLAY_LINK_RE.search(link)
            if not m:
                continue
            p_vid, sid, nid = m.groups()
            # 播放页只用于确认线路名；真正的 m3u8 在 playerContent 现拉
            try:
                conf_html = _text(link, feature="player_aaaa", ttl=60,
                                  referer="%s/index.php/vod/detail/id/%s.html"
                                          % (HOSTS[0], vid))
                conf = _play_conf(conf_html)
                line = conf.get("from") or "ppvodm3u8"
            except IOError:
                line = "ppvodm3u8"
            name = line if line not in froms else "%s#%d" % (line, len(froms))
            froms.append(name)
            # 存 iframe 地址（无 token，稳定）；playerContent 现场解析新 token
            urls.append("播放$" + _iframe_url(p_vid, sid, nid))
        if not urls:
            return {"list": []}
        vod = {
            "vod_id": vid,
            "vod_name": info["title"] or ("暗网禁地 %s" % vid),
            "vod_pic": info["pic"],
            "vod_type_name": info["type_name"],
            "vod_year": info["year"],
            "vod_area": info["area"],
            "vod_actor": info["actor"],
            "vod_remarks": info["type_name"] or info["year"],
            "vod_content": info["content"],
            "vod_play_from": "$$$".join(froms),
            "vod_play_url": "$$$".join(urls),
        }
        return {"list": [vod]}

    # ---------- 搜索 ----------

    def searchContent(self, key, quick):
        return self._search(key, 1)

    def searchContentPage(self, key, quick, pg):
        try:
            pg = max(1, int(pg))
        except Exception:  # noqa: BLE001
            pg = 1
        return self._search(key, pg)

    def _search(self, key, pg):
        empty = {"list": [], "page": pg, "pagecount": pg, "total": 0}
        key = (key or "").strip()
        if not key:
            return empty
        path = "/index.php/vod/search/page/%d/wd/%s.html" % (
            pg, urllib.parse.quote(key))
        try:
            html = _text(path, feature="search-item", ttl=30,
                         referer="%s/index.php" % HOSTS[0])
        except IOError:
            return empty
        vods = _parse_search_cards(html, HOSTS[0])
        return {"list": vods, "page": pg,
                "pagecount": _parse_pagecount(html, pg), "total": 0}

    # ---------- 播放 ----------

    def playerContent(self, flag, id, vipFlags):
        """
        id 形式（detailContent 产出的是 iframe 地址，保证 token 现拉现用）：
          .../index.php/m3u8play/play/id/{vid}/nid/{nid}/sid/{sid}
              -> 拉 iframe 页解析 cur_PlayUrl（token 一次性/短时效）
          http(s)://...m3u8  -> 原样直返（外部传入的直链）
          /index.php/vod/play/id/...  -> 先拉播放页再走 iframe 链
          {vid}               -> 兜底全链重解析
        """
        headers = _play_headers()
        pid = str(id or "").strip()
        if not pid:
            return {"parse": 0, "url": "", "header": headers}
        if "m3u8play" in pid:
            try:
                url = _resolve_iframe(pid)
            except IOError:
                url = ""
            return {"parse": 0, "url": url, "header": headers}
        if pid.startswith("http"):
            return {"parse": 0, "url": pid, "header": headers}
        if "/vod/play/" in pid:
            try:
                html = _text(pid, feature="player_aaaa",
                             referer="%s/index.php/vod/detail/id/%s.html"
                                     % (HOSTS[0],
                                        _PLAY_LINK_RE.search(pid).group(1)))
                conf = _play_conf(html)
                vid, sid, nid = (conf.get("id") or
                                 _PLAY_LINK_RE.search(pid).group(1),
                                 conf.get("sid") or 1, conf.get("nid") or 1)
                url = _resolve_iframe(_iframe_url(vid, sid, nid))
            except IOError:
                url = ""
            return {"parse": 0, "url": url, "header": headers}
        if pid.isdigit():
            try:
                info = _detail_info(pid)
                if info["plays"]:
                    m = _PLAY_LINK_RE.search(info["plays"][0])
                    url = _resolve_iframe(_iframe_url(*m.groups()))
                else:
                    url = ""
            except IOError:
                url = ""
            return {"parse": 0, "url": url, "header": headers}
        return {"parse": 0, "url": "", "header": headers}

    def localProxy(self, param):
        return None

    def destroy(self):
        pass


# ============================================================
# 自测
# ============================================================

if __name__ == "__main__":
    sp = Spider()
    sp.init("")

    print("== homeContent ==")
    hc = sp.homeContent(True)
    print("分类数:", len(hc["class"]),
          [(c["type_id"], c["type_name"]) for c in hc["class"]])
    print("筛选器:", {k: [f["key"] for f in v] for k, v in
                      hc["filters"].items()})

    print("\n== homeVideoContent ==")
    hv = sp.homeVideoContent()
    print("推荐条数:", len(hv["list"]))
    for v in hv["list"][:5]:
        print("  ", v["vod_id"], v["vod_name"][:40])

    print("\n== categoryContent (9 小女孩视频 第1页) ==")
    cc = sp.categoryContent("9", 1, True, "")
    print("条数:", len(cc["list"]), "| pagecount:", cc["pagecount"])
    for v in cc["list"][:5]:
        print("  ", v["vod_id"], v["vod_name"][:40], "|",
              v["vod_pic"][:50])

    print("\n== categoryContent (9 第2页) ==")
    cc2 = sp.categoryContent("9", 2, True, "")
    print("条数:", len(cc2["list"]))
    ids1 = {v["vod_id"] for v in cc["list"]}
    ids2 = {v["vod_id"] for v in cc2["list"]}
    print("两页重叠:", len(ids1 & ids2))

    print("\n== categoryContent (label_new 暗网视频·最新) ==")
    cn = sp.categoryContent("label_new", 1, True, "")
    print("条数:", len(cn["list"]), "| pagecount:", cn["pagecount"])
    for v in cn["list"][:3]:
        print("  ", v["vod_id"], v["vod_name"][:36], "|", v["vod_remarks"][:30])

    print("\n== categoryContent (label_ranking 热门) ==")
    cr = sp.categoryContent("label_ranking", 1, True, "")
    print("条数:", len(cr["list"]))

    if cc["list"]:
        vid = cc["list"][0]["vod_id"]
        print("\n== detailContent (%s) ==" % vid)
        dc = sp.detailContent([vid])
        if dc["list"]:
            v = dc["list"][0]
            print("标题:", v["vod_name"][:50])
            print("封面:", v["vod_pic"][:70])
            print("类型:", v["vod_type_name"], "| 年份:", v["vod_year"],
                  "| 时长:", v["vod_area"])
            print("简介:", v["vod_content"][:80])
            froms = v["vod_play_from"].split("$$$")
            urls = v["vod_play_url"].split("$$$")
            print("线路:", froms)
            for f, u in zip(froms, urls):
                print("   ", f, "->", u.split("$")[-1][:80])
            print("\n== playerContent (iframe -> 现拉 token m3u8) ==")
            pc = sp.playerContent(froms[0], urls[0].split("$")[-1], [])
            print("  parse:", pc.get("parse"))
            print("  url:", (pc.get("url") or "")[:90])
            print("  header:", pc.get("header"))
            if pc.get("url"):
                try:
                    body = _fetch(pc["url"], timeout=15,
                                  referer=HOSTS[0] + "/")
                    ok = b"#EXTM3U" in body[:300]
                    print("  m3u8 状态:",
                          "有效(%dB)" % len(body) if ok else "无效(%dB)" % len(body))
                except IOError as e:
                    print("  m3u8 校验失败:", e)
        else:
            print("详情为空")

    print("\n== searchContent (小女孩) ==")
    sc = sp.searchContent("小女孩", True)
    print("条数:", len(sc["list"]), "| pagecount:", sc["pagecount"])
    for v in sc["list"][:5]:
        print("  ", v["vod_id"], v["vod_name"][:40])

    print("\n== searchContentPage (小女孩 第2页) ==")
    sc2 = sp.searchContentPage("小女孩", True, 2)
    print("条数:", len(sc2["list"]))
    sids1 = {v["vod_id"] for v in sc["list"]}
    sids2 = {v["vod_id"] for v in sc2["list"]}
    print("两页重叠:", len(sids1 & sids2))
