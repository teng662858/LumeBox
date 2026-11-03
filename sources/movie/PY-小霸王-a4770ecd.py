# LumeSource: {"id":"pypack_001faf91a4770ecd","name":"小霸王","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
# QQ群：807916734 @Easy
"""
小霸王游戏源 (www.yikm.net) - TVBox / 影视 App 爬虫源
====================================================
接口：homeContent / homeVod / homeVideoContent / categoryContent /
     detailContent / playerContent / searchContent

站点特性（已按网页实测）：
1. 怀旧游戏站，列表页形如 /nes?tag=..&e=..&page=..，每页约 10 个游戏
2. 平台分类（采用网页顶部导航的真实入口）：
     FC(/nes?tag=0) 街机(/nes?tag=9) GBA(/nes?tag=11) MD(/nes?tag=13)
     SFC(/nes?e=5) NDS(/nes?e=7) DOS(/nes?e=6)
     Java(/nes?e=8) Flash(/nes?e=9)
3. 类型筛选（各平台独立，取自各平台页真实渲染的 tag-type 链接）：
     FC 用数字 tag（2=动作冒险 8=小游戏 3=飞行射击 4=格斗 5=棋牌 6=射击
     7=运动比赛 10=角色扮演）；其他平台用中文 tag 且 e 值各不相同
     （如 GBA 的 e=2、NDS 的 e=7、Flash 的 e=9），中文 tag 请求时须 URL 编码；
     SFC / DOS 页面无类型筛选控件，故不配置筛选器
4. 搜索：GET /search?name=关键词

播放协议（点开即玩）：
- 本站游戏无 m3u8/mp4 视频流，采用「动作协议」：列表项 vod_id 为浏览器动作
  JSON（{actionId:browser, url:游戏网页, header:移动UA...}），支持动作协议的
  播放器（影视仓 / takagen99 Box 等）点开即用内置浏览器打开网页游玩。

实现特点（简洁可靠）：
- 仅用标准库 urllib/json/re，零第三方依赖，无证书跳过、无警告屏蔽
- 短超时 + 快速重试 + 线程安全内存缓存（分类 5 分钟 / 搜索 3 分钟）
- 列表解析单次请求完成，无二次请求
"""

import json
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

# dr_py 环境提供基类；缺失时回退 object 以便本地直接测试
try:
    sys.path.append('..')
    from base.spider import Spider as _BaseSpider
except Exception:  # pragma: no cover - 本地无 base 包时的兜底
    _BaseSpider = None

_Base = _BaseSpider or object

# ------------------------------------------------------------
# 常量配置
# ------------------------------------------------------------
HOST = "https://www.yikm.net"

# 移动端 UA：确保游戏页在播放器内置浏览器中正常加载
UA = (
    "Mozilla/5.0 (Linux; Android 8.0; Pixel 2 Build/OPD3.170816.012) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 "
    "Mobile Safari/537.36"
)

TIMEOUT_PAGE = 6    # 列表页超时（秒）
TIMEOUT_API = 4     # 搜索超时（秒）
TTL_CAT = 300       # 分类缓存 5 分钟
TTL_SEARCH = 180    # 搜索缓存 3 分钟

# 随每个动作条目下发的 header，让内置浏览器带上移动 UA 打开游戏页
ACTION_HEADER = {
    'Upgrade-Insecure-Requests': '1',
    'User-Agent': UA,
}

# 去广告脚本：页面加载后持续清除 AdSense 自动广告节点（插屏/锚定横幅）。
# 只按广告特征选择器删除，不触碰游戏 DOM（canvas/模拟器容器）；ES5 语法，
# 兼容播放器内置 WebView，无广告的页面执行后完全无副作用。
AD_BLOCK_JS = """(function () {
  var SEL = 'ins.adsbygoogle,'
    + 'iframe[id^="aswift_"],'
    + 'iframe[src*="doubleclick"],'
    + 'iframe[src*="googlesyndication"],'
    + 'div[id^="google_ads_"],'
    + '[data-ad-slot]';
  function clean() {
    var nodes = document.querySelectorAll(SEL), i, el;
    for (i = 0; i < nodes.length; i++) {
      el = nodes[i];
      if (el.parentNode) el.parentNode.removeChild(el);
    }
  }
  clean();
  setInterval(clean, 800);              /* 兜底：广告可能异步注入 */
  if (window.MutationObserver) {        /* 监听 DOM 变动即时清理 */
    new MutationObserver(clean).observe(
      document.documentElement,
      { childList: true, subtree: true }
    );
  }
})();"""

# 广告请求域名黑名单：配合支持 blockUrls 的播放器从源头拦截
# （adsbygoogle 主脚本 / 广告渲染请求均来自这两个域名）
AD_BLOCK_URLS = [
    'pagead2.googlesyndication.com',
    'googleads.g.doubleclick.net',
]

# ------------------------------------------------------------
# 平台分类与类型筛选（均按网页实际抓取并逐一实测有效）
# 说明：
#   id     = 平台列表 URL 模板（网页导航真实入口，末尾 page= 处拼页码），
#            同时作为播放器的分类 id
#   e      = 该平台类型筛选 URL 中的 e 值
#   types  = [(类型显示名, tag 参数值), ...]，tag 为网页 tag-type 链接真实值
#            （中文 tag 请求时按行做 URL 编码，见 _type_tpl）
# ------------------------------------------------------------
PLATFORMS = [
    {
        "id": "/nes?tag=0&page=", "name": "FC", "e": "0",
        "types": [("动作冒险", "2"), ("小游戏", "8"), ("飞行射击", "3"),
                  ("格斗", "4"), ("棋牌", "5"), ("射击", "6"),
                  ("运动比赛", "7"), ("角色扮演", "10")],
    },
    {
        "id": "/nes?tag=9&page=", "name": "街机", "e": "1",
        "types": [("动作冒险", "动作"), ("格斗", "格斗"), ("射击", "射击"),
                  ("赛车", "赛车"), ("体育", "体育"), ("益智游戏", "益智"),
                  ("其他", "其他")],
    },
    {
        "id": "/nes?tag=11&page=", "name": "GBA", "e": "2",
        "types": [("动作", "动作"), ("冒险", "冒险"), ("角色扮演", "角色扮演"),
                  ("运动", "运动"), ("策略", "策略"), ("格斗", "格斗"),
                  ("射击", "射击"), ("赛车", "赛车"), ("体育", "体育"),
                  ("益智游戏", "益智"), ("模拟", "模拟"), ("女孩", "女孩"),
                  ("动漫", "动漫"), ("口袋妖怪", "口袋妖怪"),
                  ("赛尔达传说", "赛尔达传说"), ("汉化游戏", "汉化")],
    },
    {
        "id": "/nes?tag=13&page=", "name": "MD", "e": "3",
        "types": [("角色扮演", "角色扮演"), ("动作冒险", "动作冒险"),
                  ("策略", "策略"), ("棋牌", "棋牌"), ("射击", "射击"),
                  ("模拟经营", "模拟经营"), ("战棋", "战棋"), ("格斗", "格斗"),
                  ("动作", "动作"), ("解谜", "解谜"), ("模拟", "模拟"),
                  ("休闲益智", "休闲益智"), ("体育", "体育"), ("音乐", "音乐")],
    },
    {
        # 注意：e 系平台必须保留导航原样的空参数 tag=（缺失会被服务器当 FC 处理）
        "id": "/nes?e=5&tag=&page=", "name": "SFC", "e": "",
        "types": [],   # 该平台页面无类型筛选控件
    },
    {
        "id": "/nes?e=7&tag=&page=", "name": "NDS", "e": "7",
        "types": [("角色扮演", "角色扮演"), ("动作角色扮演", "动作角色扮演"),
                  ("模拟角色扮演", "模拟角色扮演"), ("动作游戏", "动作游戏"),
                  ("冒险游戏", "冒险游戏"), ("冒险解谜", "冒险解谜"),
                  ("策略战棋", "策略战棋"), ("模拟经营", "模拟经营"),
                  ("体育竞技", "体育竞技"), ("赛车竞速", "赛车竞速"),
                  ("格斗游戏", "格斗游戏"), ("大乱斗游戏", "大乱斗游戏"),
                  ("射击游戏", "射击游戏"), ("第一人称射击", "第一人称射击"),
                  ("益智游戏", "益智游戏"), ("养成游戏", "养成游戏"),
                  ("音乐游戏", "音乐游戏"), ("恋爱游戏", "恋爱游戏"),
                  ("卡片游戏", "卡片游戏"), ("桌面游戏", "桌面游戏")],
    },
    {
        "id": "/nes?e=6&tag=&page=", "name": "DOS", "e": "",
        "types": [],   # 该平台页面无类型筛选控件
    },
    {
        "id": "/nes?e=8&tag=&page=", "name": "Java", "e": "8",
        "types": [("角色扮演", "角色扮演"), ("益智休闲", "益智休闲"),
                  ("飞行游戏", "飞行游戏"), ("动作游戏", "动作游戏"),
                  ("冒险游戏", "冒险游戏"), ("策略战棋", "策略战棋"),
                  ("模拟经营", "模拟经营"), ("体育运动", "体育运动"),
                  ("赛车游戏", "赛车游戏"), ("格斗游戏", "格斗游戏"),
                  ("射击游戏", "射击游戏"), ("棋牌游戏", "棋牌游戏"),
                  ("养成游戏", "养成游戏"), ("音乐舞蹈", "音乐舞蹈")],
    },
    {
        "id": "/nes?e=9&tag=&page=", "name": "Flash", "e": "9",
        "types": [("RPG冒险", "RPG冒险"), ("动作", "动作"), ("射击", "射击"),
                  ("放置点击类", "放置点击类"), ("益智解谜", "益智解谜"),
                  ("策略防御", "策略防御"), ("经营模拟", "经营模拟"),
                  ("运动竞速", "运动竞速"), ("音乐绘画", "音乐绘画")],
    },
]


def _type_tpl(tag, e):
    """构造类型筛选 URL 模板：中文 tag 一律做 URL 编码（实测未编码无效）"""
    return "/nes?tag=%s&e=%s&page=" % (urllib.parse.quote(tag, safe=''), e)


def _build_classes_filters():
    """由 PLATFORMS 生成分类列表与各平台筛选器"""
    classes, filters = [], {}
    for p in PLATFORMS:
        classes.append({"type_id": p["id"], "type_name": p["name"],
                        "type_flag": "[CFS]2-00-S"})
        if p["types"]:
            value = [{"n": "全部", "v": ""}] + [
                {"n": n, "v": _type_tpl(t, p["e"])} for n, t in p["types"]]
            filters[p["id"]] = [{"key": "class", "name": "类型", "value": value}]
        else:
            filters[p["id"]] = []   # 无筛选控件：播放器不显示筛选按钮
    return classes, filters


ALL_CLASSES, ALL_FILTERS = _build_classes_filters()

# 纯数字 tid 兼容映射：旧播放器可能把 FC 数字类型当新 tid 调用
# （如 categoryContent('2')），统一映射回 FC 的数字类型路径
_TYPE_ALIAS = {str(_t): _type_tpl(_t, "0")
               for _n, _t in PLATFORMS[0]["types"]}


def _browser_vod(url, name, pic='', adblock=False):
    """构造动作协议条目：vod_id 为浏览器动作 JSON（点开即用内置浏览器打开网页）

    adblock=True 时附加去广告字段（搜索结果兜底——FC高清 分类虽已移除，
    但其游戏仍可能经搜索命中，play 页仍带 Google 自动广告）：
    - js：页面加载后持续清除广告节点（配合播放器 js 注入能力）
    - blockUrls：拦截广告请求域名（配合播放器 URL 拦截能力）
    """
    action = {
        "actionId": "browser",
        "type": "browser",
        "title": "小游戏",
        "url": url,
        "textZoom": 100,
        "header": ACTION_HEADER,
    }
    if adblock:
        action["js"] = AD_BLOCK_JS
        action["blockUrls"] = AD_BLOCK_URLS
    return {
        "vod_id": json.dumps(action, ensure_ascii=False),
        "vod_name": name,
        "vod_pic": pic,
        "vod_tag": "action",
    }


# ------------------------------------------------------------
# Spider 主类（dr_py 协议）
# ------------------------------------------------------------
class Spider(_Base):
    siteUrl = HOST

    # dr_py 加载所需类属性：声明支持搜索/筛选，标题与语言
    searchable = 1
    filterable = 1
    quickSearch = 1
    title = '小霸王游戏(点开即玩)'
    lang = 'zh'

    headers = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': HOST + '/',
    }

    def __init__(self):
        self.extend = ""
        self._lock = threading.Lock()      # 缓存读写锁
        self._cat_cache = {}               # 分类缓存
        self._search_cache = {}            # 搜索缓存

    def init(self, extend=""):
        """dr_py 加载时注入扩展配置"""
        self.extend = extend or ""

    # ---------------- 网络请求 ----------------
    def _get(self, url, referer='', timeout=TIMEOUT_PAGE):
        """GET 页面文本；失败自动重试一次，返回字符串（失败为空串）"""
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        if referer:
            req.add_header('Referer', referer)
        for attempt in (0, 1):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return r.read().decode('utf-8', 'replace')
            except Exception:
                if attempt == 0:
                    time.sleep(0.2)        # 第一次失败稍作停顿再重试
        return ""

    # ---------------- 缓存 ----------------
    def _cache_get(self, cache, key, ttl):
        """取未过期的缓存值；无则返回 None"""
        with self._lock:
            item = cache.get(key)
        if item and time.time() - item[0] < ttl:
            return item[1]
        return None

    def _cache_set(self, cache, key, value, ttl):
        """写入缓存；条目超限时整体清空防止内存膨胀"""
        with self._lock:
            if len(cache) > 512:
                cache.clear()
            cache[key] = (time.time(), value, ttl)

    # ---------------- HTML 解析 ----------------
    @staticmethod
    def _abs(u):
        """把站内相对链接补全为绝对 URL"""
        u = (u or '').strip()
        if not u:
            return ''
        if u.startswith('//'):
            return 'https:' + u
        if u.startswith('/'):
            return HOST + u
        if not u.startswith('http'):
            return HOST + '/' + u
        return u

    def _parse_cards(self, html, limit=40, adblock=False):
        """解析游戏卡片(.card-blog)，输出动作协议条目列表

        adblock=True 时条目附带去广告字段（搜索兜底，见 searchContent 的传参）
        """
        out = []
        # 按卡片起止切分；每段内取 h4>a(名称+链接) 与 img(缩略图)
        for seg in re.split(r'class="card\s+card-blog"', html)[1:]:
            m = re.search(r'<h4[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
                          seg, re.S)
            if not m:
                continue
            name = re.sub(r'\s+', ' ', m.group(2)).strip()
            url = self._abs(m.group(1))
            if not name or not url or 'javascript' in url:
                continue
            pic = ''
            mi = re.search(r'<img[^>]*src="([^"]+)"', seg, re.S)
            if mi:
                pic = self._abs(mi.group(1))
            out.append(_browser_vod(url, name, pic, adblock))
            if len(out) >= limit:
                break
        return out

    # ---------------- 首页 ----------------
    def homeContent(self, filter=False):
        """全部分类 + 筛选器；无需推荐列表（由 homeVod 填充）"""
        return {"class": ALL_CLASSES, "filters": ALL_FILTERS, "list": []}

    def _home_list(self):
        """首页推荐：取默认分类(FC)第一页，点开即玩"""
        try:
            return self.categoryContent(PLATFORMS[0]['id'], 1, None, {})['list'][:20]
        except Exception:
            return []

    def homeVod(self):
        """TVBox 加载器强制调用；缺失会导致整个源被丢弃"""
        return {"list": self._home_list()}

    def homeVideoContent(self):
        """影视仓等播放器调用；与 homeVod 等价"""
        return {"list": self._home_list()}

    # ---------------- 分类列表 ----------------
    def categoryContent(self, tid, pg, filter, extend):
        """分类列表：tid / extend.class 携带列表 URL 模板，返回动作协议条目

        兼容多种播放器调用流派：
        - extend.class 为完整 URL 路径（筛选选中后透传）→ 直接使用
        - tid 为完整 URL 路径 → 直接使用
        - tid 为纯数字（FC 数字类型，旧播放器流派）→ 映射到类型路径
        """
        try:
            page = max(1, int(pg or 1))
        except Exception:
            page = 1

        # 优先级：extend.class(完整路径) > tid 为完整路径 > tid 为数字类型
        path = ''
        if isinstance(extend, dict):
            path = (extend.get('class') or '').strip()
        elif isinstance(extend, str):
            try:
                path = (json.loads(extend).get('class') or '').strip()
            except Exception:
                path = ''
        if not path:
            raw = str(tid).strip()
            # 兼容传入完整 URL：剥掉站点前缀只留路径
            if raw.startswith(HOST):
                raw = raw[len(HOST):]
            if raw.startswith('/nes?'):
                path = raw
            else:
                path = _TYPE_ALIAS.get(raw, raw)   # 数字/中文类型 → FC 类型路径
        elif path.startswith(HOST):
            path = path[len(HOST):]

        url = HOST + path + str(page)
        ckey = url + '|p' + str(page)
        cached = self._cache_get(self._cat_cache, ckey, TTL_CAT)
        if cached is not None:
            return cached

        html = self._get(url)
        result = {"list": self._parse_cards(html) if html else []}
        self._cache_set(self._cat_cache, ckey, result, TTL_CAT)
        return result

    # ---------------- 详情（兜底） ----------------
    def detailContent(self, ids):
        """动作协议源无需详情页；解析动作 JSON 后兜底返回，避免部分播放器报错"""
        if isinstance(ids, str):
            ids = [ids]
        vid = str(ids[0]) if ids else ''
        try:
            action = json.loads(vid)
            url = action.get("url") or ""
            name = action.get("title") or "小游戏"
        except Exception:
            url, name = vid, vid
        if not url:
            return {"list": []}
        detail = {
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": '',
            "type_name": "小游戏",
            "vod_remarks": "点开即玩",
            "vod_year": '',
            "vod_area": '',
            "vod_lang": '',
            "vod_director": '',
            "vod_actor": '',
            "vod_content": "%s 点开即用浏览器打开游玩" % name,
            "vod_play_from": "在线玩",
            "vod_play_url": "在线玩$%s" % url,
        }
        return {"list": [detail]}

    # ---------------- 播放（兜底） ----------------
    def playerContent(self, flag, id, vipFlags):
        """无视频流：parse=0 直开网页，交由支持网页的播放器打开"""
        url = str(id or '').strip()
        if not url:
            return {"parse": 0, "playUrl": "", "url": ""}
        if not url.startswith('http'):
            url = self._abs(url)
        return {"parse": 0, "playUrl": "", "url": url, "header": ACTION_HEADER}

    # ---------------- 搜索 ----------------
    def searchContent(self, keyword, quick=False, pg=1):
        """站内搜索（GET /search?name=），结果同样为动作协议条目"""
        kw = (keyword or '').strip()
        if not kw:
            return {"list": [], "msg": "请输入搜索关键词", "page": 1}
        try:
            page = max(1, int(pg or 1))
        except Exception:
            page = 1

        ckey = "%d|%s" % (page, kw.lower())
        cached = self._cache_get(self._search_cache, ckey, TTL_SEARCH)
        if cached is not None:
            return cached

        url = "%s/search?name=%s" % (HOST, urllib.parse.quote(kw))
        html = self._get(url, referer=HOST + '/', timeout=TIMEOUT_API)
        # 搜索结果无法区分游戏所属平台（卡片 URL 均为 /play?id=），
        # 统一附加去广告字段：对无广告页面无任何副作用（脚本空转 + 域名本无请求）
        videos = self._parse_cards(html, adblock=True) if html else []
        result = {"list": videos, "page": page}
        if not videos:
            result["msg"] = "未找到相关游戏，请尝试其他关键词或通过分类浏览"
        self._cache_set(self._search_cache, ckey, result, TTL_SEARCH)
        return result

    # ---------------- 清理 ----------------
    def destroy(self):
        """标准库请求无连接资源，仅清空缓存即可（锁对象保留）"""
        self._cat_cache = {}
        self._search_cache = {}

    def close(self):
        self.destroy()


# ------------------------------------------------------------
# 本地自测：python 小霸王.py [home|category|search|detail]
# ------------------------------------------------------------
if __name__ == '__main__':
    s = Spider()
    act = sys.argv[1] if len(sys.argv) > 1 else 'home'
    if act == 'home':
        print(json.dumps(s.homeContent(), ensure_ascii=False)[:400])
        print('homeVod list =', len(s.homeVod().get('list', [])))
    elif act == 'category':
        tid = sys.argv[2] if len(sys.argv) > 2 else PLATFORMS[0]['id']
        r = s.categoryContent(tid, '1', False, {})
        print('list =', len(r.get('list', [])))
        for it in r.get('list', [])[:3]:
            try:
                actj = json.loads(it['vod_id'])
                print(' -', it['vod_name'], '|', actj.get('url', '')[:60])
            except Exception:
                print(' -', it['vod_name'], '|', it['vod_id'][:60])
    elif act == 'search':
        kw = sys.argv[2] if len(sys.argv) > 2 else '魂斗罗'
        r = s.searchContent(kw)
        print('list =', len(r.get('list', [])))
        for it in r.get('list', [])[:3]:
            try:
                actj = json.loads(it['vod_id'])
                print(' -', it['vod_name'], '|', actj.get('url', '')[:60])
            except Exception:
                print(' -', it['vod_name'])
    elif act == 'detail':
        vid = ('{"actionId":"browser","type":"browser","title":"小游戏",'
               '"url":"https://www.yikm.net/play?id=4137",'
               '"header":{"User-Agent":"x"}}')
        print(json.dumps(s.detailContent(vid), ensure_ascii=False)[:400])
    s.close()