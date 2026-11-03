# LumeSource: {"id":"pypack_6982f17aed4ab7c4","name":"短剧大全","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
"""短剧聚合源 —— TVBox / 影视壳 py 源插件（完整版 v3）

纯自抓实现：不依赖任何后台服务、不占端口、不需要 root。
装上丢进 /sdcard/TVBox/py/ 就能用。

特性:
  - 多站并发聚合(量子/非凡/暴风/电影天堂/无尽/光速/百度)
  - 首页精选 + 各站短剧分类 + 细分题材(重生民国/穿越年代/反转爽文...)
  - 全站聚合搜索, 同名自动合并成多线路
  - 详情自动选集, 优先取 m3u8 直链
  - 分类表缓存 / 超时重试 / 全链路兜底
  - 支持通过 init(extend) 传入自定义站点 / 聚合源 / 黑白名单
  - 全链路黑白名单过滤(首页/分类/搜索/详情合并)
  - [v3] extend 支持外部配置文件(本地路径 / file:// / http(s)://)

============================ extend 用法 ============================
在壳的插件配置里填, 可以是以下四种之一:

  1) JSON 字符串(单行):
     {"sites":[{"key":"my","name":"自建","api":"https://my.com/api.php/provide/vod/"}],
      "agg":["my","lz"],"blacklist":["预告","花絮"],"debug":true}

  2) 本地文件路径(绝对/相对都行):
     /sdcard/TVBox/py/duanju.json
     file:///sdcard/TVBox/py/duanju.json

  3) 远程 URL:
     https://example.com/duanju.json

  4) key=value&key=value 形式(仅简单场景):
     debug=true&blacklist=预告,花絮

配置文件的字段(全部可选):
{
  "replace_sites": false,          // true=用 sites 替换默认站点; 默认 false 为合并
  "sites": [
    {"key": "xx", "name": "XX站", "api": "https://xx.com/api.php/provide/vod/"}
  ],
  "agg": ["lz", "ff", "xx"],       // 首页聚合混流用哪些站; 不填用默认
  "blacklist": ["预告", "花絮", "解说", "综艺"],  // 名称命中任一即丢弃
  "whitelist": [],                 // 非空时, 名称必须命中其一才保留
  "debug": true,                   // 覆盖文件里的 DEBUG
  "cache": {                       // 可选, 覆盖默认缓存时长(秒)
    "class": 3600,
    "detail": 300
  },
  "timeout": 12,                   // 覆盖请求超时
  "retry": 2                       // 覆盖重试次数
}
===================================================================

依赖: 仅 Python 标准库
"""

import json
import os
import re
import ssl
import time

try:
    from urllib.request import Request, urlopen
    from urllib.parse import quote, urlencode
    _PY3 = True
except ImportError:  # pragma: no cover
    from urllib import quote, urlencode
    from urllib2 import Request, urlopen
    _PY3 = False

try:
    from concurrent.futures import ThreadPoolExecutor
    _HAS_POOL = True
except ImportError:
    _HAS_POOL = False

# --------------------------------------------------------------------- 配置

DEBUG = True           # 出问题先开 True, 排查完改回 False

UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")

# 默认站点表(可被 extend 覆盖/追加)
_DEFAULT_SITES = [
    {"key": "lz",  "name": "量子",   "api": "https://cj.lziapi.com/api.php/provide/vod/"},
    {"key": "ff",  "name": "非凡",   "api": "https://api.ffzyapi.com/api.php/provide/vod/"},
    {"key": "bf",  "name": "暴风",   "api": "https://bfzyapi.com/api.php/provide/vod/"},
    {"key": "dy",  "name": "天堂",   "api": "https://caiji.dyttzyapi.com/api.php/provide/vod/"},
    {"key": "wj",  "name": "无尽",   "api": "https://api.wujinapi.me/api.php/provide/vod/"},
    {"key": "gs",  "name": "光速",   "api": "https://api.guangsuapi.com/api.php/provide/vod/"},
    {"key": "bd",  "name": "百度",   "api": "https://api.apibdzy.com/api.php/provide/vod/"},
]

SITES = list(_DEFAULT_SITES)                       # 运行时站点表
SITE_MAP = dict((s["key"], s) for s in SITES)      # key -> site

THEME_WORDS = [
    "重生民国", "穿越年代", "现代言情", "反转爽文", "女恋总裁", "闪婚离婚",
    "都市脑洞", "古装仙侠", "古装言情", "言情总裁", "反转爽剧", "重生",
    "穿越", "霸总", "甜宠", "逆袭", "擦边短剧", "ai短剧", "AI漫剧",
]

SHORT_WORDS = [
    "短剧", "短剧大全", "微短剧", "竖屏短剧",
    "擦边短剧", "AI漫剧", "ai短剧",
]

# 黑白名单(可被 extend 覆盖)
BLACKLIST = ["预告", "花絮", "片花"]
WHITELIST = []

TIMEOUT = 12
RETRY = 2
AGG_SOURCES = ["lz", "ff", "bf", "dy"]

_class_cache = {}
_class_ts = {}
_CLASS_TTL = 3600
_detail_cache = {}
_DETAIL_TTL = 300

_SSL_CTX = ssl.create_default_context()
try:
    _SSL_CTX.check_hostname = False
    _SSL_CTX.verify_mode = ssl.CERT_NONE
except Exception:
    pass

# 常见配置文件候选路径(用户 extend 只写了关键词时会试着找这些)
_CONFIG_HINTS = [
    "/sdcard/TVBox/py/duanju.json",
    "/sdcard/TVBox/duanju.json",
    "/storage/emulated/0/TVBox/py/duanju.json",
    "/storage/emulated/0/TVBox/duanju.json",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "duanju.json")
    if "__file__" in globals() else "",
]


def _log(msg):
    if DEBUG:
        try:
            print("[duanju] %s" % msg)
        except Exception:
            pass


# --------------------------------------------------------------- extend 解析

def _read_text_from_any(src, timeout=None):
    """从 本地路径 / file:// / http(s):// 读取文本; 失败返回 ''"""
    if not src:
        return ""
    src = src.strip().strip('"').strip("'")
    if not src:
        return ""

    # 远程
    if src.startswith("http://") or src.startswith("https://"):
        try:
            req = Request(src, headers={"User-Agent": UA})
            resp = urlopen(req, timeout=timeout or TIMEOUT, context=_SSL_CTX)
            raw = resp.read()
            for enc in ("utf-8", "utf-8-sig", "gbk", "gb18030"):
                try:
                    return raw.decode(enc)
                except Exception:
                    continue
            return raw.decode("utf-8", "ignore")
        except Exception as e:
            _log("远程配置读取失败 %s -> %s" % (src, e))
            return ""

    # 本地 file://
    path = src
    if src.lower().startswith("file://"):
        path = src[7:]
        # file:///sdcard/... -> /sdcard/...
        if path.startswith("/") and not path.startswith("//"):
            pass
        elif path.startswith("//"):
            # file://host/path 极少见, 直接取路径部分
            idx = path.find("/", 2)
            path = path[idx:] if idx >= 0 else path

    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        try:
            with open(path, "r") as f:
                return f.read()
        except Exception as e:
            _log("本地配置读取失败 %s -> %s" % (path, e))
            return ""


def _parse_kv(text):
    """解析 key=value&key=value 或换行 key=value; 列表用逗号分隔"""
    cfg = {}
    if not text:
        return cfg
    text = text.replace("\r", "\n")
    parts = []
    if "&" in text and "\n" not in text.strip():
        parts = text.split("&")
    else:
        for line in text.split("\n"):
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            if "&" in line and "=" in line:
                parts.extend(line.split("&"))
            else:
                parts.append(line)
    for p in parts:
        p = p.strip()
        if not p or "=" not in p:
            continue
        k, _, v = p.partition("=")
        k = k.strip()
        v = v.strip()
        if not k:
            continue
        lk = k.lower()
        if lk in ("debug", "replace_sites"):
            cfg[k] = v.lower() in ("1", "true", "yes", "on", "y")
        elif lk in ("blacklist", "whitelist", "agg", "agg_sources"):
            cfg[k] = [x.strip() for x in re.split(r"[,，;；]", v) if x.strip()]
        elif lk in ("timeout", "retry"):
            try:
                cfg[k] = int(v)
            except Exception:
                pass
        else:
            cfg[k] = v
    return cfg


def _try_load_config_file(src):
    """尝试把 src 当配置来源(文件/URL)读取并解析"""
    raw = _read_text_from_any(src)
    if not raw:
        return None
    raw = raw.strip()
    if not raw:
        return None
    # 优先 JSON
    if raw.startswith("{") or raw.startswith("["):
        try:
            return json.loads(raw)
        except Exception:
            m = re.search(r"\{.*\}", raw, re.S)
            if m:
                try:
                    return json.loads(m.group(0))
                except Exception:
                    pass
    # 退化成 kv
    kv = _parse_kv(raw)
    return kv if kv else None


def _looks_like_path(s):
    if not s:
        return False
    low = s.lower().strip().strip('"').strip("'")
    if low.startswith(("http://", "https://", "file://")):
        return True
    if "/" in s or "\\" in s:
        return True
    if s.endswith(".json") or s.endswith(".txt") or s.endswith(".conf"):
        return True
    return False


def _auto_find_config():
    """extend 为空时, 试着找一下常见位置的配置文件"""
    for p in _CONFIG_HINTS:
        if not p:
            continue
        try:
            if os.path.isfile(p):
                return p
        except Exception:
            continue
    return ""


def _normalize_site(s):
    if not isinstance(s, dict):
        return None
    key = str(s.get("key") or "").strip()
    api = str(s.get("api") or "").strip()
    if not key or not api:
        return None
    if "?" not in api and not api.endswith("/"):
        api = api + "/"
    name = str(s.get("name") or key).strip()
    return {"key": key, "name": name, "api": api}


def _apply_extend(extend):
    """解析并应用 extend 配置; 空/非法则保留默认"""
    global SITES, SITE_MAP, AGG_SOURCES, BLACKLIST, WHITELIST
    global DEBUG, TIMEOUT, RETRY, _CLASS_TTL, _DETAIL_TTL

    cfg = None
    src_desc = ""

    # ---- 空 extend: 试自动找配置文件
    if not extend:
        auto = _auto_find_config()
        if auto:
            cfg = _try_load_config_file(auto)
            src_desc = auto
    elif isinstance(extend, dict):
        cfg = extend
        src_desc = "<dict>"
    elif isinstance(extend, str):
        s = extend.strip()
        if not s:
            auto = _auto_find_config()
            if auto:
                cfg = _try_load_config_file(auto)
                src_desc = auto
        else:
            # 先判断是不是路径/URL, 是就去读文件
            if _looks_like_path(s):
                cfg = _try_load_config_file(s)
                src_desc = s
            else:
                # 不是路径 -> 当 JSON 或 kv 解析
                try:
                    cfg = json.loads(s)
                    src_desc = "<json>"
                except Exception:
                    m = re.search(r"\{.*\}", s, re.S)
                    if m:
                        try:
                            cfg = json.loads(m.group(0))
                            src_desc = "<json>"
                        except Exception:
                            cfg = None
                    if cfg is None:
                        kv = _parse_kv(s)
                        if kv:
                            cfg = kv
                            src_desc = "<kv>"

    if not isinstance(cfg, dict):
        if extend:
            _log("extend 解析失败(%r), 使用默认配置" % (extend,))
        return
    _log("应用配置来源: %s" % (src_desc or "?"))

    # ---- 站点
    raw_sites = cfg.get("sites")
    if isinstance(raw_sites, list):
        valid = [x for x in (_normalize_site(s) for s in raw_sites) if x]
        if valid:
            if cfg.get("replace_sites"):
                SITES = valid
            else:
                order = [s["key"] for s in SITES]
                m = dict((s["key"], s) for s in SITES)
                for s in valid:
                    if s["key"] not in m:
                        order.append(s["key"])
                    m[s["key"]] = s
                SITES = [m[k] for k in order]
    SITE_MAP = dict((s["key"], s) for s in SITES)

    # ---- 聚合源
    agg = cfg.get("agg") or cfg.get("agg_sources")
    if isinstance(agg, list) and agg:
        picked = [str(k) for k in agg if str(k) in SITE_MAP]
        AGG_SOURCES = picked if picked else [s["key"] for s in SITES[:4]]

    # ---- 黑白名单
    bl = cfg.get("blacklist")
    if isinstance(bl, list):
        BLACKLIST = [str(x).strip() for x in bl if str(x).strip()]
    wl = cfg.get("whitelist")
    if isinstance(wl, list):
        WHITELIST = [str(x).strip() for x in wl if str(x).strip()]

    # ---- 调试开关
    if "debug" in cfg:
        try:
            DEBUG = bool(cfg["debug"])
        except Exception:
            pass

    # ---- 超时 / 重试
    if "timeout" in cfg:
        try:
            t = int(cfg["timeout"])
            if 3 <= t <= 60:
                TIMEOUT = t
        except Exception:
            pass
    if "retry" in cfg:
        try:
            r = int(cfg["retry"])
            if 0 <= r <= 5:
                RETRY = r
        except Exception:
            pass

    # ---- 缓存时长
    cache = cfg.get("cache")
    if isinstance(cache, dict):
        try:
            if "class" in cache:
                _CLASS_TTL = max(60, int(cache["class"]))
            if "detail" in cache:
                _DETAIL_TTL = max(30, int(cache["detail"]))
        except Exception:
            pass


def _clear_runtime_cache():
    _class_cache.clear()
    _class_ts.clear()
    _detail_cache.clear()
    _ok_cache.clear()


# ----------------------------------------------------------------- 基础请求

def _fetch(url, headers=None, timeout=None):
    hdr = {
        "User-Agent": UA,
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
    }
    if headers:
        hdr.update(headers)
    last = None
    t = timeout or TIMEOUT
    for i in range(RETRY):
        try:
            req = Request(url, headers=hdr)
            resp = urlopen(req, timeout=t, context=_SSL_CTX)
            raw = resp.read()
            for enc in ("utf-8", "gbk", "gb18030"):
                try:
                    return raw.decode(enc)
                except Exception:
                    continue
            return raw.decode("utf-8", "ignore")
        except Exception as e:
            last = e
            time.sleep(0.3 * (i + 1))
    _log("fetch fail %s -> %s" % (url, last))
    return ""


def _api_json(site, params, timeout=None):
    qs = urlencode(params)
    url = site["api"] + ("&" if "?" in site["api"] else "?") + qs
    txt = _fetch(url, timeout=timeout)
    if not txt:
        return {}
    txt = txt.strip()
    if txt.startswith("\ufeff"):
        txt = txt[1:]
    try:
        return json.loads(txt)
    except Exception:
        m = re.search(r"\{.*\}", txt, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except Exception:
                pass
    _log("bad json from %s: %s" % (site["key"], txt[:120]))
    return {}


def _pmap(func, items, workers=6):
    items = list(items)
    if not items:
        return []
    if not _HAS_POOL or len(items) == 1:
        out = []
        for it in items:
            try:
                out.append(func(it))
            except Exception as e:
                _log("pmap err %s" % e)
                out.append(None)
        return out
    try:
        with ThreadPoolExecutor(max_workers=min(workers, len(items))) as ex:
            futs = [ex.submit(func, it) for it in items]
            out = []
            for f in futs:
                try:
                    out.append(f.result(timeout=TIMEOUT + 6))
                except Exception as e:
                    _log("pmap fut err %s" % e)
                    out.append(None)
            return out
    except Exception as e:
        _log("pmap pool err %s" % e)
        return [None] * len(items)


# --------------------------------------------------------------- 黑白名单

def _pass_filter(item):
    name = re.sub(r"\s+", "", item.get("vod_name") or "")
    if not name:
        return True
    for w in BLACKLIST:
        if w and w in name:
            return False
    if WHITELIST:
        for w in WHITELIST:
            if w and w in name:
                return True
        return False
    return True


def _filter_list(lst):
    if not lst:
        return lst
    return [x for x in lst if _pass_filter(x)]


# --------------------------------------------------------------- 数据处理

def _clean(txt):
    if not txt:
        return ""
    txt = re.sub(r"(?is)<script.*?</script>", "", txt)
    txt = re.sub(r"(?is)<style.*?</style>", "", txt)
    txt = re.sub(r"<[^>]+>", "", txt)
    txt = txt.replace("&nbsp;", " ").replace("&amp;", "&")
    txt = txt.replace("&quot;", '"').replace("&#39;", "'")
    txt = txt.replace("&lt;", "<").replace("&gt;", ">")
    return re.sub(r"\s+", " ", txt).strip()


def _fix_pic(pic, site):
    if not pic:
        return ""
    if pic.startswith("//"):
        return "https:" + pic
    if pic.startswith("http"):
        return pic
    if pic.startswith("/"):
        m = re.match(r"(https?://[^/]+)", site["api"])
        if m:
            return m.group(1) + pic
    return pic


def _mk_item(v, site):
    vid = v.get("vod_id")
    if vid is None or vid == "":
        vid = v.get("vod_name") or "0"
    return {
        "vod_id": "%s:%s" % (site["key"], vid),
        "vod_name": (v.get("vod_name") or "").strip(),
        "vod_pic": _fix_pic(v.get("vod_pic") or "", site),
        "vod_remarks": (v.get("vod_remarks") or "").strip(),
        "vod_year": str(v.get("vod_year") or ""),
        "type_name": site["name"],
    }


def _parse_play(from_str, url_str):
    if not url_str:
        return []
    froms = [x.strip() for x in (from_str or "").split("$$$") if x.strip()]
    groups = url_str.split("$$$")
    out = []
    for gi, g in enumerate(groups):
        eps = []
        for seg in g.split("#"):
            seg = seg.strip()
            if not seg or "$" not in seg:
                continue
            name, _, link = seg.partition("$")
            link = link.strip()
            if not link:
                continue
            eps.append((name.strip() or ("第%d集" % (len(eps) + 1)), link))
        if not eps:
            continue
        gname = froms[gi] if gi < len(froms) else ("线路%d" % (gi + 1))
        out.append((gname, eps))
    return out


def _pick_group(groups):
    if not groups:
        return None
    for gname, eps in groups:
        low = (gname or "").lower()
        if "m3u8" in low or "hls" in low:
            return (gname, eps)
    for gname, eps in groups:
        if eps and any(".m3u8" in (e[1] or "") for e in eps):
            return (gname, eps)
    return max(groups, key=lambda x: len(x[1]))


# ------------------------------------------------------------- 分类表构建

def _get_classes(site):
    key = site["key"]
    now = time.time()
    if key in _class_cache and now - _class_ts.get(key, 0) < _CLASS_TTL:
        return _class_cache[key]

    cls = []
    for params in (
        {"ac": "list", "pg": 1},
        {"ac": "detail", "pg": 1},
        {"ac": "list"},
    ):
        d = _api_json(site, params)
        c = d.get("class") or d.get("classes") or d.get("types") or []
        if isinstance(c, dict):
            c = [{"type_id": k, "type_name": v} for k, v in c.items()]
        if c:
            cls = c
            break
    if not cls:
        _log("no class from %s" % key)
    _class_cache[key] = cls
    _class_ts[key] = now
    return cls


def _find_tid(site, want_names):
    classes = _get_classes(site)
    for w in want_names:
        for c in classes:
            nm = (c.get("type_name") or "").strip()
            if nm == w:
                return c.get("type_id"), nm
    for w in want_names:
        for c in classes:
            nm = (c.get("type_name") or "").strip()
            if w in nm and "解说" not in nm and "资讯" not in nm:
                return c.get("type_id"), nm
    return None, None


def _shortplay_tid(site):
    return _find_tid(site, SHORT_WORDS)


_ok_cache = {}


def _has_content(site, tid):
    ck = "%s:%s" % (site["key"], tid)
    if ck in _ok_cache:
        return _ok_cache[ck]
    d = _api_json(site, {"ac": "detail", "t": tid, "pg": 1}, timeout=8)
    lst = d.get("list") or []
    ok = bool(lst)
    _ok_cache[ck] = ok
    return ok


def _pick_shortplay_tid(site):
    tried = set()
    for w in SHORT_WORDS:
        tid, name = _find_tid(site, [w])
        if tid is None:
            continue
        key = "%s:%s" % (site["key"], tid)
        if key in tried:
            continue
        tried.add(key)
        if _has_content(site, tid):
            return tid, name
    return _shortplay_tid(site)


def _build_home_class():
    out = [{"type_id": "agg", "type_name": "🔥 短剧精选"}]
    main_tids = set()

    def one(site):
        tid, name = _pick_shortplay_tid(site)
        if tid is None:
            _log("no shortplay class: %s" % site["key"])
            return None
        main_tids.add("%s:%s" % (site["key"], tid))
        return {"type_id": "%s:%s" % (site["key"], tid),
                "type_name": "%s·%s" % (site["name"], name or "短剧")}

    for r in _pmap(one, SITES):
        if r:
            out.append(r)

    def themes(site):
        res = []
        for c in _get_classes(site):
            nm = (c.get("type_name") or "").strip()
            if nm in ("短剧", "短剧大全", "连续剧", "电影", "电视剧", "综艺", "动漫"):
                continue
            pk = "%s:%s" % (site["key"], c.get("type_id"))
            if pk in main_tids:
                continue
            for w in THEME_WORDS:
                if w in nm and len(nm) <= 10:
                    res.append({"type_id": pk,
                                "type_name": "%s·%s" % (site["name"], nm)})
                    break
        return res

    seen = set()
    for r in _pmap(themes, SITES):
        for it in (r or []):
            if it["type_name"] in seen:
                continue
            seen.add(it["type_name"])
            out.append(it)
    return out


# --------------------------------------------------------------- 核心接口

class Spider(object):

    def __init__(self):
        self.extend = ""
        self._home_class = None

    # ------------------------------------------------------------------ 初始化
    def init(self, extend=""):
        self.extend = extend or ""
        _apply_extend(self.extend)
        _clear_runtime_cache()
        self._home_class = None
        _log("init ok, sites=%s, agg=%s, bl=%s, wl=%s, debug=%s, timeout=%s"
             % ([s["key"] for s in SITES], AGG_SOURCES,
                BLACKLIST, WHITELIST, DEBUG, TIMEOUT))
        return self

    # ------------------------------------------------------------------ 首页
    def homeContent(self, filter=False):
        try:
            if self._home_class is None:
                self._home_class = _build_home_class()
            videos = self._agg_list(1, 12)
            return {"class": self._home_class, "list": videos}
        except Exception as e:
            _log("homeContent err %s" % e)
            return {"class": [{"type_id": "agg", "type_name": "🔥 短剧精选"}],
                    "list": []}

    def homeVideoContent(self):
        try:
            return {"list": self._agg_list(1, 12)}
        except Exception:
            return {"list": []}

    # ---------------------------------------------------------- 聚合混流列表
    def _agg_list(self, pg, per_site=8):
        def one(key):
            site = SITE_MAP.get(key)
            if not site:
                return []
            tid, _ = _shortplay_tid(site)
            if tid is not None:
                d = _api_json(site, {"ac": "detail", "t": tid, "pg": pg})
                lst = d.get("list") or []
                if lst:
                    return [_mk_item(v, site) for v in lst[:per_site]]
            d = _api_json(site, {"ac": "detail", "wd": "短剧", "pg": pg})
            lst = d.get("list") or []
            if not lst:
                _log("agg empty: %s pg=%s" % (key, pg))
            return [_mk_item(v, site) for v in lst[:per_site]]

        raw_buckets = [b for b in _pmap(one, AGG_SOURCES) if b]
        buckets = [_filter_list(b) for b in raw_buckets]
        buckets = [b for b in buckets if b]

        out = []
        seen = {}
        idx = 0
        while len(out) < 40:
            added = False
            for b in buckets:
                if idx < len(b):
                    it = b[idx]
                    nm = re.sub(r"\s+", "", it["vod_name"] or "")
                    if nm and nm in seen:
                        seen[nm]["vod_id"] += "|" + it["vod_id"]
                    else:
                        if nm:
                            seen[nm] = it
                        out.append(it)
                    added = True
            if not added:
                break
            idx += 1
        return out

    # ------------------------------------------------------------------ 分类
    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = int(pg or 1)
        try:
            tid = str(tid or "")
            if tid in ("", "agg"):
                lst = self._agg_list(pg, 12 if pg == 1 else 10)
                return {"list": lst, "page": pg, "pagecount": 9999,
                        "limit": 40, "total": 999999}
            if ":" in tid:
                skey, stid = tid.split(":", 1)
            else:
                skey, stid = tid, None
            site = SITE_MAP.get(skey)
            if not site:
                return {"list": [], "page": pg, "pagecount": 1,
                        "limit": 24, "total": 0}
            if not stid:
                stid, _ = _shortplay_tid(site)
            if stid is None:
                return {"list": [], "page": pg, "pagecount": 1,
                        "limit": 24, "total": 0}
            d = _api_json(site, {"ac": "detail", "t": stid, "pg": pg})
            lst = [_mk_item(v, site) for v in (d.get("list") or [])]
            lst = _filter_list(lst)
            total = int(d.get("total") or 0)
            limit = int(d.get("limit") or 20) or 20
            pagecount = int((total + limit - 1) / limit) if total else 9999
            return {"list": lst, "page": pg, "pagecount": pagecount,
                    "limit": limit, "total": total}
        except Exception as e:
            _log("categoryContent err %s" % e)
            return {"list": [], "page": pg, "pagecount": 1,
                    "limit": 24, "total": 0}

    # ------------------------------------------------------------------ 详情
    def _detail_one(self, skey, sid):
        site = SITE_MAP.get(skey)
        if not site:
            return None
        ck = "%s:%s" % (skey, sid)
        now = time.time()
        if ck in _detail_cache and now - _detail_cache[ck][0] < _DETAIL_TTL:
            return _detail_cache[ck][1]
        d = _api_json(site, {"ac": "detail", "ids": sid})
        lst = d.get("list") or []
        if not lst:
            return None
        v = lst[0]
        groups = _parse_play(v.get("vod_play_from"), v.get("vod_play_url"))
        g = _pick_group(groups)
        if not g:
            return None
        eps = [(n, l) for (n, l) in g[1] if l]
        if not eps:
            return None
        item = {
            "vod_id": ck,
            "vod_name": (v.get("vod_name") or "").strip(),
            "vod_pic": _fix_pic(v.get("vod_pic") or "", site),
            "vod_year": str(v.get("vod_year") or ""),
            "vod_area": (v.get("vod_area") or "").strip(),
            "vod_remarks": (v.get("vod_remarks") or "").strip(),
            "vod_actor": _clean(v.get("vod_actor") or ""),
            "vod_director": _clean(v.get("vod_director") or ""),
            "vod_content": _clean(v.get("vod_content") or v.get("vod_blurb") or ""),
            "type_name": (v.get("type_name") or site["name"]),
            "src_name": site["name"],
            "episodes": eps,
            "play_from": g[0],
        }
        _detail_cache[ck] = (now, item)
        return item

    def detailContent(self, ids):
        try:
            raw = ids[0] if isinstance(ids, (list, tuple)) else ids
            raw = str(raw or "")
            pairs = []
            for part in raw.split("|"):
                part = part.strip()
                if ":" in part:
                    k, _, v = part.partition(":")
                    pairs.append((k, v))
            if not pairs:
                return {"list": []}

            infos = [r for r in _pmap(
                lambda p: self._detail_one(p[0], p[1]), pairs, workers=5) if r]
            infos = _filter_list(infos)
            if not infos:
                return {"list": []}

            base = infos[0]
            if len(infos) == 1:
                base["vod_play_from"] = base["src_name"]
                base["vod_play_url"] = "#".join(
                    "%s$%s" % (n, l) for (n, l) in base["episodes"])
                base.pop("episodes", None)
                base.pop("play_from", None)
                base.pop("src_name", None)
                return {"list": [base]}

            froms, urls = [], []
            for it in infos:
                froms.append(it["src_name"])
                urls.append("#".join("%s$%s" % (n, l)
                                     for (n, l) in it["episodes"]))
            out = {
                "vod_id": raw,
                "vod_name": base["vod_name"],
                "vod_pic": base["vod_pic"],
                "vod_year": base["vod_year"],
                "vod_area": base["vod_area"],
                "vod_remarks": base["vod_remarks"],
                "vod_actor": base["vod_actor"],
                "vod_director": base["vod_director"],
                "vod_content": base["vod_content"],
                "type_name": base["type_name"],
                "vod_play_from": "$$$".join(froms),
                "vod_play_url": "$$$".join(urls),
            }
            return {"list": [out]}
        except Exception as e:
            _log("detailContent err %s" % e)
            return {"list": []}

    # ------------------------------------------------------------------ 搜索
    def searchContent(self, key, quick=False, pg="1"):
        try:
            key = (key or "").strip()
            if not key:
                return {"list": []}
            pg = int(pg or 1)

            def one(site):
                d = _api_json(site, {"ac": "detail", "wd": key, "pg": pg})
                return [_mk_item(v, site) for v in (d.get("list") or [])[:25]]

            buckets = _pmap(one, SITES)
            merged = {}
            order = []
            for b in buckets:
                for it in (b or []):
                    if not _pass_filter(it):
                        continue
                    nm = re.sub(r"\s+", "", it["vod_name"] or "")
                    if not nm:
                        continue
                    if nm in merged:
                        merged[nm]["vod_id"] += "|" + it["vod_id"]
                        continue
                    it = dict(it)
                    merged[nm] = it
                    order.append(nm)
            return {"list": [merged[n] for n in order]}
        except Exception as e:
            _log("searchContent err %s" % e)
            return {"list": []}

    # ------------------------------------------------------------------ 播放
    def playerContent(self, flag, id, vipFlags=None):
        try:
            url = (id or "").strip()
            if not url:
                return {"parse": 0, "playUrl": "", "url": "", "header": ""}
            header = json.dumps({
                "User-Agent": UA,
                "Referer": "https://www.baidu.com/",
            }, ensure_ascii=False)
            if ".m3u8" in url or url.startswith("http"):
                return {"parse": 0, "playUrl": "", "url": url, "header": header}
            return {"parse": 1, "playUrl": "", "url": url, "header": header}
        except Exception as e:
            _log("playerContent err %s" % e)
            return {"parse": 0, "playUrl": "", "url": "", "header": ""}

    def localProxy(self, param):
        return None