# LumeSource: {"id":"pypack_4c860756bba96c00","name":"jiujiu","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
# ============ ★写源必加清单（缺一不可，写源时逐条落注释核对）============
# ★必加①大图片：列表 item 四件套 style={'type':'rect','ratio':1.78'} + land=1 + ratio=1.78 + type_name
# ★必加②二级分类/筛选器：homeContent 返 filters（key=一级 type_id，『全部』项 v=该 tid）+ categoryContent 消费 extend（参数名 filter）
# ★必加③搜索：searchContent(key,quick,pg)，关键词必须 quote()
# ☆按需·资料夹分类：folder:/cat:/vod_tag='folder' 真两级契约（非必加，用户点单才做）
# ============ ★写源必加清单结束 ============
# ============ ★写源必加/必检查清单结束（五标记核验点）============
# ============ 资料夹分类契约（本项目固化）============
# 一级 class = 分组（type_id=g:{i}，vod_tag='folder'）；二级 = 站点分类（vod_id=c:{id}，vod_tag='folder'）；三级 = 视频列表（真分页）
# 只做分组，不做合集层（无 folder:rank / folder:tag 包装）；分组内分类不重复、不遗漏，合计=全部分类数
# ============ 资料夹分类契约结束 ============
# ============ ★写源必检查清单（交付前逐条核对）============
# ★必检查①翻页还少/翻页还卡顿：page/pagecount/limit/total 四件齐全，pagecount 真解析（禁 999 伪分页）
# ★必检查②多线路接口检查：全部线路解析 + 并发 probe 各线首集可播，死线排最后保留不剔除
# ★必检查③播放源还能播放：playerContent 逐线实测可播（parse=0 + 真 m3u8/MP4），只回 {'parse':0,'url','header'}
# ★必检查④分类还少：补 LABEL/排行榜/更多入口，分类覆盖度足
# ============ ★写源必检查清单结束 ============
# ============ ★写源前必调·三底座 ============
# ①记忆库：知识库/影视源开发（01-规范契约 / 02-技能与工具链 / 03-攻坚档案 / 04-源交付档案 / 05-归档与暂停）
# ②技能包：/sdcard/Download/Operit/skills/SKILL_INDEX.md v2 分层调度（L0 tvbox-py-v73 → L1 pySkill → L2 攻坚 → L3 adaptive 工作台 → L4 交付）
# ③母版：cp 母版 → 改 CONFIG ★区 → 改站点逻辑区（禁从零手写骨架）
# ============ ★写源前必调·三底座结束 ============

import sys
import re
import json
import time
import gzip
import html
import hashlib
import threading
import urllib.parse
import urllib.request
import urllib.error
import http.cookiejar

sys.path.append('..')
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider(object):
        pass

CONFIG = {
    'host': 'https://www.jiujiu.live',
    'ua': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'page_size': 45,
    'max_pg': 400,
    'card_on': 1,
    'card_type': 'rect',
    'card_ratio': 1.78,
    'card_land': 1,
    'tops': [('new', '最新'), ('hit', '热播')],
    'groups': [('日本無碼區', [23, 82, 113, 358, 219, 8, 68, 238]), ('日本有碼區', [24, 66, 217, 73, 336, 67, 90, 203, 402, 271]), ('中文字幕區', [9, 308]), ('歐美專區', [25, 309, 201, 136, 133, 86, 71, 112, 433, 111]), ('動漫專區', [87, 55, 116, 132, 176, 7, 200, 199, 92]), ('傳媒華語', [100, 122, 109, 207]), ('女優明星', [78, 32, 110, 155, 163, 193]), ('倫理三級', [148, 41, 269, 101, 489]), ('專題精選', [64, 81, 31, 143, 331])],
    'cats': [(23, '日本無碼'), (9, '中文字幕'), (82, '日韓無碼'), (78, 'AV明星'), (31, '制服誘惑'), (24, '日本有碼'), (25, '歐美精品'), (113, '無碼專區'), (87, '動漫精品'), (201, '歐美-高清無碼'), (136, '歐美情色'), (55, '成人動漫'), (133, '歐美性愛'), (271, '日韓精品'), (116, '卡通動漫'), (148, '倫理三級'), (64, '巨乳美乳'), (81, '童顏巨乳'), (66, '亞洲有碼'), (86, '歐美極品'), (32, 'AV解說'), (110, '女優明星'), (309, '歐美'), (41, '倫理片'), (100, 'SWAG'), (143, '人妻熟女'), (8, '高清無碼'), (358, '日本-素人'), (90, '日本片商'), (132, '卡通動畫'), (71, '歐美激情'), (155, '明星換臉'), (176, '動漫卡通'), (68, '亞洲無碼'), (217, '日本-高清有碼'), (122, '麻豆視頻'), (163, '換臉明星'), (269, '倫理影片'), (238, '日本素人'), (101, '三級倫理'), (109, '麻豆傳媒'), (112, '歐美系列'), (92, '激情動漫'), (219, '日本-無碼流出'), (331, '劇情介紹'), (7, '3D動漫'), (336, '日本精品'), (193, 'HEY誘惑'), (200, '動漫-黃漫'), (308, '華語AV'), (203, '日本-一本道'), (433, '歐美勁爆'), (207, '傳媒-麻豆傳媒'), (67, '日本女優'), (402, '日本動漫'), (73, '有碼精品'), (199, '動漫-里番中字'), (111, '歐美無碼'), (489, '韓國三級')],
}

_LK = threading.Lock()
_PC = {}
_OP = None


def _opener():
    global _OP
    if _OP is None:
        _OP = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    return _OP


def _clean(s):
    s = re.sub(r'<[^>]+>', '', s or '')
    return html.unescape(s).replace('\u3000', ' ').strip()


def _sec(t):
    m = re.match(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', str(t or ''))
    if not m:
        return 0
    h, mi, se = [int(x or 0) for x in m.groups()]
    return h * 3600 + mi * 60 + se


class Spider(BaseSpider):
    def __init__(self):
        self.cache = {}
        self.referer = CONFIG['host'] + '/'

    def init(self, extend=''):
        self.cache = {}
        return {}

    def getName(self):
        return '久久'

    def _raw(self, url, ref=None, data=None, timeout=20):
        h = {'User-Agent': CONFIG['ua'], 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Referer': ref or self.referer}
        if data is not None:
            h['Content-Type'] = 'application/x-www-form-urlencoded'
            if isinstance(data, dict):
                data = urllib.parse.urlencode(data).encode()
        req = urllib.request.Request(url, data=data, headers=h)
        try:
            with _opener().open(req, timeout=timeout) as r:
                b = r.read()
                if r.headers.get('Content-Encoding') == 'gzip':
                    b = gzip.decompress(b)
                return r.getcode(), b.decode('utf-8', 'ignore')
        except urllib.error.HTTPError as e:
            try:
                b = e.read()
                if e.headers.get('Content-Encoding') == 'gzip':
                    b = gzip.decompress(b)
                return e.code, b.decode('utf-8', 'ignore')
            except Exception:
                return e.code, ''
        except Exception:
            return 0, ''

    def _pow(self, url, ref=None, timeout=20):
        st, t = self._raw(url, ref=ref, timeout=timeout)
        for _ in range(3):
            if st != 492:
                return st, t
            m = re.search(r'__cdnlah_pow_config"[^>]*>(\{.*?\})</script>', t, re.S)
            if not m:
                return st, t
            try:
                cfg = json.loads(m.group(1))
                seed = cfg['seed']
                dif = int(cfg['difficulty'])
                pre = '0' * dif
                n = 0
                while True:
                    ns = format(n, '016x')
                    if hashlib.sha256((seed + ns).encode()).hexdigest()[:dif] == pre:
                        break
                    n += 1
                form = {'seed': seed, 'nonce': ns, 'redirect': cfg.get('redirect', '/'), 'challenge_cookie': cfg.get('challenge_cookie', '')}
                form[cfg.get('metadata_field', 'challenge_metadata')] = cfg.get('metadata_token', '')
                with _LK:
                    self._raw(CONFIG['host'] + cfg.get('verify_path', '/__cdnlah/pow/verify'), ref=url, data=form)
            except Exception:
                return st, t
            st, t = self._raw(url, ref=ref, timeout=timeout)
        return st, t

    def _req(self, url, ref=None, timeout=20):
        for _ in range(2):
            st, t = self._pow(url, ref, timeout)
            if st == 200 and t:
                return t
        return ''

    def _pages(self, t):
        if 'page-item next' not in t:
            return 1
        if re.search(r'page-item next\s+disabled', t) or re.search(r'class="page-item next disabled"', t):
            return 0
        return 2

    def _cards(self, t):
        out = []
        seen = set()
        for p in re.split(r'<div class="col-[^"]*\bitem\b[^"]*">', t)[1:]:
            m = re.search(r'href="/(\d+)"', p)
            if not m:
                continue
            vid = m.group(1)
            if vid in seen:
                continue
            im = re.search(r'<img[^>]*src="([^"]+)"', p)
            pic = (im.group(1) if im else '').strip()
            if pic.startswith('data:'):
                im2 = re.search(r'data-src="([^"]+)"', p)
                pic = im2.group(1) if im2 else ''
            tm = re.search(r"<div class='lines lines3'>\s*<a[^>]*>(.*?)</a>", p, re.S)
            name = _clean(tm.group(1)) if tm else ''
            if not name:
                am = re.search(r'alt="([^"]*)"', p)
                name = _clean(am.group(1)) if am else ''
            if not name:
                continue
            bm = re.search(r'badge badge-success">([^<]*)<', p)
            cat = _clean(bm.group(1)) if bm else ''
            seen.add(vid)
            out.append({'vod_id': 'v:' + vid, 'vod_name': name.replace('$', '＄'), 'vod_pic': pic, 'vod_remarks': cat, 'vod_tag': ('HD' if '高清' in cat else ''), 'style': {'type': CONFIG['card_type'], 'ratio': CONFIG['card_ratio']}, 'land': CONFIG['card_land'], 'ratio': CONFIG['card_ratio'], 'type_name': cat or '久久'})
        return out

    def _base(self, tid, pg):
        tid = str(tid or '').strip()
        sort = ''
        if '|' in tid:
            tid, sort = tid.split('|', 1)
        if tid.startswith('c:'):
            u = CONFIG['host'] + '/c/' + tid[2:]
        elif tid.startswith('top:'):
            u = CONFIG['host'] + '/' + ('?sort=hits' if tid[3:] == 'hit' else '')
        else:
            u = CONFIG['host'] + '/'
            sort = 'hit'
        if sort in ('hit', 'hits') and 'sort=' not in u:
            u = u + ('&' if '?' in u else '?') + 'sort=hits'
        return u + ('&' if '?' in u else '?') + 'page=%d' % pg

    def homeContent(self, filter=False):
        c = self.cache.get('hc')
        if c and time.time() - c[0] < 1800:
            return c[1]
        classes = [{'type_id': 'top:' + k, 'type_name': n} for k, n in CONFIG['tops']]
        classes += [{'type_id': 'g:%d' % i, 'type_name': g[0], 'vod_tag': 'folder'} for i, g in enumerate(CONFIG['groups'])]
        fl = {}
        for k, n in CONFIG['tops']:
            t0 = 'top:' + k
            fl[t0] = [{'key': 'filter', 'name': '排序', 'value': [{'n': '最新', 'v': t0}, {'n': '热播', 'v': t0 + '|hit'}]}]
        for i, n in CONFIG['cats']:
            t0 = 'c:%d' % i
            fl[t0] = [{'key': 'filter', 'name': '排序', 'value': [{'n': '最新', 'v': t0}, {'n': '热播', 'v': t0 + '|hit'}]}]
        out = {'class': classes, 'filters': fl}
        self.cache['hc'] = (time.time(), out)
        return out

    def homeVideoContent(self):
        c = self.cache.get('hv')
        if c and time.time() - c[0] < 600:
            return c[1]
        t = self._req(CONFIG['host'] + '/')
        out = {'list': self._cards(t)}
        self.cache['hv'] = (time.time(), out)
        return out

    def _first_pic(self, tid):
        c = self.cache.get('fc:' + tid) or _PC.get(tid)
        if c and time.time() - c[0] < 1800:
            return c[1]
        pic = ''
        try:
            t = self._req(self._base(tid, 1), timeout=6)
            for it in self._cards(t)[:8]:
                p = it.get('vod_pic') or ''
                if p.startswith('http') and ('/upload/' in p or 'http' in p):
                    pic = p
                    break
        except Exception:
            pic = ''
        _PC[tid] = self.cache['fc:' + tid] = (time.time(), pic)
        return pic

    def _folder(self, tid):
        items = []
        cm = dict(CONFIG['cats'])
        if tid.startswith('g:'):
            try:
                gi = int(tid[2:])
                src = [('c:%d' % i, cm.get(i, str(i))) for i in CONFIG['groups'][gi][1]]
            except Exception:
                src = []
        else:
            src = []

        def one(x):
            k = x[0]
            if k.startswith('g:'):
                try:
                    k = 'c:%d' % CONFIG['groups'][int(k[2:])][1][0]
                except Exception:
                    pass
            return {'vod_id': x[0], 'vod_name': x[1], 'vod_pic': self._first_pic(k), 'vod_remarks': '', 'vod_tag': 'folder'}

        try:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(6) as ex:
                items = list(ex.map(one, src))
        except Exception:
            items = [one(x) for x in src]
        return {'class': [], 'list': items, 'page': 1, 'pagecount': 1, 'limit': len(items), 'total': len(items)}

    def categoryContent(self, tid, pg, filter, extend):
        tid = str(tid or '').strip() or 'top:new'
        if tid.startswith('g:'):
            return self._folder(tid)
        if not (tid.startswith('c:') or tid.startswith('top:')):
            return {'class': [], 'list': [], 'page': 1, 'pagecount': 1, 'limit': 0, 'total': 0}
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        if pg > CONFIG['max_pg']:
            return {'list': [], 'page': pg, 'pagecount': pg, 'limit': CONFIG['page_size'], 'total': 0}
        if isinstance(extend, dict):
            f = extend.get('filter') or extend.get('sort')
            if f and isinstance(f, str):
                tid = f
        c = self.cache.get('c:%s:%d' % (tid, pg))
        if c and time.time() - c[0] < 600:
            return c[1]
        t = self._req(self._base(tid, pg))
        items = self._cards(t)
        nx = self._pages(t)
        pc = pg + 1 if (items and nx == 2) else pg
        out = {'list': items, 'page': pg, 'pagecount': pc, 'limit': CONFIG['page_size'], 'total': pc * CONFIG['page_size']}
        self.cache['c:%s:%d' % (tid, pg)] = (time.time(), out)
        return out

    def searchContent(self, key, quick=False, pg='1'):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key or '').strip())
        t = self._req(CONFIG['host'] + '/q/%s?page=%d' % (kw, pg), ref=CONFIG['host'] + '/node/search')
        items = self._cards(t)
        if not items and pg == 1:
            t2 = self._req(CONFIG['host'] + '/node/search?title=' + kw, ref=CONFIG['host'] + '/node/search')
            items = self._cards(t2)
        nx = self._pages(t)
        pc = pg + 1 if (items and nx == 2) else pg
        return {'list': items, 'page': pg, 'pagecount': pc, 'limit': CONFIG['page_size'], 'total': pc * CONFIG['page_size']}

    def detailContent(self, ids):
        vid = str(ids[0] if isinstance(ids, list) and ids else ids or '')
        if vid.startswith('folder:') or vid.startswith('g:'):
            return {'list': []}
        if vid.startswith('v:'):
            vid = vid[2:]
        if not vid.isdigit():
            return {'list': []}
        c = self.cache.get('d:' + vid)
        if c and time.time() - c[0] < 600:
            return c[1]
        t = self._req(CONFIG['host'] + '/' + vid)
        if not t:
            return {'list': []}
        name = ''
        pic = ''
        dur = 0
        year = ''
        area = ''
        vm = re.search(r'<script type=.application/ld\+json.>(.*?)</script>', t, re.S)
        if vm:
            try:
                d = json.loads(vm.group(1))
                name = d.get('name') or ''
                pic = d.get('thumbnailUrl') or ''
                dur = _sec(d.get('duration'))
                year = str(d.get('uploadDate') or '')[:4]
            except Exception:
                pass
        if not name:
            h1 = re.search(r'<h1[^>]*>(.*?)</h1>', t, re.S)
            name = _clean(h1.group(1)) if h1 else vid
        if not pic:
            im = re.search(r'property="og:image"\s+content="([^"]+)"', t) or re.search(r'content="([^"]+)"\s+property="og:image"', t)
            pic = im.group(1) if im else ''
        bc = re.search(r'href="(/c/\d+)"[^>]*>(.*?)</a>', t, re.S)
        if bc:
            area = _clean(bc.group(2))
        lines = []
        seen = set()
        for m in re.finditer(r'href="/' + vid + r'\?source_id=(\d+)"[^>]*?(?:title="([^"]*)")?[^>]*>([^<]*)<', t):
            sid = m.group(1)
            nm = _clean(m.group(3)) or _clean(m.group(2) or '') or ('线路' + sid)
            if sid in seen:
                continue
            seen.add(sid)
            lines.append((nm, sid))
        if not lines:
            sm = re.search(r'<source src="([^"]+)"', t)
            if sm:
                d2 = {'name': name, 'pic': pic, 'dur': dur, 'sources': [{'label': '默认', 'file': sm.group(1)}]}
                self.cache['d:' + vid] = (time.time(), d2)
                return {'list': [{'vod_id': 'v:' + vid, 'vod_name': name.replace('$', '＄'), 'vod_pic': pic, 'type_name': area or '久久', 'vod_year': year, 'vod_area': area, 'vod_remarks': '单线', 'vod_play_from': '默认', 'vod_play_url': '正片$' + vid + '|0', 'vod_content': name}]}
        froms = '$$$'.join([x[0] for x in lines])
        urls = '$$$'.join(['正片$' + vid + '|' + x[1] for x in lines])
        rem = ('%d分钟' % (dur // 60)) if dur else '多线'
        item = {'vod_id': 'v:' + vid, 'vod_name': name.replace('$', '＄'), 'vod_pic': pic, 'type_name': area or '久久', 'vod_year': year, 'vod_area': area, 'vod_remarks': rem, 'vod_play_from': froms, 'vod_play_url': urls, 'vod_content': name}
        out = {'list': [item]}
        self.cache['d:' + vid] = (time.time(), out)
        return out

    def playerContent(self, flag, id, vipFlags):
        rid = str(id or '').strip()
        if rid.startswith('v:'):
            rid = rid[2:]
        vid, sid = (rid.split('|', 1) + ['0'])[:2] if '|' in rid else (rid, '0')
        pk = 'p:%s:%s' % (vid, sid)
        c = self.cache.get(pk)
        if c and time.time() - c[0] < 300:
            return c[1]
        u = CONFIG['host'] + '/' + vid + ('' if sid in ('', '0') else '?source_id=' + sid)
        t = self._req(u, ref=CONFIG['host'] + '/' + vid)
        m = re.search(r'<source src="([^"]+)"', t)
        if not m:
            m = re.search(r'"contentUrl"\s*:\s*"([^"]+)"', t)
        url = ''
        if m:
            url = m.group(1).replace('\\/', '/')
        if not url:
            return {'parse': 0, 'url': '', 'header': {'User-Agent': CONFIG['ua']}}
        out = {'parse': 0, 'url': url, 'header': {'User-Agent': CONFIG['ua'], 'Referer': CONFIG['host'] + '/'}}
        self.cache[pk] = (time.time(), out)
        return out

    def isVideoFormat(self, url):
        return '.m3u8' in str(url or '') or '.mp4' in str(url or '')

    def manualVideoCheck(self):
        return False

    def destroy(self):
        self.cache = {}
        return True
