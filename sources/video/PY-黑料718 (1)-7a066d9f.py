# LumeSource: {"id":"pypack_df3dd9f97a066d9f","name":"黑料718 (1)","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
"""
黑料718 TVBox 爬虫 (type:3 纯 Python 单文件 · 类式 Spider)
=========================================================
目标站点 : https://clash.windowheiliao.com  (黑料718 / 吃瓜爆料)
站点框架 : Typecho 博客 + Mirages 主题
视频来源 : 文章详情页内 DPlayer 播放器的 data-config -> video.url2
           是一段 HLS(m3u8) 流, 切片为 TS, 部分带 AES-128 加密(密钥相对路径 enc.key)

【重要 · 本文件格式说明】
TVBox / 影视仓 / FongMi 各分支加载 py 源时, 会查找一个名为 Spider 的类。
因此本文件必须定义为 "类式 Spider" 格式 (而不是模块级散函数):
    class Spider(_BaseSpider):
        def homeContent(self, filter=True): ...
        def categoryContent(self, tid, pg=1, filter=1, extend=None): ...
        def detailContent(self, ids): ...
        def searchContent(self, key, quick=False, pg=1): ...
        def playerContent(self, flag, id, vipFlags=None): ...
标准壳内存在 base.spider.Spider 基类; 独立运行时(本地自测)自动退化为 object。

踩坑提示
--------
1. 列表页(首页/分类/搜索)结构完全一致, 每篇文章包在 <article> 里:
        <meta itemprop="image" content="封面">  +  <h2 class="post-card-title">标题</h2>
   广告卡片带 rel="sponsored" 且无标题标签, 直接跳过
2. 视频不是列表直链, 藏在每篇详情页的 DPlayer 配置里, 必须进详情页取
3. m3u8 链接带 sign 签名参数, 可能限时有效; detailContent 实时抓详情页取最新签名
4. 一篇文章可能含多个 DPlayer(多段视频), 解析后并成同一播放源的多集
5. 部分文章只有图文没有视频, 播放地址留空并标注 "图文, 无视频源"
"""

import re
import json
import ssl
import sys
import time
import urllib.request
import urllib.parse

# ---- 类式 Spider 基类兼容 (标准壳有 base.spider.Spider, 独立运行退化为 object) ----
try:
    if '..' not in sys.path:
        sys.path.append('..')
    from base.spider import Spider as _BaseSpider
except Exception:
    _BaseSpider = object


# ============================ 基础配置 ============================
SITE = "https://clash.windowheiliao.com"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 首页导航里的分类 (tid 用分类 slug, TVBox 回传时原样带回)
CATEGORIES = [
    ("每日黑料", "daily-gossip"),
    ("黑料热榜", "top-stories"),
    ("娱乐黑料", "entertainment-news"),
    ("明星黑料", "celebrity-scandals"),
    ("黑料精华", "hljh"),
    ("网黄合集", "wanghuang"),
    ("网红吃瓜", "internet-celebrities"),
    ("福利姬料", "model-photos"),
    ("每日大赛", "daily-contest"),
    ("社会吃瓜", "trending-news"),
    ("反差婊们", "contrast-reveal"),
    ("真实乱伦", "zsll"),
    ("AI短剧成人", "AICG"),
]

# 跳过证书校验 (部分 CDN 证书链不全, 不跳过会直接抛异常)
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE


# ============================ 通用工具 ============================
def _fetch(url, retries=3):
    """
    带 UA / Referer 的 GET 请求, 返回解码后的文本
    该站由 Cloudflare 防护, python 直连偶尔会被无故断连, 加重试兜底
    """
    last = None
    for _ in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": SITE + "/"})
            with urllib.request.urlopen(req, timeout=20, context=_SSL) as r:
                return r.read().decode("utf-8", "ignore")
        except Exception as e:
            last = e
            time.sleep(1.5)
    raise last


def _abs(url):
    """相对路径补全为绝对地址"""
    if not url:
        return ""
    if url.startswith("http"):
        return url
    return SITE + (url if url.startswith("/") else "/" + url)


def _clean(text):
    """去掉 HTML 标签并压缩空白"""
    t = re.sub(r"<[^>]+>", " ", text or "")
    return re.sub(r"\s+", " ", t).strip()


def _parse_list(html):
    """
    解析列表页(首页/分类/搜索通用): 返回 vod 卡片列表
    站点把每篇文章包在 <article> 里, 广告卡片带 rel="sponsored" 直接跳过
    """
    vods = []
    seen = set()
    for art in re.findall(r"<article\b.*?</article>", html, re.S):
        if 'rel="sponsored' in art:          # 赞助广告, 跳过
            continue
        mid = re.search(r"/archives/(\d+)", art)
        if not mid:
            continue
        aid = mid.group(1)
        if aid in seen:                       # 同页可能重复出现, 去重
            continue
        # 标题: 必须用 post-card-title, 避免混入 CSS 注入的日期/作者/分类
        hm = re.search(r'<h2[^>]*post-card-title[^>]*>(.*?)</h2>', art, re.S)
        if not hm:
            continue
        name = _clean(hm.group(1))
        if not name:
            continue
        # 封面: 优先 <meta itemprop="image">, 退回 data-pic; 跳过 JS 模板占位符 ${...}
        pic = ""
        for pat in (r'itemprop="image" content="([^"]+)"',
                    r'data-pic=["\']([^"\']+)["\']'):
            im = re.search(pat, art)
            if im and "${" not in im.group(1):
                pic = _abs(im.group(1))
                break
        seen.add(aid)
        vods.append({
            "vod_id": aid,
            "vod_name": name,
            "vod_pic": pic,
            "vod_remarks": "",
        })
    return vods


# ============================ Spider 类 (TVBox 入口) ============================
class Spider(_BaseSpider):
    """TVBox 类式爬虫: 所有接口方法都必须定义在本类里"""

    def __init__(self):
        self.name = "黑料718"
        self.host = SITE
        self.ua = UA
        self.timeout = 20
        # 分类 (供 homeContent 输出导航)
        self.categories = [{"type_id": slug, "type_name": name} for name, slug in CATEGORIES]

    # ---------------- 元信息 / 生命周期 ----------------
    def getName(self):
        """爬虫显示名"""
        return "黑料718"

    def init(self, extend=""):
        """初始化; extend 为订阅里配置的扩展参数(本爬虫无需)"""
        return None

    def destroy(self):
        return None

    def getDependence(self):
        return []

    def isVideoFormat(self, url):
        u = url or ""
        return ".m3u8" in u or ".mp4" in u

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        """本爬虫不需要本地代理, 返回 None"""
        return None

    # ---------------- TVBox 五大接口 ----------------
    def homeContent(self, filter=True):
        """首页: 返回分类导航 + 首页推荐"""
        try:
            html = _fetch(SITE + "/")
            vods = _parse_list(html)
        except Exception:
            vods = []
        return {"class": self.categories, "list": vods[:30]}

    def homeVideoContent(self):
        """首页推荐视频列表(可选接口)"""
        try:
            html = _fetch(SITE + "/")
            vods = _parse_list(html)
        except Exception:
            vods = []
        return {"list": vods[:30]}

    def categoryContent(self, tid, pg=1, filter=1, extend=None):
        """分类/翻页: tid 为分类 slug; 首页推荐翻页走 /page/N/"""
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if not tid or tid == "home":
            url = SITE + ("/page/%d/" % pg if pg > 1 else "/")
        else:
            url = SITE + "/category/%s/?page=%d" % (tid, pg)
        try:
            html = _fetch(url)
            vods = _parse_list(html)
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": pg,
            "pagecount": 999,        # 该站页数很多, 给足够大的值让 TVBox 持续翻页
            "total": 999 * 30,
            "limit": 30,
        }

    def detailContent(self, ids):
        """
        详情: 进文章页, 提取所有 DPlayer 的 m3u8 作为同一源的多集
        ids 是 TVBox 回传的 vod_id 列表(文章 ID)
        """
        aid = ids[0] if isinstance(ids, (list, tuple)) else str(ids)
        aid = str(aid)
        try:
            html = _fetch(SITE + "/archives/%s" % aid)
        except Exception:
            return {"list": [{
                "vod_id": aid,
                "vod_name": "详情获取失败",
                "vod_pic": "",
                "vod_play_from": "黑料",
                "vod_play_url": "",
                "vod_remarks": "详情页无法访问",
            }]}

        # 标题: 取 <title> 第一段 (去掉站点后缀)
        title = ""
        tm = re.search(r"<title>([^<]+)</title>", html)
        if tm:
            title = _clean(tm.group(1)).split(" - ")[0]

        # 封面: 优先文章级 <meta itemprop="image">, 退回 data-pic; 跳过 ${...} 占位符
        pic = ""
        for pat in (r'itemprop="image" content="([^"]+)"',
                    r"data-pic=['\"]([^'\"]+)['\"]"):
            im = re.search(pat, html)
            if im and "${" not in im.group(1):
                pic = _abs(im.group(1))
                break

        # 提取所有 DPlayer 视频源 (data-config 内 video.url2 优先, 退回 url)
        sources = []
        for cfg in re.findall(r"data-config='(\{.*?\})'", html, re.S):
            try:
                d = json.loads(cfg)
            except Exception:
                continue
            v = d.get("video", {}) or {}
            url = v.get("url2") or v.get("url")
            if url and url not in sources:
                sources.append(url)

        # 兜底: 直接在正文里捞 m3u8 链接
        if not sources:
            sources = re.findall(r'(https?://[^\s"\'<>]+\.m3u8[^\s"\'<>]*)', html)

        if not sources:      # 纯图文, 没有视频可播放
            return {"list": [{
                "vod_id": aid,
                "vod_name": title or "图文内容",
                "vod_pic": pic,
                "vod_play_url": "",
                "vod_remarks": "该条为图文, 无视频源",
            }]}

        # 多段视频并成同一播放源的多集: "第N集$url" 用 # 连接
        episodes = ["第%d集$%s" % (i, s) for i, s in enumerate(sources, 1)]
        return {"list": [{
            "vod_id": aid,
            "vod_name": title,
            "vod_pic": pic,
            "vod_play_from": "黑料",
            "vod_play_url": "#".join(episodes),
            "vod_remarks": "%d个视频" % len(sources),
        }]}

    def searchContent(self, key, quick=False, pg=1):
        """搜索: 关键字需 URL 编码"""
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        q = urllib.parse.quote(key)
        url = SITE + "/search/%s/?page=%d" % (q, pg)
        try:
            html = _fetch(url)
            vods = _parse_list(html)
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": pg,
            "pagecount": 50,
            "total": 50 * 30,
            "limit": 30,
        }

    def playerContent(self, flag, id, vipFlags=None):
        """
        播放: TVBox 把 detailContent 里某集的 url 作为 id 回传
        直接返回该 m3u8 地址, 并带上 UA/Referer 头
        (m3u8 及其 TS 分片都需要相同请求头, 否则可能 403)
        """
        return {
            "playUrl": "",
            "url": id,
            "header": {
                "User-Agent": UA,
                "Referer": SITE + "/",
            },
        }


# ============================ 本地自检(可选) ============================
if __name__ == "__main__":
    import pprint
    _sp = Spider()
    print("== getName:", _sp.getName())
    print("== homeContent ==")
    _h = _sp.homeContent()
    print("   分类数:", len(_h.get("class", [])), " 推荐数:", len(_h.get("list", [])))
    print("== categoryContent(daily-gossip,1) ==")
    print("   数量:", len(_sp.categoryContent("daily-gossip", 1).get("list", [])))
