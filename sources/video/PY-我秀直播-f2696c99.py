# LumeSource: {"id":"pypack_bbbc0c3df2696c99","name":"我秀直播","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding=utf-8
# 我秀直播 spider for 影视仓 / OK影视 / TVBox (type=3)
# 仅供个人学习和技术研究使用；请遵守目标站点条款及当地法律。

import json
import re
import ssl
import sys
import time
import urllib.request
import urllib.parse
import warnings
from datetime import datetime

warnings.filterwarnings("ignore")
sys.path.append("..")
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    BaseSpider = object

try:
    _SSL_CTX = ssl.create_default_context()
    _SSL_CTX.check_hostname = False
    _SSL_CTX.verify_mode = ssl.CERT_NONE
except Exception:
    _SSL_CTX = None


def _urlopen(req, timeout=20):
    if _SSL_CTX is not None:
        return urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX)
    return urllib.request.urlopen(req, timeout=timeout)


def _to_int(v, default=0):
    try:
        return int(str(v).strip())
    except Exception:
        return default


class Spider(BaseSpider):
    """我秀直播（woxiu.com）适配器（灵风自研模板，参照 py 文件夹直播爬虫库风格）。

    站点结构（2026-10-15 实测）：
      - 移动端列表 M_API: https://m.woxiu.com/index.php?action=M/Index&do=<cate>&page=<n>
        返回 {"totalPage":N,"data":[...]}；do=popular 热门 / do=Recommend 推荐。
        房间字段：room_id / nickname / grade / is_zb(1=直播中) / photo(头像) /
        room_img(封面) / host(CDN, bplay.xiuimg.com) / token(播放令牌) /
        is_phone / starttime / count(人气) / label。
      - PC 端主播等级 API: https://www.woxiu.com/index.php?action=Index/Main
        &do=ApiZhuboGradeNew[&gtype=1|2|3|4]&page=<n>
        返回 {"page":N,"count":M,"data":[...]}，每页 20 条；
        gtype: 1=红心 2=钻石 3=明星 4=巨星，缺省=全部。
      - PC 端游戏房间: do=ApiGameRoom&page=<n>（room_type=2）。
      - 直播间信息: https://m.woxiu.com/index.php?action=M/Live&do=LiveInfo&room_id=<rid>
        返回 live_stream(HLS m3u8) / room_img / zb_photo / zb_nickname /
        viewer_count(人气) / online(1=直播中) / last_chat。
      - 播放直链（parse=0，已实测 200 可拉流）：
          HLS: https://bhls.xiuimg.com/vshow/<token>/playlist.m3u8
          FLV: https://bplay.xiuimg.com/vshow/<token>.flv
        token 即列表接口 host/token 字段，或从 live_stream 中提取。
      - 搜索: https://www.woxiu.com/index.php?action=Search&q=<kw>
        [&search_type=nickname|roomid]，HTML 结果 ul.zb_live_list > li。
    """

    name = "我秀直播"
    M_HOST = "https://m.woxiu.com"
    PC_HOST = "https://www.woxiu.com"
    M_API = M_HOST + "/index.php?action=M/Index&do="
    LIVE_API = M_HOST + "/index.php?action=M/Live&do=LiveInfo&room_id="
    PC_API = PC_HOST + "/index.php?action=Index/Main&do="
    SEARCH_URL = PC_HOST + "/index.php?action=Search&q="
    FLV_HOST = "https://bplay.xiuimg.com"
    HLS_RE = re.compile(r"/vshow/([^/]+)/playlist\.m3u8", re.I)

    UA = ("Mozilla/5.0 (Linux; Android 11; SM-G991B) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
    TIMEOUT = 20

    PC_PAGE = 20  # PC 端 API 每页条数

    # 父分类：type_id -> (名称, 数据源)
    #   mobile = 移动端 M/Index 接口；pc = PC 端 Index/Main 接口
    CATS = [
        ("popular", "热门直播", "mobile"),
        ("Recommend", "推荐主播", "mobile"),
        ("grade_all", "全部主播", "pc"),
        ("grade_4", "巨星", "pc"),
        ("grade_3", "明星", "pc"),
        ("grade_2", "钻石", "pc"),
        ("grade_1", "红心", "pc"),
        ("game", "游戏主播", "pc"),
    ]
    PC_DO = {
        "grade_all": "ApiZhuboGradeNew",
        "grade_4": "ApiZhuboGradeNew&gtype=4",
        "grade_3": "ApiZhuboGradeNew&gtype=3",
        "grade_2": "ApiZhuboGradeNew&gtype=2",
        "grade_1": "ApiZhuboGradeNew&gtype=1",
        "game": "ApiGameRoom",
    }

    SORTS = [("0", "默认"), ("hotdown", "人气高→低"), ("hotup", "人气低→高")]
    TOPS = [("0", "全部"), ("30", "Top30"), ("60", "Top60"), ("100", "Top100")]
    ONLINES = [("", "全部"), ("1", "只看直播中")]

    # ---------------- 基础设施 ------------------------------------------
    def init(self, extend=""):
        self._extend = str(extend or "")
        self._nav = None
        return ""

    def getName(self):
        return self.name

    def isVideoFormat(self, url):
        u = str(url or "").lower()
        return u.endswith((".m3u8", ".flv", ".mp4", ".mkv"))

    def manualVideoCheck(self):
        return False

    def _headers(self, referer=None):
        return {"User-Agent": self.UA,
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "zh-CN,zh;q=0.9",
                "Referer": referer or (self.M_HOST + "/")}

    def _fetch(self, url, referer=None, retry=1):
        for i in range(retry + 1):
            try:
                req = urllib.request.Request(url, headers=self._headers(referer))
                with _urlopen(req, timeout=self.TIMEOUT) as r:
                    return r.read().decode("utf-8", "replace")
            except Exception:
                if i >= retry:
                    return ""
                time.sleep(0.4)
        return ""

    def _json_get(self, url, referer=None):
        text = self._fetch(url, referer=referer)
        if not text:
            return {}
        try:
            return json.loads(text)
        except Exception:
            a = text.find("{")
            b = text.rfind("}")
            if a > -1 and b > a:
                try:
                    return json.loads(text[a:b + 1])
                except Exception:
                    return {}
        return {}

    @staticmethod
    def _fix_pic(url):
        url = str(url or "").strip().replace("\\/", "/")
        if not url:
            return ""
        if url.startswith("//"):
            url = "https:" + url
        return url

    @staticmethod
    def _grade_name(grade):
        g = _to_int(grade)
        if g >= 31:
            return "巨星"
        if g >= 21:
            return "明星"
        if g >= 11:
            return "钻石"
        if g >= 1:
            return "红心"
        return "新人"

    @staticmethod
    def _live_dur(starttime):
        """starttime: '2026-10-15 14:09:06' -> 已播时长文案。"""
        s = str(starttime or "").strip()
        if not s:
            return ""
        try:
            st = datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S")
        except Exception:
            return s
        sec = max(0, int((datetime.now() - st).total_seconds()))
        h, m = sec // 3600, (sec % 3600) // 60
        if h > 0:
            return "%d小时%d分钟" % (h, m)
        return "%d分钟" % m

    # ---------------- 分类树（父分类 + 完整筛选器）----------------------
    def homeContent(self, filter):
        data = {"class": [{"type_id": t, "type_name": n} for t, n, _s in self.CATS]}
        if filter:
            filters = {}
            for tid, _n, src in self.CATS:
                rows = [{"key": "sort", "name": "排序", "init": "0",
                         "value": [{"n": n, "v": v} for v, n in self.SORTS]},
                        {"key": "online", "name": "状态", "init": "",
                         "value": [{"n": n, "v": v} for v, n in self.ONLINES]}]
                if src == "mobile":
                    rows.append({"key": "top", "name": "人气排行", "init": "0",
                                 "value": [{"n": n, "v": v} for v, n in self.TOPS]})
                filters[tid] = rows
            data["filters"] = filters
        return data

    # ---------------- 卡片解析 ------------------------------------------
    def _card_mobile(self, j):
        rid = str(j.get("room_id") or "").strip()
        if not rid:
            return None
        online = _to_int(j.get("is_zb")) == 1
        count = _to_int(j.get("count"))
        remark = "👥 %s" % (count if count > 0 else "直播中")
        if not online:
            remark = "未开播"
        return {
            "vod_id": rid,
            "vod_name": str(j.get("nickname") or ("房间" + rid)),
            "vod_pic": self._fix_pic(j.get("room_img") or j.get("photo")),
            "type_name": "我秀直播",
            "vod_year": "",
            "vod_area": "",
            "vod_remarks": remark,
            "style": {"type": "rect", "ratio": 1.0},
        }

    def _card_pc(self, j):
        rid = str(j.get("room_id") or "").strip()
        if not rid:
            return None
        online = _to_int(j.get("online")) == 1
        count = _to_int(j.get("count"))
        remark = "👥 %s" % (count if count > 0 else "直播中")
        if not online:
            remark = "未开播"
        return {
            "vod_id": rid,
            "vod_name": str(j.get("name") or ("房间" + rid)),
            "vod_pic": self._fix_pic(j.get("room_img") or j.get("index_img")),
            "type_name": "我秀直播",
            "vod_year": "",
            "vod_area": "",
            "vod_remarks": remark,
            "style": {"type": "rect", "ratio": 1.0},
        }

    # ---------------- 首页列表 ------------------------------------------
    def homeVideoContent(self):
        payload = self._json_get(self.M_API + "popular&page=1")
        cards = [c for c in (self._card_mobile(j)
                             for j in (payload.get("data") or [])) if c]
        return {"list": cards[:20]}

    # ---------------- 分类列表（分页）-----------------------------------
    @staticmethod
    def _norm_extend(extend):
        ex = {}
        if isinstance(extend, dict):
            ex = extend
        elif extend:
            try:
                if str(extend).strip().startswith("{"):
                    ex = json.loads(extend)
            except Exception:
                ex = {}
        if not isinstance(ex, dict):
            ex = {}
        return {str(k): str(v or "") for k, v in ex.items()}

    def _apply_local_filter(self, cards, ex):
        """本地筛选/排序/截断：online / sort / top（站点接口不支持这些参数）。"""
        online = (ex.get("online") or "").strip()
        if online == "1":
            cards = [c for c in cards if "未开播" not in str(c.get("vod_remarks"))]
        sort = (ex.get("sort") or "0").strip()

        def hot(c):
            m = re.search(r"(\d+)", str(c.get("vod_remarks") or ""))
            return _to_int(m.group(1)) if m else 0

        if sort == "hotdown":
            cards = sorted(cards, key=hot, reverse=True)
        elif sort == "hotup":
            cards = sorted(cards, key=hot)
        top = _to_int(ex.get("top"))
        if top > 0:
            cards = cards[:top]
        return cards

    def _category_mobile(self, tid, page, ex):
        filter_mode = (ex.get("sort") in ("hotdown", "hotup")) or _to_int(ex.get("top")) > 0
        if filter_mode:
            # 合并前 3 页去重后本地排序/截断，再本地分页
            seen, merged = set(), []
            for p in (1, 2, 3):
                payload = self._json_get("%s%s&page=%d" % (self.M_API, tid, p))
                rows = payload.get("data") or []
                for j in rows:
                    rid = str(j.get("room_id") or "")
                    if not rid or rid in seen:
                        continue
                    seen.add(rid)
                    c = self._card_mobile(j)
                    if c:
                        merged.append(c)
                if not rows:
                    break
            cards = self._apply_local_filter(merged, ex)
            per = 20
            start = (page - 1) * per
            total = len(cards)
            return {"list": cards[start:start + per], "page": page,
                    "pagecount": max(1, (total + per - 1) // per) if total else 1,
                    "limit": per, "total": total}
        payload = self._json_get("%s%s&page=%d" % (self.M_API, tid, page))
        cards = [c for c in (self._card_mobile(j)
                             for j in (payload.get("data") or [])) if c]
        cards = self._apply_local_filter(cards, ex)
        total_page = max(1, _to_int(payload.get("totalPage"), 1))
        return {"list": cards, "page": page, "pagecount": total_page,
                "limit": len(cards) or 20, "total": len(cards)}

    def _category_pc(self, tid, page, ex):
        do = self.PC_DO.get(tid)
        if not do:
            return {"list": [], "page": page, "pagecount": 1, "limit": self.PC_PAGE, "total": 0}
        payload = self._json_get(self.PC_API + do + "&page=%d" % page,
                                 referer=self.PC_HOST + "/")
        rows = payload.get("data") or []
        cards = [c for c in (self._card_pc(j) for j in rows) if c]
        cards = self._apply_local_filter(cards, ex)
        total = _to_int(payload.get("count"), len(cards))
        per = len(rows) or self.PC_PAGE
        pagecount = max(1, (total + per - 1) // per) if total else 1
        return {"list": cards, "page": page, "pagecount": pagecount,
                "limit": per, "total": total}

    def categoryContent(self, tid, pg, filter, extend):
        del filter  # filters 由 homeContent 声明；筛选值由 extend 传入
        try:
            page = max(1, _to_int(pg, 1))
        except Exception:
            page = 1
        tid = str(tid or "").strip()
        ex = self._norm_extend(extend)
        src = ""
        for t, _n, s in self.CATS:
            if t == tid:
                src = s
                break
        try:
            if src == "mobile":
                return self._category_mobile(tid, page, ex)
            if src == "pc":
                return self._category_pc(tid, page, ex)
        except Exception:
            pass
        return {"list": [], "page": page, "pagecount": 1, "limit": 20, "total": 0}

    # ---------------- 详情 ----------------------------------------------
    def _live_info(self, rid):
        return self._json_get(self.LIVE_API + urllib.parse.quote(str(rid)))

    def detailContent(self, ids):
        if isinstance(ids, str):
            ids = [ids]
        out = []
        for vid in ids or []:
            rid = str(vid or "").strip()
            if not rid:
                continue
            info = self._live_info(rid)
            if not info:
                out.append({
                    "vod_id": rid, "vod_name": "房间" + rid,
                    "vod_pic": "", "type_name": "我秀直播",
                    "vod_year": "", "vod_area": "",
                    "vod_remarks": "加载失败", "vod_actor": "",
                    "vod_director": "", "vod_content": "直播间信息加载失败，请重试。",
                    "vod_play_from": "", "vod_play_url": "",
                })
                continue
            online = _to_int(info.get("online")) == 1
            stream = str(info.get("live_stream") or "").strip()
            nickname = str(info.get("zb_nickname") or ("房间" + rid))
            count = _to_int(info.get("viewer_count"))
            pic = self._fix_pic(info.get("room_img") or info.get("zb_photo"))
            grade = ""
            st = str(info.get("starttime") or "").strip()
            if st:
                grade = "开播时间：%s（已播 %s）" % (st, self._live_dur(st) or "—")
            content = "\n".join(x for x in [
                "房号：%s" % rid,
                "主播：%s" % nickname,
                grade,
                "人气：%s" % (count if count > 0 else "—"),
                "平台：我秀直播（woxiu.com）",
            ] if x)
            if online and stream:
                froms = ["高清", "原画"]
                urls = ["直播$%s$hls" % rid, "直播$%s$flv" % rid]
                remark = "👥 %s" % (count if count > 0 else "直播中")
            else:
                froms = []
                urls = []
                remark = "未开播"
            out.append({
                "vod_id": rid,
                "vod_name": nickname,
                "vod_pic": pic,
                "type_name": "我秀直播",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": remark,
                "vod_actor": nickname,
                "vod_director": "",
                "vod_content": content,
                "vod_play_from": "$$$".join(froms),
                "vod_play_url": "$$$".join(urls),
            })
        return {"list": out}

    # ---------------- 播放 ----------------------------------------------
    def _flv_from_stream(self, stream):
        m = self.HLS_RE.search(str(stream or ""))
        if m:
            return "%s/vshow/%s.flv" % (self.FLV_HOST, m.group(1))
        return ""

    def playerContent(self, flag, id, vipFlags=""):
        target = str(id or "")
        # 兼容壳端可能传入 "名称$room_id$line"（detail 原始值）或 "room_id$line"
        parts = [p for p in target.split("$") if p]
        if target.startswith("http://") or target.startswith("https://"):
            return {"parse": 0, "jx": 0, "url": target,
                    "header": {"User-Agent": self.UA, "Referer": self.M_HOST + "/"}}
        if len(parts) >= 3:
            rid, line = parts[-2], parts[-1]
        elif len(parts) == 2:
            rid, line = parts[0], parts[1]
        else:
            rid, line = (parts[0] if parts else ""), "hls"
        if not rid:
            return {"parse": 0, "jx": 0, "msg": "无效的播放参数"}
        header = {"User-Agent": self.UA, "Referer": self.M_HOST + "/"}
        info = self._live_info(rid)
        stream = str((info or {}).get("live_stream") or "").strip()
        if not stream:
            return {"parse": 0, "jx": 0, "url": "",
                    "header": header, "msg": "主播未开播或直播间不存在"}
        if line == "flv":
            url = self._flv_from_stream(stream)
            if not url:
                url = stream
        else:
            url = stream
        return {"parse": 0, "jx": 0, "url": url, "header": header}

    # ---------------- 搜索 ------------------------------------------------
    def _search_html(self, keyword, search_type, page):
        url = self.SEARCH_URL + urllib.parse.quote(keyword)
        if search_type:
            url += "&search_type=" + search_type
        if page > 1:
            url += "&page=%d" % page
        return self._fetch(url, referer=self.PC_HOST + "/")

    @staticmethod
    def _parse_search_cards(html):
        cards = []
        for block in re.findall(r"<li>(.*?)</li>", html, re.S):
            m = re.search(r'href="https?://(?:www|m)\.woxiu\.com/(\d+)"', block)
            if not m:
                continue
            rid = m.group(1)
            img = re.search(r'<img[^>]+src="([^"]+)"', block)
            name = re.search(r'alt="([^"]*)"', block)
            if not name:
                name = re.search(r"<i>([^<]*)</i>", block)
            online = "online_icon" in block
            hot = re.search(r"人气：\s*(\d+)", block)
            remark = "👥 %s" % (hot.group(1) if hot else "直播中") if online else "未开播"
            cards.append({
                "vod_id": rid,
                "vod_name": (name.group(1).strip() if name else ("房间" + rid)),
                "vod_pic": (img.group(1) if img else ""),
                "type_name": "我秀直播",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": remark,
                "style": {"type": "rect", "ratio": 1.0},
            })
        return cards

    def searchContent(self, key, quick, pg="1"):
        keyword = str(key or "").strip()
        try:
            page = max(1, _to_int(pg, 1))
        except Exception:
            page = 1
        if not keyword:
            return {"list": [], "page": page, "pagecount": 1, "limit": 20, "total": 0}
        # 纯数字关键词按房号搜索更精准
        stype = "roomid" if keyword.isdigit() else "nickname"
        cards = []
        html = self._search_html(keyword, stype, page)
        if html:
            cards = self._parse_search_cards(html)
        if not cards and stype == "roomid":
            cards = self._parse_search_cards(
                self._search_html(keyword, "nickname", page))
        return {"list": cards, "page": page,
                "pagecount": page if cards else 1,
                "limit": 20, "total": len(cards)}

    # ---------------- 兼容部分壳端的图片代理调用 -------------------------
    def localProxy(self, param):
        if isinstance(param, dict):
            url = param.get("url") or param.get("do") or ""
        else:
            url = str(param or "")
        url = self._fix_pic(url)
        if not url:
            return None
        try:
            req = urllib.request.Request(url, headers=self._headers())
            with _urlopen(req, timeout=self.TIMEOUT) as r:
                body = r.read()
                typ = (r.headers.get("Content-Type") or "image/jpeg").split(";", 1)[0]
            if body:
                return [200, typ, body]
        except Exception:
            pass
        return None

    def destroy(self):
        self._nav = None


if __name__ == "__main__":
    sp = Spider()
    sp.init("")
    print("== homeContent ==")
    print(json.dumps(sp.homeContent(True), ensure_ascii=False)[:600])
    print("== categoryContent popular p1 ==")
    r = sp.categoryContent("popular", "1", True, "")
    print(json.dumps({k: (len(v) if k == "list" else v) for k, v in r.items()}, ensure_ascii=False))
    print("== categoryContent grade_4 p1 ==")
    r = sp.categoryContent("grade_4", "1", True, "")
    print(json.dumps({k: (len(v) if k == "list" else v) for k, v in r.items()}, ensure_ascii=False))
    rid = (r.get("list") or [{}])[0].get("vod_id")
    print("== detailContent %s ==" % rid)
    print(json.dumps(sp.detailContent([rid]), ensure_ascii=False)[:800])
    print("== playerContent hls ==")
    print(json.dumps(sp.playerContent("我秀直播", "%s$hls" % rid, ""), ensure_ascii=False))
    print("== playerContent flv ==")
    print(json.dumps(sp.playerContent("我秀直播", "%s$flv" % rid, ""), ensure_ascii=False))
    print("== searchContent ==")
    print(json.dumps(sp.searchContent("乐儿", False, "1"), ensure_ascii=False)[:800])
