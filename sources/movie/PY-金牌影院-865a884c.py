# LumeSource: {"id":"pypack_7a942e6e865a884c","name":"金牌影院","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
"""
================================================================
 金牌影院 (jpyy2.com) —— CatPawPlayer / TVBox 通用 «PY 源»
================================================================
 对接的是站点自家 App 接口 /api/mw-movie/*（与网页同源），接口签名已复刻：

     sign = sha1( md5( "<k=v&k=v 按 key 升序、去掉空值>&key=<signKey>&t=<毫秒时间戳>" ) )
     请求头: client-type: 3 / t / sign / deviceId(UUID) / authorization(Bearer <token>)

 站点能力:
   分类        GET /anonymous/get/filer/type
   分类筛选    GET /anonymous/v1/get/filer/list?type1=<分类>
   列表        GET /anonymous/video/list   {type1, v_class, area, year, lang, sort, sortBy, pageNum, pageSize}
   搜索        GET /anonymous/video/searchByWord   {keyword, pageNum, pageSize}
   详情        GET /anonymous/video/detail   {id}
   播放地址    GET /anonymous/v2/video/episode/url   {clientType, id, nid}
               → 多码率 m3u8：蓝光1080 / 高清720 / 标清480
               needLogin=true 只是网页端的 UI 提示（提示登录后可在网页选该清晰度），
               实测三条线不管登录与否都能拉流，真正的门槛是取链/拉流 IP 一致（见下）。
               本源默认取**最高码率（蓝光）**，配置 "quality":"720" 可指定。

 重要: 筛选项的值是**中文文本**（如 v_class=动作 / area=中国大陆 / year=2026 / lang=国语），
      不是筛选字典里的数字 id —— 实测数字 id 会返回 0 条。

 可配置项（写在播放器源的 ext / 配置里，JSON 或 k=v 都认）:
     {"host": "https://m.vv3nwjk.com",   // 手动指定域名（默认自动解析 jpyy2.com 的当前跳转域名）
      "token": "<登录后的 token>"}        // 可选：登录后能播 1080/720 蓝光线路

 播放 IP 一致性（重点）:
   该站 CDN 会把播放地址与"取地址时的出口 IP"绑定（URL 里的 whip 参数），
   而播放器拉流是不走系统代理的（直连宽带）。所以本源内部**强制直连**
   （requests 关 trust_env、urllib 空 ProxyHandler），避免"取链接走代理、
   拉流走直连"造成 IP 不一致而被 CDN 拒绝(403 the source ip is forbidden)。
   如果你的网络必须走代理才能播，配置里加 {"direct": false}。

 可配置项（写在播放器源的 ext / 配置里，JSON 或 k=v 都认）:
     {"host": "https://m.vv3nwjk.com",   // 手动指定域名（默认自动解析 jpyy2.com 的当前跳转域名）
      "token": "<登录后的 token>",         // 可选（备而不用，见上：清晰度不由登录决定）
      "quality": "1080",                   // 可选：指定清晰度 1080/720/480，默认取最高
      "direct": true}                      // 默认 true：源内部直连（绕开系统代理）
================================================================
"""

import hashlib
import json
import re
import sys
import time
import uuid
import urllib.request
from urllib.parse import urlencode

try:
    from base.spider import Spider as _BaseSpider
except Exception:
    class _BaseSpider(object):
        def log(self, msg):
            pass

try:
    import requests
except Exception:
    requests = None


SIGN_KEY = "cb808529bae6b6be45ecfab29a4889bc"
ENTRY = "https://jpyy2.com"          # 入口域名（会跳转到当时的可用域名）
KNOWN_HOSTS = ["https://m.vv3nwjk.com", "https://vv3nwjk.com"]
UA = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

# 排序（网页端定义）: 电影/动漫 -> 1 上映时间, 3 人气, 4 评分; 剧集/综艺 另有 2 添加时间
SORT_ITEMS = [("最新", "1"), ("最热", "3"), ("评分", "4")]


class Spider(_BaseSpider):

    # ------------------------------------------------------------------ 基础
    def init(self, extend=''):
        self.cfg = {}
        ext = (extend or '').strip()
        if ext:
            try:
                self.cfg = json.loads(ext)
            except Exception:
                for kv in ext.split('&'):
                    if '=' in kv:
                        k, v = kv.split('=', 1)
                        self.cfg[k.strip()] = v.strip()
        if not isinstance(self.cfg, dict):
            self.cfg = {}
        self.host = (self.cfg.get('host') or '').rstrip('/')
        self.token = self.cfg.get('token') or ''
        self.device = self.cfg.get('deviceId') or str(uuid.uuid4())
        self.direct = str(self.cfg.get('direct', 'true')).lower() not in ('0', 'false', 'no')
        self._cat_cache = None
        self._filter_cache = {}
        self._http = None
        if self.host:
            try:
                self._cat_list()
            except Exception:
                self.host = ''

    def getName(self):
        return "金牌影院"

    def destroy(self):
        pass

    # ------------------------------------------------------------------ HTTP
    # 强制直连：requests 关 trust_env（不吃 Windows 系统代理/环境变量），urllib 用空代理表。
    # 原因见文件头「播放 IP 一致性」。
    def _client(self):
        if self._http is None:
            if requests is not None:
                s = requests.Session()
                if self.direct:
                    s.trust_env = False
                    s.proxies = {}
                s.headers.update({'User-Agent': UA})
                self._http = ('requests', s)
            elif self.direct:
                self._http = ('urllib', urllib.request.build_opener(urllib.request.ProxyHandler({})))
            else:
                self._http = ('urllib', urllib.request.build_opener())
        return self._http

    def _get(self, url, headers=None, timeout=20, allow_redirects=True):
        h = {'User-Agent': UA}
        if headers:
            h.update(headers)
        kind, cli = self._client()
        if kind == 'requests':
            return cli.get(url, headers=h, timeout=timeout, allow_redirects=allow_redirects)
        req = urllib.request.Request(url, headers=h)
        return cli.open(req, timeout=timeout)

    def _resolve_host(self):
        """域名会换：先看手动配置，再解析 jpyy2.com 的跳转，最后试已知域名。"""
        cands = []
        if self.host:
            cands.append(self.host)
        try:
            loc = ''
            if requests is not None:
                s = requests.Session()
                if self.direct:
                    s.trust_env = False
                    s.proxies = {}
                r = s.get(ENTRY, headers={'User-Agent': UA}, timeout=12, allow_redirects=False)
                loc = r.headers.get('Location') or ''
            m = re.match(r'https?://([^/]+)', loc)
            if m:
                dom = re.sub(r'^www\.', '', m.group(1))
                for h in ('https://m.' + dom, 'https://' + dom):
                    if h not in cands:
                        cands.append(h)
        except Exception:
            pass
        for h in KNOWN_HOSTS:
            if h not in cands:
                cands.append(h)
        self.host = cands[0].rstrip('/')
        return self.host

    # ------------------------------------------------------------------ 接口
    def _sign(self, params):
        t = str(int(time.time() * 1000))
        items = sorted((k, v) for k, v in (params or {}).items()
                       if v not in (None, '', []))
        body = '&'.join('%s=%s' % (k, v) for k, v in items)
        raw = (body + '&' if body else '') + 'key=%s&t=%s' % (SIGN_KEY, t)
        sig = hashlib.sha1(hashlib.md5(raw.encode('utf-8')).hexdigest().encode()).hexdigest()
        return sig, t

    def _api(self, path, params=None, _retry=True):
        if not self.host:
            self._resolve_host()
        params = dict(params or {})
        sig, t = self._sign(params)
        url = self.host + '/api/mw-movie' + path
        if params:
            url += ('&' if '?' in url else '?') + urlencode(params)
        headers = {
            'client-type': '3', 't': t, 'sign': sig,
            'deviceId': self.device,
            'authorization': ('Bearer %s' % self.token) if self.token else '',
            'Referer': self.host + '/',
        }
        try:
            resp = self._get(url, headers=headers)
            data = resp.json() if hasattr(resp, 'json') else json.loads(resp)
        except Exception as e:
            if _retry:
                # 域名可能又换了：重新解析一次再试
                self._resolve_host()
                return self._api(path, params, _retry=False)
            raise
        code = data.get('code')
        if code not in (200, '200'):
            raise RuntimeError('api %s -> %s %s' % (path, code, data.get('msg')))
        return data.get('data')

    # ------------------------------------------------------------------ 首页
    def homeContent(self, filter):
        types = self._cat_list()
        classes = [{'type_id': str(t.get('typeId')), 'type_name': t.get('typeName')}
                   for t in types]
        filters = {}
        for c in classes:
            fl = self._filters(c['type_id'])
            if fl:
                filters[c['type_id']] = fl
        return {'class': classes, 'filters': filters}

    def homeVideoContent(self):
        try:
            d = self._api('/anonymous/video/list',
                          {'type1': '1', 'pageNum': '1', 'pageSize': '12', 'sort': '1', 'sortBy': '1'})
            return {'list': [self._to_vod(v) for v in (d.get('list') or [])]}
        except Exception:
            return {'list': []}

    def _cat_list(self):
        if self._cat_cache is None:
            data = self._api('/anonymous/get/filer/type') or []
            self._cat_cache = [t for t in data if t.get('typeName')]
        return self._cat_cache

    def _filters(self, tid):
        """分类的筛选组：剧情(class)/地区(area)/年份(year)/语言(lang)/排序(sort)，值都用中文文本。"""
        if tid in self._filter_cache:
            return self._filter_cache[tid]
        groups = []
        try:
            data = self._api('/anonymous/v1/get/filer/list', {'type1': tid}) or {}
            g = data.get(tid) or (list(data.values())[0] if data else {})
            for key, name, field in [('class', '剧情', 'plotList'),
                                     ('area', '地区', 'districtList'),
                                     ('year', '年份', 'yearList'),
                                     ('lang', '语言', 'languageList')]:
                items = g.get(field) or []
                if not items:
                    continue
                vals = [{'n': '全部', 'v': ''}]
                for it in items:
                    text = it.get('itemText') or ''
                    if text:
                        vals.append({'n': text, 'v': text})
                groups.append({'key': key, 'name': name, 'value': vals})
        except Exception:
            pass
        if groups:
            groups.append({'key': 'sort', 'name': '排序',
                           'value': [{'n': n, 'v': v} for n, v in SORT_ITEMS]})
        self._filter_cache[tid] = groups
        return groups

    # ------------------------------------------------------------------ 列表
    def categoryContent(self, tid, pg, filter, extend):
        extend = extend or {}
        if isinstance(extend, str):
            try:
                extend = json.loads(extend)
            except Exception:
                extend = {}
        params = {
            'type1': str(tid),
            'pageNum': str(pg or 1),
            'pageSize': '30',
            'sort': str(extend.get('sort') or 1),
            'sortBy': '1',
        }
        if extend.get('class'):
            params['v_class'] = extend['class']
        if extend.get('area'):
            params['area'] = extend['area']
        if extend.get('year'):
            params['year'] = extend['year']
        if extend.get('lang'):
            params['lang'] = extend['lang']
        d = self._api('/anonymous/video/list', params) or {}
        return {
            'list': [self._to_vod(v) for v in (d.get('list') or [])],
            'page': int(d.get('pageNum') or pg or 1),
            'pagecount': int(d.get('totalPage') or 1),
            'limit': int(d.get('pageSize') or 30),
            'total': int(d.get('totalCount') or 0),
        }

    def searchContent(self, key, quick, pg='1'):
        d = self._api('/anonymous/video/searchByWord',
                      {'keyword': key, 'pageNum': str(pg or 1), 'pageSize': '20'}) or {}
        r = d.get('result') or {}
        lst = list(r.get('list') or [])
        tr = (d.get('typeResult') or {}).get('list') or []
        seen = {str(v.get('vodId')) for v in lst}
        for v in tr:
            if str(v.get('vodId')) not in seen:
                lst.append(v)
        return {'list': [self._to_vod(v) for v in lst], 'page': pg}

    # ------------------------------------------------------------------ 详情
    def detailContent(self, ids):
        vid = str(ids[0] if isinstance(ids, (list, tuple)) else ids)
        d = self._api('/anonymous/video/detail', {'id': vid}) or {}
        eps = sorted(d.get('episodeList') or [], key=lambda x: x.get('sort') or 0)
        if not eps:
            return {'list': []}
        one = len(eps) == 1
        parts = []
        for e in eps:
            name = '正片' if one else (str(e.get('name') or e.get('sort') or ''))
            parts.append('%s$jpyy|%s|%s' % (name, vid, e.get('nid')))
        vod = {
            'vod_id': vid,
            'vod_name': d.get('vodName') or '',
            'vod_pic': d.get('vodPic') or '',
            'vod_remarks': d.get('vodRemarks') or '',
            'vod_year': str(d.get('vodYear') or ''),
            'vod_area': d.get('vodArea') or '',
            'vod_actor': d.get('vodActor') or '',
            'vod_director': d.get('vodDirector') or '',
            'vod_content': re.sub(r'<[^>]+>', '', d.get('vodContent') or '').strip(),
            'vod_score': str(d.get('vodScore') or ''),
            'vod_play_from': '金牌线路',
            'vod_play_url': '#'.join(parts),
        }
        return {'list': [vod]}

    # ------------------------------------------------------------------ 播放
    def playerContent(self, flag, id, vipFlags):
        vid, nid = self._parse_play_id(id)
        if not vid:
            return {'parse': 1, 'playUrl': '', 'url': id}
        d = self._api('/anonymous/v2/video/episode/url',
                      {'clientType': '3', 'id': vid, 'nid': nid}) or {}
        lines = [l for l in (d.get('list') or []) if l.get('url')]
        if not lines:
            return {'parse': 1, 'playUrl': '', 'url': ''}
        # needLogin 只是网页 UI 提示，不代表拉流受限；默认取最高码率（蓝光1080）
        want = str(self.cfg.get('quality') or '').strip()
        pick = [l for l in lines if str(l.get('resolution')) == want] or lines
        pick = sorted(pick, key=lambda x: x.get('resolution') or 0, reverse=True)[0]
        return {
            'parse': 0,
            'playUrl': '',
            'url': pick.get('url') or '',
            'header': {'User-Agent': UA, 'Referer': self.host + '/'},
        }

    @staticmethod
    def _parse_play_id(id):
        s = str(id or '')
        if s.startswith('jpyy|'):
            p = s.split('|')
            if len(p) >= 3:
                return p[1], p[2]
        if '|' in s:
            p = s.split('|')
            if len(p) >= 2:
                return p[0], p[1]
        return s, ''

    def isVideoFormat(self, url):
        return bool(re.search(r'\.(m3u8|mp4|flv|mkv|ts)(\?|$)', url or '', re.I))

    # ------------------------------------------------------------------ 工具
    def _to_vod(self, v):
        d = {
            'vod_id': str(v.get('vodId') or ''),
            'vod_name': v.get('vodName') or '',
            'vod_pic': v.get('vodPic') or '',
            'vod_remarks': v.get('vodRemarks') or v.get('vodSub') or '',
        }
        for src, dst in (('vodYear', 'vod_year'), ('vodArea', 'vod_area'),
                         ('vodActor', 'vod_actor'), ('vodDirector', 'vod_director'),
                         ('vodScore', 'vod_score'), ('typeName', 'type_name')):
            if v.get(src) not in (None, ''):
                d[dst] = str(v.get(src))
        return d


# ----------------------------------------------------------------------
if __name__ == "__main__":
    sp = Spider()
    sp.init('')
    print('站名 :', sp.getName(), '| 当前域名:', sp.host)
    r = sp.homeContent(None)
    cats = r['class']
    print('分类 :', len(cats), [c['type_name'] for c in cats])
    for c in cats[:2]:
        fl = r['filters'].get(c['type_id']) or []
        print('  筛选[%s]:' % c['type_name'], [(g['name'], len(g['value'])) for g in fl])
    if cats:
        tid = cats[0]['type_id']
        rr = sp.categoryContent(tid, '1', False, {})
        print('列表[%s]: %d 条; 首条 = %s' % (tid, len(rr['list']), rr['list'][0]['vod_name'] if rr['list'] else '-'))
        if rr['list']:
            vid = rr['list'][0]['vod_id']
            det = sp.detailContent([vid])['list'][0]
            print('详情 :', det['vod_name'], '| 线路:', det['vod_play_from'], '| 集数:', len(det['vod_play_url'].split('#')))
            first = det['vod_play_url'].split('#')[0]
            name, _, pid = first.partition('$')
            pl = sp.playerContent('金牌线路', pid, None)
            print('播放 :', name, '->', {'parse': pl.get('parse'), 'url': (pl.get('url') or '')[:90]})
    s = sp.searchContent('哪吒', False, '1')
    print('搜索 :', len(s['list']), '条;', s['list'][0]['vod_name'] if s['list'] else '-')
