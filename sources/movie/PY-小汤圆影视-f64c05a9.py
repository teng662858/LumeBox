# LumeSource: {"id":"pypack_b2973bccf64c05a9","name":"小汤圆影视","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import re
import sys
import json
import time
import base64
import urllib.parse

import requests

try:
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
except Exception:
    pass

sys.path.append('..')
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider(object):
        def fetch(self, url, headers=None, timeout=20, verify=False, cookies=None):
            s = requests.Session()
            s.trust_env = False
            return s.get(url, headers=headers, timeout=timeout, verify=verify, cookies=cookies)

        def post(self, url, headers=None, data=None, timeout=20, verify=False, cookies=None):
            s = requests.Session()
            s.trust_env = False
            return s.post(url, headers=headers, timeout=timeout, verify=verify, cookies=cookies)


_LN = base64.b64decode('54G16aOO5LiT57q/').decode('utf-8')
_CP = base64.b64decode('4piG54G16aOO5Ye65ZOBICDlv4XlsZ7nsr7lk4HimIblsI/mkrjmgKHmg4UgIOWkp+aSuOS8pOi6q+KYhg==').decode('utf-8')


class Spider(BaseSpider):
    name = '小汤圆视频'
    host = 'https://mmajj.icu'

    UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')

    CATEGORIES = [
        ('1', '国产'), ('2', '日韩'), ('3', '欧美'), ('4', '动漫'),
        ('8', '中文字幕'), ('9', '高清无码'), ('10', '吃瓜黑料'),
        ('11', '酒店探花'), ('12', '网红主播'), ('13', '网络传媒'),
        ('14', '欧美精品'), ('15', '成人动漫'), ('16', '日韩精品'),
        ('17', 'AV明星'), ('18', 'AV解说'), ('19', '伦理影片'),
        ('20', '自拍偷拍'), ('21', '反差母狗'), ('22', '熟女少妇'),
        ('23', '乱伦强奸'),
    ]

    def init(self, extend=''):
        self._session = None
        self._last = {}
        return {}

    def getName(self):
        return self.name

    def isVideoFormat(self, url):
        low = (url or '').lower()
        return any(k in low for k in ('.m3u8', '.mp4', '.flv', '.mkv', '.avi', '.ts'))

    def manualVideoCheck(self):
        return False

    def destroy(self):
        try:
            if self._session:
                self._session.close()
        except Exception:
            pass

    def localProxy(self, param):
        return [200, 'text/plain', '']

    def _log(self, msg):
        try:
            print('[%s] %s' % (self.name, msg))
        except Exception:
            pass

    def _headers(self, referer=None):
        return {
            'User-Agent': self.UA,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'Accept-Encoding': 'gzip, deflate',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
            'Referer': referer or (self.host + '/'),
        }

    def _sess(self):
        if getattr(self, '_session', None) is None:
            s = requests.Session()
            s.trust_env = False
            self._session = s
        return self._session

    def _throttle(self, key, gap=0.5):
        now = time.time()
        if not hasattr(self, '_last') or not isinstance(self._last, dict):
            self._last = {}
        last = self._last.get(key, 0)
        wait = gap - (now - last)
        if wait > 0:
            time.sleep(wait)
        self._last[key] = time.time()

    def _get(self, url, referer=None, retries=4, timeout=20):
        last = ''
        for i in range(retries):
            try:
                r = self._sess().get(url, headers=self._headers(referer),
                                     timeout=timeout, verify=False)
                if r.status_code == 200:
                    r.encoding = 'utf-8'
                    text = r.text or ''
                    if len(text.strip()) > 200:
                        return text
                    last = text
                else:
                    self._log('GET %d -> %d %s' % (i + 1, r.status_code, url))
            except Exception as e:
                self._log('GET fail(%d) %s %s' % (i + 1, type(e).__name__, url))
            time.sleep(1.0 + i * 0.6)
        return last

    @staticmethod
    def _strip(s):
        s = re.sub(r'<[^>]+>', '', s or '')
        s = (s.replace('&nbsp;', ' ').replace('&amp;', '&')
             .replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"'))
        return re.sub(r'\s+', ' ', s).strip()

    def _fix(self, u):
        if not u:
            return ''
        u = u.strip()
        if u.startswith('//'):
            return 'https:' + u
        if u.startswith('http'):
            return u
        if u.startswith('/'):
            return self.host + u
        return self.host + '/' + u

    def _parse_list(self, html):
        vods = []
        if not html:
            return vods
        seen = set()
        marks = [m.start() for m in re.finditer(r'<div class="xv-video-card">', html)]
        marks.append(len(html))
        for idx in range(len(marks) - 1):
            block = html[marks[idx]:marks[idx + 1]]
            m = re.search(
                r'href="(/index\.php/vod/play/id/(\d+)/sid/(\d+)/nid/(\d+)\.html)"',
                block)
            if not m:
                continue
            vid = m.group(2)
            if not vid or vid in seen:
                continue
            name = ''
            mt = re.search(r'title="([^"]*)"', block)
            if mt:
                name = self._strip(mt.group(1))
            if not name:
                mt = re.search(r'class="xv-video-title">\s*<a[^>]*>(.*?)</a>', block, re.S)
                if mt:
                    name = self._strip(mt.group(1))
            if not name:
                name = vid
            pic = ''
            mp = re.search(r'data-original="([^"]+)"', block)
            if mp and '/statics/img/' not in mp.group(1):
                pic = mp.group(1)
            if not pic:
                mp = re.search(r'<img[^>]*src="([^"]+)"', block)
                if mp and '/statics/img/' not in mp.group(1):
                    pic = mp.group(1)
            remark = ''
            mq = re.search(r'class="xv-quality">([^<]*)</span>', block)
            if mq:
                remark = self._strip(mq.group(1))
            if not remark:
                mh = re.search(r'class="xv-hits">.*?(\d+)\s*次播放', block, re.S)
                if mh:
                    remark = mh.group(1) + '次播放'
            seen.add(vid)
            vods.append({
                'vod_id': vid,
                'vod_name': name,
                'vod_pic': self._fix(pic),
                'vod_remarks': remark,
            })
        return vods

    @staticmethod
    def _parse_pagecount(html, page):
        page = int(page or 1)
        if not html:
            return page
        m = re.search(r'href="[^"]*?/page/(\d+)\.html">尾页', html)
        if m:
            return max(int(m.group(1)), page)
        return page

    def homeContent(self, filter=False):
        classes = [{'type_id': tid, 'type_name': name}
                   for tid, name in self.CATEGORIES]
        filters = {tid: [] for tid, _n in self.CATEGORIES}
        result = {'class': classes, 'filters': filters}
        try:
            self._throttle('home', 0.4)
            result['list'] = self._parse_list(self._get(self.host + '/'))
        except Exception:
            result['list'] = []
        return result

    def homeVideoContent(self):
        self._throttle('home', 0.4)
        return {'list': self._parse_list(self._get(self.host + '/'))}

    def categoryContent(self, tid, pg, filter=False, extend=''):
        try:
            page = int(pg or 1)
        except Exception:
            page = 1
        if page < 1:
            page = 1

        tid = str(tid or '').strip().strip('/')
        if not tid:
            tid = '1'

        if page > 1:
            url = '%s/index.php/vod/type/id/%s/page/%d.html' % (self.host, tid, page)
        else:
            url = '%s/index.php/vod/type/id/%s.html' % (self.host, tid)

        self._throttle('cat', 0.5)
        html = self._get(url)
        vods = self._parse_list(html)
        pagecount = self._parse_pagecount(html, page)
        if not vods and page > 1:
            pagecount = page

        return {
            'list': vods,
            'page': page,
            'pagecount': pagecount,
            'limit': len(vods) or 28,
            'total': (pagecount * 28) if pagecount else len(vods),
        }

    @staticmethod
    def _extract_player(html):
        i = html.find('var player_aaaa')
        if i < 0:
            return None
        j = html.find('{', i)
        if j < 0:
            return None
        depth = 0
        end = -1
        for k in range(j, len(html)):
            c = html[k]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    end = k
                    break
        if end < 0:
            return None
        try:
            return json.loads(html[j:end + 1])
        except Exception:
            return None

    @staticmethod
    def _derive_pic(play_url):
        u = (play_url or '').replace('\\/', '/')
        m = re.match(r'(https?://)([^/]+)(/.*/)index\.m3u8', u)
        if not m:
            return ''
        scheme, host, path = m.group(1), m.group(2), m.group(3)
        hm = re.match(r'^(\d+)\.xbv\d+\.com$', host)
        if hm:
            host = '%s.xbpi%s.top' % (hm.group(1), hm.group(1))
        return scheme + host + path + '1.jpg'

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, (list, tuple)) and ids else str(ids or '')
        vid = str(vid).strip().strip('/')
        if '-' in vid:
            vid = vid.split('-')[0]
        if not vid:
            return {'list': []}

        url = '%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (self.host, vid)
        self._throttle('detail', 0.4)
        html = self._get(url)
        if not html:
            return {'list': [{'vod_id': vid, 'vod_name': vid, 'vod_pic': '',
                              'vod_play_from': _LN, 'vod_play_url': ''}]}

        cfg = self._extract_player(html) or {}
        vdata = cfg.get('vod_data') or {}

        name = ''
        mh = re.search(r'<h1 class="xv-video-title">(.*?)</h1>', html, re.S)
        if mh:
            name = self._strip(mh.group(1))
        if not name:
            name = self._strip(vdata.get('vod_name') or '') or vid

        vclass = ''
        mc = re.search(r'分类：<a href="/index\.php/vod/type/id/\d+\.html">([^<]+)</a>', html)
        if mc:
            vclass = self._strip(mc.group(1))
        if not vclass:
            vclass = self._strip(vdata.get('vod_class') or '')

        hits = ''
        mhi = re.search(r'播放：<strong[^>]*>([\d,]+)</strong>\s*次', html)
        if mhi:
            hits = mhi.group(1)
        update = ''
        mu = re.search(r'更新：(\d{4}-\d{2}-\d{2})', html)
        if mu:
            update = mu.group(1)

        play_url = (cfg.get('url') or '').replace('\\/', '/')
        pic = self._derive_pic(play_url)

        actor = self._strip(vdata.get('vod_actor') or '')
        director = self._strip(vdata.get('vod_director') or '')
        desc_bits = []
        if vclass:
            desc_bits.append('分类：' + vclass)
        if hits:
            desc_bits.append('播放：' + hits + '次')
        if update:
            desc_bits.append('更新：' + update)
        desc = '　'.join(desc_bits) if desc_bits else name

        remark = '更新至' + update if update else 'HD'

        vod = {
            'vod_id': vid,
            'vod_name': name,
            'vod_pic': pic,
            'vod_year': '',
            'vod_area': '',
            'type_name': vclass,
            'vod_lang': '',
            'vod_remarks': remark,
            'vod_actor': actor,
            'vod_director': director,
            'vod_content': _CP + ' ' + desc,
            'vod_play_from': _LN,
            'vod_play_url': '第01集$%s-1-1' % vid,
        }
        return {'list': [vod]}

    def playerContent(self, flag, id, vipFlags=None):
        pid = str(id or '').strip().strip('/')
        if pid.startswith('http'):
            return self._play(pid)
        parts = pid.split('-')
        vid = parts[0]
        sid = parts[1] if len(parts) > 1 and parts[1].isdigit() else '1'
        nid = parts[2] if len(parts) > 2 and parts[2].isdigit() else '1'

        play_url = '%s/index.php/vod/play/id/%s/sid/%s/nid/%s.html' % (
            self.host, vid, sid, nid)

        self._throttle('play', 0.3)
        html = self._get(play_url)
        if not html:
            return {'parse': 1, 'url': play_url, 'header': self._play_header()}

        cfg = self._extract_player(html)
        if not cfg:
            return {'parse': 1, 'url': play_url, 'header': self._play_header()}

        raw = (cfg.get('url') or '').replace('\\/', '/').strip()
        enc = str(cfg.get('encrypt', 0))
        if enc == '1':
            try:
                raw = urllib.parse.unquote(raw)
            except Exception:
                pass

        if raw.startswith('http') and self.isVideoFormat(raw):
            return {'parse': 0, 'jx': 0, 'url': raw, 'header': self._play_header()}

        return {'parse': 1, 'jx': 1, 'url': play_url, 'header': self._play_header()}

    def _play_header(self):
        return {
            'User-Agent': self.UA,
            'Referer': self.host + '/',
            'Accept': '*/*',
        }

    def _play(self, url):
        url = (url or '').replace('\\/', '/')
        if self.isVideoFormat(url):
            return {'parse': 0, 'jx': 0, 'url': url, 'header': self._play_header()}
        return {'parse': 1, 'jx': 1, 'url': url, 'header': self._play_header()}

    def searchContent(self, key, quick, pg='1'):
        return self.searchContentPage(key, quick, pg)

    def searchContentPage(self, key, quick, pg='1'):
        try:
            page = int(pg or 1)
        except Exception:
            page = 1
        if page < 1:
            page = 1

        wd = (key or '').strip()
        if not wd:
            return {'list': [], 'page': 1, 'pagecount': 0, 'limit': 0, 'total': 0}

        wd_q = urllib.parse.quote(wd)
        if page > 1:
            url = '%s/index.php/vod/search/page/%d/wd/%s.html' % (self.host, page, wd_q)
        else:
            url = '%s/index.php/vod/search/wd/%s.html' % (self.host, wd_q)

        self._throttle('search', 0.8)
        html = self._get(url)
        vods = self._parse_list(html)
        pagecount = self._parse_pagecount(html, page)
        if not vods and page > 1:
            pagecount = page

        return {
            'list': vods,
            'page': page,
            'pagecount': pagecount,
            'limit': len(vods) or 28,
            'total': len(vods),
        }
