# LumeSource: {"id":"pypack_2046cc0308d1abbe","name":"重口味影院-TVBox爬虫","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding=utf-8
import base64
import gzip
import json
import re
import ssl
import time
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

try:
    from base.spider import Spider as _Spider
except Exception:
    class _Spider(object):
        pass

UA = ('Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Mobile Safari/537.36')
DEF_HOST = 'https://poopeegirls.com'
_PXY_B64 = 'aHR0cHM6Ly84OTc0NTYyMTIzLjg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4LmNjd3UuY2MvP3VybD0='
DEF_PROXY = base64.b64decode(_PXY_B64).decode('utf-8')
PAGE_SIZE = 60
THROTTLE = 0.4
TIMEOUT = 25

CATS = [
    ('c-1', 'Pooping Girls'),
    ('c-2', 'Hidden Camera In The Toilet'),
    ('c-3', 'Girls Pooping In The Mouth'),
    ('c-4', 'Sex With Shitting Girl'),
    ('c-5', 'Pissing Girls'),
    ('c-6', 'Girls Farts'),
    ('c-7', 'Panty Poop'),
]

TAGS = [
    ('t-1', 'amateur'), ('t-2', 'japanese scat'), ('t-3', 'shit in mouth'),
    ('t-4', 'piss in mouth'), ('t-5', 'brazilian scat'), ('t-6', 'diarrhea'),
    ('t-7', 'compilation'), ('t-8', 'lesbian scat'), ('t-9', 'cute girl'),
    ('t-10', 'pooping girl'), ('t-11', 'pissing girl'), ('t-12', 'teen girl'),
    ('t-13', 'farting girl'), ('t-14', 'enema'), ('t-15', 'big ass'),
    ('t-16', 'big tits'), ('t-17', 'hidden camera'), ('t-18', 'russian'),
    ('t-19', 'eating shit'), ('t-20', 'dildo'), ('t-21', 'close-up'),
    ('t-22', 'college girl'), ('t-23', 'bathroom'), ('t-24', 'shower'),
    ('t-25', 'mature'), ('t-26', 'pissing on the street'),
    ('t-27', 'panty poop'), ('t-28', 'femdom'), ('t-29', 'ebony girl'),
    ('t-30', 'huge poop'), ('t-31', 'webcam'), ('t-32', 'human toilet'),
    ('t-33', 'smeared shit'), ('t-34', 'scat porn'), ('t-35', 'orgy'),
    ('t-36', 'stockings'), ('t-37', 'facesitting'), ('t-38', 'dirty anal sex'),
    ('t-39', 'pov'), ('t-40', 'pooping on the street'),
    ('t-41', 'asian'), ('t-42', 'piss in the public toilet'),
    ('t-43', 'piss in the parking'), ('t-44', 'piss on the nature'),
    ('t-45', 'panty pissing'), ('t-46', 'outdoor'),
    ('t-47', 'pooping on the nature'), ('t-48', 'two girls'),
    ('t-49', 'three girls'), ('t-50', 'pooping in the public toilet'),
    ('t-51', 'pooping sex'), ('t-52', 'pooping in the toilet'),
    ('t-53', 'pooping into the sink'),
]

PICS_TID = 'pics'


class Spider(_Spider):
    def __init__(self):
        self.host = DEF_HOST
        self.proxy = DEF_PROXY
        self.jar = CookieJar()
        self.opener = self._build_opener()
        self._last_req = 0.0
        self._cache = {}

    def _build_opener(self):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(self.jar))

    def _headers(self, referer=None):
        return {'User-Agent': UA,
                'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.9',
                'Accept-Encoding': 'gzip, deflate',
                'Referer': referer or (self.host + '/')}

    def _throttle(self):
        gap = time.time() - self._last_req
        if gap < THROTTLE:
            time.sleep(THROTTLE - gap)
        self._last_req = time.time()

    def _abs(self, path):
        if path.startswith('http'):
            return path
        return self.host + ('/' + path if not path.startswith('/') else path)

    def _wrap(self, url):
        return self.proxy + urllib.parse.quote(str(url), safe='')

    def _get(self, path, referer=None, retry=2):
        url = self._abs(path)
        url = self._wrap(url)
        html = ''
        for attempt in range(retry + 1):
            self._throttle()
            try:
                h = self._headers(referer)
                req = urllib.request.Request(url, headers=h)
                with self.opener.open(req, timeout=TIMEOUT) as resp:
                    raw = resp.read()
                    if resp.headers.get('Content-Encoding') == 'gzip':
                        raw = gzip.decompress(raw)
                    html = raw.decode('utf-8', 'ignore')
                if html:
                    return html
            except Exception:
                html = ''
            if attempt < retry:
                time.sleep(0.6 + attempt)
        return html

    @staticmethod
    def _raw(url):
        u = str(url or '').strip()
        if not u:
            return ''
        m = re.match(r'^https?://[^/?]+\.[^/?]+/\?url=(.+)$', u)
        if m:
            try:
                return urllib.parse.unquote(m.group(1))
            except Exception:
                return u
        return u

    def _pic(self, url):
        u = self._raw(url)
        u = self._abs(u)
        if not u:
            return ''
        if self.proxy and not u.startswith(self.proxy):
            u = self._wrap(u)
        return u

    def _play(self, url):
        u = self._raw(url)
        if not u or not u.startswith('http'):
            return ''
        if self.proxy and not u.startswith(self.proxy):
            u = self._wrap(u)
        return u

    def _parse_cards(self, html):
        out = []
        if not html:
            return out
        chunks = html.split("<div class='thumb'>")
        seen = set()
        for ch in chunks[1:]:
            m = re.search(r"href='(/v-(\d+)-[^']+)'", ch)
            if not m:
                m = re.search(r'href="(/v-(\d+)-[^"]+)"', ch)
            if not m:
                continue
            vod_id = m.group(1)
            vid_num = m.group(2)
            if vod_id in seen:
                continue
            seen.add(vod_id)
            title = ''
            tm = re.search(r"title='([^']*)'", ch)
            if not tm:
                tm = re.search(r'title="([^"]*)"', ch)
            if tm:
                title = tm.group(1).strip()
            if not title:
                tm2 = re.search(r"<div class='thumb_title'>([^<]*)</div>", ch)
                if tm2:
                    title = tm2.group(1).strip()
            pic = ''
            pm = re.search(r"data-src='([^']+)'", ch)
            if not pm:
                pm = re.search(r'data-src="([^"]+)"', ch)
            if pm:
                pic = self._pic(pm.group(1))
            out.append({'vod_id': vod_id, 'vod_name': title or ('视频 ' + vid_num),
                        'vod_pic': pic,
                        'vod_remarks': '视频 ' + vid_num})
        return out

    @staticmethod
    def _pagecount(html, pg):
        if not html:
            return pg
        nums = []
        for m in re.finditer(r"<div class=['\"]paginator['\"][^>]*>\s*<a\s+href=['\"][^'\"]+['\"][^>]*>\s*(\d{1,4})\s*</a>", html):
            n = int(m.group(1))
            if n > 0:
                nums.append(n)
        if nums:
            return max(max(nums), pg)
        return pg + 1

    def _categories(self):
        return list(CATS)

    def _tags(self):
        return list(TAGS)

    def _types(self):
        out = [('home', '首页最新')]
        out += self._categories()
        out += self._tags()
        out += [(PICS_TID, '图片集')]
        return out

    def _list_path(self, tid, pg=1):
        tid = str(tid or '').strip()
        if tid == 'home':
            return '/' if pg <= 1 else '/page-%d' % pg
        if tid == PICS_TID:
            return '/piclist'
        if tid.startswith('c-'):
            slug = ''
            for cid, name in self._categories():
                if cid == tid:
                    slug = name.lower().replace(' ', '-')
                    break
            if not slug:
                slug = 'category'
            return ('/c-%s-%s' % (tid[2:], slug)) if pg <= 1 else \
                   ('/c-%s-%d-%s' % (tid[2:], pg, slug))
        if tid.startswith('t-'):
            slug = ''
            for tidx, name in self._tags():
                if tidx == tid:
                    slug = name.lower().replace(' ', '-')
                    break
            if not slug:
                slug = 'tag'
            return ('/t-%s-%s' % (tid[2:], slug)) if pg <= 1 else \
                   ('/t-%s-%d-%s' % (tid[2:], pg, slug))
        return '/'

    def _search_path(self, kw, pg=1):
        enc = urllib.parse.quote(kw, safe='')
        return '/search/?q=%s' % enc if pg <= 1 else \
               '/search/%d/?q=%s' % (pg, enc)

    def _filters(self):
        filters = {}
        tag_vals = [{'n': '全部', 'v': ''}] + [{'n': n, 'v': t} for t, n in self._tags()]
        for cid, _ in self._categories():
            filters[cid] = [{'key': 'tag', 'name': '子分类（标签）', 'value': tag_vals}]
        for tid, _ in self._types():
            if tid not in filters:
                filters[tid] = []
        return filters

    @staticmethod
    def _ext_values(extend):
        try:
            ext = json.loads(extend) if extend and str(extend).strip() else {}
            if not isinstance(ext, dict):
                ext = {}
        except Exception:
            ext = {}
        return str(ext.get('tag') or '').strip()

    def init(self, extend=""):
        try:
            cfg = json.loads(extend) if extend and str(extend).strip() else {}
            if not isinstance(cfg, dict):
                cfg = {}
        except Exception:
            cfg = {}
        host = str(cfg.get('host', '')).strip().rstrip('/')
        if host:
            if not host.startswith('http'):
                host = 'https://' + host
            self.host = host
        proxy = str(cfg.get('proxy', '')).strip()
        if proxy:
            if not proxy.endswith('?url=') and '?url=' not in proxy:
                proxy = proxy.rstrip('/') + '/?url='
            self.proxy = proxy

    def getName(self):
        return "重口味影院"

    def homeContent(self, filter):
        cls = [{'type_id': tid, 'type_name': name} for tid, name in self._types()]
        return {'class': cls, 'filters': self._filters()}

    def homeVideoContent(self):
        html = self._get('/')
        lst = self._parse_cards(html)
        return {'list': lst[:PAGE_SIZE]}

    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        tid = str(tid or '').strip()
        sub = self._ext_values(extend)
        if sub:
            tid = sub
        html = self._get(self._list_path(tid, pg))
        lst = self._parse_cards(html)
        pc = self._pagecount(html, pg)
        if pc < pg:
            pc = pg
        return {'list': lst, 'page': pg, 'pagecount': pc,
                'limit': len(lst), 'total': pc * PAGE_SIZE}

    def _detail_html(self, vod_id):
        key = 'detail_' + vod_id
        if key in self._cache:
            return self._cache[key]
        html = self._get('/' + str(vod_id).strip('/'))
        if len(self._cache) > 200:
            self._cache = {}
        self._cache[key] = html
        return html

    def detailContent(self, ids):
        vod_id = str(ids[0]).strip().strip('/') if ids else ''
        if not vod_id or not vod_id.startswith('v-'):
            return {'list': []}
        html = self._detail_html(vod_id)
        if not html:
            return {'list': []}

        title = vod_id
        tm = re.search(r'<h1>([^<]+)</h1>', html)
        if tm:
            title = tm.group(1).strip()
        if not title or title == vod_id:
            tm = re.search(r'<title>([^<]+)</title>', html)
            if tm:
                title = tm.group(1).strip()

        pic = ''
        pm = re.search(r"property=['\"]og:thumbnailUrl['\"]\s*content=['\"]([^'\"]+)['\"]", html)
        if not pm:
            pm = re.search(r"itemprop=['\"]thumbnailUrl['\"]\s*content=['\"]([^'\"]+)['\"]", html)
        if not pm:
            pm = re.search(r"property=['\"]og:image['\"]\s*content=['\"]([^'\"]+)['\"]", html)
        if pm:
            pic = self._pic(pm.group(1))

        play = ''
        sm = re.search(r"<source\s+src=['\"]([^'\"]+)['\"]\s*type=['\"]video/[^'\"]+['\"]", html)
        if not sm:
            sm = re.search(r"<source\s+type=['\"]video/[^'\"]+['\"]\s+src=['\"]([^'\"]+)['\"]", html)
        if not sm:
            sm = re.search(r"<video[^>]*>[\s\S]*?<source[^>]*src=['\"]([^'\"]+)['\"]", html)
        if sm:
            play = self._play(sm.group(1))

        tags = []
        tm2 = re.search(r"<div id=['\"]post_tags['\"][\s\S]*?</div>", html)
        scope = tm2.group(0) if tm2 else html
        for m in re.finditer(r"<a[^>]+class=['\"]tag['\"][^>]*>([^<]+)</a>", scope):
            n = m.group(1).strip()
            if n and n not in tags:
                tags.append(n)

        added = dur = ''
        tm3 = re.search(r"<div class=['\"]top_text['\"][^>]*>([\s\S]*?)</div>", html)
        if tm3:
            seg = tm3.group(1)
            a = re.search(r'Added:\s*<span[^>]*>([^<]+)</span>', seg)
            if a:
                added = a.group(1).strip()
            d = re.search(r'Duration:\s*<span[^>]*>([^<]+)</span>', seg)
            if d:
                dur = d.group(1).strip()
            if not added:
                a2 = re.search(r'Added:\s*([\d\.]+)', seg)
                if a2:
                    added = a2.group(1).strip()
            if not dur:
                d2 = re.search(r'Duration:\s*(\d+:\d+)', seg)
                if d2:
                    dur = d2.group(1).strip()

        bits = []
        if tags:
            bits.append('标签：' + '、'.join(tags))
        meta = []
        if added:
            meta.append('发布 %s' % added)
        if dur:
            meta.append('时长 %s' % dur)
        if meta:
            bits.append(' · '.join(meta))

        vod = {
            'vod_id': vod_id,
            'vod_name': title,
            'vod_pic': pic,
            'vod_year': '',
            'vod_area': '',
            'vod_actor': '、'.join(tags),
            'vod_director': '',
            'vod_content': '\n'.join(bits),
            'vod_remarks': dur or added or '',
            'vod_play_from': '直链',
            'vod_play_url': '正片$%s' % (play or vod_id),
        }
        return {'list': [vod]}

    def playerContent(self, flag, id, vipFlags):
        header = {'User-Agent': UA, 'Referer': self.host + '/'}
        raw = str(id or '').strip().strip('/')
        if raw.startswith('http'):
            u = self._play(raw)
            if not u:
                u = raw
            return {'parse': 0, 'playUrl': '', 'url': u, 'header': header}
        if raw.startswith('v-'):
            html = self._detail_html(raw)
            if html:
                sm = re.search(r"<source\s+src=['\"]([^'\"]+)['\"]\s*type=['\"]video/[^'\"]+['\"]", html)
                if not sm:
                    sm = re.search(r"<source\s+type=['\"]video/[^'\"]+['\"]\s+src=['\"]([^'\"]+)['\"]", html)
                if not sm:
                    sm = re.search(r"<video[^>]*>[\s\S]*?<source[^>]*src=['\"]([^'\"]+)['\"]", html)
                if sm:
                    u = self._play(sm.group(1))
                    if u:
                        return {'parse': 0, 'playUrl': '', 'url': u, 'header': header}
        return {'parse': 1, 'playUrl': '', 'url': raw, 'header': header}

    def searchContent(self, key, quick, pg="1"):
        kw = str(key or '').strip()
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        if not kw:
            return {'list': [], 'page': pg, 'pagecount': pg, 'limit': 0, 'total': 0}
        html = self._get(self._search_path(kw, pg))
        lst = self._parse_cards(html)
        pc = self._pagecount(html, pg)
        if pc < pg:
            pc = pg
        return {'list': lst, 'page': pg, 'pagecount': pc,
                'limit': len(lst), 'total': pc * PAGE_SIZE}

    def searchContentPage(self, key, quick, pg):
        return self.searchContent(key, quick, pg)

    def action(self, action):
        return None

    def liveContent(self):
        return {}

    def localProxy(self, params):
        try:
            if (params or {}).get('type') == 'pic':
                url = self._raw(str(params.get('url') or ''))
                if url.startswith('http'):
                    req = urllib.request.Request(self._wrap(url), headers={
                        'User-Agent': UA, 'Referer': self.host + '/'})
                    with self.opener.open(req, timeout=20) as resp:
                        raw = resp.read()
                    mime = 'image/jpeg'
                    if raw[:8] == b'\x89PNG\r\n\x1a\n':
                        mime = 'image/png'
                    elif raw[:4] == b'RIFF' and raw[8:12] == b'WEBP':
                        mime = 'image/webp'
                    elif raw[:3] == b'GIF':
                        mime = 'image/gif'
                    return [200, mime, raw]
        except Exception:
            pass
        return [200, "text/plain;charset=utf-8", b""]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or '.m3u8?' in u or u.endswith('.mp4') \
            or '.mp4?' in u or u.endswith('.flv')

    def manualVideoCheck(self):
        return False

    def destroy(self):
        self._cache = {}


if __name__ == "__main__":
    sp = Spider()
    sp.init('{}')
    ok = True

    def check(name, cond, extra=""):
        global ok
        print(("PASS " if cond else "FAIL ") + name +
              (("  -> " + str(extra)[:90]) if extra else ""))
        if not cond:
            ok = False

    types = sp._types()
    check("分类：62 个 type_id", len(types) == 62, "got %d" % len(types))
    hc = sp.homeContent(1)
    check("homeContent: class 62 + filters 齐",
          len(hc.get('class') or []) == 62 and len(hc.get('filters') or {}) == 62,
          "class=%d filters=%d" % (len(hc.get('class') or []),
                                   len(hc.get('filters') or {})))
    f_c1 = (hc.get('filters') or {}).get('c-1', [])
    tag_flt = [f for f in f_c1 if f.get('key') == 'tag']
    check("父分类筛选器：c-1 挂 53 项标签子分类",
          bool(tag_flt) and len(tag_flt[0].get('value') or []) == 54,
          "tag options=%d" % (len(tag_flt[0].get('value') or []) if tag_flt else 0))

    hv = sp.homeVideoContent()
    check("首页：有片且字段齐全",
          len(hv.get('list') or []) > 0
          and all(v.get('vod_id') and v.get('vod_name') for v in (hv.get('list') or [])[:10]),
          "n=%d" % len(hv.get('list') or []))

    cc = sp.categoryContent('c-1', '1', '', '')
    cc2 = sp.categoryContent('c-1', '2', '', '')
    ids1 = set(v['vod_id'] for v in cc.get('list') or [])
    ids2 = set(v['vod_id'] for v in cc2.get('list') or [])
    check("分类：第 1 页有片",
          len(cc.get('list') or []) > 0,
          "n=%d pagecount=%s" % (len(cc.get('list') or []), cc.get('pagecount')))
    check("分页：第 2 页与第 1 页不重复",
          len(ids1 & ids2) == 0 and len(ids2) > 0,
          "p1=%d p2=%d overlap=%d" % (len(ids1), len(ids2), len(ids1 & ids2)))

    cfs = sp.categoryContent('c-1', '1', '', '{"tag":"t-9"}')
    check("筛选·子分类：父分类下选标签 t-9",
          len(cfs.get('list') or []) > 0,
          "n=%d" % (len(cfs.get('list') or [])))

    vid = (cc.get('list') or [{}])[0].get('vod_id')
    dc = sp.detailContent([vid])
    vod = (dc.get('list') or [{}])[0]
    check("详情：标题/封面",
          bool(vod.get('vod_name')) and bool(vod.get('vod_pic')),
          "%s | pic=%s" % (vod.get('vod_name'), (vod.get('vod_pic') or '')[:50]))
    check("详情：播放直链 mp4",
          '.mp4' in (vod.get('vod_play_url') or ''),
          (vod.get('vod_play_url') or '')[:70])

    pc = sp.playerContent('直链', (vod.get('vod_play_url') or '').split('$')[-1], [])
    u = pc.get('url') or ''
    check("播放：parse=0 且 mp4 直链",
          pc.get('parse') == 0 and '.mp4' in u, u[:90])
    check("播放：URL 已代理包装（壳端可直连）",
          u.startswith(sp.proxy), u[:100])
    mp4_ok = False
    if u:
        try:
            req = urllib.request.Request(u, headers={'User-Agent': UA, 'Range': 'bytes=0-127'})
            with sp.opener.open(req, timeout=25) as resp:
                body = resp.read(128)
            mp4_ok = resp.status in (200, 206) and body[4:8] == b'ftyp'
        except Exception as e:
            print('   (mp4 fetch: %s)' % str(e)[:80])
    check("播放：代理 URL 实际可拉（Range ftyp）", mp4_ok, u[:70])

    sc = sp.searchContent('pooping', False, '1')
    check("搜索：有结果",
          len(sc.get('list') or []) > 0,
          "n=%d" % len(sc.get('list') or []))
    sc0 = sp.searchContent('zzzzqqq不存在的关键词', False, '1')
    check("搜索：无结果时返回空列表", sc0.get('list') == [])

    pic = vod.get('vod_pic') or ''
    check("封面：vod_pic 已代理包装", pic.startswith(sp.proxy), pic[:80])
    if pic:
        try:
            req = urllib.request.Request(pic, headers={
                'User-Agent': UA, 'Referer': sp.host + '/'})
            with sp.opener.open(req, timeout=20) as resp:
                check("封面：代理可达", resp.status == 200 and len(resp.read()) > 500,
                      pic[:60])
        except Exception as e:
            check("封面：代理可达", False, str(e)[:80])
    hp = (hv.get('list') or [{}])[0].get('vod_pic') or ''
    check("封面：列表卡片 vod_pic 已代理包装", hp.startswith(sp.proxy), hp[:80])

    ct = sp.categoryContent('t-9', '1', '', '')
    check("标签：t-9 cute girl 可浏览", len(ct.get('list') or []) > 0,
          "n=%d" % len(ct.get('list') or []))

    cbad = sp.categoryContent('c-999', '1', '', '')
    check("无效分类：接口可调不抛异常", isinstance(cbad.get('list'), list))

    print("\n==== %s ====" % ("ALL PASS" if ok else "HAS FAILURES"))
